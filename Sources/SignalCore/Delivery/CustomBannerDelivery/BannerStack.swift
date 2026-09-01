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

    /// How much room there is to stack in. A `var` because the display can change size,
    /// or be swapped for another one, while banners are up.
    public var availableHeight: CGFloat
    private let spacing: CGFloat
    /// How long a banner stays up. A `var` because a person can change it in a settings
    /// window while banners are already on screen.
    public var visibleLifetime: TimeInterval
    private let minimumReadableTime: TimeInterval
    private let queueLimitWhileLaunching: Int
    private let queueLimitWhenSteady: Int

    public init(
        availableHeight: CGFloat,
        spacing: CGFloat = 8,
        visibleLifetime: TimeInterval = 5,
        minimumReadableTime: TimeInterval = 4.5,
        queueLimitWhileLaunching: Int = 64,
        queueLimitWhenSteady: Int = 16
    ) {
        self.availableHeight = availableHeight
        self.spacing = spacing
        self.visibleLifetime = visibleLifetime
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

        if !fits(height) {
            change.removed = evict(toFit: height, at: now)
        }

        if fits(height) {
            visible.insert(Slot(id: id, event: event, height: height, revealedAt: now), at: 0)
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

    private func fits(_ height: CGFloat) -> Bool {
        let extra = visible.isEmpty ? height : occupiedHeight() + spacing + height
        return extra <= availableHeight
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

    /// Promotes waiting banners, oldest first, for as long as they fit. Stops at the
    /// first one that does not, so that arrival order is preserved rather than letting a
    /// small banner jump ahead of a large one that has been waiting longer.
    private mutating func drainQueue(at now: Date) -> [BannerID] {
        var revealed: [BannerID] = []

        while let next = queue.first, fits(next.height) {
            queue.removeFirst()
            visible.insert(
                Slot(id: next.id, event: next.event, height: next.height, revealedAt: now),
                at: 0
            )
            revealed.append(next.id)
        }

        return revealed
    }
}
