import Foundation

/// A Thunderbolt/PCI device, as much of one as is worth telling someone about.
///
/// `baseClass` is the PCI-SIG base class byte (top byte of the registry's 3-byte
/// "class-code" property) — `0x03` ("Display Controller") is, in practice, always an
/// external GPU on this hardware, since an internal Apple Silicon GPU never enumerates as
/// a post-launch add/remove.
public struct ThunderboltDevice: Sendable, Equatable {
    public let name: String
    public let baseClass: UInt8?
    public let vendorID: UInt16?
    public let deviceID: UInt16?

    public init(name: String, baseClass: UInt8? = nil, vendorID: UInt16? = nil, deviceID: UInt16? = nil) {
        self.name = name
        self.baseClass = baseClass
        self.vendorID = vendorID
        self.deviceID = deviceID
    }

    public var isDisplayController: Bool { baseClass == 0x03 }

    /// The PCI-SIG base class in words. Nil for classes with nothing useful to say.
    public var typeLabel: String? {
        switch baseClass {
        case 0x01: return "Storage Controller"
        case 0x02: return "Network Controller"
        case 0x03: return "Display Controller"
        case 0x04: return "Multimedia Controller"
        case 0x06: return "Bridge / Dock"
        case 0x07: return "Communication Controller"
        case 0x09: return "Input Device"
        case 0x0C: return "Serial Bus Controller"
        case 0x0D: return "Wireless Controller"
        default: return nil
        }
    }

    public var identifierLabel: String? {
        guard let vendorID, let deviceID else { return nil }
        return String(format: "%04X:%04X", vendorID, deviceID)
    }

    /// Vendors actually seen in Thunderbolt dock and accessory hardware — not a full
    /// PCI-SIG registry, just enough to turn the common ones into a name. An unknown ID
    /// simply shows as hex rather than as an error.
    public var vendorName: String? {
        switch vendorID {
        case 0x8086: return "Intel"
        case 0x1D65: return "OWC (Other World Computing)"
        case 0x0FD9: return "CalDigit"
        case 0x203A: return "Kensington"
        case 0x2149: return "Belkin"
        case 0x1AB8: return "Elgato"
        default: return nil
        }
    }
}

/// The optional details this monitor can add to a connect notification.
public enum ThunderboltField: String, CaseIterable {
    case type = "Type"
    case identifier = "VIDPID"
    case vendor = "Vendor"
}

public enum ThunderboltDeviceChange: Sendable, Equatable {
    case attached(ThunderboltDevice)
    /// Registry properties are frequently unreadable from an already-terminating entry by
    /// the time a removal is reported, so a departure carries only the name — the monitor
    /// itself remembers what it saw at connect time, the same way `USBMonitor`'s subject
    /// choice keeps a flapping device recognisable as one thing.
    case detached(name: String)
}

/// Where news of Thunderbolt/PCI devices comes from.
public protocol ThunderboltDeviceSource: Sendable {
    func changes() -> AsyncStream<ThunderboltDeviceChange>
}
