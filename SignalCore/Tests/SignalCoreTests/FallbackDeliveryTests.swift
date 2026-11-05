import Testing
@testable import SignalCore

/// A channel that always declines, for exercising what happens when the preferred one
/// will not have us.
struct DecliningDelivery: NotificationDelivering {
    let reason: String
    func present(_ event: NotificationEvent, context: DispatchContext) async -> DeliveryOutcome {
        .failed(reason: reason)
    }
}

@Suite("FallbackDelivery")
struct FallbackDeliveryTests {
    @Test("the preferred channel is used when it accepts")
    func preferredWins() async {
        let preferred = RecordingDelivery()
        let fallback = RecordingDelivery()
        let delivery = FallbackDelivery(preferred: preferred, fallback: fallback)

        let outcome = await delivery.present(makeEvent(), context: makeContext())

        #expect(outcome == .presented)
        #expect(await preferred.presented.count == 1)
        #expect(await fallback.presented.isEmpty)
    }

    @Test("declining hands the notification to the other channel")
    func fallbackTakesOver() async {
        let fallback = RecordingDelivery()
        let delivery = FallbackDelivery(
            preferred: DecliningDelivery(reason: "not authorized"),
            fallback: fallback
        )

        let outcome = await delivery.present(makeEvent(), context: makeContext())

        #expect(outcome == .presented)
        #expect(await fallback.presented.count == 1)
    }

    @Test("a notification is lost only if both channels decline")
    func bothDeclining() async {
        let delivery = FallbackDelivery(
            preferred: DecliningDelivery(reason: "not authorized"),
            fallback: DecliningDelivery(reason: "no screen")
        )

        let outcome = await delivery.present(makeEvent(), context: makeContext())

        #expect(outcome == .failed(reason: "no screen"))
    }

    // The arrangement this exists for: everything raised while the permission question is
    // still open gets drawn, and the system takes over by itself once the answer is in.
    @Test("notifications raised before permission is settled are still shown")
    func drawnWhileAuthorizationPending() async {
        let scheduler = FakeScheduler(status: .notDetermined, grantsAuthorization: true)
        let system = SystemDelivery(scheduler: scheduler)
        let banners = RecordingDelivery()
        let delivery = FallbackDelivery(preferred: system, fallback: banners)

        await delivery.present(makeEvent(name: "AtLaunch"), context: makeContext())
        #expect(await banners.presented.count == 1)
        #expect(await scheduler.scheduled.isEmpty)

        await system.prepare()
        await delivery.present(makeEvent(name: "Later"), context: makeContext())

        #expect(await banners.presented.count == 1) // unchanged
        #expect(await scheduler.scheduled.count == 1)
    }
}
