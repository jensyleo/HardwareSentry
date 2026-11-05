import SignalCore
import Testing
@testable import SystemIcons

@Suite("IconBadge from an event name")
struct IconBadgeEventNameTests {
    @Test("arrivals are positive", arguments: [
        "USBConnectedKeyboard", "VolumeMountedNAS", "ScannerFound", "AudioMIDIDeviceAdded",
        "NetworkAdapterAttaching", "NetworkLinkUp", "BluetoothPaired", "WifiRadioOn", "DisplayConnected"
    ])
    func positive(_ name: String) {
        #expect(IconBadge.representative(forEventName: name) == .positive)
    }

    @Test("departures are negative, even where the word for arriving hides inside", arguments: [
        "USBDisconnected", "VolumeUnmountedNAS", "ScannerLost", "AudioMIDIDeviceRemoved",
        "NetworkAdapterDetaching", "NetworkLinkDown", "BluetoothUnpaired", "WifiRadioOff", "BluetoothRadioOff"
    ])
    func negative(_ name: String) {
        #expect(IconBadge.representative(forEventName: name) == .negative)
    }

    @Test("trouble is a warning", arguments: [
        "VolumeLowSpaceNAS", "VolumeNotReadable", "VolumeUnsafeEject", "AudioDeviceStoppedResponding", "ThermalCritical"
    ])
    func warning(_ name: String) {
        #expect(IconBadge.representative(forEventName: name) == .warning)
    }

    @Test("a name that says no direction is unmarked — and a word merely ending in 'on' is not 'On'", arguments: [
        "DisplayModeChanged", "IPAddressChanged", "NetworkLocationChanged", "Connection", "PrinterDefaultChanged"
    ])
    func none(_ name: String) {
        #expect(IconBadge.representative(forEventName: name) == nil)
    }
}
