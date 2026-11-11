import AppKit
import Foundation
import Network
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

    /// Three rows per kind of drive — mounted, unmounted, low space — then the generics
    /// and the two that are about a drive going wrong rather than coming and going.
    public static let events: [MonitorEventDescription] = VolumeKind.allCases.flatMap { kind in
        [
            MonitorEventDescription(
                name: kind.mountedEvent.rawValue,
                title: kind.settingsTitle,
                icon: .asset(kind.iconBaseName, in: .module),
                iconKind: kind.iconKind
            ),
            MonitorEventDescription(
                name: kind.unmountedEvent.rawValue,
                title: "\(kind.settingsTitle) (Unmounted)",
                icon: .asset("\(kind.iconBaseName)-Unmounted", in: .module),
                iconKind: kind.iconKind
            ),
            MonitorEventDescription(
                name: kind.lowSpaceEvent.rawValue,
                title: "\(kind.settingsTitle) (Critical)",
                enabledByDefault: false,
                icon: .asset("\(kind.iconBaseName)-Critical", in: .module),
                iconKind: kind.iconKind
            )
        ]
    } + [
        .init(name: VolumeEvent.lowSpace.rawValue, title: "Critical (generic)", enabledByDefault: false, icon: .asset("Device-Critical", in: .module), iconKind: VolumeKind.genericIconKind),
        .init(name: VolumeEvent.mounted.rawValue, title: "Mounted (generic)", icon: .asset("DisksVolumes-Mounted", in: .module), iconKind: VolumeKind.genericIconKind),
        .init(name: VolumeEvent.unmounted.rawValue, title: "Unmounted (generic)", icon: .asset("DisksVolumes-Eject", in: .module), iconKind: VolumeKind.genericIconKind),
        .init(name: VolumeEvent.unsafeEject.rawValue, title: "Ejected Unsafely", enabledByDefault: false, icon: .asset("Device-Unstable", in: .module), iconKind: VolumeKind.genericIconKind),
        .init(name: VolumeEvent.notReadable.rawValue, title: "Disk Not Readable", icon: .asset("Device-Critical", in: .module), iconKind: VolumeKind.genericIconKind),
        // The network drive's own picture, marked rather than redrawn: it has no "not
        // answering" version, and the state is what these two are about.
        .init(name: VolumeEvent.notResponding.rawValue, title: "Network Drive Not Responding", icon: .asset(VolumeKind.nas.iconBaseName, in: .module), iconKind: VolumeKind.nas.iconKind),
        .init(name: VolumeEvent.responding.rawValue, title: "Network Drive Responding Again", icon: .asset(VolumeKind.nas.iconBaseName, in: .module), iconKind: VolumeKind.nas.iconKind)
    ]

    /// Said outright: the first event is now an optical disc, and this module is about
    /// every kind of volume.
    public static let icon: NotificationIcon = .asset("DisksVolumes-Mounted", in: .module)

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
    /// A `var` because the list is edited in a settings window while this is running.
    private var exclusions: VolumeExclusions
    private var unreadableTracker = UnreadableDiskTracker()
    /// How long a promised unmount is believed before the path goes back to being one a
    /// surprise removal can be reported for.
    private let unmountWaitNanoseconds: UInt64
    private var pathsBelowSpaceThreshold: Set<String> = []
    private var purgeableAwareFreeByPath: [String: String] = [:]
    /// Remembered at mount: by the time a volume goes away there is no filesystem left to
    /// ask what it was, so the artwork has to come from what was seen on the way in.
    private var kindByPath: [String: VolumeKind] = [:]

    // MARK: - Network drives that stop answering

    /// What is known about one mounted network volume's server.
    private struct NetworkVolumeState {
        let endpoint: NetworkVolumeEndpoint
        let name: String
        /// Whether the server has ever answered since this was mounted. Until it has, a
        /// failure is not news — it may be that this application is not allowed to reach
        /// the local network at all, which looks exactly like a server that is down.
        var hasResponded = false
        var failures = 0
        var isReportedDown = false
    }

    private let reachabilityProbe: (any NetworkReachabilityProbe)?
    private let reachabilityInterval: Duration
    /// How soon to ask again once an answer has failed once, so a real outage is confirmed
    /// in seconds rather than after a whole interval — and a blip is not mistaken for one.
    private let reachabilityFollowUp: Duration
    private let reachabilityTimeout: Duration
    private let watchesNetworkPath: Bool
    /// Consecutive failed checks before saying so.
    private let failuresBeforeReporting = 2
    private var networkVolumes: [String: NetworkVolumeState] = [:]
    private var reachabilityTask: Task<Void, Never>?
    private var reachabilitySleep: Task<Void, Never>?
    private var pathMonitor: NWPathMonitor?
    private var lastReachabilityRound: ContinuousClock.Instant?

    public init(
        source: any VolumeSource,
        context: MonitorContext,
        unmountWait: Double = 600,
        exclusions: VolumeExclusions = VolumeExclusions(),
        lowSpaceThresholdPercent: Double = 5,
        reachabilityProbe: (any NetworkReachabilityProbe)? = nil,
        reachabilityInterval: Duration = .seconds(10),
        reachabilityFollowUp: Duration = .seconds(3),
        reachabilityTimeout: Duration = .seconds(3),
        watchesNetworkPath: Bool = false
    ) {
        self.reachabilityProbe = reachabilityProbe
        self.reachabilityInterval = reachabilityInterval
        self.reachabilityFollowUp = reachabilityFollowUp
        self.reachabilityTimeout = reachabilityTimeout
        self.watchesNetworkPath = watchesNetworkPath
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
    public func apply(lowSpaceThresholdPercent percent: Double, exclusions: VolumeExclusions) {
        lowSpaceThresholdPercent = percent
        lowSpaceRecoverPercent = percent + 5
        // A volume already announced stays announced: adding it to the list means "stop
        // telling me about this", not "pretend the last hour did not happen".
        self.exclusions = exclusions
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
        startReachabilityChecks()
    }

    public func stop() async {
        watching?.cancel()
        watching = nil
        expectedUnmountExpiries.values.forEach { $0.cancel() }
        expectedUnmountExpiries.removeAll()
        reachabilityTask?.cancel()
        reachabilityTask = nil
        reachabilitySleep?.cancel()
        reachabilitySleep = nil
        pathMonitor?.cancel()
        pathMonitor = nil
    }

    // MARK: - Reachability

    private func startReachabilityChecks() {
        guard reachabilityProbe != nil, reachabilityTask == nil else { return }
        reachabilityTask = Task { await self.reachabilityLoop() }

        guard watchesNetworkPath else { return }
        // The network changing is when a share is most likely to have just gone, so it
        // brings the next check forward instead of waiting out the interval.
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            guard let self else { return }
            Task { await self.checkSoon() }
        }
        monitor.start(queue: DispatchQueue(label: "VolumeMonitor.path", qos: .utility))
        pathMonitor = monitor
    }

    /// Ends the wait before the next check, so it happens now. Rate-limited: a network
    /// settling reports several changes in a row, and one check answers all of them.
    private func checkSoon() {
        if let last = lastReachabilityRound, ContinuousClock.now - last < .seconds(1) { return }
        reachabilitySleep?.cancel()
    }

    private func reachabilityLoop() async {
        var wait = reachabilityInterval
        while !Task.isCancelled {
            // A task of its own, so `checkSoon` can cut the wait short without cancelling
            // the loop.
            let pause = wait
            let sleep = Task<Void, Never> { _ = try? await Task.sleep(for: pause) }
            reachabilitySleep = sleep
            await sleep.value
            guard !Task.isCancelled else { return }

            lastReachabilityRound = .now
            let suspect = await runReachabilityRound()
            wait = suspect ? reachabilityFollowUp : reachabilityInterval
        }
    }

    /// Asks every mounted network volume's server whether it is answering, all at once.
    /// - Returns: whether any of them has just failed for the first time and wants asking
    ///   again soon.
    private func runReachabilityRound() async -> Bool {
        guard let probe = reachabilityProbe, !networkVolumes.isEmpty else { return false }
        let targets = networkVolumes.map { (path: $0.key, endpoint: $0.value.endpoint) }
        let timeout = reachabilityTimeout

        let answers = await withTaskGroup(of: (String, Bool).self) { group in
            for target in targets {
                group.addTask {
                    (target.path, await probe.isReachable(host: target.endpoint.host, port: target.endpoint.port, timeout: timeout))
                }
            }
            var collected: [(String, Bool)] = []
            for await answer in group { collected.append(answer) }
            return collected
        }

        var wantsAnotherLook = false
        for (path, reachable) in answers {
            // Gone while the question was out: nothing left to say about it.
            guard var state = networkVolumes[path] else { continue }
            var announcement: VolumeEvent?

            if reachable {
                state.hasResponded = true
                state.failures = 0
                if state.isReportedDown {
                    state.isReportedDown = false
                    announcement = .responding
                }
            } else if state.hasResponded {
                state.failures += 1
                if state.failures >= failuresBeforeReporting {
                    if !state.isReportedDown {
                        state.isReportedDown = true
                        announcement = .notResponding
                    }
                } else {
                    wantsAnotherLook = true
                }
            }
            // Written back before anything is awaited: another event can run while a
            // notification is being delivered.
            networkVolumes[path] = state

            if let announcement { await announce(announcement, path: path, state: state) }
        }
        return wantsAnotherLook
    }

    private func announce(_ event: VolumeEvent, path: String, state: NetworkVolumeState) async {
        let isDown = event == .notResponding
        await context.notify(
            event.rawValue,
            subject: path,
            title: isDown ? "\(state.name) Not Responding" : "\(state.name) Responding Again",
            body: await context.body([
                .always(isDown
                    ? "The server \(state.endpoint.host) is not answering. The drive is still mounted, but its files may not open until the network or the server is back."
                    : "The server \(state.endpoint.host) is answering again.")
            ]),
            icon: .asset(VolumeKind.nas.iconBaseName, in: .module),
            iconKind: VolumeKind.nas.iconKind,
            iconBadge: isDown ? .warning : .positive,
            showsIconBadge: true
        )
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
                // The row this drive's own kind owns; the generic one only for a volume
                // with no honest signal about what it is.
                (detail.kind?.mountedEvent ?? VolumeEvent.mounted).rawValue,
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
                    .prose(VolumeField.fileSystem.rawValue, "File system", detail.fileSystemLabel),
                    .prose(VolumeField.size.rawValue, "Size", detail.sizeLabel)
                ]),
                icon: .asset(detail.kind?.iconBaseName ?? "DisksVolumes-Mounted", in: .module),
                iconKind: detail.kind?.iconKind ?? VolumeKind.genericIconKind,
                iconBadge: .positive,
                // Clicking a mount notification opens the volume, which is the one thing
                // somebody is likely to want the moment they are told it appeared.
                onInteraction: { outcome in
                    guard outcome == .clicked else { return }
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                }
            )
            if let kind = detail.kind { kindByPath[path] = kind }
            // Only a network drive has a server to ask, and only while this is checking.
            if reachabilityProbe != nil, detail.kind == .nas,
               let endpoint = NetworkVolumeEndpoint.parse(mountSource: detail.mountSource, fileSystemType: detail.fileSystemType) {
                networkVolumes[path] = NetworkVolumeState(endpoint: endpoint, name: name)
                // Asked now rather than after an interval, so the baseline — "this server
                // does answer" — exists before it matters.
                checkSoon()
            }
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
                    icon: .asset(kindByPath[report.wholeDiskName].map { "\($0.iconBaseName)-Critical" } ?? "Device-Critical", in: .module),
                    iconKind: kindByPath[report.wholeDiskName]?.iconKind ?? VolumeKind.genericIconKind,
                    iconBadge: .warning
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
            networkVolumes.removeValue(forKey: path)
            pathsBelowSpaceThreshold.remove(path)
            purgeableAwareFreeByPath.removeValue(forKey: path)
            if !wasExpected {
                await context.notify(
                    VolumeEvent.unsafeEject.rawValue,
                    subject: path,
                    title: "Volume Ejected Unsafely",
                    body: "\(name) disappeared without being ejected first.",
                    icon: .asset(kind.map { "\($0.iconBaseName)-Critical" } ?? "Device-Critical", in: .module),
                    iconKind: kind?.iconKind ?? VolumeKind.genericIconKind,
                    iconBadge: .warning
                )
            }
            await context.notify(
                (kind?.unmountedEvent ?? VolumeEvent.unmounted).rawValue,
                subject: path,
                title: "\(name) Unmounted",
                body: "",
                icon: .asset(kind.map { "\($0.iconBaseName)-Unmounted" } ?? "DisksVolumes-Eject", in: .module),
                iconKind: kind?.iconKind ?? VolumeKind.genericIconKind,
                iconBadge: .negative
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
                    (kindByPath[path]?.lowSpaceEvent ?? VolumeEvent.lowSpace).rawValue,
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
                    icon: .asset("Device-Critical", in: .module),
                    iconKind: kindByPath[path]?.iconKind ?? VolumeKind.genericIconKind,
                    iconBadge: .warning
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
