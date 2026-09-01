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
}
