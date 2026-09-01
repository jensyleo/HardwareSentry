import CoreWLAN
import Foundation
import Network

/// Reads the live Wi-Fi interface and network path for everything they will answer.
///
/// Untested for the same reason `SystemNetworkSource` is: both need a real machine on a
/// real network. What is worth reasoning about — which lines appear, in what order, under
/// which preferences, and how a raw dBm figure turns into something readable — lives in
/// `NetworkMonitor` and `NetworkDetail`, and is tested there.
extension WiFiDetail {
    init(interface: CWInterface) {
        self.init(
            bssid: interface.bssid(),
            channel: interface.wlanChannel().map(Self.describe(channel:)),
            generation: Self.describe(phyMode: interface.activePHYMode()),
            security: Self.describe(security: interface.security()),
            rssi: interface.rssiValue(),
            noise: interface.noiseMeasurement(),
            transmitRate: interface.transmitRate(),
            countryCode: interface.countryCode(),
            interfaceName: interface.interfaceName
        )
    }

    private static func describe(channel: CWChannel) -> String {
        let band: String
        switch channel.channelBand {
        case .band2GHz: band = "2.4 GHz"
        case .band5GHz: band = "5 GHz"
        case .band6GHz: band = "6 GHz"
        default: band = "unknown band"
        }

        let width: String?
        switch channel.channelWidth {
        case .width20MHz: width = "20 MHz"
        case .width40MHz: width = "40 MHz"
        case .width80MHz: width = "80 MHz"
        case .width160MHz: width = "160 MHz"
        default: width = nil
        }

        let base = "\(band), channel \(channel.channelNumber)"
        return width.map { "\(base) (\($0))" } ?? base
    }

    /// Given as the generation people actually say out loud, with the standard's own name
    /// after it — "Wi-Fi 6" means something to most people in a way "802.11ax" does not,
    /// and the reverse is true for the rest.
    private static func describe(phyMode: CWPHYMode) -> String? {
        switch phyMode {
        case .mode11a: return "802.11a"
        case .mode11b: return "802.11b"
        case .mode11g: return "802.11g"
        case .mode11n: return "Wi-Fi 4 (802.11n)"
        case .mode11ac: return "Wi-Fi 5 (802.11ac)"
        case .mode11ax: return "Wi-Fi 6 (802.11ax)"
        case .modeNone: return nil
        @unknown default: return nil
        }
    }

    private static func describe(security: CWSecurity) -> String? {
        switch security {
        case .none: return "Open — no encryption"
        case .WEP, .dynamicWEP: return "WEP (obsolete)"
        case .wpaPersonal, .wpaEnterprise: return "WPA"
        case .wpaPersonalMixed, .wpaEnterpriseMixed: return "WPA/WPA2"
        case .wpa2Personal, .wpa2Enterprise: return "WPA2"
        case .wpa3Personal, .wpa3Enterprise: return "WPA3"
        case .wpa3Transition: return "WPA2/WPA3"
        case .OWE, .oweTransition: return "Enhanced Open (OWE)"
        case .personal: return "Personal"
        case .enterprise: return "Enterprise"
        // `.unknown` is the framework declining to say, which is not the same as open —
        // and reporting an unknown security setting as "Open" would be alarming and wrong.
        case .unknown: return nil
        @unknown default: return nil
        }
    }
}

extension NetworkPathDetail {
    init(path: NWPath) {
        self.init(
            interfaceType: Self.describeInterface(of: path),
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained,
            supportsIPv4: path.supportsIPv4,
            supportsIPv6: path.supportsIPv6,
            supportsDNS: path.supportsDNS
        )
    }

    /// The first interface the path actually uses, in the order the system ranked them.
    /// Loopback is skipped: it is present on every path and says nothing about how the
    /// traffic leaves this Mac.
    private static func describeInterface(of path: NWPath) -> String? {
        for interface in path.availableInterfaces where interface.type != .loopback {
            switch interface.type {
            case .wifi: return "Wi-Fi"
            case .wiredEthernet: return "Wired"
            case .cellular: return "Cellular"
            case .other: return "Other"
            default: continue
            }
        }
        return nil
    }
}
