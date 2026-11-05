import Foundation

/// Identifies one banner for as long as the stack knows about it.
public struct BannerID: Hashable, Sendable {
    let value: UInt64
}

/// Where a banner ended up when it was admitted.
public enum BannerPlacement: Sendable, Equatable {
    /// On screen straight away.
    case revealed
    /// Waiting for room.
    case queued
    /// Never shown: the queue was already full.
    case dropped
}

/// What changed on screen as a result of one operation.
public struct StackChange: Sendable, Equatable {
    /// Banners that just went up, oldest first.
    public var revealed: [BannerID] = []
    /// Banners that just came down, whether because their time was up, because the user
    /// dismissed them, or because they were evicted to make room.
    public var removed: [BannerID] = []
    /// Banners discarded from the queue without ever being shown. Reported rather than
    /// dropped quietly, so a host can say so instead of appearing to have shown
    /// everything.
    public var dropped: [BannerID] = []

    public var isEmpty: Bool { revealed.isEmpty && removed.isEmpty && dropped.isEmpty }
}

/// Decides which banners are on screen, which are waiting, and which have to go.
///
/// Deliberately a value type with no notion of time of its own: every operation is told
/// what time it is. That keeps the whole policy — stacking, eviction, queueing, expiry —
/// exercisable directly, with no clocks, timers or windows involved, and leaves the actor
/// that owns it responsible for scheduling alone.
///
/// The policy itself is carried over rather than reinvented, having already been settled
/// twice in practice:
///
/// - A new banner goes up if it fits.
/// - If it does not, banners that have been readable for long enough are evicted, oldest
///   first, until it does.
/// - If nothing may be evicted — which is exactly what a burst at startup looks like,
///   every banner being seconds old — the newcomer waits its turn instead of being shown
///   somewhere nobody can see it.
/// - A waiting banner's lifetime starts when it actually appears, not when it arrived.
///
/// Two limits shape a burst into something readable rather than a wall.
///
/// The first is a count, not just a height: a tall display fits fifteen banners, and
/// fifteen banners is not a notification, it is a page of text that appears and vanishes.
/// The second is spacing in time — banners are revealed one every fraction of a second, so
/// they arrive in a row instead of all at once. That second limit is what makes them go
/// away in a row too: banners revealed at the same instant expire at the same instant, so
/// the whole screenful blinks out together and the next screenful takes its place. Staggered
/// arrival gives staggered departure for free, and the stack rolls rather than flashing.
public struct BannerStack: Sendable {
    public struct Slot: Sendable, Equatable {
        public let id: BannerID
        public let event: NotificationEvent
        public let height: CGFloat
        /// When this banner went up. Only meaningful once it is visible.
        public let revealedAt: Date

        public static func == (lhs: Slot, rhs: Slot) -> Bool {
            lhs.id == rhs.id && lhs.height == rhs.height && lhs.revealedAt == rhs.revealedAt
        }
    }

    private struct Pending: Sendable {
        let id: BannerID
        let event: NotificationEvent
        let height: CGFloat
    }

    /// On screen, newest first.
    public private(set) var visible: [Slot] = []
    private var queue: [Pending] = []
    private var nextID: UInt64 = 0
    /// When the last banner went up, so the next one can be held back a moment.
    private var lastRevealAt: Date?

    /// How much room there is to stack in. A `var` because the display can change size,
    /// or be swapped for another one, while banners are up.
    public var availableHeight: CGFloat
    private let spacing: CGFloat
    /// How long a banner stays up. A `var` because a person can change it in a settings
    /// window while banners are already on screen.
    public var visibleLifetime: TimeInterval
    /// The most that may be on screen at once, however much room there is. A `var` for
    /// the same reason the lifetime is: it can be changed while banners are already up.
    public var maximumVisible: Int
    /// How long to leave between one banner appearing and the next.
    public var revealSpacing: TimeInterval
    private let minimumReadableTime: TimeInterval
    private let queueLimitWhileLaunching: Int
    private let queueLimitWhenSteady: Int

