import Foundation
import Testing
@testable import SignalCore

@Suite("FlapDetectionMiddleware")
struct FlapDetectionMiddlewareTests {
    @Test("events below the threshold pass through untouched")
    func belowThresholdPassesThrough() async {
        let middleware = FlapDetectionMiddleware(window: 20, threshold: 4)

        for second in 0..<3 {
            let decision = await middleware.process(
                makeEvent(subject: "Cruzer"),
                context: makeContext(at: Double(second))
            )
            #expect(decision.deliveredEvent?.name == "TestEvent")
        }
    }

    @Test("crossing the threshold replaces the triggering event with a report")
    func crossingThresholdReportsInstability() async {
        let middleware = FlapDetectionMiddleware(window: 20, threshold: 4)

        var decision: MiddlewareDecision?
        for second in 0..<4 {
            decision = await middleware.process(
                makeEvent(subject: "Cruzer"),
                context: makeContext(at: Double(second))
            )
        }

        let reported = decision?.deliveredEvent
        #expect(reported?.name == "FlapDetected")
        #expect(reported?.subject == "Cruzer")
        #expect(reported?.priority == .high)
    }

    @Test("further events for a flapping subject are dropped, not re-reported")
    func furtherEventsSuppressedAfterReport() async {
        let middleware = FlapDetectionMiddleware(window: 20, threshold: 4, reportCooldown: 20)

        for second in 0..<4 {
            _ = await middleware.process(makeEvent(subject: "Cruzer"), context: makeContext(at: Double(second)))
        }
        let after = await middleware.process(makeEvent(subject: "Cruzer"), context: makeContext(at: 5))

        #expect(after.isSuppress)
    }

    @Test("events spread beyond the window never count as flapping")
    func spreadOutEventsDoNotFlap() async {
        let middleware = FlapDetectionMiddleware(window: 20, threshold: 4)

        var decision: MiddlewareDecision?
        for index in 0..<6 {
            decision = await middleware.process(
                makeEvent(subject: "Cruzer"),
                context: makeContext(at: Double(index) * 15) // 15s apart, window is 20s
            )
        }

        #expect(decision?.deliveredEvent?.name == "TestEvent")
    }

    @Test("two subjects flapping independently do not add up")
    func subjectsAreTrackedSeparately() async {
        let middleware = FlapDetectionMiddleware(window: 20, threshold: 4)

        var decision: MiddlewareDecision?
        for second in 0..<4 {
            let subject = second.isMultiple(of: 2) ? "Cruzer" : "Kingston"
            decision = await middleware.process(makeEvent(subject: subject), context: makeContext(at: Double(second)))
        }

        // Two events each: neither reaches the threshold on its own.
        #expect(decision?.deliveredEvent?.name == "TestEvent")
    }

    // A device that flips between two paired states is one unstable subject, not two
    // subjects seen half as often — so the suffixes are stripped before counting.
    @Test("paired-transition suffixes collapse onto one subject")
    func pairedTransitionsCountTogether() async {
        let middleware = FlapDetectionMiddleware(window: 20, threshold: 4)

        var decision: MiddlewareDecision?
        for second in 0..<4 {
            let subject = second.isMultiple(of: 2) ? "Mic-started" : "Mic-stopped"
            decision = await middleware.process(makeEvent(subject: subject), context: makeContext(at: Double(second)))
        }

        #expect(decision?.deliveredEvent?.name == "FlapDetected")
        #expect(decision?.deliveredEvent?.subject == "Mic")
    }

    @Test("a host can phrase the report itself")
    func reportIsCustomisable() async {
        let middleware = FlapDetectionMiddleware(window: 20, threshold: 2) { report in
            NotificationEvent(
                name: "Wobbly",
                subject: report.subject,
                category: report.category,
                title: "Check the cable",
                body: "\(report.subject) is misbehaving"
            )
        }

        _ = await middleware.process(makeEvent(subject: "Cruzer"), context: makeContext(at: 0))
        let decision = await middleware.process(makeEvent(subject: "Cruzer"), context: makeContext(at: 1))

        #expect(decision.deliveredEvent?.name == "Wobbly")
        #expect(decision.deliveredEvent?.title == "Check the cable")
    }

    @Test("subjects that fall quiet are pruned from tracking")
    func quietSubjectsArePruned() async {
        let middleware = FlapDetectionMiddleware(window: 20, threshold: 4, pruneThreshold: 4)

        for index in 0..<5 {
            _ = await middleware.process(makeEvent(subject: "device-\(index)"), context: makeContext(at: 0))
        }
        _ = await middleware.process(makeEvent(subject: "device-later"), context: makeContext(at: 500))

        #expect(await middleware.trackedSubjectCount == 1)
    }
}

@Suite("FlapDetectionMiddleware · two modules, one device")
struct FlapDetectionAcrossCategoriesTests {
    @Test("one device spoken for by two modules does not count double")
    func categoriesAreCountedSeparately() async {
        // Reported live, 2026-09-07: a Joy-Con is announced by Bluetooth Monitor and by
        // Gamepad Monitor, both naming it "Joy-Con (R)". Keyed on the name alone, those
        // two notices shared one counter — so two connect/disconnect cycles reached a
        // threshold meant for four, and everything about the device was dropped for the
        // cooldown. Two modules agreeing is not the device flapping.
        let middleware = FlapDetectionMiddleware(window: 20, threshold: 4)

        for second in 0..<3 {
            for category: NotificationCategory in ["Bluetooth", "Gamepad"] {
                let decision = await middleware.process(
                    makeEvent(subject: "Joy-Con (R)", category: category),
                    context: makeContext(at: Double(second))
                )
                #expect(decision.deliveredEvent?.name == "TestEvent",
                        "\(category.rawValue) at \(second)s should still pass through")
            }
        }
    }

    @Test("a device really flapping in one module is still caught")
    func oneCategoryStillFlaps() async {
        let middleware = FlapDetectionMiddleware(window: 20, threshold: 4)

        var decision: MiddlewareDecision?
        for second in 0..<4 {
            decision = await middleware.process(
                makeEvent(subject: "Joy-Con (R)", category: "Bluetooth"),
                context: makeContext(at: Double(second))
            )
        }
        #expect(decision?.deliveredEvent?.name != "TestEvent", "the fourth should be the report")
        // And the report still names the device, not the internal bucket key.
        #expect(decision?.deliveredEvent?.subject == "Joy-Con (R)")
    }
}
