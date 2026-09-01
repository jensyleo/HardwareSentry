import Foundation

/// Watches Bonjour for `_scanner._tcp` (generic network scanner/WSD) and `_uscan._tcp`
/// (eSCL/AirScan) services on the local network.
///
/// Deliberately thin and untested, for the same reason `IOKitUSBDeviceSource` is: none of
/// it can run without a real device on the network. Everything worth reasoning about lives
/// in `ScannerMonitor`, behind `ScannerSource`.
///
/// Starting this is the first thing in HardwareSentry that would trigger macOS's Local
/// Network permission prompt — which is exactly why `MonitorRegistry` does not start it
/// automatically the way it does every other monitor.
public struct BonjourScannerSource: ScannerSource {
    public init() {}

    public func changes() -> AsyncStream<NetworkScannerChange> {
        AsyncStream { continuation in
            let watcher = BrowserPair(continuation: continuation)
            continuation.onTermination = { _ in watcher.stop() }
            watcher.start()
        }
    }
}

/// Holds the two `NetServiceBrowser`s (one per service type) and their delegate. A plain
/// `NSObject` subclass, the same shape as `SystemNotificationResponder` in `SignalCore`:
/// `NetServiceBrowserDelegate` callbacks are not actor-isolated, so the delegate has to be
/// something that can receive them unisolated and forward into the stream.
private final class BrowserPair: NSObject, NetServiceBrowserDelegate, NetServiceDelegate, @unchecked Sendable {
    private let continuation: AsyncStream<NetworkScannerChange>.Continuation
    private var scannerTCP: NetServiceBrowser?
    private var uscan: NetServiceBrowser?
    /// Keeps a strong reference to every currently-known service so it isn't deallocated
    /// while still resolving — `NetServiceBrowser` does not retain them.
    private var known: [String: NetService] = [:]
    /// Services whose sighting has already been announced, so the two ways resolution can
    /// end — success and failure — cannot both report the same scanner.
    private var announced: Set<String> = []

    /// How long to wait for a scanner to answer with its TXT record before announcing it
    /// without one. Long enough for a device that is merely slow, short enough that the
    /// sighting is still news by the time it arrives.
    private static let resolveTimeout: TimeInterval = 3

    init(continuation: AsyncStream<NetworkScannerChange>.Continuation) {
        self.continuation = continuation
    }

    func start() {
        let scannerTCP = NetServiceBrowser()
        scannerTCP.delegate = self
        scannerTCP.searchForServices(ofType: "_scanner._tcp.", inDomain: "local.")
        self.scannerTCP = scannerTCP

        let uscan = NetServiceBrowser()
        uscan.delegate = self
        uscan.searchForServices(ofType: "_uscan._tcp.", inDomain: "local.")
        self.uscan = uscan
    }

    func stop() {
        scannerTCP?.stop()
        uscan?.stop()
        scannerTCP = nil
        uscan = nil
        // Any service still waiting to answer is told to stop first: a resolution that
        // completes after this would call into a continuation that has already finished.
        known.values.forEach { $0.stop() }
        known.removeAll()
        announced.removeAll()
        continuation.finish()
    }

    private func key(for service: NetService) -> String { "\(service.type)|\(service.name)" }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        known[key(for: service)] = service
        // Announced once resolution finishes rather than immediately: what makes the
        // notification worth reading is which scanner it is and where, and none of that
        // is known until the device answers. It is announced either way — see both
        // delegate callbacks below — so a scanner that never answers is not lost.
        service.delegate = self
        service.resolve(withTimeout: Self.resolveTimeout)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        let key = key(for: service)
        known.removeValue(forKey: key)
        announced.remove(key)
        service.stop()
        continuation.yield(.lost(name: service.name))
    }

    // MARK: Resolution

    func netServiceDidResolveAddress(_ service: NetService) {
        let txt = service.txtRecordData().map(NetService.dictionary(fromTXTRecord:)) ?? [:]
        announce(
            service,
            detail: ScannerDetail(
                txt: txt,
                serviceType: service.type,
                host: service.hostName,
                // `NetService` reports -1 until it has resolved a port.
                port: service.port > 0 ? service.port : nil
            )
        )
    }

    func netService(_ service: NetService, didNotResolve errorDict: [String: NSNumber]) {
        // A scanner that will not say anything about itself is still a scanner that
        // appeared, so this reports the sighting with nothing attached rather than
        // swallowing it.
        announce(service, detail: nil)
    }

    private func announce(_ service: NetService, detail: ScannerDetail?) {
        let key = key(for: service)
        guard known[key] != nil, announced.insert(key).inserted else { return }
        continuation.yield(.found(name: service.name, detail: detail))
    }
}
