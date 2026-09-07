import Foundation
import Testing
@testable import BluetoothMonitor

@Suite("BluetoothDeviceKind")
struct BluetoothDeviceKindTests {
    @Test("major classes with artwork of their own are recognised")
    func majorClasses() {
        #expect(BluetoothDeviceKind.from(major: 0x01, minor: 0) == .computer)
        #expect(BluetoothDeviceKind.from(major: 0x02, minor: 0) == .phone)
        #expect(BluetoothDeviceKind.from(major: 0x07, minor: 0) == .wearable)
    }

    @Test("a peripheral's two-bit minor class separates keyboard, pointer and both")
    func peripheralMinorClass() {
        #expect(BluetoothDeviceKind.from(major: 0x05, minor: 0x10) == .keyboard)
        #expect(BluetoothDeviceKind.from(major: 0x05, minor: 0x20) == .mouse)
        #expect(BluetoothDeviceKind.from(major: 0x05, minor: 0x30) == .combo)
        // A peripheral that is neither gets no specific artwork.
        #expect(BluetoothDeviceKind.from(major: 0x05, minor: 0x00) == nil)
    }

    @Test("a peripheral's four-bit device type is read too, not just the keyboard/pointer bits")
    func peripheralDeviceType() {
        // None of these set the keyboard/pointing bits, so reading only those bits — as
        // this used to — left every one of them generic.
        #expect(BluetoothDeviceKind.from(major: 0x05, minor: 0x01) == .gamepad)   // joystick
        #expect(BluetoothDeviceKind.from(major: 0x05, minor: 0x02) == .gamepad)
        #expect(BluetoothDeviceKind.from(major: 0x05, minor: 0x03) == .remote)
        #expect(BluetoothDeviceKind.from(major: 0x05, minor: 0x04) == .sensor)
        #expect(BluetoothDeviceKind.from(major: 0x05, minor: 0x05) == .tablet)
        #expect(BluetoothDeviceKind.from(major: 0x05, minor: 0x06) == .cardReader)
        #expect(BluetoothDeviceKind.from(major: 0x05, minor: 0x07) == .tablet)    // digital pen
        #expect(BluetoothDeviceKind.from(major: 0x05, minor: 0x08) == .barcodeScanner)
        // A handheld gestural device has no artwork that would be honest for it.
        #expect(BluetoothDeviceKind.from(major: 0x05, minor: 0x09) == nil)
    }

    @Test("the keyboard/pointer bits still win over the device type, except for a tablet")
    func peripheralBitsTakePrecedence() {
        // A real Magic Keyboard and Magic Mouse must keep answering as they always have,
        // whatever the four bits underneath happen to say.
        #expect(BluetoothDeviceKind.from(major: 0x05, minor: 0x13) == .keyboard)
        #expect(BluetoothDeviceKind.from(major: 0x05, minor: 0x32) == .combo)
        #expect(BluetoothDeviceKind.from(major: 0x05, minor: 0x21) == .mouse)
        // A digitizer tablet is a pointing device with somewhere more specific to go.
        #expect(BluetoothDeviceKind.from(major: 0x05, minor: 0x25) == .tablet)
        #expect(BluetoothDeviceKind.from(major: 0x05, minor: 0x27) == .tablet)
    }

    @Test("audio devices are told apart by their minor class")
    func audioMinorClass() {
        #expect(BluetoothDeviceKind.from(major: 0x04, minor: 0x01) == .headset)
        #expect(BluetoothDeviceKind.from(major: 0x04, minor: 0x02) == .headset)
        #expect(BluetoothDeviceKind.from(major: 0x04, minor: 0x06) == .headphones)
        #expect(BluetoothDeviceKind.from(major: 0x04, minor: 0x05) == .speaker)
        // Car audio and hi-fi have no artwork of their own; generic beats wrong.
        #expect(BluetoothDeviceKind.from(major: 0x04, minor: 0x08) == nil)
    }

    @Test("imaging devices are read from flags, most specific first")
    func imagingMinorFlags() {
        #expect(BluetoothDeviceKind.from(major: 0x06, minor: 0x20) == .printer)
        #expect(BluetoothDeviceKind.from(major: 0x06, minor: 0x10) == .scanner)
        #expect(BluetoothDeviceKind.from(major: 0x06, minor: 0x08) == .camera)
        #expect(BluetoothDeviceKind.from(major: 0x06, minor: 0x04) == .display)
        // Unlike every other major class, these are flags: a print/scan/copy machine
        // claims both, and is named for the more specific of the two.
        #expect(BluetoothDeviceKind.from(major: 0x06, minor: 0x30) == .printer)
        #expect(BluetoothDeviceKind.from(major: 0x06, minor: 0x18) == .scanner)
        // An imaging device claiming no flag at all has said nothing.
        #expect(BluetoothDeviceKind.from(major: 0x06, minor: 0x00) == nil)
    }

    @Test("a toy controller is a gamepad; the rest of the toys are left generic")
    func toyController() {
        #expect(BluetoothDeviceKind.from(major: 0x08, minor: 0x04) == .gamepad)
        for minor: UInt32 in [0x00, 0x01, 0x02, 0x03, 0x05] {
            #expect(BluetoothDeviceKind.from(major: 0x08, minor: minor) == nil, "toy \(minor)")
        }
    }

    @Test("an unclassified device gets no specific artwork")
    func unknownStaysGeneric() {
        #expect(BluetoothDeviceKind.from(major: 0x00, minor: 0) == nil)
        #expect(BluetoothDeviceKind.from(major: 0xFF, minor: 0xFF) == nil)
    }

    @Test("every kind knows its artwork")
    func everyKindHasArtwork() {
        #expect(BluetoothDeviceKind.allCases.allSatisfy { $0.iconBaseName.hasPrefix("BT-Type") })
        // Artwork on disk is checked by Tools/parity-audit.sh; what a unit test can hold
        // is that no two kinds were wired to the same picture, or to the same event.
        let icons = BluetoothDeviceKind.allCases.map(\.iconBaseName)
        #expect(Set(icons).count == icons.count)
        let events = BluetoothDeviceKind.allCases.map(\.connectedEvent)
        #expect(Set(events).count == events.count)
    }
}
