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

    /// Software, not hardware: a Multi-Output/Aggregate device somebody built in Audio
    /// MIDI Setup, or a driver an app like Zoom or Teams installs so it can capture what
    /// is playing. Neither one arrived or left the room, which is why whether to hear
    /// about them is its own switch rather than being lumped in with real devices.
    public var isVirtualOrAggregate: Bool { self == .virtual || self == .aggregate }

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
    /// Everything about the device itself, rather than about it arriving.
    public let detail: AudioDeviceDetail

    public init(
        id: String,
        name: String,
        transport: AudioTransport,
        isInputCapable: Bool,
        detail: AudioDeviceDetail = AudioDeviceDetail()
    ) {
        self.id = id
        self.name = name
        self.transport = transport
        self.isInputCapable = isInputCapable
        self.detail = detail
    }
}

/// What an audio device says about itself.
public struct AudioDeviceDetail: Sendable, Equatable {
    public let outputChannels: Int?
    public let inputChannels: Int?
    /// The rate it is running at right now, in Hz.
    public let sampleRate: Double?
    /// The whole range it supports, when that is more than one rate.
    public let sampleRateRange: ClosedRange<Double>?
    public let uid: String?
    public let modelUID: String?
    public let manufacturer: String?
    public let clockSource: String?
    public let isMuted: Bool?
    public let bitDepth: Int?
    /// Latency in frames — the unit the device reports and the one that matters for
    /// recording, with the millisecond equivalent alongside when the rate is known.
    public let latencyFrames: Int?

    public init(
        outputChannels: Int? = nil,
        inputChannels: Int? = nil,
        sampleRate: Double? = nil,
        sampleRateRange: ClosedRange<Double>? = nil,
        uid: String? = nil,
        modelUID: String? = nil,
        manufacturer: String? = nil,
        clockSource: String? = nil,
        isMuted: Bool? = nil,
        bitDepth: Int? = nil,
        latencyFrames: Int? = nil
    ) {
        self.outputChannels = outputChannels
        self.inputChannels = inputChannels
        self.sampleRate = sampleRate
        self.sampleRateRange = sampleRateRange
        self.uid = uid
        self.modelUID = modelUID
        self.manufacturer = manufacturer
        self.clockSource = clockSource
        self.isMuted = isMuted
        self.bitDepth = bitDepth
        self.latencyFrames = latencyFrames
    }

    var outputChannelsNote: String? { outputChannels.map(String.init) }
    var inputChannelsNote: String? { inputChannels.map(String.init) }
    var sampleRateNote: String? { sampleRate.map { String(format: "%.0f Hz", $0) } }
    var muteNote: String? { isMuted.map { $0 ? "Yes" : "No" } }
    var bitDepthNote: String? { bitDepth.map { "\($0)-bit" } }

    /// Only worth a line when the device supports more than one rate — a range of
    /// "48000–48000 Hz" is a fixed rate dressed up as a choice.
    var sampleRateRangeNote: String? {
        guard let range = sampleRateRange, range.lowerBound != range.upperBound else { return nil }
        return String(format: "%.0f–%.0f Hz", range.lowerBound, range.upperBound)
    }

    /// Frames, with the milliseconds that many frames actually take when the rate is
    /// known. Frames alone mean nothing without the rate to divide by.
    var latencyNote: String? {
        guard let latencyFrames else { return nil }
        guard let sampleRate, sampleRate > 0 else { return "\(latencyFrames) frames" }
        return String(format: "%d frames (~%.1f ms)", latencyFrames, Double(latencyFrames) / sampleRate * 1000)
    }

    /// The two identifiers read as one line: separately they are two lines of opaque
    /// string, together they say who made it and which model.
    var modelManufacturerNote: String? {
        let parts = [manufacturer, modelUID].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
    /// A device's running sample rate moved.
    case sampleRateChanged(id: String, name: String, from: Double, to: Double)
    /// The output volume as a percentage, for whichever device is the default.
    case outputVolume(name: String, percent: Int)
    /// Something was plugged into or unplugged from a jack on the device.
    case jackChanged(name: String, isConnected: Bool)
    /// The device switched which physical input or output it is using — a headset socket
    /// versus internal speakers on the same device.
    case dataSourceChanged(name: String, source: String)
    /// The device stopped answering. Distinct from disconnecting: it is still listed.
    case deviceStoppedResponding(name: String)
    /// Standard, Wide Spectrum, or Voice Isolation.
    case microphoneModeChanged(String)
    /// AirPods or similar with spatial-audio head tracking becoming active.
    case headTrackingChanged(isActive: Bool)
}

public protocol AudioSource: Sendable {
    func changes() -> AsyncStream<AudioSourceEvent>
}