    public init(
        availableHeight: CGFloat,
        spacing: CGFloat = 8,
        visibleLifetime: TimeInterval = 5,
        maximumVisible: Int = 12,
        revealSpacing: TimeInterval = 0.4,
        minimumReadableTime: TimeInterval = 4.5,
        queueLimitWhileLaunching: Int = 64,
        queueLimitWhenSteady: Int = 16
    ) {
        self.availableHeight = availableHeight
        self.spacing = spacing
        self.visibleLifetime = visibleLifetime
        self.maximumVisible = max(1, maximumVisible)
        self.revealSpacing = max(0, revealSpacing)
        self.minimumReadableTime = minimumReadableTime
        self.queueLimitWhileLaunching = queueLimitWhileLaunching
        self.queueLimitWhenSteady = queueLimitWhenSteady
    }

    public var queuedCount: Int { queue.count }

    public func isVisible(_ id: BannerID) -> Bool {
        visible.contains { $0.id == id }
    }

    // MARK: - Operations

    /// Takes in a new banner, making room for it if that is possible without cutting
    /// anything short.
    @discardableResult
    public mutating func admit(
        _ event: NotificationEvent,
        height: CGFloat,
        at now: Date,
        phase: DispatchPhase
    ) -> (id: BannerID, placement: BannerPlacement, change: StackChange) {
        nextID += 1
        let id = BannerID(value: nextID)
        var change = StackChange()

        // Nothing is evicted while a banner is being held back for spacing: a newcomer
        // that is going to wait its turn anyway has no business cutting short something
        // already on screen.
        if mayReveal(at: now), !fits(height) {
            change.removed = evict(toFit: height, at: now)
        }

        if mayReveal(at: now), fits(height) {
            visible.insert(Slot(id: id, event: event, height: height, revealedAt: now), at: 0)
            lastRevealAt = now
            change.revealed.append(id)
            return (id, .revealed, change)
        }

        let limit = phase == .launching ? queueLimitWhileLaunching : queueLimitWhenSteady
        queue.append(Pending(id: id, event: event, height: height))
        while queue.count > limit {
            change.dropped.append(queue.removeFirst().id)
        }

        let placement: BannerPlacement = change.dropped.contains(id) ? .dropped : .queued
        return (id, placement, change)
    }

    /// Takes a banner down — because the user dismissed it, or because the host decided
    /// to — and lets whatever was waiting take its place.
    @discardableResult
    public mutating func dismiss(_ id: BannerID, at now: Date) -> StackChange {
        var change = StackChange()

        if let index = visible.firstIndex(where: { $0.id == id }) {
            visible.remove(at: index)
            change.removed.append(id)
        } else if let index = queue.firstIndex(where: { $0.id == id }) {
            queue.remove(at: index)
            change.dropped.append(id)
            return change
        } else {
            return change
        }

        change.revealed = drainQueue(at: now)
        return change
    }

    /// Retires banners whose time is up and promotes whatever was waiting.
    ///
    /// Banners marked sticky are left alone: they are meant to stay until acted upon.
    @discardableResult
    public mutating func expire(at now: Date) -> StackChange {
        var change = StackChange()

        let expired = visible.filter { slot in
            !slot.event.isSticky && now.timeIntervalSince(slot.revealedAt) >= visibleLifetime
        }
        guard !expired.isEmpty else { return change }

        let expiredIDs = Set(expired.map(\.id))
        visible.removeAll { expiredIDs.contains($0.id) }
        change.removed = expired.map(\.id)
        change.revealed = drainQueue(at: now)
        return change
    }

    /// Puts up whatever has been waiting and is now allowed to appear.
    ///
    /// Separate from `expire(at:)` because the two are answers to different questions —
    /// something coming down, and something being due to go up — and a burst hits the
    /// second far more often than the first.
    @discardableResult
    public mutating func revealDue(at now: Date) -> StackChange {
        var change = StackChange()
        change.revealed = drainQueue(at: now)
        return change
    }

