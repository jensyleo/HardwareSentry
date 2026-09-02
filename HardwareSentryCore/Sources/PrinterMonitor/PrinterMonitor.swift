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
        .init(name: PrinterEvent.rejectingJobs.rawValue, title: "Rejecting/accepting jobs", enabledByDefault: false, icon: .asset("PrinterMonitor-Icon-Rejecting", in: .module)),
        // Supply warnings are on: running out of toner is precisely the thing somebody
        // wants told, it fires rarely, and the hysteresis below stops it repeating.
        .init(name: PrinterEvent.supplyLow.rawValue, title: "Toner/ink running low", icon: .asset("PrinterMonitor-Icon-Disconnected", in: .module)),
        // The job events are off. Somebody who has just pressed Print knows they pressed
        // Print, and on a busy queue this is one notification per document.
        .init(name: PrinterEvent.jobStarted.rawValue, title: "Print job started", enabledByDefault: false, icon: .asset("PrinterMonitor-Icon-Connected", in: .module)),
        .init(name: PrinterEvent.jobFinished.rawValue, title: "Print job finished", enabledByDefault: false, icon: .asset("PrinterMonitor-Icon-Connected", in: .module)),
        .init(name: PrinterEvent.jobCanceled.rawValue, title: "Print job cancelled or aborted", enabledByDefault: false, icon: .asset("PrinterMonitor-Icon-Rejecting", in: .module))
    ]

    public static let fields: [MonitorFieldDescription] = PrinterField.allCases.map {
        .init(name: $0.rawValue, title: $0.settingsTitle, shownByDefault: $0.shownByDefault)
    }

    private let source: any PrinterSource
    private let context: MonitorContext
    private var watching: Task<Void, Never>?

    private var known: [String: PrinterSnapshot] = [:]
    private var lastKnownDefault: String?
    private var hasBaseline = false

    /// Jobs seen in the active list last time round, so a new one can be told from one
    /// that has been queued for ten minutes.
    private var knownJobIDs: Set<Int> = []
    private var hasJobBaseline = false
    /// Which supplies have already been reported low, keyed by printer and supply name.
    /// Without this, every poll while a cartridge is low would be another warning.
    private var reportedLowSupplies: Set<String> = []

    private let supplyThreshold: Int
    private let supplyRecoveryMargin: Int

    /// - Parameter supplyThresholdPercent: the level at which a supply counts as low, for
    ///   printers that do not publish a low mark of their own. Ten percent, which is where
    ///   the original drew the line.
    public init(
        source: any PrinterSource,
        context: MonitorContext,
        supplyThresholdPercent: Int = 10,
        supplyRecoveryMargin: Int = 5
    ) {
        self.source = source
        self.context = context
        self.supplyThreshold = min(90, max(1, supplyThresholdPercent))
        self.supplyRecoveryMargin = max(1, supplyRecoveryMargin)
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
            await handleSupplies(printers)
        case .jobs(let active, let recentlyEnded):
            await handleJobs(active: active, recentlyEnded: recentlyEnded)
        }
    }

    // MARK: - Supplies

    /// Warns once when a consumable runs low, and again only after it has been replaced.
    ///
    /// Edge-triggered on purpose: the printer keeps reporting eight percent for as long as
    /// there is eight percent left, and a poll every eight seconds would otherwise be a
    /// warning every eight seconds.
    private func handleSupplies(_ printers: [PrinterSnapshot]) async {
        var stillPresent: Set<String> = []

        for printer in printers {
            for supply in printer.supplies {
                let key = "\(printer.name)\u{0000}\(supply.name)"
                stillPresent.insert(key)
                let wasLow = reportedLowSupplies.contains(key)

                if !wasLow, supply.isLow(fallbackThreshold: supplyThreshold) {
                    reportedLowSupplies.insert(key)
                    await context.notify(
                        PrinterEvent.supplyLow.rawValue,
                        subject: printer.name,
                        title: Self.supplyTitle(for: supply),
                        body: await context.body([
                            .always(printer.name),
                            .prose(PrinterField.supplyLevels.rawValue, "Levels", Self.levelsNote(of: printer)),
                            .field(PrinterField.location.rawValue, "Location", printer.location),
                            .field(PrinterField.model.rawValue, "Model", printer.makeAndModel)
                        ]),
                        icon: .asset("PrinterMonitor-Icon-Disconnected", in: .module)
                    )
                } else if wasLow, supply.hasRecovered(fallbackThreshold: supplyThreshold, margin: supplyRecoveryMargin) {
                    // Replaced. Forgotten rather than announced: a fresh cartridge is not
                    // news, it is the absence of news.
                    reportedLowSupplies.remove(key)
                }
            }
        }

        // A printer that has gone away takes its supplies with it, so plugging it back in
        // reports a genuinely low cartridge again instead of staying silent forever.
        reportedLowSupplies.formIntersection(stillPresent)
    }

    /// Named in the title, because "toner" and "staples" are not the same urgency and the
    /// title is the part that gets read.
    static func supplyTitle(for supply: PrinterSupply) -> String {
        let level = supply.percentage.map { " (\($0)%)" } ?? ""
        return "\(supply.name) Low\(level)"
    }

    /// Every supply the printer reports, not just the low one: replacing a cartridge means
    /// looking at what else is nearly out while the printer is open anyway.
    static func levelsNote(of printer: PrinterSnapshot) -> String? {
        let notes = printer.supplies.compactMap(\.levelNote)
        return notes.isEmpty ? nil : notes.joined(separator: ", ")
    }

    // MARK: - Jobs

    private func handleJobs(active: [PrintJob], recentlyEnded: [PrintJob]) async {
        let activeIDs = Set(active.map(\.id))

        // The jobs already queued when this started are not news; only later ones are.
        guard hasJobBaseline else {
            hasJobBaseline = true
            knownJobIDs = activeIDs
            return
        }

        let endedByID = Dictionary(recentlyEnded.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        for job in active where !knownJobIDs.contains(job.id) {
            await context.notify(
                PrinterEvent.jobStarted.rawValue,
                subject: "\(job.printerName)#\(job.id)",
                title: "Printing \(job.displayTitle)",
                body: await jobBody(job),
                icon: .asset("PrinterMonitor-Icon-Connected", in: .module)
            )
        }

        for id in knownJobIDs.subtracting(activeIDs) {
            // Looked up in the finished list, because a job leaving the queue could have
            // printed, been cancelled, or been aborted by the printer, and those are three
            // different pieces of news.
            guard let job = endedByID[id] else { continue }

            switch job.state {
            case .completed:
                await context.notify(
                    PrinterEvent.jobFinished.rawValue,
                    subject: "\(job.printerName)#\(job.id)",
                    title: "Finished printing \(job.displayTitle)",
                    body: await jobBody(job),
                    icon: .asset("PrinterMonitor-Icon-Connected", in: .module)
                )
            case .canceled, .aborted:
                await context.notify(
                    PrinterEvent.jobCanceled.rawValue,
                    subject: "\(job.printerName)#\(job.id)",
                    title: job.state == .canceled
                        ? "Cancelled printing \(job.displayTitle)"
                        : "Print job failed: \(job.displayTitle)",
                    body: await jobBody(job),
                    icon: .asset("PrinterMonitor-Icon-Rejecting", in: .module)
                )
            default:
                // Left the active list without reaching a final state: CUPS moved it, or
                // the poll caught it mid-transition. Saying nothing is better than
                // guessing which of three things happened.
                continue
            }
        }

        knownJobIDs = activeIDs
    }

    private func jobBody(_ job: PrintJob) async -> String {
        await context.body([
            .field(PrinterField.jobPrinter.rawValue, "Printer", job.printerName),
            .field(PrinterField.jobOwner.rawValue, "Submitted by", job.user),
            .field(PrinterField.jobSize.rawValue, "Size", job.sizeNote)
        ])
    }

    private func handleSnapshot(_ printers: [PrinterSnapshot]) async {
        let current = Dictionary(uniqueKeysWithValues: printers.map { ($0.name, $0) })

        if !hasBaseline {
            hasBaseline = true
            // Remembered either way: which printer is the default is a fact about the
            // machine, not an event, and announcing "the default changed" at launch when
            // it has not changed would be a lie.
            lastKnownDefault = printers.first(where: \.isDefault)?.name
            // Falls through with nothing "known" when the startup sweep is meant to
            // speak: every item then reads as newly arrived, which is exactly what
            // "here is what is plugged in" means.
            guard context.announcesWhatIsAlreadyThere else {
                known = current
                return
            }
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
                    .prose(PrinterField.location.rawValue, "Location", printer.location),
                    .prose(PrinterField.model.rawValue, "Model", printer.makeAndModel),
                    .prose(PrinterField.connection.rawValue, "Connection", printer.connection),
                    .prose(PrinterField.shared.rawValue, "Shared", printer.isShared ? "Yes" : "No"),
                    .prose(PrinterField.capabilities.rawValue, "Capabilities", printer.capabilities)
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
