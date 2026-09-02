import Foundation
import Testing
@testable import SignalCore

@Suite("BannerStack")
struct BannerStackTests {
    private func at(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1000 + seconds)
    }

    /// Room for exactly three 100pt banners: 3 * 100 + 2 * 8 spacing = 316.
    ///
    /// No reveal spacing and no count limit unless a test asks for them: these exercise
    /// what fits and what may be cut short, and holding banners back in time would make
    /// every one of them fail for the wrong reason. The spacing has its own suite below.
    private func makeStack(
        height: CGFloat = 316,
        maximumVisible: Int = 99,
        revealSpacing: TimeInterval = 0
    ) -> BannerStack {
        BannerStack(
            availableHeight: height,
            spacing: 8,
            visibleLifetime: 5,
            maximumVisible: maximumVisible,
            revealSpacing: revealSpacing,
            minimumReadableTime: 4.5
        )
    }

    @Test("a banner that fits goes straight up")
    func fittingBannerIsRevealed() {
        var stack = makeStack()
        let result = stack.admit(makeEvent(), height: 100, at: at(0), phase: .steady)

        #expect(result.placement == .revealed)
        #expect(stack.isVisible(result.id))
    }

    @Test("banners stack newest first")
    func newestOnTop() {
        var stack = makeStack()
        let first = stack.admit(makeEvent(name: "First"), height: 100, at: at(0), phase: .steady)
        let second = stack.admit(makeEvent(name: "Second"), height: 100, at: at(1), phase: .steady)

        #expect(stack.visible.map(\.id) == [second.id, first.id])
    }

    @Test("a banner that does not fit waits when nothing may be evicted yet")
    func waitsWhenNothingEvictable() {
        var stack = makeStack()
        for index in 0..<3 {
            stack.admit(makeEvent(name: "E\(index)"), height: 100, at: at(0), phase: .steady)
        }

        // One second in, every banner on screen is still too fresh to cut short.
        let fourth = stack.admit(makeEvent(name: "E3"), height: 100, at: at(1), phase: .steady)

        #expect(fourth.placement == .queued)
        #expect(stack.visible.count == 3)
        #expect(stack.queuedCount == 1)
    }

    // The heart of the policy: a banner may only be pushed out once it has been up long
    // enough to have been read.
    @Test("a banner that has been readable long enough is evicted to make room")
    func evictsOnceReadable() {
        var stack = makeStack()
        var ids: [BannerID] = []
        for index in 0..<3 {
            ids.append(stack.admit(makeEvent(name: "E\(index)"), height: 100, at: at(0), phase: .steady).id)
        }

        let newcomer = stack.admit(makeEvent(name: "E3"), height: 100, at: at(4.6), phase: .steady)

        #expect(newcomer.placement == .revealed)
        #expect(newcomer.change.removed == [ids[0]]) // the oldest went first
        #expect(stack.visible.count == 3)
    }

    @Test("a banner comes down when its time is up and lets the queue through")
    func expiryPromotesQueue() {
        var stack = makeStack()
        var ids: [BannerID] = []
        for index in 0..<3 {
            ids.append(stack.admit(makeEvent(name: "E\(index)"), height: 100, at: at(0), phase: .steady).id)
        }
        let waiting = stack.admit(makeEvent(name: "E3"), height: 100, at: at(1), phase: .steady)
        #expect(waiting.placement == .queued)

        let change = stack.expire(at: at(5))

        #expect(Set(change.removed) == Set(ids))
        #expect(change.revealed == [waiting.id])
        #expect(stack.queuedCount == 0)
    }

    @Test("a waiting banner's lifetime starts when it appears, not when it arrived")
    func queuedLifetimeStartsOnReveal() {
        var stack = makeStack(height: 108) // room for one 100pt banner
        let first = stack.admit(makeEvent(name: "First"), height: 100, at: at(0), phase: .steady)
        let waiting = stack.admit(makeEvent(name: "Waiting"), height: 100, at: at(0), phase: .steady)
        #expect(waiting.placement == .queued)

        stack.expire(at: at(5))          // first comes down, waiting goes up at t=5
        #expect(stack.isVisible(waiting.id))

        stack.expire(at: at(9))          // only 4s of screen time so far
        #expect(stack.isVisible(waiting.id))

        stack.expire(at: at(10))         // now its own 5s are up
        #expect(!stack.isVisible(waiting.id))
        #expect(first.id != waiting.id)
    }

    @Test("dismissing a banner lets the queue through")
    func dismissPromotesQueue() {
        var stack = makeStack(height: 108)
        let first = stack.admit(makeEvent(), height: 100, at: at(0), phase: .steady)
        let waiting = stack.admit(makeEvent(), height: 100, at: at(0), phase: .steady)

        let change = stack.dismiss(first.id, at: at(1))

        #expect(change.removed == [first.id])
        #expect(change.revealed == [waiting.id])
    }

    @Test("dismissing something that is still waiting removes it without showing it")
    func dismissWhileQueued() {
        var stack = makeStack(height: 108)
        stack.admit(makeEvent(), height: 100, at: at(0), phase: .steady)
        let waiting = stack.admit(makeEvent(), height: 100, at: at(0), phase: .steady)

        let change = stack.dismiss(waiting.id, at: at(1))

        #expect(change.dropped == [waiting.id])
        #expect(stack.queuedCount == 0)
    }

    @Test("the queue keeps arrival order rather than letting a small banner jump ahead")
    func queuePreservesOrder() {
        var stack = makeStack(height: 108)
        let onScreen = stack.admit(makeEvent(), height: 100, at: at(0), phase: .steady)
        let tall = stack.admit(makeEvent(name: "Tall"), height: 100, at: at(0), phase: .steady)
        let short = stack.admit(makeEvent(name: "Short"), height: 20, at: at(0), phase: .steady)

        #expect(tall.placement == .queued)
        #expect(short.placement == .queued)

        let change = stack.dismiss(onScreen.id, at: at(1))

        // The short one could have fitted alongside, but the tall one arrived first.
        #expect(change.revealed == [tall.id])
        #expect(stack.queuedCount == 1)
    }

    @Test("a sticky banner stays put when its time would otherwise be up")
    func stickyBannerDoesNotExpire() {
        var stack = makeStack()
        var sticky = makeEvent()
        sticky.isSticky = true
        let pinned = stack.admit(sticky, height: 100, at: at(0), phase: .steady)

        stack.expire(at: at(60))

        #expect(stack.isVisible(pinned.id))
    }

    @Test("a sticky banner is only evicted once nothing else can go")
    func stickyEvictedLast() {
        var stack = makeStack()
        var sticky = makeEvent()
        sticky.isSticky = true

        let pinned = stack.admit(sticky, height: 100, at: at(0), phase: .steady)
        let ordinary = stack.admit(makeEvent(), height: 100, at: at(0), phase: .steady)
        stack.admit(makeEvent(), height: 100, at: at(0), phase: .steady)

        let newcomer = stack.admit(makeEvent(), height: 100, at: at(4.6), phase: .steady)

        #expect(newcomer.change.removed == [ordinary.id]) // not the sticky one
        #expect(stack.isVisible(pinned.id))
    }

    @Test("a startup burst is allowed a longer queue than steady operation")
    func queueLimitDependsOnPhase() {
        var launching = BannerStack(availableHeight: 108, queueLimitWhileLaunching: 5, queueLimitWhenSteady: 1)
        var steady = BannerStack(availableHeight: 108, queueLimitWhileLaunching: 5, queueLimitWhenSteady: 1)

        for _ in 0..<4 {
            launching.admit(makeEvent(), height: 100, at: at(0), phase: .launching)
            steady.admit(makeEvent(), height: 100, at: at(0), phase: .steady)
        }

        #expect(launching.queuedCount == 3)
        #expect(steady.queuedCount == 1)
    }

    // Anything discarded is named, so a host can report it rather than appear to have
    // shown everything.
    @Test("overflowing the queue reports what was discarded")
    func queueOverflowIsReported() {
        var stack = BannerStack(availableHeight: 108, queueLimitWhenSteady: 1)
        stack.admit(makeEvent(), height: 100, at: at(0), phase: .steady)
        let first = stack.admit(makeEvent(name: "First"), height: 100, at: at(0), phase: .steady)
        let second = stack.admit(makeEvent(name: "Second"), height: 100, at: at(0), phase: .steady)

        #expect(second.change.dropped == [first.id])
        #expect(stack.queuedCount == 1)
    }

    @Test("the next expiry is the earliest one due")
    func nextExpiryIsEarliest() {
        var stack = makeStack()
        stack.admit(makeEvent(), height: 100, at: at(0), phase: .steady)
        stack.admit(makeEvent(), height: 100, at: at(2), phase: .steady)

        #expect(stack.nextExpiry() == at(5))
    }

    @Test("with nothing but sticky banners up, nothing is due")
    func nextExpiryIgnoresSticky() {
        var stack = makeStack()
        var sticky = makeEvent()
        sticky.isSticky = true
        stack.admit(sticky, height: 100, at: at(0), phase: .steady)

        #expect(stack.nextExpiry() == nil)
    }
}

