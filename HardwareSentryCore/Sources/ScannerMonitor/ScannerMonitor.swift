import Foundation
import SentryContract
import SignalCore

/// Says when a network scanner appears or disappears from Bonjour discovery.
///
/// Assembled like every other monitor, but the only one that does not run until someone
/// switches it on: browsing Bonjour is what triggers macOS's Local Network permission
/// prompt. HG4MAC shipped this off by default for exactly that reason, and the registry
/// honours the same choice through `enabledByDefault`.
public actor ScannerMonitor: Monitor {
    public static let category = ScannerEvent.category

    /// The one monitor that stays off until asked for. Browsing Bonjour is what makes
    /// macOS ask for permission to look at the local network, and a prompt nobody
    /// invited is worse than a feature nobody switched on.
    public static let enabledByDefault = false

    public static let events: [MonitorEventDescription] = [
        .init(name: ScannerEvent.found.rawValue, title: "Network scanner found", icon: .asset("ScannerMonitor-Icon-Found", in: .module)),
        .init(name: ScannerEvent.lost.rawValue, title: "Network scanner lost", icon: .asset("ScannerMonitor-Icon-Lost", in: .module)),
        // Both off. Unlike everything else in this application these two are not read from
        // something the system already knows: each one costs an HTTP request to the
        // scanner every few seconds, for as long as it is on the network. That is a real
        // cost to impose on somebody who has not asked for it.
        .init(name: ScannerEvent.scanStatus.rawValue, title: "Scan started / finished", enabledByDefault: false, icon: .asset("ScannerMonitor-Icon-Found", in: .module)),
        .init(name: ScannerEvent.adfStateChanged.rawValue, title: "Document feeder loaded / empty / jammed", enabledByDefault: false, icon: .asset("ScannerMonitor-Icon-Found", in: .module))
    ]

    public static let fields: [MonitorFieldDescription] = ScannerField.allCases.map {
        .init(name: $0.rawValue, title: $0.settingsTitle, shownByDefault: $0.shownByDefault)
    }

    private let source: any ScannerSource
    private let context: MonitorContext
    private let statusReader: (any ScannerStatusReading)?
    private let statusInterval: Duration
    private var watching: Task<Void, Never>?

    /// One polling task per scanner, so a scanner going away stops its own polling and
    /// nobody else's.
    private var polling: [String: Task<Void, Never>] = [:]
    /// The last status each scanner reported, so only changes are announced.
    private var lastStatus: [String: ScannerStatus] = [:]

    /// - Parameters:
    ///   - statusReader: how to ask a scanner what it is doing. Nil turns the whole of the
    ///     status polling off, which is what a host that only wants discovery passes.
    ///   - statusInterval: how often to ask. Clamped to something that cannot become a
    ///     flood: a stored value of zero would be a request as fast as the network allows.
    public init(
        source: any ScannerSource,
        context: MonitorContext,
        statusReader: (any ScannerStatusReading)? = nil,
        statusInterval: Duration = .seconds(10)
    ) {
        self.source = source
        self.context = context
        self.statusReader = statusReader
        self.statusInterval = max(.seconds(2), min(.seconds(300), statusInterval))
    }

    public func start() async {
        guard watching == nil else { return }

        watching = Task {
            for await change in self.source.changes() {
                guard !Task.isCancelled else { return }
                await self.handle(change)
            }
        }
    }

    public func stop() async {
        watching?.cancel()
        watching = nil
        for task in polling.values { task.cancel() }
        polling.removeAll()
        lastStatus.removeAll()
    }

    private func handle(_ change: NetworkScannerChange) async {
        await Self.report(change, through: context)

        switch change {
        case .found(let name, let detail):
            startPolling(name: name, detail: detail)
        case .lost(let name):
            polling.removeValue(forKey: name)?.cancel()
            lastStatus.removeValue(forKey: name)
        }
    }

    // MARK: - Asking what it is doing

    /// Starts asking one scanner about its state, if it told us where to ask.
    ///
    /// A scanner discovered without a resolved address is announced but not polled: there
    /// is nowhere to send the request, and guessing a hostname from a service name would
    /// be knocking on a stranger's door.
    private func startPolling(name: String, detail: ScannerDetail?) {
        guard let statusReader,
              let host = detail?.host,
              let port = detail?.port
        else { return }

        polling.removeValue(forKey: name)?.cancel()
        polling[name] = Task { [statusInterval] in
            while !Task.isCancelled {
                // Awaited before sleeping again, which is the whole in-flight guard: a
                // scanner taking six seconds to answer a poll every five cannot end up
                // with two requests outstanding, because the next sleep does not begin
                // until this read has come back.
                if let status = await statusReader.readStatus(host: host, port: port) {
                    await self.recordStatus(status, of: name)
                }
                try? await Task.sleep(for: statusInterval)
            }
        }
    }

    /// Reports what moved since the last reading, and nothing else.
    ///
    /// Reachable from a test on purpose, so which transitions are news can be checked
    /// without waiting out a poll interval — the same reason the power monitor's repeat is
    /// reachable. What the timer does is wiring; what this decides is the behaviour.
    func recordStatus(_ status: ScannerStatus, of name: String) async {
        let previous = lastStatus[name]
        lastStatus[name] = status

        // The first reading is the baseline. Without this, switching the feature on would
        // announce every scanner on the network as having just started being idle.
        guard let previous else { return }

        if let state = status.state, state != previous.state {
            await context.notify(
                ScannerEvent.scanStatus.rawValue,
                subject: name,
                title: Self.title(for: state, of: previous.state),
                body: await context.body([
                    .always(name),
                    .prose(ScannerField.statusReasons.rawValue, "Reason", status.reasonsNote)
                ]),
                icon: .asset("ScannerMonitor-Icon-Found", in: .module),
                // A scanner that has stopped mid-job is waiting for somebody; one that has
                // simply finished is not.
                priority: state == .stopped || state == .down ? .high : .normal
            )
        }

        if let adf = status.adfState, adf != previous.adfState {
            await context.notify(
                ScannerEvent.adfStateChanged.rawValue,
                subject: name,
                title: adf.title,
                body: await context.body([
                    .always(name),
                    .prose(ScannerField.statusReasons.rawValue, "Reason", status.reasonsNote)
                ]),
                icon: .asset("ScannerMonitor-Icon-Found", in: .module),
                priority: adf.needsAttention ? .high : .normal
            )
        }
    }

    /// Worded as the transition, not as the state.
    ///
    /// "Scan Started" and "Scan Finished" are what happened; "Processing" and "Idle" are
    /// what the protocol calls it, and reading "Idle" tells nobody that their document
    /// just came out.
    static func title(for state: ScannerState, of previous: ScannerState?) -> String {
        switch state {
        case .processing: return "Scan Started"
        case .idle where previous == .processing: return "Scan Finished"
        case .idle: return "Scanner Ready"
        case .stopped: return "Scanner Stopped"
        case .down: return "Scanner Unavailable"
        case .testing: return "Scanner Testing"
        }
    }

    private static func report(_ change: NetworkScannerChange, through context: MonitorContext) async {
        switch change {
        case .found(let name, let detail):
            await context.notify(
                ScannerEvent.found.rawValue,
                subject: name,
                title: "Network Scanner Found",
                body: await context.body([
                    .always(name),
                    // Left out when it just repeats the service name — plenty of scanners
                    // advertise the same string in both places, and a message that says
                    // the same thing twice reads as a bug.
                    .field(ScannerField.model.rawValue, "Model", detail?.model == name ? nil : detail?.model),
                    .field(ScannerField.location.rawValue, "Location", detail?.location),
                    .field(ScannerField.address.rawValue, "Address", detail?.addressNote),
                    .field(ScannerField.scanProtocol.rawValue, "Protocol", detail?.scanProtocol),
                    .field(ScannerField.inputSources.rawValue, "Sources", detail?.inputSources),
                    .field(ScannerField.duplex.rawValue, "Duplex", detail?.duplexNote),
                    .field(ScannerField.formats.rawValue, "Formats", detail?.formats),
                    .field(ScannerField.colorModes.rawValue, "Colour", detail?.colorModes),
                    .field(ScannerField.adminURL.rawValue, "Admin", detail?.adminURL)
                ]),
                icon: .asset("ScannerMonitor-Icon-Found", in: .module)
            )
        case .lost(let name):
            await context.notify(
                ScannerEvent.lost.rawValue,
                subject: name,
                title: "Network Scanner Lost",
                body: name,
                icon: .asset("ScannerMonitor-Icon-Lost", in: .module)
            )
        }
    }
}
