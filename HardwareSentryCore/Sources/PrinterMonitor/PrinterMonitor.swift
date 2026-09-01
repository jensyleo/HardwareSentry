import Foundation
import SentryContract
import SignalCore

/// Says when a printer (CUPS destination — USB, Bluetooth, or network/AirPrint all end up
/// as one once macOS has added it) connects or disconnects, starts or stops needing
/// attention, starts or stops rejecting jobs, or the default printer changes.
public actor PrinterMonitor: Monitor {
    public static let category = PrinterEvent.category

    public static let events: [MonitorEventDescription] = [
        .init(name: PrinterEvent.connected.rawValue, title: "Printer connected", icon: .asset("PrinterMonitor-Icon-Connected", in: .module)),
        .init(name: PrinterEvent.disconnected.rawValue, title: "Printer disconnected", icon: .asset("PrinterMonitor-Icon-Disconnected", in: .module)),
        .init(name: PrinterEvent.error.rawValue, title: "Needs attention / OK", enabledByDefault: false, icon: .asset("PrinterMonitor-Icon-Disconnected", in: .module)),
        .init(name: PrinterEvent.defaultChanged.rawValue, title: "Default printer changed", enabledByDefault: false, icon: .asset("PrinterMonitor-Icon-DefaultChanged", in: .module)),
        .init(name: PrinterEvent.rejectingJobs.rawValue, title: "Rejecting/accepting jobs", enabledByDefault: false, icon: .asset("PrinterMonitor-Icon-Rejecting", in: .module))
    ]

    public static let fields: [MonitorFieldDescription] = [
        .init(name: PrinterField.location.rawValue, title: "Location", shownByDefault: false),
        .init(name: PrinterField.model.rawValue, title: "Make and model", shownByDefault: false),
        .init(name: PrinterField.connection.rawValue, title: "How it is connected", shownByDefault: false),
        .init(name: PrinterField.shared.rawValue, title: "Shared with other Macs", shownByDefault: false),
        .init(name: PrinterField.capabilities.rawValue, title: "Capabilities", shownByDefault: false)
    ]

    private let source: any PrinterSource
    private let context: MonitorContext
    private var watching: Task<Void, Never>?

    private var known: [String: PrinterSnapshot] = [:]
    private var lastKnownDefault: String?
    private var hasBaseline = false

    public init(source: any PrinterSource, context: MonitorContext) {
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

    private func handle(_ event: PrinterSourceEvent) async {
        switch event {
        case .snapshot(let printers):
            await handleSnapshot(printers)
        }
    }

    private func handleSnapshot(_ printers: [PrinterSnapshot]) async {
        let current = Dictionary(uniqueKeysWithValues: printers.map { ($0.name, $0) })

        if !hasBaseline {
            hasBaseline = true
            known = current
            lastKnownDefault = printers.first(where: \.isDefault)?.name
            return
        }

        let currentNames = Set(current.keys)
        let knownNames = Set(known.keys)

        for name in currentNames.subtracting(knownNames) {
            let printer = current[name]!
            await context.notify(
                PrinterEvent.connected.rawValue,
                subject: name,
                title: "Printer Connected",
                body: await context.body([
                    .always(name),
                    .field(PrinterField.location.rawValue, "Location", printer.location),
                    .field(PrinterField.model.rawValue, "Model", printer.makeAndModel),
                    .field(PrinterField.connection.rawValue, "Connection", printer.connection),
                    .field(PrinterField.shared.rawValue, "Shared", printer.isShared ? "Yes" : "No"),
                    .field(PrinterField.capabilities.rawValue, "Capabilities", printer.capabilities)
                ]),
                icon: .asset("PrinterMonitor-Icon-Connected", in: .module)
            )
        }
        for name in knownNames.subtracting(currentNames) {
            await context.notify(PrinterEvent.disconnected.rawValue, subject: name, title: "Printer Disconnected", body: name, icon: .asset("PrinterMonitor-Icon-Disconnected", in: .module))
        }

        for printer in printers {
            let previous = known[printer.name]

            let wasProblem = previous.map { PrinterStateReasons.indicatesProblem($0.stateReasons) } ?? false
            let isProblem = PrinterStateReasons.indicatesProblem(printer.stateReasons)
            if previous != nil, isProblem != wasProblem {
                await context.notify(
                    PrinterEvent.error.rawValue,
                    subject: printer.name,
                    title: isProblem ? "Printer Needs Attention" : "Printer OK",
                    body: isProblem
                        ? "\(printer.name)\n\(PrinterStateReasons.friendlyDescription(printer.stateReasons) ?? printer.stateReasons)"
                        : printer.name,
                    icon: .asset(isProblem ? "PrinterMonitor-Icon-Disconnected" : "PrinterMonitor-Icon-Connected", in: .module)
                )
            }

            if let previous, previous.isRejectingJobs != printer.isRejectingJobs {
                await context.notify(
                    PrinterEvent.rejectingJobs.rawValue,
                    subject: printer.name,
                    title: printer.isRejectingJobs ? "Printer Is Rejecting Jobs" : "Printer Is Accepting Jobs Again",
                    body: printer.name,
                    icon: .asset(printer.isRejectingJobs ? "PrinterMonitor-Icon-Rejecting" : "PrinterMonitor-Icon-Connected", in: .module)
                )
            }
        }

        if let newDefault = printers.first(where: \.isDefault)?.name, newDefault != lastKnownDefault {
            let previousDefault = lastKnownDefault
            lastKnownDefault = newDefault
            if let previousDefault {
                await context.notify(
                    PrinterEvent.defaultChanged.rawValue,
                    subject: "Default",
                    title: "Default Printer Changed",
                    body: "\(previousDefault) → \(newDefault)",
                    icon: .asset("PrinterMonitor-Icon-DefaultChanged", in: .module)
                )
            }
        }

        known = current
    }
}
