import Foundation
import Testing
@testable import SignalCore

/// Exercises the stages composed as a host would actually arrange them.
///
/// The order matters and is not arbitrary:
/// 1. the category gate, being the coarsest and cheapest, rejects whole modules first;
/// 2. the event gate rejects individual event types;
/// 3. deduplication collapses exact repeats, so that
/// 4. instability detection counts only genuinely distinct events.
///
/// Putting deduplication ahead of instability detection means a subject repeating the
/// *same* notification is treated as one notification rather than as evidence of
/// flapping. Flapping shows up as a subject alternating between different events, which
/// deduplication leaves alone.
@Suite("Pipeline integration")
struct PipelineIntegrationTests {
    private func makePipeline(
        preferences: StubPreferences = StubPreferences()
    ) -> [any NotificationMiddleware] {
        [
            CategoryEnabledFilter(preferences: preferences),
            EventEnabledFilter(preferences: preferences),
            DuplicateSuppressionMiddleware(window: 3),
            FlapDetectionMiddleware(window: 20, threshold: 4)
        ]
    }

    @Test("an ordinary event survives every stage")
    func ordinaryEventSurvives() async {
        let delivery = RecordingDelivery()
        let dispatcher = NotificationDispatcher(pipeline: makePipeline(), delivery: delivery)

        await dispatcher.fire(makeEvent(name: "USBConnected", subject: "Cruzer", category: "USB"))

        let presented = await delivery.presentedEvents
        #expect(presented.count == 1)
        #expect(presented.first?.name == "USBConnected")
    }

    @Test("the coarsest gate wins over everything downstream")
    func categoryGateShortCircuits() async {
        let delivery = RecordingDelivery()
        let dispatcher = NotificationDispatcher(
            pipeline: makePipeline(preferences: StubPreferences(disabledCategories: ["USB"])),
            delivery: delivery
        )

        await dispatcher.fire(makeEvent(category: "USB"))

        #expect(await delivery.presented.isEmpty)
    }

    @Test("a device flapping between two states yields one report, not a storm")
    func flappingDeviceYieldsSingleReport() async {
        let clock = MutableClock()
        let delivery = RecordingDelivery()
        let dispatcher = NotificationDispatcher(
            pipeline: makePipeline(),
            delivery: delivery,
            now: { clock.date }
        )

        // A loose cable: connect/disconnect, eight times, one second apart.
        for index in 0..<8 {
            let connected = index.isMultiple(of: 2)
            await dispatcher.fire(makeEvent(
                name: connected ? "USBConnected" : "USBDisconnected",
                subject: "Cruzer",
                category: "USB",
                body: connected ? "Cruzer attached" : "Cruzer removed"
            ))
            clock.advance(by: 1)
        }

        let presented = await delivery.presentedEvents

        // The first three come through as themselves; the fourth becomes the report;
        // everything after it is dropped while the subject stays unstable.
        #expect(presented.count == 4)
        #expect(presented.prefix(3).allSatisfy { $0.name.hasPrefix("USB") })
        #expect(presented.last?.name == "FlapDetected")
        #expect(presented.last?.subject == "Cruzer")
    }

    @Test("a startup burst is stamped as such all the way to delivery")
    func startupBurstIsVisibleToDelivery() async {
        let delivery = RecordingDelivery()
        let dispatcher = NotificationDispatcher(
            pipeline: makePipeline(),
            delivery: delivery,
            phase: .launching
        )

        await dispatcher.fire(makeEvent(name: "USBConnected", subject: "Cruzer"))
        await dispatcher.setPhase(.steady)
        await dispatcher.fire(makeEvent(name: "USBConnected", subject: "Kingston"))

        let phases = await delivery.presented.map(\.context.phase)
        #expect(phases == [.launching, .steady])
    }
}