/// The two limits that turn a burst into a stack rather than a wall.
@Suite("BannerStack · pacing a burst")
struct BannerPacingTests {
    private func at(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1000 + seconds)
    }

    /// Room on screen for far more than the count allows, so the count is what bites —
    /// which is the situation on a real display.
    private func makeStack(maximumVisible: Int = 5, revealSpacing: TimeInterval = 0.4) -> BannerStack {
        BannerStack(
            availableHeight: 2000,
            spacing: 8,
            visibleLifetime: 5,
            maximumVisible: maximumVisible,
            revealSpacing: revealSpacing,
            minimumReadableTime: 4.5
        )
    }

    @Test("a burst arriving at once puts up one banner, not the whole burst")
    func burstRevealsOneAtATime() {
        var stack = makeStack()
        var placements: [BannerPlacement] = []
        for index in 0..<12 {
            placements.append(stack.admit(makeEvent(name: "E\(index)"), height: 60, at: at(0), phase: .launching).placement)
        }

        #expect(placements.first == .revealed)
        #expect(placements.dropFirst().allSatisfy { $0 == .queued })
        #expect(stack.visible.count == 1)
        #expect(stack.queuedCount == 11)
    }

    @Test("the queue is let through one at a time, on the spacing")
    func queueDrainsOnePerTick() {
        var stack = makeStack()
        for index in 0..<12 {
            stack.admit(makeEvent(name: "E\(index)"), height: 60, at: at(0), phase: .launching)
        }

        // Too soon: nothing moves.
        #expect(stack.revealDue(at: at(0.2)).revealed.isEmpty)
        #expect(stack.visible.count == 1)

        #expect(stack.revealDue(at: at(0.4)).revealed.count == 1)
        #expect(stack.revealDue(at: at(0.8)).revealed.count == 1)
        #expect(stack.visible.count == 3)
    }

    @Test("the count is a limit even when there is plenty of room on screen")
    func countLimitsTheStack() {
        var stack = makeStack(maximumVisible: 3)
        for index in 0..<8 {
            stack.admit(makeEvent(name: "E\(index)"), height: 60, at: at(0), phase: .launching)
        }
        for step in 1...8 {
            stack.revealDue(at: at(Double(step) * 0.5))
        }

        #expect(stack.visible.count == 3)
        #expect(stack.queuedCount == 5)
    }

    @Test("banners that arrived together do not all expire together")
    func staggeredArrivalMeansStaggeredDeparture() {
        var stack = makeStack(maximumVisible: 3)
        for index in 0..<6 {
            stack.admit(makeEvent(name: "E\(index)"), height: 60, at: at(0), phase: .launching)
        }
        stack.revealDue(at: at(0.4))
        stack.revealDue(at: at(0.8))
        #expect(stack.visible.count == 3)

        // Each was revealed at a different moment, so each is due at a different moment —
        // the whole point of the spacing. The first one out is the first one in.
        let first = stack.expire(at: at(5.0))
        #expect(first.removed.count == 1)
        #expect(stack.visible.count == 3)  // one out, one straight in from the queue

        let second = stack.expire(at: at(5.4))
        #expect(second.removed.count == 1)
    }

    @Test("the next reveal is scheduled from the last one, and only while something waits")
    func nextRevealTime() {
        var stack = makeStack()
        #expect(stack.nextRevealTime() == nil)

        stack.admit(makeEvent(), height: 60, at: at(0), phase: .launching)
        // Nothing waiting yet.
        #expect(stack.nextRevealTime() == nil)

        stack.admit(makeEvent(), height: 60, at: at(0), phase: .launching)
        #expect(stack.nextRevealTime() == at(0.4))
    }

    @Test("nothing is cut short to make room for a banner that is waiting its turn anyway")
    func spacingDoesNotEvict() {
        // Spacing deliberately longer than the readable time, so the two rules disagree:
        // the banner on screen has been up long enough to be evicted, and the newcomer is
        // still not due. The newcomer waiting is the right answer.
        var stack = makeStack(maximumVisible: 1, revealSpacing: 6)
        let first = stack.admit(makeEvent(name: "First"), height: 60, at: at(0), phase: .steady)

        // Long enough that the first banner could be evicted on readability grounds, but
        // the newcomer is inside the spacing window, so it waits instead.
        let second = stack.admit(makeEvent(name: "Second"), height: 60, at: at(4.7), phase: .steady)
        #expect(second.placement == .queued)
        #expect(second.change.removed.isEmpty)
        #expect(stack.isVisible(first.id))
    }

    @Test("spacing switched off keeps the old behaviour of filling the screen")
    func zeroSpacingDrainsFully() {
        var stack = makeStack(maximumVisible: 5, revealSpacing: 0)
        for index in 0..<8 {
            stack.admit(makeEvent(name: "E\(index)"), height: 60, at: at(0), phase: .launching)
        }
        #expect(stack.visible.count == 5)
        #expect(stack.queuedCount == 3)
    }
}
