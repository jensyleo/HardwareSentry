import SignalCore

/// What this monitor can tell you about.
///
/// This is the core: which device macOS is actually using (default output/input — distinct
/// from a device merely connecting), a device connecting/disconnecting over a transport
/// USB/Bluetooth Monitor don't already cover, a microphone starting/stopping being used by
/// any app, MIDI devices appearing/disappearing, and the state of the device itself —
/// sample rate, jack, data source, whether it is still responding, dangerous volume,
/// microphone mode, and head-tracking headphones.
public enum AudioEvent: String, NotificationEventKey {
    case defaultOutputChanged = "AudioDefaultOutputChanged"
    case defaultInputChanged = "AudioDefaultInputChanged"
    case connected = "AudioDeviceConnected"
    case disconnected = "AudioDeviceDisconnected"
    case micInUseChanged = "AudioMicInUseChanged"
    case midiDeviceAdded = "AudioMIDIDeviceAdded"
    case midiDeviceRemoved = "AudioMIDIDeviceRemoved"
    case sampleRateChanged = "AudioSampleRateChanged"
    case volumeCritical = "AudioVolumeCritical"
    case jackChanged = "AudioJackChanged"
    case dataSourceChanged = "AudioDataSourceChanged"
    case deviceStoppedResponding = "AudioDeviceStoppedResponding"
    case microphoneModeChanged = "AudioMicrophoneModeChanged"
    case headTrackingConnected = "AudioHeadTrackingHeadphonesConnected"
    case headTrackingDisconnected = "AudioHeadTrackingHeadphonesDisconnected"

    public static let category: NotificationCategory = "Audio"
}

/// The optional details this monitor can add.
public enum AudioField: String, CaseIterable {
    // In the original's order, which is the order they read best in: what the device is,
    // then what it is doing, then the specification nobody reads unless something is wrong.
    case transport = "Transport"
    case channels = "Channels"
    case sampleRate = "SampleRate"
    case deviceUID = "DeviceUID"
    case muteState = "MuteState"
    case deviceChangeArrow = "DeviceChangeArrow"
    case bitDepth = "BitDepth"
    case latency = "Latency"
    case clockSource = "ClockSource"
    case modelManufacturer = "ModelManufacturer"
    case sampleRateRange = "SampleRateRange"

    /// How the line is named in Settings → Events, under "Include in the message".
    var settingsTitle: String {
        switch self {
        case .transport: return "Transport type (USB/Bluetooth/HDMI/etc.)"
        case .channels: return "Channel count"
        case .sampleRate: return "Sample rate"
        case .deviceUID: return "Device UID (stable identity)"
        case .modelManufacturer: return "Model UID + Manufacturer"
        case .clockSource: return "Clock source (Word Clock/S-PDIF/ADAT/Internal)"
        case .sampleRateRange: return "Supported sample rate range"
        case .muteState: return "Mute state"
        case .bitDepth: return "Bit depth"
        case .latency: return "Latency"
        case .deviceChangeArrow: return "Show old → new device when the default changes"
        }
    }

    /// What the original shows without being asked: how it is connected, how many channels
    /// it has, what rate it is running at, and — when the default changes — which device
    /// it replaced.
    var shownByDefault: Bool {
        // The original's six: how it is connected, how many channels, at what rate, its
        // stable identity, whether it is muted, and which device it replaced.
        [.transport, .channels, .sampleRate, .deviceUID, .muteState, .deviceChangeArrow]
            .contains(self)
    }
}
