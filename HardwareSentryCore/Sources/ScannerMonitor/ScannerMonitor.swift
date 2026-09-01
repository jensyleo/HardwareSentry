import Foundation
import SentryContract
import SignalCore

/// Says when a network scanner appears or disappears from Bonjour discovery.
///
/// Unlike every other monitor in `MonitorRegistry`, this one is not assembled and started
/// automatically — see `MonitorRegistry`'s doc comment on why. Bonjour discovery is what
/// triggers macOS's Local Network permission prompt, and HG4MAC shipped this off by
/// default specifically to keep that prompt from surprising anyone; HardwareSentry has no
/// preferences screen yet (C1) to offer the same opt-in.
public actor ScannerMonitor: Monitor {
    public static let category = ScannerEvent.category

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
                icon: .symbol("scanner")
            )
        case .lost(let name):
            await context.notify(
                ScannerEvent.lost.rawValue,
                subject: name,
                title: "Network Scanner Lost",
                body: name,
                icon: .symbol("scanner.fill")
            )
        }
    }
}
