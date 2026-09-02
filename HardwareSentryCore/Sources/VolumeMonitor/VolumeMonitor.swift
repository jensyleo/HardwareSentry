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
    /// Where the low-space warning fires, and where it re-arms.
    ///
    /// Configurable because what counts as "low" depends on the disk: five percent of a
    /// 4 TB drive is 200 GB, which is not low, while five percent of a 128 GB one is
    /// genuinely tight.
    private var lowSpaceThresholdPercent: Double
    private var lowSpaceRecoverPercent: Double

    public static let events: [MonitorEventDescription] = [
        .init(name: VolumeEvent.mounted.rawValue, title: "Volume mounted", icon: .asset("DisksVolumes-Mounted", in: .module)),
        .init(name: VolumeEvent.unmounted.rawValue, title: "Volume unmounted", icon: .asset("DisksVolumes-Eject", in: .module)),
        .init(name: VolumeEvent.unsafeEject.rawValue, title: "Volume disappeared without being ejected", enabledByDefault: false, icon: .asset("Device-Unstable", in: .module)),
        .init(name: VolumeEvent.notReadable.rawValue, title: "Disk could not be read", icon: .asset("Device-Critical", in: .module)),
        .init(name: VolumeEvent.lowSpace.rawValue, title: "Free space low", enabledByDefault: false, icon: .asset("Device-Critical", in: .module))
    ]

    public static let fields: [MonitorFieldDescription] = VolumeField.allCases.map {
        .init(name: $0.rawValue, title: $0.settingsTitle, shownByDefault: $0.shownByDefault)
    }

    private let source: any VolumeSource
    private let context: MonitorContext
    private var watching: Task<Void, Never>?

    /// Paths Finder told us it's about to eject — a path that disappears WITHOUT having
    /// passed through here first was pulled out, not ejected.
    private var pathsExpectingUnmount: Set<String> = []
    private var expectedUnmountExpiries: [String: Task<Void, Never>] = [:]
    private let exclusions: VolumeExclusions
    private var unreadableTracker = UnreadableDiskTracker()
    /// How long a promised unmount is believed before the path goes back to being one a
    /// surprise removal can be reported for.
    private let unmountWaitNanoseconds: UInt64
    private var pathsBelowSpaceThreshold: Set<String> = []
    private var purgeableAwareFreeByPath: [String: String] = [:]
    /// Remembered at mount: by the time a volume goes away there is no filesystem left to
    /// ask what it was, so the artwork has to come from what was seen on the way in.
    private var kindByPath: [String: VolumeKind] = [:]

    public init(
        source: any VolumeSource,
        context: MonitorContext,
        unmountWait: Double = 600,
        exclusions: VolumeExclusions = VolumeExclusions(),
        lowSpaceThresholdPercent: Double = 5
    ) {
        self.source = source
        self.context = context
        self.unmountWaitNanoseconds = UInt64(unmountWait * 1_000_000_000)
        self.exclusions = exclusions
        self.lowSpaceThresholdPercent = lowSpaceThresholdPercent
        // Five points above, so coming back means space was actually freed rather than a
        // file being written and deleted around the line.
        self.lowSpaceRecoverPercent = lowSpaceThresholdPercent + 5
    }

    /// Takes a changed threshold while running.
    ///
    /// The set of volumes already reported as low is deliberately left alone: raising the
    /// threshold should not re-announce a volume that is already known to be low, and
    /// lowering it should not announce recovery on a volume whose free space never moved.
    /// Either way the next free-space reading settles it.
    public func apply(lowSpaceThresholdPercent percent: Double) {
        lowSpaceThresholdPercent = percent
        lowSpaceRecoverPercent = percent + 5
    }

    /// The path and name an event is about, when it is about one volume.
    ///
    /// The free-space snapshot covers every volume at once, so it has no single subject
    /// and is filtered per volume further in.
    private static func subject(of event: VolumeSourceEvent) -> (path: String, name: String)? {
        switch event {
        case .mounted(let path, let name, _): return (path, name)
        case .willUnmount(let path, let name): return (path, name)
        case .unmounted(let path, let name): return (path, name)
        // These cover several disks at once, or none — no single subject to match a
        // pattern against, so they are filtered per disk further in.
        case .freeSpaceSnapshot, .unreadable, .wholeDiskDisappeared: return nil
        }
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
        // Applied here rather than per case, so an excluded volume is passed over in both
        // directions. Silencing only its arrival would leave a list of departures for
        // things that never appeared.
        if let (path, name) = Self.subject(of: event), exclusions.excludes(path: path, name: name) {
            return
        }

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
                    // In the original's order: health and encryption first, because they
                    // are the two that would change what somebody does next.
                    .field(VolumeField.health.rawValue, "Drive Health", detail.healthNote),
                    .field(VolumeField.fileVault.rawValue, "Encrypted (FileVault)", detail.encryptedNote),
                    .field(VolumeField.format.rawValue, "Format", detail.format),
                    .field(VolumeField.uuid.rawValue, "Volume UUID", detail.uuid),
                    .field(VolumeField.removable.rawValue, "Removable", detail.removableNote),
                    // Only worth saying when it is true; most volumes are writable and
                    // saying so every time is noise.
                    .field(VolumeField.readOnly.rawValue, "Read-only", detail.isReadOnly ? "Yes" : nil),
                    .field(VolumeField.caseSensitive.rawValue, "Case-sensitive", detail.caseSensitiveNote),
                    .prose(VolumeField.interfaceType.rawValue, "Interface", detail.interfaceDescription),
                    .prose(VolumeField.busInfo.rawValue, "Bus", detail.busNote),
                    .prose(VolumeField.fileSystem.rawValue, "File system", detail.fileSystemType),
                    .prose(VolumeField.size.rawValue, "Size", detail.sizeLabel)
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
            // Remembered from the mount, because the low-space poll reads percentages
            // rather than re-reading each volume's resource values every five minutes.
            if let purgeable = detail.purgeableAwareFreeLabel { purgeableAwareFreeByPath[path] = purgeable }

        case .unreadable(let partitions, let readableWholeDisks):
            for report in unreadableTracker.consider(
                unreadable: partitions, readableWholeDisks: readableWholeDisks
            ) where !exclusions.excludes(path: report.wholeDiskName, name: report.displayName) {
                await context.notify(
                    VolumeEvent.notReadable.rawValue,
                    // Subjected on the whole disk, so one card is one thing however many
                    // partitions it turned out to have.
                    subject: report.wholeDiskName,
                    title: "Disk Not Readable",
                    body: report.message,
                    icon: .asset(kindByPath[report.wholeDiskName].map { "\($0.iconBaseName)-Critical" } ?? "Device-Critical", in: .module)
                )
            }

        case .wholeDiskDisappeared(let wholeDiskName):
            unreadableTracker.forget(wholeDiskName: wholeDiskName)

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
                self.forgetExpectedUnmount(path)
            }

        case .unmounted(let path, let name):
            expectedUnmountExpiries.removeValue(forKey: path)?.cancel()
            let wasExpected = pathsExpectingUnmount.remove(path) != nil
            let kind = kindByPath.removeValue(forKey: path)
            pathsBelowSpaceThreshold.remove(path)
            purgeableAwareFreeByPath.removeValue(forKey: path)
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
            if !wasBelow, freePercent <= lowSpaceThresholdPercent {
                pathsBelowSpaceThreshold.insert(path)
                let purgeable = purgeableAwareFreeByPath[path]
                await context.notify(
                    VolumeEvent.lowSpace.rawValue,
                    subject: path,
                    title: "Low Disk Space",
                    body: await context.body([
                        .always("\(path) has \(Int(freePercent.rounded()))% free space left."),
                        // The two figures can differ by a lot, and the difference is the
                        // difference between "act now" and "it will sort itself out".
                        .prose(
                            VolumeField.purgeableSpace.rawValue,
                            "Actually available (incl. purgeable)",
                            purgeable
                        )
                    ]),
                    icon: .asset("Device-Critical", in: .module)
                )
            } else if wasBelow, freePercent >= lowSpaceRecoverPercent {
                pathsBelowSpaceThreshold.remove(path)
            }
        }
        // A path that unmounted since the last poll drops its bookkeeping, so a future
        // re-mount of the same path starts fresh instead of staying "already reported".
        pathsBelowSpaceThreshold.formIntersection(byPath.keys)
    }
}
