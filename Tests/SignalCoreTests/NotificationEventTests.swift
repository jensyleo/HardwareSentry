import Testing
@testable import SignalCore

@Suite("NotificationEvent")
struct NotificationEventTests {
    @Test("subject defaults to the event name when the event has no specific instance")
    func subjectDefaultsToName() {
        let event = makeEvent(name: "WifiRadioOn", subject: nil)
        #expect(event.subject == "WifiRadioOn")
    }

    @Test("subject and name stay independent when both are supplied")
    func subjectAndNameAreIndependent() {
        let connected = makeEvent(name: "USBConnected", subject: "SanDisk Cruzer")
        let disconnected = makeEvent(name: "USBDisconnected", subject: "SanDisk Cruzer")

        // Same device, different events: subject shared, name distinct.
        #expect(connected.subject == disconnected.subject)
        #expect(connected.name != disconnected.name)
    }

    @Test("an event that says nothing about its icon's kind or state carries neither")
    func iconKindAndBadgeDefaultToNil() {
        let event = NotificationEvent(name: "X", category: "USB", title: "t", body: "b")
        #expect(event.iconKind == nil)
        #expect(event.iconBadge == nil)
    }

    @Test("the icon's kind and state are carried as given")
    func iconKindAndBadgeAreCarried() {
        let event = NotificationEvent(
            name: "X", category: "USB", title: "t", body: "b",
            iconKind: "usb.keyboard", iconBadge: .negative
        )
        #expect(event.iconKind == "usb.keyboard")
        #expect(event.iconBadge == .negative)
    }
}
