import Foundation

/// Asks a scanner over the network what it is doing.
///
/// eSCL is plain HTTP with an XML answer, so this is one GET and a parse — no framework
/// stands between the two. Untested for the same reason `BonjourScannerSource` is: it
/// needs a real scanner answering on a real network. The parsing, and every decision
/// about which change is worth a notification, live in `ScannerStatus` and
/// `ScannerMonitor` and are tested there.
public struct eSCLStatusReader: ScannerStatusReading {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        // Short, and deliberately shorter than any sensible poll interval: a scanner that
        // has been switched off must not leave a request outstanding when the next poll
        // comes round.
        configuration.timeoutIntervalForRequest = 4
        // Nothing here is worth caching: the whole point of each read is that it might
        // differ from the last one, and a cached answer would report a finished scan as
        // still running.
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        self.session = URLSession(configuration: configuration)
    }

    public func readStatus(host: String, port: Int) async -> ScannerStatus? {
        // The path eSCL fixes for this, with the trailing dot Bonjour puts on a hostname
        // trimmed — it is valid in DNS and rejected by URL parsing.
        let cleanHost = host.hasSuffix(".") ? String(host.dropLast()) : host
        guard var components = URLComponents(string: "http://\(cleanHost)") else { return nil }
        components.port = port
        components.path = "/eSCL/ScannerStatus"
        guard let url = components.url else { return nil }

        do {
            let (data, response) = try await session.data(from: url)
            // A 404 is a scanner that advertised eSCL and does not implement the status
            // endpoint, which several older ones do; its body is an error page, and
            // parsing that would be inventing a status out of an apology.
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return ScannerStatus.parse(escl: data)
        } catch {
            // Unreachable, timed out, refused. Nil rather than a thrown error: this runs
            // in a poll loop where a scanner being asleep is the ordinary case, not a
            // failure worth reporting.
            return nil
        }
    }
}
