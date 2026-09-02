import AppKit
import Foundation
import SentryContract
import SignalCore

/// Says when a volume mounts or unmounts, when one disappears without being ejected first,
/// and when a mounted volume's free space drops below a threshold.
public actor VolumeMonitor: Monitor {
    public static let category = VolumeEvent.category

    /// Same hysteresis shape as `PrinterMonitor`'s toner/ink check and HG4MAC's own
    /// original: fire once crossing at/below the threshold, re-arm only once recovered
    /// comfortably above it, so a volume hovering right at the line can't spam notices.
    public static let lowSpaceThresholdPercent = 5.0
    public static let lowSpaceRecoverPercent = 10.0

    public static let events: [MonitorEventDescription] = [
        .init(name: VolumeEvent.mounted.rawValue, title: "Volume mounted", icon: .asset("DisksVolumes-Mounted", in: .module)),
        .init(name: VolumeEvent.unmounted.rawValue, title: "Volume unmounted", icon: .asset("DisksVolumes-Eject", in: .module)),
        .init(name: VolumeEvent.unsafeEject.rawValue, title: "Volume disappeared without being ejected", enabledByDefault: false, icon: .asset("Device-Unstable", in: .module)),
        .init(name: VolumeEvent.lowSpace.rawValue, title: "Free space low", enabledByDefault: false, icon: .asset("Device-Critical", in: .module))
    ]

    public static let fields: [MonitorFieldDescription] = [
        .init(name: VolumeField.path.rawValue, title: "Mount path", shownByDefault: VolumeField.path.shownByDefault),
        .init(name: VolumeField.fileSystem.rawValue, title: "File system type", shownByDefault: VolumeField.fileSystem.shownByDefault),
        .init(name: VolumeField.size.rawValue, title: "Volume size", shownByDefault: VolumeField.size.shownByDefault),
        .init(name: VolumeField.readOnly.rawValue, title: "Read-only flag", shownByDefault: VolumeField.readOnly.shownByDefault)
    ]

    private let source: any VolumeSource
    private let context: MonitorContext
    private var watching: Task<Void, Never>?

    /// Paths Finder told us it's about to eject — a path that disappears WITHOUT having
    /// passed through here first was pulled out, not ejected.
    private var pathsExpectingUnmount: Set<String> = []
    private var expectedUnmountExpiries: [String: Task<Void, Never>] = [:]
    /// How long a promised unmount is believed before the path goes back to being one a
    /// surprise removal can be reported for.
    private let unmountWaitNanoseconds: UInt64
    private var pathsBelowSpaceThreshold: Set<String> = []
    /// Remembered at mount: by the time a volume goes away there is no filesystem left to
    /// ask what it was, so the artwork has to come from what was seen on the way in.
    private var kindByPath: [String: VolumeKind] = [:]

    public init(source: any VolumeSource, context: MonitorContext, unmountWait: Double = 600) {
        self.source = source
        self.context = context
        self.unmountWaitNanoseconds = UInt64(unmountWait * 1_000_000_000)
    }

    /// Puts a path back to being one an unsafe ejection can be reported for.
    private func forgetExpectedUnmount(_ path: String) {
        expectedUnmountExpiries.removeValue(forKey: path)
        pathsExpectingUnmount.remove(path)
    }

    public func start() async {
        guard watching == nil else { return }

        watching = Task { [source] in
            for await event in source.changes() {
                guard !Task.isCancelled else { return }
                await self.handle(event)
            }
        }
    }

    public func stop() async {
        watching?.cancel()
        watching = nil
        expectedUnmountExpiries.values.forEach { $0.cancel() }
        expectedUnmountExpiries.removeAll()
    }

    private func handle(_ event: VolumeSourceEvent) async {
        switch event {
        case .mounted(let path, let name, let detail):
            await context.notify(
                VolumeEvent.mounted.rawValue,
                subject: path,
                // The volume's own name in the title, not a fixed word: with eight
                // volumes announced at once, a column of identical "Volume Mounted"
                // headings tells you nothing about which is which.
                title: "\(name) Mounted",
                body: await context.body([
                    .always("Click to open"),
                    .field(VolumeField.path.rawValue, path),
                    .prose(VolumeField.fileSystem.rawValue, "File system", detail.fileSystemType),
                    .prose(VolumeField.size.rawValue, "Size", detail.sizeLabel),
                    // Only worth saying when it is true; most volumes are writable and
                    // saying so every time is noise.
                    .field(VolumeField.readOnly.rawValue, "Read-only", detail.isReadOnly ? "Yes" : nil)
                ]),
                icon: .asset(detail.kind?.iconBaseName ?? "DisksVolumes-Mounted", in: .module),
                // Clicking a mount notification opens the volume, which is the one thing
                // somebody is likely to want the moment they are told it appeared.
                onInteraction: { outcome in
                    guard outcome == .clicked else { return }
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                }
            )
            if let kind = detail.kind { kindByPath[path] = kind }

        case .willUnmount(let path, _):
            pathsExpectingUnmount.insert(path)
            // Expires, because a `willUnmount` is a promise the system does not always
            // keep — an eject that stalls or is cancelled leaves the path marked
            // "expected" forever, and a later genuine yank of that same disk would then
            // never raise the unsafe-eject warning. Ten minutes, the original's figure.
            expectedUnmountExpiries[path]?.cancel()
            expectedUnmountExpiries[path] = Task { [unmountWaitNanoseconds] in
                try? await Task.sleep(nanoseconds: unmountWaitNanoseconds)
                guard !Task.isCancelled else { return }
                await self.forgetExpectedUnmount(path)
            }

        case .unmounted(let path, let name):
            expectedUnmountExpiries.removeValue(forKey: path)?.cancel()
            let wasExpected = pathsExpectingUnmount.remove(path) != nil
            let kind = kindByPath.removeValue(forKey: path)
            pathsBelowSpaceThreshold.remove(path)
            if !wasExpected {
                await context.notify(
                    VolumeEvent.unsafeEject.rawValue,
                    subject: path,
                    title: "Volume Ejected Unsafely",
                    body: "\(name) disappeared without being ejected first.",
                    icon: .asset(kind.map { "\($0.iconBaseName)-Critical" } ?? "Device-Critical", in: .module)
                )
            }
            await context.notify(
                VolumeEvent.unmounted.rawValue,
                subject: path,
                title: "\(name) Unmounted",
                body: "",
                icon: .asset(kind.map { "\($0.iconBaseName)-Unmounted" } ?? "DisksVolumes-Eject", in: .module)
            )

        case .freeSpaceSnapshot(let byPath):
            await handleFreeSpaceSnapshot(byPath)
        }
    }

    private func handleFreeSpaceSnapshot(_ byPath: [String: Double]) async {
        for (path, freePercent) in byPath {
            let wasBelow = pathsBelowSpaceThreshold.contains(path)
            if !wasBelow, freePercent <= Self.lowSpaceThresholdPercent {
                pathsBelowSpaceThreshold.insert(path)
                await context.notify(
                    VolumeEvent.lowSpace.rawValue,
                    subject: path,
                    title: "Low Disk Space",
                    body: "\(path) has \(Int(freePercent.rounded()))% free space left.",
                    icon: .asset("Device-Critical", in: .module)
                )
            } else if wasBelow, freePercent >= Self.lowSpaceRecoverPercent {
                pathsBelowSpaceThreshold.remove(path)
            }
        }
        // A path that unmounted since the last poll drops its bookkeeping, so a future
        // re-mount of the same path starts fresh instead of staying "already reported".
        pathsBelowSpaceThreshold.formIntersection(byPath.keys)
    }
}
