import Darwin
import Foundation
import SystemConfiguration

/// Reads the machine's current addresses from the BSD interface list.
///
/// Untested for the same reason the rest of the reading in this module is: it needs the
/// real interfaces of a real Mac. What is worth reasoning about — which lines appear, how
/// a self-assigned address is marked, what counts as routable — lives in `IPAddressReport`
/// and is tested there against reports built by hand.
extension IPAddressReport {
    /// Only the interfaces a person would recognise, for the same reason link events are
    /// filtered: an address on AirDrop's own back channel is not news.
    /// - Parameter perInterface: gateway, configuration method and search domains, which
    ///   live in `SCDynamicStore` rather than in the kernel's address list — handed in so
    ///   this stays one read of one thing.
    static func current(
        friendlyNames: [String: String] = [:],
        perInterface: [String: ServiceDetail] = [:],
        searchDomains: [String] = []
    ) -> IPAddressReport {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return IPAddressReport(interfaces: []) }
        defer { freeifaddrs(head) }

        var ipv4: [String: [String]] = [:]
        var ipv6: [String: [String]] = [:]
        var mtus: [String: Int] = [:]
        var macAddresses: [String: String] = [:]
        var baudrates: [String: Int] = [:]
        var decodedTypes: [String: String] = [:]

        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard let addressPointer = interface.ifa_addr else { continue }
            let name = String(cString: interface.ifa_name)
            // Loopback carries an address on every Mac ever made and tells nobody anything.
            guard (interface.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            guard (interface.ifa_flags & UInt32(IFF_UP)) != 0 else { continue }

            let family = addressPointer.pointee.sa_family

            // The hardware address arrives as its own AF_LINK entry for the same
            // interface, alongside the IP ones rather than inside them.
            if family == UInt8(AF_LINK) {
                if let mac = Self.hardwareAddress(of: addressPointer) { macAddresses[name] = mac }
                if let data = interface.ifa_data {
                    let stats = data.assumingMemoryBound(to: if_data.self).pointee
                    mtus[name] = Int(stats.ifi_mtu)
                    if stats.ifi_baudrate > 0 { baudrates[name] = Int(stats.ifi_baudrate) }
                    decodedTypes[name] = Self.typeName(stats.ifi_type)
                }
                continue
            }

            guard family == UInt8(AF_INET) || family == UInt8(AF_INET6) else { continue }
            guard let text = Self.presentation(of: addressPointer, family: family) else { continue }

            if family == UInt8(AF_INET) {
                let mask = interface.ifa_netmask.flatMap { Self.prefixLength(ofMask: $0) }
                ipv4[name, default: []].append(mask.map { "\(text)/\($0)" } ?? text)
            } else {
                ipv6[name, default: []].append(text)
            }
        }

        let names = Set(ipv4.keys).union(ipv6.keys)
        return IPAddressReport(interfaces: names.map { name in
            InterfaceAddresses(
                bsdName: name,
                friendlyName: friendlyNames[name],
                ipv4: ipv4[name] ?? [],
                ipv6: ipv6[name] ?? [],
                gateway: perInterface[name]?.gateway,
                configurationMethod: perInterface[name]?.configurationMethod,
                mtu: mtus[name],
                macAddress: macAddresses[name],
                dhcpLease: perInterface[name]?.dhcpLease,
                baudrate: baudrates[name],
                decodedType: decodedTypes[name]
            )
        }, dnsSearchDomains: searchDomains)
    }

    /// The number of leading 1 bits in a netmask — 255.255.255.0 becomes 24.
    private static func prefixLength(ofMask mask: UnsafeMutablePointer<sockaddr>) -> Int? {
        guard mask.pointee.sa_family == UInt8(AF_INET) else { return nil }
        return mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
            Int(UInt32(bigEndian: $0.pointee.sin_addr.s_addr).nonzeroBitCount)
        }
    }

    private static func presentation(of address: UnsafeMutablePointer<sockaddr>, family: UInt8) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(
            address, socklen_t(address.pointee.sa_len),
            &host, socklen_t(host.count), nil, 0,
            NI_NUMERICHOST
        ) == 0 else { return nil }

        // Trimmed at the terminator before decoding: the buffer is fixed-length, so the
        // bytes past the address are zeroes that would otherwise become part of the string.
        let text = String(decoding: host.prefix { $0 != 0 }.map(UInt8.init), as: UTF8.self)
        // IPv6 addresses come back with the scope appended ("fe80::1%en0"); the interface
        // is already the line's own label, so repeating it inside the address is noise.
        return text.split(separator: "%").first.map(String.init) ?? text
    }

    /// The kernel's own name for an interface type, from `net/if_types.h`.
    ///
    /// Only the handful a Mac actually reports. Anything else comes back as its raw
    /// number, which is more use than nothing when an unfamiliar interface shows up.
    private static func typeName(_ type: UInt8) -> String {
        switch Int32(type) {
        case IFT_ETHER: return "Ethernet"
        case IFT_LOOP: return "Loopback"
        case IFT_L2VLAN: return "VLAN"
        case IFT_IEEE1394: return "FireWire"
        case IFT_BRIDGE: return "Bridge"
        case IFT_PPP: return "PPP"
        case IFT_OTHER: return "Other"
        case IFT_CELLULAR: return "Cellular"
        default: return "Type \(type)"
        }
    }

    /// The six bytes of a link-layer address, as "a4:83:e7:1c:9d:5b".
    private static func hardwareAddress(of pointer: UnsafeMutablePointer<sockaddr>) -> String? {
        pointer.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { link in
            let length = Int(link.pointee.sdl_alen)
            guard length == 6 else { return nil }

            // The address sits after the interface name inside the same variable-length
            // field, which is why the name's length is the offset to start at.
            return withUnsafeBytes(of: link.pointee.sdl_data) { bytes in
                let start = Int(link.pointee.sdl_nlen)
                guard start + length <= bytes.count else { return nil }
                return (0..<length)
                    .map { String(format: "%02x", bytes[start + $0]) }
                    .joined(separator: ":")
            }
        }
    }
}

extension SystemNetworkSource {
    /// BSD name → the name System Settings shows, for the interfaces it lists.
    static func friendlyInterfaceNames() -> [String: String] {
        guard let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return [:] }
        var names: [String: String] = [:]
        for interface in interfaces {
            guard let bsd = SCNetworkInterfaceGetBSDName(interface) as String?,
                  let friendly = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String?
            else { continue }
            names[bsd] = friendly
        }
        return names
    }
}

/// What `SCDynamicStore` knows about one interface's service that the kernel does not.
public struct ServiceDetail: Sendable, Equatable {
    public let gateway: String?
    public let configurationMethod: String?
    public let dhcpLease: String?

    public init(gateway: String? = nil, configurationMethod: String? = nil, dhcpLease: String? = nil) {
        self.gateway = gateway
        self.configurationMethod = configurationMethod
        self.dhcpLease = dhcpLease
    }

    /// How a lease reads on one line: only the parts that are actually known, joined.
    ///
    /// A lease with a start time and no server is normal — the dictionary is filled in as
    /// the negotiation proceeds — so the parts are gathered rather than demanded together.
    public static func describeLease(start: Date?, duration: TimeInterval?, server: String?) -> String? {
        var parts: [String] = []

        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short

        if let start { parts.append("since \(formatter.string(from: start))") }
        if let start, let duration, duration > 0 {
            parts.append("expires \(formatter.string(from: start.addingTimeInterval(duration)))")
        }
        if let server { parts.append("server \(server)") }

        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}
