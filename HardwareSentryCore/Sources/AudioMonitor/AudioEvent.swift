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
    case transport = "Transport"
    case channels = "Channels"
    case sampleRate = "SampleRate"
    case deviceUID = "DeviceUID"
    case modelManufacturer = "ModelManufacturer"
    case clockSource = "ClockSource"
    case sampleRateRange = "SampleRateRange"
    case muteState = "MuteState"
    case bitDepth = "BitDepth"
    case latency = "Latency"
    case deviceChangeArrow = "DeviceChangeArrow"

    /// How the line is named in Settings → Events, under "Include in the message".
    var settingsTitle: String {
        switch self {
        case .transport: return "How it is connected"
        case .channels: return "Input and output channel counts"
        case .sampleRate: return "Sample rate"
        case .deviceUID: return "Device UID"
        case .modelManufacturer: return "Model and manufacturer"
        case .clockSource: return "Clock source"
        case .sampleRateRange: return "Supported sample rates"
        case .muteState: return "Muted"
        case .bitDepth: return "Bit depth"
        case .latency: return "Latency"
        case .deviceChangeArrow: return "Show which device it replaced"
        }
    }

    /// What the original shows without being asked: how it is connected, how many channels
    /// it has, what rate it is running at, and — when the default changes — which device
    /// it replaced.
    var shownByDefault: Bool {
        [.transport, .channels, .sampleRate, .deviceChangeArrow].contains(self)
    }
}