    /// When the next waiting banner may appear, so a host can schedule for it.
    ///
    /// Nil when nothing is waiting, or when what is waiting would not fit anyway — in that
    /// case it is an expiry that will let it in, and `nextExpiry()` already covers that.
    public func nextRevealTime() -> Date? {
        guard let next = queue.first, fits(next.height), let lastRevealAt else { return nil }
        let due = lastRevealAt.addingTimeInterval(revealSpacing)
        return due
    }

    /// When the next banner is due to come down, so a host can schedule a single timer
    /// rather than one per banner.
    public func nextExpiry() -> Date? {
        visible
            .filter { !$0.event.isSticky }
            .map { $0.revealedAt.addingTimeInterval(visibleLifetime) }
            .min()
    }

    // MARK: - Internals

    private func occupiedHeight() -> CGFloat {
        guard !visible.isEmpty else { return 0 }
        let heights = visible.reduce(CGFloat.zero) { $0 + $1.height }
        return heights + spacing * CGFloat(visible.count - 1)
    }

    /// Whether there is room, by count as well as by height.
    ///
    /// The count is checked first because it is the cheaper check, not because it is
    /// meant to be the one that bites — `maximumVisible`'s own default sits at the top of
    /// its range for exactly that reason. Ordinarily the screen runs out of room before
    /// the count does, matching HG4MAC's own behaviour, which has no count limit at all.
    private func fits(_ height: CGFloat) -> Bool {
        guard visible.count < maximumVisible else { return false }
        let extra = visible.isEmpty ? height : occupiedHeight() + spacing + height
        return extra <= availableHeight
    }

    /// Whether enough time has passed since the last banner appeared.
    ///
    /// With a few milliseconds of slack, because a timer scheduled for exactly the moment
    /// a banner is due will sometimes fire a hair before it — and a difference of a
    /// microsecond should not cost the next banner a whole extra round trip through the
    /// scheduler. Caught by a test that asked for the reveal at exactly the spacing and
    /// was told no, thanks to a fraction of floating-point error in the date arithmetic.
    private static let slack: TimeInterval = 0.005

    private func mayReveal(at now: Date) -> Bool {
        guard let lastRevealAt else { return true }
        return now.timeIntervalSince(lastRevealAt) >= revealSpacing - Self.slack
    }

    /// Frees space by retiring banners that have already been up long enough to read,
    /// oldest first. Sticky banners are considered only once nothing else is left, so a
    /// banner meant to persist is not sacrificed while ordinary ones are still up.
    private mutating func evict(toFit height: CGFloat, at now: Date) -> [BannerID] {
        var evicted: [BannerID] = []

        func evictCandidates(sticky: Bool) {
            while !fits(height) {
                guard let index = visible.lastIndex(where: { slot in
                    slot.event.isSticky == sticky
                        && now.timeIntervalSince(slot.revealedAt) >= minimumReadableTime
                }) else { return }
                evicted.append(visible.remove(at: index).id)
            }
        }

        evictCandidates(sticky: false)
        evictCandidates(sticky: true)
        return evicted
    }

    /// Promotes waiting banners, oldest first, for as long as they fit and are allowed to
    /// appear. Stops at the first one that does not, so that arrival order is preserved
    /// rather than letting a small banner jump ahead of a large one that has been waiting
    /// longer — and, with any spacing at all configured, stops after one, because the
    /// second one's turn is by definition not yet.
    private mutating func drainQueue(at now: Date) -> [BannerID] {
        var revealed: [BannerID] = []

        // One per pass, not as many as fit: revealing three at once is the wall this
        // spacing exists to prevent, and the host comes back for the next one.
        while let next = queue.first, fits(next.height), mayReveal(at: now) {
            queue.removeFirst()
            visible.insert(
                Slot(id: next.id, event: next.event, height: next.height, revealedAt: now),
                at: 0
            )
            lastRevealAt = now
            revealed.append(next.id)
        }

        return revealed
    }
}
