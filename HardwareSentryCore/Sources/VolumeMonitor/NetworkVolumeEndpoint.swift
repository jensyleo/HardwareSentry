import Foundation

/// Where a network volume's server is, worked out from how macOS describes the mount.
///
/// `statfs` reports a mounted share as the thing it was mounted *from* — `//Admin@nas/LEO`
/// for SMB, `nas:/export` for NFS — and that string is the only record of which machine
/// to ask when the share stops answering: by then the volume itself cannot be read without
/// hanging whatever reads it.
public struct NetworkVolumeEndpoint: Sendable, Equatable {
    public let host: String
    public let port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    /// Nil for anything that is not a network filesystem this knows how to find, or whose
    /// source string says no host.
    public static func parse(mountSource: String?, fileSystemType: String?) -> NetworkVolumeEndpoint? {
        guard let source = mountSource?.trimmingCharacters(in: .whitespacesAndNewlines), !source.isEmpty,
              let type = fileSystemType?.lowercased()
        else { return nil }

        switch type {
        case "smbfs": return fromAuthority(source, defaultPort: 445)
        case "afpfs": return fromAuthority(source, defaultPort: 548)
        case "nfs": return fromNFS(source)
        case "webdav": return fromURL(source, defaultPort: nil)
        case "ftp": return fromURL(source, defaultPort: 21)
        default: return nil
        }
    }

    // MARK: - Shapes

    /// `//[user[:password]@]host[:port]/share`, as SMB and AFP describe a mount.
    private static func fromAuthority(_ source: String, defaultPort: UInt16) -> NetworkVolumeEndpoint? {
        var rest = Substring(source)
        if rest.hasPrefix("//") { rest = rest.dropFirst(2) }
        let authority = rest.prefix { $0 != "/" }
        // The last "@": a password may contain one, a host cannot.
        var hostPart = authority.split(separator: "@", omittingEmptySubsequences: false).last.map(Substring.init) ?? authority

        var port = defaultPort
        if hostPart.hasPrefix("[") {
            // An IPv6 address, with the brackets that separate it from a port.
            guard let close = hostPart.firstIndex(of: "]") else { return nil }
            let after = hostPart[hostPart.index(after: close)...]
            if after.hasPrefix(":"), let p = UInt16(after.dropFirst()) { port = p }
            hostPart = hostPart[hostPart.index(after: hostPart.startIndex)..<close]
        } else if hostPart.filter({ $0 == ":" }).count == 1,
                  let colon = hostPart.firstIndex(of: ":"), let p = UInt16(hostPart[hostPart.index(after: colon)...]) {
            port = p
            hostPart = hostPart[..<colon]
        }
        return make(host: String(hostPart), port: port)
    }

    /// `host:/export`.
    private static func fromNFS(_ source: String) -> NetworkVolumeEndpoint? {
        guard let colon = source.firstIndex(of: ":") else { return nil }
        return make(host: String(source[..<colon]), port: 2049)
    }

    /// `http://host[:port]/path`, `ftp://host/path`.
    private static func fromURL(_ source: String, defaultPort: UInt16?) -> NetworkVolumeEndpoint? {
        guard let components = URLComponents(string: source), let host = components.host else { return nil }
        let fallback: UInt16 = defaultPort ?? (components.scheme?.lowercased() == "https" ? 443 : 80)
        return make(host: host, port: components.port.flatMap(UInt16.init(exactly:)) ?? fallback)
    }

    /// Cleans a host and refuses an empty one.
    ///
    /// A share found through Bonjour is named after its service — `Nas._smb._tcp.local` —
    /// which no resolver can look up as written, so it is turned back into the `.local`
    /// name the machine answers to.
    private static func make(host: String, port: UInt16) -> NetworkVolumeEndpoint? {
        var name = host.removingPercentEncoding ?? host
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        for service in ["._smb._tcp.local", "._afpovertcp._tcp.local"] where name.lowercased().hasSuffix(service) {
            name = String(name.dropLast(service.count)) + ".local"
        }
        guard !name.isEmpty else { return nil }
        return NetworkVolumeEndpoint(host: name, port: port)
    }
}
