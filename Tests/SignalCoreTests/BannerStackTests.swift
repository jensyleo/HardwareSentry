import Foundation
import Testing
@testable import SignalCore

@Suite("BannerStack")
struct BannerStackTests {
    private func at(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1000 + seconds)
    }

    /// Room for exactly three 100pt banners: 3 * 100 + 2 * 8 spacing = 316.
    private func makeStack(height: CGFloat = 316) -> BannerStack {
        BannerStack(availableHeight: height, spacing: 8, visibleLifetime: 5, minimumReadableTime: 4.5)
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
