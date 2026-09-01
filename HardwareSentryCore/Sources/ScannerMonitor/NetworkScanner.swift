import Foundation

/// A network scanner appearing or disappearing from Bonjour discovery
/// (`_scanner._tcp` — generic network scanner/WSD — and `_uscan._tcp` — eSCL/AirScan).
public enum NetworkScannerChange: Sendable, Equatable {
    case found(name: String)
    case lost(name: String)
}

/// Where news of network scanners comes from.
public protocol ScannerSource: Sendable {
    func changes() -> AsyncStream<NetworkScannerChange>
}
