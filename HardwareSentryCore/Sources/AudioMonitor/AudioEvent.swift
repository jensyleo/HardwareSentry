import SignalCore

/// What this monitor can tell you about.
///
/// This is the core: which device macOS is actually using (default output/input — distinct
/// from a device merely connecting), a device connecting/disconnecting over a transport
/// USB/Bluetooth Monitor don't already cover, a microphone starting/stopping being used by
/// any app, and MIDI devices appearing/disappearing. Sample rate changes, jack/data-source
/// changes, "device stopped responding", volume-critical, microphone mode, and head-tracking
/// headphones are not ported at all; see the porting notes for why and what each would take.
public enum AudioEvent: String, NotificationEventKey {
    case defaultOutputChanged = "AudioDefaultOutputChanged"
    case defaultInputChanged = "AudioDefaultInputChanged"
    case connected = "AudioDeviceConnected"
    case disconnected = "AudioDeviceDisconnected"
    case micInUseChanged = "AudioMicInUseChanged"
    case midiDeviceAdded = "AudioMIDIDeviceAdded"
    case midiDeviceRemoved = "AudioMIDIDeviceRemoved"

    public static let category: NotificationCategory = "Audio"
}
