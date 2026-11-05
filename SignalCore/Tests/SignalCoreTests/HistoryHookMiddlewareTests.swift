import Foundation
import Testing
@testable import SignalCore

/// Collects what the hook was told about.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _seen: [String] = []
    var seen: [String] { lock.withLock { _seen } }

    var record: @Sendable (NotificationEvent, DispatchContext) -> Void {
        { event, _ in self.lock.withLock { self._seen.append(event.name) } }
    }
}

@Suite("HistoryHookMiddleware")
struct HistoryHookMiddlewareTests {
    @Test("it reports what passed through and never stops it")
    func observesWithoutInterfering() async {
        let recorder = Recorder()
        let middleware = HistoryHookMiddleware(record: recorder.record)
        let event = makeEvent(name: "USBConnected")

        let decision = await middleware.process(event, context: makeContext())

        #expect(decision.deliveredEvent?.name == event.name)
        #expect(recorder.seen == ["USBConnected"])
    }

    @Test("placed last, it only hears about what a filter let through")
    func recordsWhatSurvivedTheFilters() async {
        let recorder = Recorder()
        let delivery = RecordingDelivery()
        // The order a host would use: gate first, remember afterwards.
        let dispatcher = NotificationDispatcher(
            pipeline: [
                EventEnabledFilter(preferences: StubPreferences(disabledEvents: ["Silenced"])),
                HistoryHookMiddleware(record: recorder.record)
            ],
            delivery: delivery
        )

        await dispatcher.fire(makeEvent(name: "Wanted"))
        await dispatcher.fire(makeEvent(name: "Silenced"))

        // The silenced one never reaches the hook, so the history shows what was seen
        // rather than what was raised.
        #expect(recorder.seen == ["Wanted"])
        #expect(await delivery.presented.map(\.event.name) == ["Wanted"])
    }

    @Test("it keeps them in the order they happened")
    func preservesOrder() async {
        let recorder = Recorder()
        let middleware = HistoryHookMiddleware(record: recorder.record)

        for name in ["first", "second", "third"] {
            _ = await middleware.process(makeEvent(name: name), context: makeContext())
        }

        #expect(recorder.seen == ["first", "second", "third"])
    }
}
