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
    static func current(friendlyNames: [String: String] = [:]) -> IPAddressReport {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return IPAddressReport(interfaces: []) }
        defer { freeifaddrs(head) }

        var ipv4: [String: [String]] = [:]
        var ipv6: [String: [String]] = [:]

        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard let addressPointer = interface.ifa_addr else { continue }
            let name = String(cString: interface.ifa_name)
            // Loopback carries an address on every Mac ever made and tells nobody anything.
            guard (interface.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            guard (interface.ifa_flags & UInt32(IFF_UP)) != 0 else { continue }

            let family = addressPointer.pointee.sa_family
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
                ipv6: ipv6[name] ?? []
            )
        })
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

        let text = String(cString: host)
        // IPv6 addresses come back with the scope appended ("fe80::1%en0"); the interface
        // is already the line's own label, so repeating it inside the address is noise.
        return text.split(separator: "%").first.map(String.init) ?? text
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
