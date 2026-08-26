import Testing
@testable import SignalCore

@Suite("NotificationDispatcher")
struct NotificationDispatcherTests {
    @Test("delivers an event with an empty pipeline")
    func deliversWithEmptyPipeline() async {
        let delivery = RecordingDelivery()
        let dispatcher = NotificationDispatcher(delivery: delivery)

        let result = await dispatcher.fire(makeEvent())

        #expect(result == .delivered(makeEvent()))
        let presented = await delivery.presented
        #expect(presented.count == 1)
        #expect(presented.first?.id == "test-id")
    }

    @Test("a suppressing stage stops delivery")
    func suppressingStageStopsDelivery() async {
        struct AlwaysSuppress: NotificationMiddleware {
            func process(_ event: NotificationEvent) async -> MiddlewareDecision {
                .suppress(reason: "test suppression")
            }
        }

        let delivery = RecordingDelivery()
        let dispatcher = NotificationDispatcher(pipeline: [AlwaysSuppress()], delivery: delivery)

        let result = await dispatcher.fire(makeEvent())

        #expect(result == .suppressed(reason: "test suppression"))
        let presented = await delivery.presented
        #expect(presented.isEmpty)
    }

    @Test("stages run in registration order and can transform the event")
    func stagesRunInOrderAndCanTransform() async {
        struct AppendToTitle: NotificationMiddleware {
            let suffix: String
            func process(_ event: NotificationEvent) async -> MiddlewareDecision {
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

        _ = await dispatcher.fire(makeEvent(title: "Base"))

        let presented = await delivery.presented
        #expect(presented.first?.title == "Base-A-B")
    }
}
