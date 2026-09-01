import Foundation
import SentryContract
import SignalCore
import Testing

/// Answers only about the fields it was told to allow.
private struct ChosenFields: NotificationPreferences {
    let allowed: Set<String>

    func isFieldEnabled(_ name: String, in category: NotificationCategory) async -> Bool {
        allowed.contains(name)
    }
}

private func context(allowing allowed: Set<String>) -> MonitorContext {
    MonitorContext(
        dispatcher: NotificationDispatcher(delivery: DiscardingDelivery()),
        category: "Test",
        preferences: ChosenFields(allowed: allowed)
    )
}

private struct DiscardingDelivery: NotificationDelivering {
    func present(_ event: NotificationEvent, context: DispatchContext) async -> DeliveryOutcome { .presented }
}

@Suite("Optional body detail")
struct BodyLineTests {
    @Test("a line with no field behind it is always there")
    func alwaysLineSurvives() async {
        let body = await context(allowing: []).body([.always("SanDisk Cruzer")])
        #expect(body == "SanDisk Cruzer")
    }

    @Test("a field that is switched off leaves no trace in the message")
    func unwantedFieldIsOmitted() async {
        let body = await context(allowing: ["Vendor"]).body([
            .always("Dock"),
            .field("Type", "Type", "Bridge / Dock"),
            .field("Vendor", "Vendor", "CalDigit")
        ])

        #expect(body == "Dock\nVendor:\tCalDigit")
    }

    @Test("a wanted field with nothing to report is left out rather than shown empty")
    func wantedFieldWithNoValueIsOmitted() async {
        let body = await context(allowing: ["Vendor"]).body([
            .always("Dock"),
            .field("Vendor", "Vendor", String?.none)
        ])

        #expect(body == "Dock")
    }

    @Test("the text for an unwanted field is never even worked out")
    func unwantedFieldIsNeverEvaluated() async {
        // The point of the field being lazy: some of these are a hardware read, not a
        // string already in hand, and paying for one nobody wants is the whole cost.
        final class Counter: @unchecked Sendable { var reads = 0 }
        let counter = Counter()

        _ = await context(allowing: []).body([
            .field("Expensive", { counter.reads += 1; return "read" }())
        ])

        #expect(counter.reads == 0)
    }

    @Test("lines come out in the order the monitor listed them")
    func orderIsPreserved() async {
        let body = await context(allowing: ["A", "B"]).body([
            .always("first"),
            .field("A", "second"),
            .field("B", "third")
        ])

        #expect(body == "first\nsecond\nthird")
    }
}
