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

@Suite("ConnectionNaming")
struct ConnectionNamingTests {
    @Test("the medium comes first, then what the thing is")
    func mediumAndType() {
        let naming = ConnectionNaming.mediumAndType
        #expect(naming.title(medium: "USB", type: "Hub", action: "Connected") == "USB Hub Connected")
        #expect(naming.title(medium: "Bluetooth", type: "Keyboard", action: "Connected") == "Bluetooth Keyboard Connected")
        #expect(naming.title(medium: "Thunderbolt", type: "Bridge / Dock", action: "Disconnected") == "Thunderbolt Bridge / Dock Disconnected")
    }

    @Test("just what it is, for somebody who does not care how it got here")
    func typeOnly() {
        let naming = ConnectionNaming.typeOnly
        #expect(naming.title(medium: "USB", type: "Hub", action: "Connected") == "Hub Connected")
        #expect(naming.title(medium: "Bluetooth", type: "Keyboard", action: "Disconnected") == "Keyboard Disconnected")
    }

    @Test("a device that never said what it is falls back to the generic word")
    func unknownTypeFallsBack() {
        // Not a failure: most USB devices declare their class on each interface rather
        // than on the device, so this is what a great many working things get.
        #expect(ConnectionNaming.mediumAndType.title(medium: "USB", type: nil, action: "Connected") == "USB Device Connected")
        // And "Connected" on its own would be a sentence with its subject missing.
        #expect(ConnectionNaming.typeOnly.title(medium: "USB", type: nil, action: "Connected") == "Device Connected")
    }

    @Test("both choices are offered, and the medium-first one is the default")
    func bothAreOffered() {
        #expect(ConnectionNaming.allCases.count == 2)
        #expect(MonitorContext(
            dispatcher: NotificationDispatcher(delivery: DiscardingDelivery()),
            category: "Test"
        ).connectionNaming == .mediumAndType)
    }
}

@Suite("Naming the module that spoke")
struct ReportingModuleLineTests {
    private func context(names: Bool) -> MonitorContext {
        MonitorContext(
            dispatcher: NotificationDispatcher(delivery: DiscardingDelivery()),
            category: "Bluetooth",
            namesReportingModule: names
        )
    }

    @Test("off by default, nothing is added")
    func offAddsNothing() async {
        let body = await context(names: false).body([.always("Joy-Con (R)")])
        #expect(body == "Joy-Con (R)")
    }

    @Test("on, the module is named last, after everything the device said")
    func onNamesTheModuleLast() async {
        // The case this exists for: a controller connecting raises one notification from
        // Gamepad Monitor and another from Bluetooth Monitor, both about a controller and
        // both wearing a picture of one.
        let body = await context(names: true).body([
            .always("Joy-Con (R)"),
            .field("Type", "Type", "Gamepad")
        ])
        #expect(body == "Joy-Con (R)\nType:\tGamepad\nModule:\tBluetooth")
    }

    @Test("a message with nothing else to say still names its module")
    func namesTheModuleAlone() async {
        #expect(await context(names: true).body([]) == "Module:\tBluetooth")
    }
}
