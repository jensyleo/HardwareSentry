import Foundation

/// A USB device, as much of one as is worth telling someone about.
public struct USBDevice: Sendable, Equatable {
    public let name: String
    public let vendorName: String?
    public let isHub: Bool
    /// The USB-IF `bDeviceClass` byte. `0x00` means "look at the interfaces instead", so a
    /// device saying that has told us nothing about what it is.
    public let deviceClass: UInt8?

    public init(name: String, vendorName: String? = nil, isHub: Bool = false, deviceClass: UInt8? = nil) {
        self.name = name
        self.vendorName = vendorName
        self.isHub = isHub
        self.deviceClass = deviceClass
    }

    /// The artwork for what this device says it is, or nil when it has not said anything
    /// specific — most USB devices declare their class per-interface rather than on the
    /// device, so falling back to the plain USB icon is the common case, not a failure.
    public var iconBaseName: String? {
        if isHub { return "USB-TypeHub" }
        switch deviceClass {
        case 0x01: return "USB-TypeAudio"
        case 0x03: return "USB-TypeHID"
        case 0x06: return "USB-TypeScanner"
        case 0x07: return "USB-TypePrinter"
        case 0x09: return "USB-TypeHub"
        case 0x0B: return "USB-TypeSmartCard"
        case 0x0E: return "USB-TypeWebcam"
        case 0x0F: return "USB-TypeHealthcare"
        case 0x10: return "USB-TypeAudioVideo"
        case 0x12: return "USB-TypeTypeCBridge"
        case 0xE0: return "USB-TypeWireless"
        default: return nil
        }
    }
}

public enum USBDeviceChange: Sendable, Equatable {
    case attached(USBDevice)
    case detached(USBDevice)
}

/// Where news of USB devices comes from.
///
/// A protocol so the monitor's own behaviour — what it says, and about what — can be
/// exercised without any hardware being plugged in or unplugged. The implementation that
/// talks to the system is deliberately thin, for the same reason the notification service
/// sits behind a protocol in `SignalCore`.
public protocol USBDeviceSource: Sendable {
    /// Devices already attached when watching begins, followed by changes as they happen.
    func changes() -> AsyncStream<USBDeviceChange>
}
