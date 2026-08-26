import Foundation
import Testing
@testable import SignalCore

@Suite("DuplicateSuppressionMiddleware")
struct DuplicateSuppressionMiddlewareTests {
    @Test("first occurrence is always delivered")
    func firstOccurrenceDelivered() async {
        let middleware = DuplicateSuppressionMiddleware()
        let decision = await middleware.process(makeEvent())

        guard case .deliver = decision else {
            Issue.record("expected .deliver, got \(decision)")
            return
        }
    }

    @Test("repeat within the window is suppressed")
    func repeatWithinWindowSuppressed() async {
        let clock = MutableClock(Date(timeIntervalSince1970: 1000))
        let middleware = DuplicateSuppressionMiddleware(window: 3, now: { clock.date })

        _ = await middleware.process(makeEvent())
        clock.advance(by: 1) // 1s later, still inside the 3s window

        let decision = await middleware.process(makeEvent())

        guard case .suppress = decision else {
            Issue.record("expected .suppress, got \(decision)")
            return
        }
    }

    @Test("repeat after the window elapses is delivered again")
    func repeatAfterWindowDelivered() async {
        let clock = MutableClock(Date(timeIntervalSince1970: 1000))
        let middleware = DuplicateSuppressionMiddleware(window: 3, now: { clock.date })

        _ = await middleware.process(makeEvent())
        clock.advance(by: 4) // past the 3s window

        let decision = await middleware.process(makeEvent())

        guard case .deliver = decision else {
            Issue.record("expected .deliver, got \(decision)")
            return
        }
    }

    @Test("started/stopped suffixed identifiers are exempt from dedup")
    func startedStoppedSuffixExempt() async {
        let clock = Date(timeIntervalSince1970: 1000)
        let middleware = DuplicateSuppressionMiddleware(window: 3, now: { clock })

        _ = await middleware.process(makeEvent(id: "Mic-started"))
        let decision = await middleware.process(makeEvent(id: "Mic-started"))

        guard case .deliver = decision else {
            Issue.record("expected .deliver (exempt suffix), got \(decision)")
            return
        }
    }
}
