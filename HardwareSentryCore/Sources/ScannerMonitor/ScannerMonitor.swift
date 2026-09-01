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
        .init(name: ScannerEvent.found.rawValue, title: "Network scanner found"),
        .init(name: ScannerEvent.lost.rawValue, title: "Network scanner lost")
    ]

    private let source: any ScannerSource
    private let context: MonitorContext
    private var watching: Task<Void, Never>?

    public init(source: any ScannerSource, context: MonitorContext) {
        self.source = source
        self.context = context
    }

    public func start() async {
        guard watching == nil else { return }

        watching = Task { [source, context] in
            for await change in source.changes() {
                guard !Task.isCancelled else { return }
                await Self.report(change, through: context)
            }
        }
    }

    public func stop() async {
        watching?.cancel()
        watching = nil
    }

    private static func report(_ change: NetworkScannerChange, through context: MonitorContext) async {
        switch change {
        case .found(let name):
            await context.notify(
                ScannerEvent.found.rawValue,
                subject: name,
                title: "Network Scanner Found",
                body: name,
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
