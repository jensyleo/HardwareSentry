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

            result.append(PrinterSnapshot(
                name: String(cString: namePtr),
                isDefault: dest.is_default != 0,
                stateReasons: reasons,
                isRejectingJobs: (printerType & CUPS_PRINTER_REJECTING.rawValue) != 0
            ))
        }
        return result
    }
}
