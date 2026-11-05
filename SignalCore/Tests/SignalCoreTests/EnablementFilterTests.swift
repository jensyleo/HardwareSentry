import Testing
@testable import SignalCore

@Suite("Enablement filters")
struct EnablementFilterTests {
    @Test("a switched-off category is dropped")
    func disabledCategoryDropped() async {
        let filter = CategoryEnabledFilter(preferences: StubPreferences(disabledCategories: ["Bluetooth"]))
        let decision = await filter.process(makeEvent(category: "Bluetooth"), context: makeContext())

        #expect(decision.isSuppress)
    }

    @Test("a category left on passes through")
    func enabledCategoryPasses() async {
        let filter = CategoryEnabledFilter(preferences: StubPreferences(disabledCategories: ["Bluetooth"]))
        let decision = await filter.process(makeEvent(category: "USB"), context: makeContext())

        #expect(decision.isDeliver)
    }

    @Test("a switched-off event type is dropped")
    func disabledEventDropped() async {
        let filter = EventEnabledFilter(preferences: StubPreferences(disabledEvents: ["USBDisconnected"]))
        let decision = await filter.process(makeEvent(name: "USBDisconnected"), context: makeContext())

        #expect(decision.isSuppress)
    }

    @Test("switching off one event type leaves its siblings alone")
    func siblingEventUnaffected() async {
        let filter = EventEnabledFilter(preferences: StubPreferences(disabledEvents: ["USBDisconnected"]))
        let decision = await filter.process(makeEvent(name: "USBConnected"), context: makeContext())

        #expect(decision.isDeliver)
    }

    @Test("a host that implements neither requirement gates nothing")
    func defaultsAllowEverything() async {
        let preferences = SilentPreferences()
        let categoryFilter = CategoryEnabledFilter(preferences: preferences)
        let eventFilter = EventEnabledFilter(preferences: preferences)

        #expect(await categoryFilter.process(makeEvent(), context: makeContext()).isDeliver)
        #expect(await eventFilter.process(makeEvent(), context: makeContext()).isDeliver)
    }
}
