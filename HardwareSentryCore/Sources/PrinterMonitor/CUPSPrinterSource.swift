import CCUPS
import Foundation

/// Polls CUPS's local destination list (`cupsGetDests`, the same call `lpstat -p` is built
/// on) and turns each read into a snapshot.
///
/// Deliberately thin and untested, for the same reason `IOKitUSBDeviceSource` is: it needs
/// a real CUPS daemon and real destinations to say anything interesting. Everything worth
/// reasoning about — the diffing that turns snapshots into connect/disconnect/error/default/
/// rejecting events — lives in `PrinterMonitor`, behind `PrinterSource`.
///
/// Polling, not push-driven: neither libcups nor AppKit's printing API exposes a
/// notification/KVO hook for "a printer was added" or "state changed" — confirmed in
/// HG4MAC's own history, including a reverted attempt to watch CUPS's config file directly
/// (root-owned, mode 0600 — an ordinary process cannot even open it).
public struct CUPSPrinterSource: PrinterSource {
    private let pollInterval: Duration

    public init(pollInterval: Duration = .seconds(8)) {
        self.pollInterval = pollInterval
    }

    public func changes() -> AsyncStream<PrinterSourceEvent> {
        AsyncStream { continuation in
            let task = Task {
                while !Task.isCancelled {
                    continuation.yield(.snapshot(Self.collect()))
                    continuation.yield(.jobs(active: Self.activeJobs(), recentlyEnded: Self.endedJobs()))
                    try? await Task.sleep(for: pollInterval)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func collect() -> [PrinterSnapshot] {
        var destsPtr: UnsafeMutablePointer<cups_dest_t>?
        let count = cupsGetDests(&destsPtr)
        defer { if let destsPtr { cupsFreeDests(count, destsPtr) } }
        guard let dests = destsPtr, count > 0 else { return [] }

        var result: [PrinterSnapshot] = []
        for i in 0..<Int(count) {
            let dest = dests[i]
            guard let namePtr = dest.name else { continue }
            let reasons = cupsGetOption("printer-state-reasons", dest.num_options, dest.options)
                .map { String(cString: $0) } ?? "none"
            let printerType = cupsGetOption("printer-type", dest.num_options, dest.options)
                .flatMap { UInt32(String(cString: $0)) } ?? 0

            func option(_ key: String) -> String? {
                guard let raw = cupsGetOption(key, dest.num_options, dest.options) else { return nil }
                let value = String(cString: raw)
                return value.isEmpty ? nil : value
            }

            result.append(PrinterSnapshot(
                name: String(cString: namePtr),
                isDefault: dest.is_default != 0,
                stateReasons: reasons,
                isRejectingJobs: (printerType & CUPS_PRINTER_REJECTING.rawValue) != 0,
                location: option("printer-location"),
                makeAndModel: option("printer-make-and-model"),
                connection: option("device-uri").flatMap(Self.connectionKind(fromDeviceURI:)),
                isShared: option("printer-is-shared") == "true",
                capabilities: Self.capabilities(printerType),
                // The marker attributes CUPS caches alongside the destination, which is
                // what `lpstat -l -p` prints. Absent on a printer that does not report its
                // consumables at all, and on one macOS has not yet talked to — in which
                // case there is nothing to warn about, which is the right answer rather
                // than a fabricated level.
                supplies: PrinterSupply.parse(
                    names: option("marker-names"),
                    levels: option("marker-levels"),
                    types: option("marker-types"),
                    lowLevels: option("marker-low-levels")
                )
            ))
        }
        return result
    }

    /// The jobs CUPS is still working on, across every destination.
    static func activeJobs() -> [PrintJob] {
        jobs(whichJobs: CUPS_WHICHJOBS_ACTIVE)
    }

    /// The jobs CUPS has finished with — printed, cancelled or aborted.
    ///
    /// Needed because the active list cannot say why a job left it. CUPS keeps a bounded
    /// history (`MaxJobs`, 500 by default), so a job that has just ended is reliably in
    /// here; one that is not is left unreported rather than guessed at.
    static func endedJobs() -> [PrintJob] {
        jobs(whichJobs: CUPS_WHICHJOBS_COMPLETED)
    }

    private static func jobs(whichJobs: Int32) -> [PrintJob] {
        var jobsPtr: UnsafeMutablePointer<cups_job_t>?
        // `myJobs: 1` — this user's own jobs. A Mac sharing its printer would otherwise
        // report the neighbours' documents by name, which is somebody else's business.
        let count = cupsGetJobs(&jobsPtr, nil, 1, whichJobs)
        defer { if let jobsPtr { cupsFreeJobs(count, jobsPtr) } }
        guard let list = jobsPtr, count > 0 else { return [] }

        return (0..<Int(count)).map { index in
            let job = list[index]
            return PrintJob(
                id: Int(job.id),
                title: job.title.map { String(cString: $0) } ?? "",
                printerName: job.dest.map { String(cString: $0) } ?? "",
                user: job.user.map { String(cString: $0) },
                // No copy count: `cups_job_t` does not carry one. Reading it would mean a
                // hand-built IPP request per job, and "how many copies" is not worth a
                // round trip to the printer for every poll — so the model keeps the field
                // for a caller that can fill it, and this source leaves it empty rather
                // than offering a switch that could never produce a line.
                sizeKilobytes: Int(job.size) > 0 ? Int(job.size) : nil,
                state: state(of: job.state)
            )
        }
    }

    private static func state(of state: ipp_jstate_t) -> PrintJobState {
        switch state {
        case IPP_JSTATE_PENDING: return .pending
        case IPP_JSTATE_HELD: return .held
        case IPP_JSTATE_PROCESSING: return .processing
        case IPP_JSTATE_STOPPED: return .stopped
        case IPP_JSTATE_CANCELED: return .canceled
        case IPP_JSTATE_ABORTED: return .aborted
        case IPP_JSTATE_COMPLETED: return .completed
        // An unrecognised state is treated as still running rather than as finished: the
        // wrong "your document printed" is worse than a job this never mentions again.
        default: return .processing
        }
    }

    /// A device URI's scheme says how the printer is reached — the same three-way split
    /// this monitor's own documentation uses to explain what it can see.
    static func connectionKind(fromDeviceURI uri: String) -> String? {
        guard let scheme = uri.split(separator: ":").first?.lowercased() else { return nil }
        switch scheme {
        case "usb": return "USB"
        case "bluetooth": return "Bluetooth"
        case "dnssd", "ipp", "ipps", "socket", "lpd", "http", "https": return "Network"
        default: return scheme.uppercased()
        }
    }

    /// Only the bits someone would recognise. `CUPS_PRINTER_COMMANDS` and friends describe
    /// how CUPS talks to the queue, which is not what "what can this printer do" means.
    static func capabilities(_ printerType: UInt32) -> String? {
        var named: [String] = []
        if printerType & CUPS_PRINTER_COLOR.rawValue != 0 { named.append("Color") }
        if printerType & CUPS_PRINTER_DUPLEX.rawValue != 0 { named.append("Duplex") }
        if printerType & CUPS_PRINTER_STAPLE.rawValue != 0 { named.append("Staple") }
        if printerType & CUPS_PRINTER_FAX.rawValue != 0 { named.append("Fax") }
        if printerType & CUPS_PRINTER_MFP.rawValue != 0 { named.append("Scanner (MFP)") }
        return named.isEmpty ? nil : named.joined(separator: ", ")
    }
}
