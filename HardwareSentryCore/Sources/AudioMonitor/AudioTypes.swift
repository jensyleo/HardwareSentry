import Foundation

/// How an audio device is connected. Bluetooth is called out specifically because it is
/// the one this monitor still does not report connect/disconnect for — Bluetooth Monitor
/// already does, and that pairing is a deliberate, separate event worth its own place.
///
/// A USB audio device used to be silenced the same way, on the theory that USB Monitor
/// already said something. What USB Monitor says is "a USB device connected", or, if the
/// class byte cooperates, "a USB audio device connected" — never the sample rate, the
/// channel count, or which of two audio interfaces just became the default. Two
/// notifications for one physical event is not noise when the second one is the only
/// place that information exists; it is only noise when it repeats the first.
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
    /// An iPhone standing in as a microphone over Continuity. A real device that really
    /// arrived, and common enough now to be worth naming rather than filing under
    /// "Other" — the wired and wireless constants are one transport as far as anybody
    /// reading the notification is concerned, and Camera Monitor spells it this way too.
    case continuity
    /// Audio Video Bridging — audio over Ethernet, which pro interfaces use.
    case avb
    case other

    /// Bluetooth Monitor already announces a device pairing — wireless transports are
    /// left alone for now (USB's silencing was the one confirmed to be losing real
    /// information; Bluetooth's own trade has not been reconsidered yet).
    public var isCoveredByAnotherMonitor: Bool { self == .bluetooth }

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
        case .continuity: return "Continuity"
        case .avb: return "AVB"
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

    /// What the system answers when it does not know who made the device.
    ///
    /// CoreAudio's placeholder is the phrase "Unknown Manufacturer", not an empty string,
    /// so an emptiness check alone lets it straight through: a real Logitech BRIO, read
    /// live 2026-09-07, reported `Model: Unknown Manufacturer · Logitech BRIO:046D:085E`.
    /// Saying nothing is better — the maker is already in the device's own name.
    ///
    /// Matched whole, never as a prefix: a real company called "Unknown Devices Ltd" must
    /// still come through. `CameraMonitor` refuses the same phrases at its own read site;
    /// the list is repeated rather than shared because a monitor may only depend on
    /// `SentryContract`.
    static func realAnswer(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              !placeholders.contains(trimmed.lowercased())
        else { return nil }
        return trimmed
    }

    private static let placeholders: Set<String> = [
        "unknown", "unknown manufacturer", "unknown model", "unknown device"
    ]

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
