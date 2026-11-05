import SignalCore
import Testing
@testable import SentryContract

actor SpyDelivery: NotificationDelivering {
    private(set) var events: [NotificationEvent] = []
    func present(_ event: NotificationEvent, context: DispatchContext) async -> DeliveryOutcome {
        events.append(event)
        return .presented
    }
}

@Suite("MonitorContext")
struct MonitorContextTests {
    // A monitor cannot speak for a module other than its own: the category comes from the
    // context it was handed, not from anything it passes in.
    @Test("the monitor's own category is stamped on whatever it raises")
    func categoryIsStamped() async {
        let delivery = SpyDelivery()
        let context = MonitorContext(
            dispatcher: NotificationDispatcher(delivery: delivery),
            category: "Bluetooth"
        )

        await context.notify("Paired", title: "Paired", body: "Keyboard")

        #expect(await delivery.events.first?.category == "Bluetooth")
    }

    @Test("an event with no particular device is its own subject")
    func subjectDefaultsToName() async {
        let delivery = SpyDelivery()
        let context = MonitorContext(
            dispatcher: NotificationDispatcher(delivery: delivery),
            category: "Network"
        )

        await context.notify("WifiRadioOff", title: "Wi-Fi Off", body: "")

        #expect(await delivery.events.first?.subject == "WifiRadioOff")
    }

    @Test("what the icon depicts, and the state it stands for, reach the notification")
    func iconKindAndBadgeArePassedThrough() async {
        let delivery = SpyDelivery()
        let context = MonitorContext(
            dispatcher: NotificationDispatcher(delivery: delivery),
            category: "USB"
        )

        await context.notify(
            "USBDisconnected", title: "t", body: "b",
            iconKind: DeviceIconKind("usb", "keyboard"), iconBadge: .negative
        )

        let event = await delivery.events.first
        #expect(event?.iconKind == "usb.keyboard")
        #expect(event?.iconBadge == .negative)
    }

    @Test("an icon that depicts an idea carries no kind and no state")
    func iconKindAndBadgeDefaultToNil() async {
        let delivery = SpyDelivery()
        let context = MonitorContext(
            dispatcher: NotificationDispatcher(delivery: delivery),
            category: "Network"
        )

        await context.notify("VPNConnected", title: "t", body: "b")

        let event = await delivery.events.first
        #expect(event?.iconKind == nil)
        #expect(event?.iconBadge == nil)
    }

    @Test("a kind splits into its module and its name")
    func kindModule() {
        #expect(DeviceIconKind("volume", "nas").rawValue == "volume.nas")
        #expect(DeviceIconKind("volume", "nas").module == "volume")
    }

    @Test("a model is written as lowercase vendor:product hex, or not at all")
    func modelFormat() {
        #expect(DeviceIconModel.string(vendorID: 0x05AC, productID: 0x029C) == "05ac:029c")
        #expect(DeviceIconModel.string(vendorID: 0x4C, productID: 0x1) == "004c:0001")
        #expect(DeviceIconModel.string(vendorID: nil, productID: 1) == nil)
        #expect(DeviceIconModel.string(vendorID: 1, productID: nil) == nil)
        #expect(DeviceIconModel.string(vendorID: 0x10000, productID: 1) == nil)
        #expect(DeviceIconModel.string(vendorID: -1, productID: 1) == nil)
    }
}
