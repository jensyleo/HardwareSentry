import Foundation

/// How an audio device is connected. USB and Bluetooth are called out specifically
/// because they are the two this monitor deliberately does NOT report connect/disconnect
/// for — USB/Bluetooth Monitor already do, and reporting the same physical event twice
/// would be noise, not new information.
public enum AudioTransport: Sendable, Equatable {
    case usb
    case bluetooth
    case builtIn
    case hdmi
    case displayPort
    case thunderbolt
    case aggregate
    case airPlay
    case pci
    case fireWire
    case virtual
    case other

    /// USB/Bluetooth Monitor already announce these devices connecting/disconnecting.
    public var isCoveredByAnotherMonitor: Bool { self == .usb || self == .bluetooth }

    public var label: String {
        switch self {
        case .usb: return "USB"
        case .bluetooth: return "Bluetooth"
        case .builtIn: return "Built-in"
        case .hdmi: return "HDMI"
        case .displayPort: return "DisplayPort"
        case .thunderbolt: return "Thunderbolt"
        case .aggregate: return "Aggregate"
        case .airPlay: return "AirPlay"
        case .pci: return "PCI"
        case .fireWire: return "FireWire"
        case .virtual: return "Virtual"
        case .other: return "Other"
        }
    }
}

public struct AudioDeviceSnapshot: Sendable, Equatable {
    public let id: String
    public let name: String
    public let transport: AudioTransport
    public let isInputCapable: Bool

    public init(id: String, name: String, transport: AudioTransport, isInputCapable: Bool) {
        self.id = id
        self.name = name
        self.transport = transport
        self.isInputCapable = isInputCapable
    }
}

/// What the system told this monitor just happened.
public enum AudioSourceEvent: Sendable, Equatable {
    /// The full current device list — not a delta, same reasoning as `DisplaySourceEvent.snapshot`.
    case deviceSnapshot([AudioDeviceSnapshot])
    case defaultOutputChanged(id: String, name: String)
    case defaultInputChanged(id: String, name: String)
    /// Every input-capable device currently reported as running somewhere (id → name) —
    /// not a delta; the monitor debounces and diffs it.
    case micRunningSnapshot([String: String])
    case midiDeviceAdded(name: String)
    case midiDeviceRemoved(name: String)
}

public protocol AudioSource: Sendable {
    func changes() -> AsyncStream<AudioSourceEvent>
}
