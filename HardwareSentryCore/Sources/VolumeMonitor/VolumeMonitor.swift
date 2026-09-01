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
        .init(name: VolumeEvent.mounted.rawValue, title: "Volume mounted"),
        .init(name: VolumeEvent.unmounted.rawValue, title: "Volume unmounted"),
        .init(name: VolumeEvent.unsafeEject.rawValue, title: "Volume disappeared without being ejected", enabledByDefault: false),
        .init(name: VolumeEvent.lowSpace.rawValue, title: "Free space low", enabledByDefault: false)
    ]

    private let source: any VolumeSource
    private let context: MonitorContext
    private var watching: Task<Void, Never>?

    /// Paths Finder told us it's about to eject — a path that disappears WITHOUT having
    /// passed through here first was pulled out, not ejected.
    private var pathsExpectingUnmount: Set<String> = []
    private var pathsBelowSpaceThreshold: Set<String> = []

    public init(source: any VolumeSource, context: MonitorContext) {
        self.source = source
        self.context = context
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
    }

    private func handle(_ event: VolumeSourceEvent) async {
        switch event {
        case .mounted(let path, let name):
            await context.notify(VolumeEvent.mounted.rawValue, subject: path, title: "Volume Mounted", body: name)

        case .willUnmount(let path, _):
            pathsExpectingUnmount.insert(path)

        case .unmounted(let path, let name):
            let wasExpected = pathsExpectingUnmount.remove(path) != nil
            pathsBelowSpaceThreshold.remove(path)
            if !wasExpected {
                await context.notify(
                    VolumeEvent.unsafeEject.rawValue,
                    subject: path,
                    title: "Volume Ejected Unsafely",
                    body: "\(name) disappeared without being ejected first."
                )
            }
            await context.notify(VolumeEvent.unmounted.rawValue, subject: path, title: "Volume Unmounted", body: name)

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
                    body: "\(path) has \(Int(freePercent.rounded()))% free space left."
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
