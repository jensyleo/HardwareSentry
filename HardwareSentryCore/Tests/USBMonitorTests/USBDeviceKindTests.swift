import Foundation
import Testing
@testable import USBMonitor

@Suite("USB device class")
struct USBDeviceKindTests {
    private func icon(class code: UInt8?, isHub: Bool = false) -> String? {
        USBDevice(name: "x", isHub: isHub, deviceClass: code).iconBaseName
    }

    @Test("a declared class picks the artwork for what the device says it is")
    func declaredClasses() {
        #expect(icon(class: 0x03) == "USB-TypeHID")
        #expect(icon(class: 0x07) == "USB-TypePrinter")
        #expect(icon(class: 0x0E) == "USB-TypeWebcam")
        #expect(icon(class: 0xE0) == "USB-TypeWireless")
    }

    @Test("a hub is a hub however it was worked out")
    func hubEitherWay() {
        #expect(icon(class: 0x09) == "USB-TypeHub")
        // IOKit can also say so through the class it conforms to, with no class byte.
        #expect(icon(class: nil, isHub: true) == "USB-TypeHub")
    }

    /// Class 0x00 means "look at the interfaces instead" — most USB devices say this, so
    /// it is the ordinary case rather than a failure, and gets the plain USB icon.
    @Test("a device that defers to its interfaces gets no specific artwork")
    func perInterfaceStaysGeneric() {
        #expect(icon(class: 0x00) == nil)
        #expect(icon(class: nil) == nil)
        #expect(icon(class: 0xAB) == nil)
    }
}
