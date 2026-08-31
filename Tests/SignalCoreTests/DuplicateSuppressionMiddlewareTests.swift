import Foundation
import Testing
@testable import SignalCore

@Suite("DuplicateSuppressionMiddleware")
struct DuplicateSuppressionMiddlewareTests {
    @Test("first occurrence is always delivered")
    func firstOccurrenceDelivered() async {
        let middleware = DuplicateSuppressionMiddleware()
        let decision = await middleware.process(makeEvent(), context: makeContext())

        #expect(decision.isDeliver)
    }

    @Test("an identical repeat within the window is suppressed")
    func repeatWithinWindowSuppressed() async {
        let middleware = DuplicateSuppressionMiddleware(window: 3)

        _ = await middleware.process(makeEvent(), context: makeContext(at: 0))
        let decision = await middleware.process(makeEvent(), context: makeContext(at: 1))

        #expect(decision.isSuppress)
    }

    @Test("an identical repeat after the window elapses is delivered again")
    func repeatAfterWindowDelivered() async {
        let middleware = DuplicateSuppressionMiddleware(window: 3)

        _ = await middleware.process(makeEvent(), context: makeContext(at: 0))
        let decision = await middleware.process(makeEvent(), context: makeContext(at: 4))

        #expect(decision.isDeliver)
    }

    // Regression guard for the design fault this middleware was rewritten to fix: the
    // event name must take part in the key. A connect and a disconnect of the same
    // device share category, subject and body, and differ only by name — collapsing
    // them would silently swallow the second half of every quick state flip.
    @Test("same subject and body but a different event name is not a duplicate")
    func differentEventNameIsNotDuplicate() async {
        let middleware = DuplicateSuppressionMiddleware(window: 3)

        _ = await middleware.process(
            makeEvent(name: "USBConnected", subject: "Cruzer", body: "Cruzer"),
            context: makeContext(at: 0)
        )
        let decision = await middleware.process(
            makeEvent(name: "USBDisconnected", subject: "Cruzer", body: "Cruzer"),
            context: makeContext(at: 1)
        )

        #expect(decision.isDeliver)
    }

    @Test("the same event for a different subject is not a duplicate")
    func differentSubjectIsNotDuplicate() async {
        let middleware = DuplicateSuppressionMiddleware(window: 3)

        _ = await middleware.process(
            makeEvent(name: "USBConnected", subject: "Cruzer"),
            context: makeContext(at: 0)
        )
        let decision = await middleware.process(
            makeEvent(name: "USBConnected", subject: "Kingston"),
            context: makeContext(at: 1)
        )

        #expect(decision.isDeliver)
    }

    @Test("title alone does not distinguish two otherwise identical events")
    func titleIsNotPartOfIdentity() async {
        let middleware = DuplicateSuppressionMiddleware(window: 3)

        _ = await middleware.process(makeEvent(title: "One phrasing"), context: makeContext(at: 0))
        let decision = await middleware.process(makeEvent(title: "Another phrasing"), context: makeContext(at: 1))

        #expect(decision.isSuppress)
    }

    @Test("subjects with paired-transition suffixes are exempt from suppression")
    func pairedTransitionSuffixesExempt() async {
        let middleware = DuplicateSuppressionMiddleware(window: 3)

        _ = await middleware.process(makeEvent(subject: "Mic-started"), context: makeContext(at: 0))
        let decision = await middleware.process(makeEvent(subject: "Mic-started"), context: makeContext(at: 1))

        #expect(decision.isDeliver)
    }

    @Test("the dedup table is pruned once it passes its threshold")
    func tableIsPruned() async {
        let middleware = DuplicateSuppressionMiddleware(window: 3, pruneThreshold: 4)

        // Fill past the threshold with distinct subjects, all inside the window.
        for index in 0..<5 {
            _ = await middleware.process(makeEvent(subject: "device-\(index)"), context: makeContext(at: 0))
        }
        #expect(await middleware.trackedKeyCount > 0)

        // A later event triggers a prune; everything older than the window drops out,
        // leaving only the entry just recorded.
        _ = await middleware.process(makeEvent(subject: "device-later"), context: makeContext(at: 100))
        #expect(await middleware.trackedKeyCount == 1)
    }
}

private extension MiddlewareDecision {
    var isDeliver: Bool {
        if case .deliver = self { return true }
        return false
    }

    var isSuppress: Bool {
        if case .suppress = self { return true }
        return false
    }
}
