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
private final class BrowserPair: NSObject, NetServiceBrowserDelegate, @unchecked Sendable {
    private let continuation: AsyncStream<NetworkScannerChange>.Continuation
    private var scannerTCP: NetServiceBrowser?
    private var uscan: NetServiceBrowser?
    /// Keeps a strong reference to every currently-known service so it isn't deallocated
    /// while still resolving — `NetServiceBrowser` does not retain them.
    private var known: [String: NetService] = [:]

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
        known.removeAll()
        continuation.finish()
    }

    private func key(for service: NetService) -> String { "\(service.type)|\(service.name)" }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        known[key(for: service)] = service
        continuation.yield(.found(name: service.name))
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        known.removeValue(forKey: key(for: service))
        continuation.yield(.lost(name: service.name))
    }
}
