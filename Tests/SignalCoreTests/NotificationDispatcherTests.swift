import Testing
@testable import SignalCore

@Suite("NotificationDispatcher")
struct NotificationDispatcherTests {
    @Test("delivers an event with an empty pipeline")
    func deliversWithEmptyPipeline() async {
        let delivery = RecordingDelivery()
        let dispatcher = NotificationDispatcher(delivery: delivery)

        let result = await dispatcher.fire(makeEvent(name: "USBConnected"))

        #expect(result.isDelivered)
        let presented = await delivery.presentedEvents
        #expect(presented.count == 1)
        #expect(presented.first?.name == "USBConnected")
    }

    @Test("a suppressing stage stops delivery")
    func suppressingStageStopsDelivery() async {
        struct AlwaysSuppress: NotificationMiddleware {
            func process(_ event: NotificationEvent, context: DispatchContext) async -> MiddlewareDecision {
                .suppress(reason: "test suppression")
            }
        }

        let delivery = RecordingDelivery()
        let dispatcher = NotificationDispatcher(pipeline: [AlwaysSuppress()], delivery: delivery)

        let result = await dispatcher.fire(makeEvent())

        #expect(result.suppressionReason == "test suppression")
        let presented = await delivery.presented
        #expect(presented.isEmpty)
    }

    @Test("stages run in registration order and can transform the event")
    func stagesRunInOrderAndCanTransform() async {
        struct AppendToTitle: NotificationMiddleware {
            let suffix: String
            func process(_ event: NotificationEvent, context: DispatchContext) async -> MiddlewareDecision {
                var updated = event
                updated.title += suffix
                return .deliver(updated)
            }
        }

        let delivery = RecordingDelivery()
        let dispatcher = NotificationDispatcher(
            pipeline: [AppendToTitle(suffix: "-A"), AppendToTitle(suffix: "-B")],
            delivery: delivery
        )

        let result = await dispatcher.fire(makeEvent(title: "Base"))

        #expect(result.deliveredEvent?.title == "Base-A-B")
        let presented = await delivery.presentedEvents
        #expect(presented.first?.title == "Base-A-B")
    }

    @Test("stamps the current phase onto the context it passes down")
    func stampsCurrentPhase() async {
        let delivery = RecordingDelivery()
        let dispatcher = NotificationDispatcher(delivery: delivery, phase: .launching)

        await dispatcher.fire(makeEvent())
        await dispatcher.setPhase(.steady)
        await dispatcher.fire(makeEvent(name: "Second"))

        let phases = await delivery.presented.map(\.context.phase)
        #expect(phases == [.launching, .steady])
    }

    @Test("stamps the firing instant onto the context")
    func stampsFiringInstant() async {
        let clock = MutableClock()
        let delivery = RecordingDelivery()
        let dispatcher = NotificationDispatcher(delivery: delivery, now: { clock.date })

        await dispatcher.fire(makeEvent())
        clock.advance(by: 30)
        await dispatcher.fire(makeEvent(name: "Second"))

        let stamps = await delivery.presented.map(\.context.firedAt)
        #expect(stamps.count == 2)
        #expect(stamps[1].timeIntervalSince(stamps[0]) == 30)
    }
}
