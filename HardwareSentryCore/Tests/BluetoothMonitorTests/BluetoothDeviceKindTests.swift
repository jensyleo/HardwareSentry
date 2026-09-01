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

    @Test("audio devices are told apart by their minor class")
    func audioMinorClass() {
        #expect(BluetoothDeviceKind.from(major: 0x04, minor: 0x01) == .headset)
        #expect(BluetoothDeviceKind.from(major: 0x04, minor: 0x02) == .headset)
        #expect(BluetoothDeviceKind.from(major: 0x04, minor: 0x06) == .headphones)
        #expect(BluetoothDeviceKind.from(major: 0x04, minor: 0x05) == .speaker)
        // Car audio and hi-fi have no artwork of their own; generic beats wrong.
        #expect(BluetoothDeviceKind.from(major: 0x04, minor: 0x08) == nil)
    }

    @Test("an unclassified device gets no specific artwork")
    func unknownStaysGeneric() {
        #expect(BluetoothDeviceKind.from(major: 0x00, minor: 0) == nil)
        #expect(BluetoothDeviceKind.from(major: 0xFF, minor: 0xFF) == nil)
    }

    @Test("every kind knows its artwork")
    func everyKindHasArtwork() {
        #expect(BluetoothDeviceKind.allCases.allSatisfy { $0.iconBaseName.hasPrefix("BT-Type") })
    }
}
