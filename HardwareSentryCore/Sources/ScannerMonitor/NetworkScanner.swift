import Foundation

/// A network scanner appearing or disappearing from Bonjour discovery
/// (`_scanner._tcp` — generic network scanner/WSD — and `_uscan._tcp` — eSCL/AirScan).
public enum NetworkScannerChange: Sendable, Equatable {
    /// `detail` is what the TXT record and resolution added. Nil when the service could
    /// not be resolved in time — the sighting is still worth announcing without it.
    case found(name: String, detail: ScannerDetail? = nil)
    case lost(name: String)
}

/// Where news of network scanners comes from.
public protocol ScannerSource: Sendable {
    func changes() -> AsyncStream<NetworkScannerChange>
}
