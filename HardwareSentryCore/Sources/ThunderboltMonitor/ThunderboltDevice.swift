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
    public var typeLabel: String? { Self.label(forBaseClass: baseClass) }

    /// The same lookup for a class code remembered from before a device left, since by
    /// then there is no device left to ask.
    public static func label(forBaseClass baseClass: UInt8?) -> String? {
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

    /// The artwork for this device's PCI class, or nil when there is nothing more specific
    /// than "a Thunderbolt device" to say. A wrong specific icon reads worse than an
    /// honest generic one.
    public var iconBaseName: String? { kind?.iconBaseName }

    /// What this device says it is, or nil for a class with no artwork of its own.
    public var kind: ThunderboltDeviceKind? { ThunderboltDeviceKind(baseClass: baseClass) }
}

/// The PCI classes that have artwork and a row of their own.
///
/// One row per class, as the original has it, so a dock and an external disk on the same
/// Mac can be silenced and re-iconed apart from each other.
public enum ThunderboltDeviceKind: String, Sendable, Equatable, CaseIterable {
    case egpu, dock, disk, networkAdapter, capture, communication
    case inputDevice, serialBus, wirelessController

    public init?(baseClass: UInt8?) {
        switch baseClass {
        case 0x01: self = .disk
        case 0x02: self = .networkAdapter
        case 0x03: self = .egpu
        case 0x04: self = .capture
        case 0x06: self = .dock
        case 0x07: self = .communication
        case 0x09: self = .inputDevice
        case 0x0C: self = .serialBus
        case 0x0D: self = .wirelessController
        default: return nil
        }
    }

    public var iconBaseName: String {
        switch self {
        case .disk: return "TB-TypeDisk"
        case .networkAdapter: return "TB-TypeNetworkAdapter"
        case .egpu: return "TB-TypeEGPU"
        case .capture: return "TB-TypeCapture"
        case .dock: return "TB-TypeDock"
        case .communication: return "TB-TypeCommunication"
        case .inputDevice: return "TB-TypeInputDevice"
        case .serialBus: return "TB-TypeSerialBus"
        case .wirelessController: return "TB-TypeWirelessController"
        }
    }

    /// How the row is named in Settings, in the original's words.
    var settingsTitle: String {
        switch self {
        case .egpu: return "eGPU"
        case .dock: return "Dock"
        case .disk: return "Disk"
        case .networkAdapter: return "Network Adapter"
        case .capture: return "Capture"
        case .communication: return "Communication Controller"
        case .inputDevice: return "Input Device"
        case .serialBus: return "Serial Bus Controller"
        case .wirelessController: return "Wireless Controller"
        }
    }

    var connectedEvent: ThunderboltEvent {
        switch self {
        case .egpu: return .connectedEGPU
        case .dock: return .connectedDock
        case .disk: return .connectedDisk
        case .networkAdapter: return .connectedNetworkAdapter
        case .capture: return .connectedCapture
        case .communication: return .connectedCommunication
        case .inputDevice: return .connectedInputDevice
        case .serialBus: return .connectedSerialBus
        case .wirelessController: return .connectedWirelessController
        }
    }
}

/// The optional details this monitor can add to a connect notification.
public enum ThunderboltField: String, CaseIterable {
    case identifier = "VIDPID"
    case type = "Type"
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
