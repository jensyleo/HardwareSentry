import AppKit
import Foundation

/// Presents notifications as self-drawn banners, for when the system's own service is
/// unavailable — an application without a stable signing identity is refused by it, which
/// would otherwise mean no notifications at all.
///
/// Holds the stacking policy and gives it the one thing it refuses to have: a clock. The
/// policy decides what should be on screen; this decides when to ask it again, and turns
/// its answers into windows.
@MainActor
public final class BannerDelivery: NotificationDelivering {
    private var stack: BannerStack?
    private var controllers: [BannerID: BannerWindowController] = [:]
    private var events: [BannerID: NotificationEvent] = [:]
    /// One timer for both kinds of due work — something coming down, something going up.
    private var tickTask: Task<Void, Never>?

    /// How banners should look and where they belong.
    ///
    /// Setting this rearranges what is already on screen, so a person changing the corner
    /// in a settings window sees it take effect rather than wondering whether it worked.
    /// Banners already up keep the size and material they were built with — rebuilding a
    /// notification underneath someone mid-read would be worse than a few seconds of the
    /// old look — so a change of width or material shows on the next banner to arrive.
    public var appearance: BannerAppearance {
        didSet {
            guard appearance != oldValue else { return }
            if appearance.visibleLifetime != oldValue.visibleLifetime {
                stack?.visibleLifetime = appearance.visibleLifetime
            }
            if appearance.moduleLifetimes != oldValue.moduleLifetimes {
                stack?.lifetimeByModule = appearance.moduleLifetimes
            }
            if appearance.maximumVisible != oldValue.maximumVisible {
                // Lowering it does not pull banners already up out from under anybody; it
                // takes effect as they retire, which the next expiry sees to.
                stack?.maximumVisible = appearance.maximumVisible
            }
            if appearance.revealSpacing != oldValue.revealSpacing {
                stack?.revealSpacing = appearance.revealSpacing
            }
            // A different screen can be a different size, so what fits changes with it.
            if appearance.screen != oldValue.screen || appearance.margin != oldValue.margin {
                resizeStackToCurrentScreen()
            }
            relayout()
        }
    }

    /// Overridable so the layout can be exercised against a pretend desk. Left nil by a
    /// host, in which case the screen the appearance asks for is looked up for real.
    private let visibleFrameOverride: (@MainActor () -> NSRect?)?
    private let screenChangeObserver = ObserverBox()
    /// When a sound was last played, so a handful of banners arriving together do not
    /// arrive as a burst of chimes.
    private var lastSoundAt: Date?

    /// Two banners closer together than this share one sound. Long enough to collapse the
    /// "several devices woke up at once" case, short enough that separate events an
    /// unhurried person causes each still make a noise.
    private static let soundInterval: TimeInterval = 1

    public init(
        appearance: BannerAppearance = .standard,
        visibleFrame: (@MainActor () -> NSRect?)? = nil
    ) {
        self.appearance = appearance
        self.visibleFrameOverride = visibleFrame
        watchForScreenChanges()
    }

    deinit {
        screenChangeObserver.removeIfNeeded()
    }

    /// The area to draw in, asked fresh every time rather than remembered: a display can
    /// be unplugged, rearranged or have its resolution changed between one notification
    /// and the next, and a remembered rectangle would put banners off the edge of the
    /// world.
    private func visibleFrame() -> NSRect? {
        if let visibleFrameOverride { return visibleFrameOverride() }
        return appearance.screen.resolve(among: ScreenSnapshot.current(), pointer: NSEvent.mouseLocation)
    }

    /// Displays being plugged in, unplugged or rearranged moves the ground under any
    /// banner currently up. Without this, one on a display that has just gone away stays
    /// at coordinates that no longer exist.
    private func watchForScreenChanges() {
        screenChangeObserver.token = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.resizeStackToCurrentScreen()
                self.relayout()
            }
        }
    }

    /// Tells the policy how much room it now has. A banner already up is left alone even
    /// if it no longer fits — pulling one out from under someone mid-read to satisfy a
    /// height limit would be worse than briefly exceeding it.
    private func resizeStackToCurrentScreen() {
        guard let frame = visibleFrame() else { return }
        stack?.availableHeight = frame.height - appearance.margin * 2
    }

    /// Puts every banner currently on screen back where the current appearance says it
    /// belongs, and re-times the next expiry.
    private func relayout() {
        guard let frame = visibleFrame(), stack != nil else { return }
        apply(StackChange(), in: frame)
    }

    @discardableResult
    public func present(_ event: NotificationEvent, context: DispatchContext) async -> DeliveryOutcome {
        guard let frame = visibleFrame() else {
            return .failed(reason: "no screen available to draw on")
        }

        let content = BannerContent(event: event)
        let style = appearance.style(for: content.severity)
        let quiet = appearance.quietHours.effect(for: content.severity, at: Date())
        // Hidden is not dropped news: the history stage ran before this one.
        if quiet == .hide { return .failed(reason: "quiet hours") }
        // A kind that stays until it is closed is told to the stack the way any sticky
        // notice is, so it needs nothing of its own there.
        var event = event
        if style.staysUntilDismissed { event.isSticky = true }
        var placedID: BannerID?

        // The banner has to be built before it can be measured, and measured before the
        // policy can say whether there is room for it.
        let controller = BannerWindowController(
            content: content,
            appearance: appearance,
            onActivate: { [weak self] in
                guard let id = placedID else { return }
                self?.finish(id, with: .clicked)
            },
            onDismiss: { [weak self] in
                guard let id = placedID else { return }
                self?.finish(id, with: .dismissed)
            }
        )

        var stack = self.stack ?? makeStack(for: frame)
        let admission = stack.admit(
            event,
            height: controller.height,
            at: context.firedAt,
            phase: context.phase
        )
        self.stack = stack
        placedID = admission.id

        guard admission.placement != .dropped else {
            return .failed(reason: "too many banners are already waiting")
        }

        events[admission.id] = event
        controllers[admission.id] = controller
        apply(admission.change, in: frame)
        if quiet != .silence { playSound(for: context, style: style, module: event.category.rawValue) }

        return .presented
    }

    /// Takes a banner down and tells whoever raised it how it ended.
    ///
    /// This is where an expiry finally reaches the module that asked — in the design being
    /// replaced the plumbing existed but nothing ever called it, so a notification timing
    /// out was indistinguishable from one that never happened.
    private func finish(_ id: BannerID, with interaction: NotificationInteraction) {
        guard let frame = visibleFrame(), var stack else { return }

        let event = events[id]
        let change = stack.dismiss(id, at: Date())
        self.stack = stack

        apply(change, in: frame)
        event?.onInteraction?(interaction)
    }

    /// Does whatever has come due: retires banners whose time is up, and puts up whatever
    /// has been waiting its turn.
    ///
    /// Both in one pass, in that order, because an expiry is what makes room for a reveal —
    /// doing them separately would leave a gap on screen until the next timer.
    private func tick() {
        guard let frame = visibleFrame(), var stack else { return }

        let now = Date()
        var change = stack.expire(at: now)
        let reveals = stack.revealDue(at: now)
        change.revealed += reveals.revealed
        self.stack = stack

        guard !change.isEmpty else {
            // Nothing was due after all — but something may still be waiting, so the timer
            // has to be set again or the queue would stall until the next notification.
            scheduleNextTick()
            return
        }

        let timedOut = change.removed.compactMap { events[$0] }
        apply(change, in: frame)
        for event in timedOut {
            event.onInteraction?(.timedOut)
        }
    }

    private func makeStack(for frame: NSRect) -> BannerStack {
        var stack = BannerStack(
            availableHeight: frame.height - appearance.margin * 2,
            spacing: appearance.spacing,
            visibleLifetime: appearance.visibleLifetime,
            maximumVisible: appearance.maximumVisible,
            revealSpacing: appearance.revealSpacing
        )
        stack.lifetimeByModule = appearance.moduleLifetimes
        return stack
    }

    /// Makes a noise, if one was asked for and this is a moment for it.
    ///
    /// Silent during the opening sweep on purpose: everything already plugged in is
    /// announced at launch, and a dozen chimes in two seconds is not a notification, it is
    /// an alarm. The phase is already tracked for exactly this kind of distinction.
    private func playSound(for context: DispatchContext, style: BannerSeverityStyle, module: String) {
        guard context.phase != .launching,
              let name = (style.sound ?? appearance.moduleSounds[module] ?? appearance.sound).systemName
        else { return }

        let now = Date()
        if let lastSoundAt, now.timeIntervalSince(lastSoundAt) < Self.soundInterval { return }
        lastSoundAt = now

        NSSound(named: name)?.play()
    }

    /// A reveal due since the last time it ran, so a second one arriving before it fires
    /// reschedules rather than stacking up a second, independent timer.
    private var pendingReveal: DispatchWorkItem?

    /// One slot's position, worked out fresh from wherever `stack` stands right now.
    ///
    /// Kept as its own step, called both from `apply` — to move what is already up — and
    /// from `firePendingReveal` — to place what is not, at whatever slot it has *by the
    /// time it actually appears* rather than the slot it was offered when first admitted.
    /// The gap between those two moments is exactly where the bug this replaces lived:
    /// see the note on `firePendingReveal`.
    private func layout(_ stack: BannerStack, in frame: NSRect) -> [(id: BannerID, origin: NSPoint, offscreenX: CGFloat)] {
        let corner = appearance.corner
        let margin = appearance.margin
        var edge = corner.isTop ? frame.maxY - margin : frame.minY + margin
        var result: [(id: BannerID, origin: NSPoint, offscreenX: CGFloat)] = []

        for slot in stack.visible {
            let width = controllers[slot.id]?.width ?? appearance.width
            let x = corner.isLeading ? frame.minX + margin : frame.maxX - width - margin
            let y = corner.isTop ? edge - slot.height : edge
            let offscreenX = corner.isLeading ? frame.minX - width - 4 : frame.maxX + 4
            result.append((slot.id, NSPoint(x: x, y: y), offscreenX))
            edge += (corner.isTop ? -1 : 1) * (slot.height + appearance.spacing)
        }

        return result
    }

    /// Turns the policy's answer into windows appearing, moving and going away.
    ///
    /// Takes no word on which banner is newly admitted: `controllers[id].hasAppeared`
    /// already says that for every slot, and asking `stack` fresh rather than being told
    /// is what lets a banner still waiting to reveal survive an intervening `apply` call
    /// without going stale — see `scheduleReveal`.
    private func apply(_ change: StackChange, in frame: NSRect) {
        for id in change.removed + change.dropped {
            controllers.removeValue(forKey: id)?.dismiss()
            events.removeValue(forKey: id)
        }

        guard let stack else { return }


        reposition(in: frame)

        // A separate pass, after every already-on-screen banner has its correct,
        // non-overlapping frame: re-asserts window front-to-back order to match the
        // stack's own order, oldest first so the newest ends up frontmost. Confirmed live,
        // reproduced on screen, as the fix for a banner left behind a newer one: `move(to:)`
        // repositions a window but was never the thing that also re-fronted it, so a stale
        // front-to-back order from however the windows happened to be created could
        // survive even once every frame was correct again.
        //
        // A banner that has not appeared yet is skipped here on purpose: fronting it now,
        // before it has a real frame, would flash an unstyled box in the corner of the
        // screen it belongs to. `present`, when it eventually runs, fronts it itself.
        for slot in stack.visible.reversed() {
            guard let controller = controllers[slot.id], controller.hasAppeared else { continue }
            controller.bringToFront()
        }

        scheduleNextTick()
    }

    /// Steps every banner already on screen to the slot it now holds, and then lets
    /// whatever is still waiting appear.
    ///
    /// Strictly one thing at a time. Nothing is moved while any banner is still
    /// animating, because a banner mid-arrival has to hold its own move back — and if its
    /// neighbours went ahead without it, it would sit still while they slid out from
    /// under it, which is the overlap this exists to prevent. Everything therefore waits
    /// for the screen to be still, moves together, and only then admits the next arrival.
    private func reposition(in frame: NSRect) {
        guard let stack else { return }

        if controllers.values.contains(where: \.isBusy) {
            scheduleReveal(in: frame, delay: 0.03)
            return
        }

        // Every banner that has to get out of the way is counted, and the reveal happens
        // when the last of them reports in — not on a timer that only guesses at how long
        // that takes. See `move(to:completion:)`.
        let batch = MoveBatch()

        for (id, origin, _) in layout(stack, in: frame) {
            guard let controller = controllers[id], controller.hasAppeared else {
                batch.needsReveal = true
                continue
            }
            batch.inFlight += 1
            controller.move(to: origin) { [weak self] in
                batch.inFlight -= 1
                guard batch.issuedAll, batch.inFlight == 0, batch.needsReveal else { return }
                self?.firePendingReveal()
            }
        }

        batch.issuedAll = true

        if batch.needsReveal {
            // Nothing had to move, so the slot is already free — or every move finished
            // synchronously while they were being issued.
            if batch.inFlight == 0 {
                firePendingReveal()
            }
            // A backstop, in case an animation is interrupted and never reports in: the
            // queue must not stall on a callback that is not coming.
            scheduleReveal(in: frame)
        }
    }

    /// Waits out however long an already-visible banner needs to finish vacating a slot,
    /// then reveals whatever is still waiting — at the position that slot holds *then*,
    /// not the one it held when the wait began.
    ///
    /// That distinction is the fix for a real, reproduced bug: the first version of this
    /// captured each newcomer's target position up front and handed it to a delayed
    /// closure. When a second admission arrived before that delay elapsed — which a
    /// composite USB device that enumerates as more than one node makes routine, not
    /// rare — the second `apply` correctly moved every *visible* banner to its new slot,
    /// but the first banner's still-pending reveal knew nothing about that: it fired
    /// later using the position captured at the moment it was scheduled, parking the
    /// banner exactly where an unrelated one now already was. The result was not a brief
    /// animation crossing but a permanent, static overlap — a banner that never slid into
    /// its correct place because nothing had told it there was a new one. Re-deriving the
    /// slot from the live stack at the moment of firing, rather than trusting a value
    /// carried across however many intervening `apply` calls happened in between, removes
    /// the staleness instead of shortening the window for it.
    private func scheduleReveal(in frame: NSRect, delay explicitDelay: TimeInterval? = nil) {
        pendingReveal?.cancel()

        // Deliberately longer than any real sequence of animations — an arrival followed
        // by the move it held back — because this is only the backstop for a completion
        // that never arrives. The reveal normally happens the moment the last move
        // reports in, well before this. A caller retrying because something was still
        // animating passes its own, much shorter delay.
        let delay: TimeInterval = explicitDelay ?? (appearance.isAnimated ? 1 : 0)
        // Goes back through `reposition`, not straight to the reveal: whatever made this
        // retry necessary may equally have left a banner needing to be stepped down.
        let work = DispatchWorkItem { [weak self] in
            guard let self, let frame = self.visibleFrame() else { return }
            self.reposition(in: frame)
        }
        pendingReveal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func firePendingReveal() {
        pendingReveal?.cancel()
        pendingReveal = nil
        guard let frame = visibleFrame(), let stack else { return }

        let slots = layout(stack, in: frame)
        let due = slots.filter { !(controllers[$0.id]?.hasAppeared ?? true) }
        guard !due.isEmpty else { return }

        // Nothing new enters the corner while anything is still animating. Without this,
        // a banner still sliding in — or an older one that has not finished stepping down
        // yet — is still occupying the slot the newcomer is about to be placed in, and the
        // two are simply drawn on top of each other. Measured against the window server:
        // two banners both at the top slot, overlapping by 146 points, the lower one only
        // beginning to move once the newer had completely arrived.
        if controllers.values.contains(where: \.isBusy) {
            scheduleReveal(in: frame, delay: 0.03)
            return
        }

        // The slot being revealed into is only free if everyone else is already standing
        // where this same layout puts them. They are not, whenever another banner was
        // admitted between the moves being issued and this running: the layout then
        // describes a taller stack than the one on screen, and the newcomer is placed into
        // a gap that nobody has opened yet — measured landing it squarely on top of two
        // banners still holding their old slots. Moving everyone first, and revealing from
        // that move's completion, is what keeps the two in step.
        let settled = slots.allSatisfy { id, origin, _ in
            guard let controller = controllers[id], controller.hasAppeared else { return true }
            return abs(controller.currentOrigin.y - origin.y) < 0.5
                && abs(controller.currentOrigin.x - origin.x) < 0.5
        }

        guard settled else {
            reposition(in: frame)
            return
        }

        // One at a time, oldest first. Revealing the whole batch at once is what put two
        // banners in one slot; each arrival now gets the corner to itself, and the next
        // pass follows once this one has landed and everyone else has stepped down.
        guard let (id, origin, offscreenX) = due.last else { return }
        controllers[id]?.present(at: origin, enteringFrom: offscreenX)

        if due.count > 1 {
            scheduleReveal(in: frame, delay: 0.03)
        }
    }

    /// One timer for the whole stack rather than one per banner: the policy already knows
    /// what is due first, whether that is a banner coming down or one going up.
    private func scheduleNextTick() {
        tickTask?.cancel()
        tickTask = nil

        guard let stack else { return }
        let due = [stack.nextExpiry(), stack.nextRevealTime()].compactMap { $0 }.min()
        guard let due else { return }
        let interval = due.timeIntervalSinceNow

        tickTask = Task { [weak self] in
            if interval > 0 {
                try? await Task.sleep(for: .seconds(interval))
            }
            guard !Task.isCancelled else { return }
            self?.tick()
        }
    }
}

/// Counts the repositionings issued by one pass of `apply`, so the reveal that follows
/// can wait for the last of them rather than for a fixed delay. A reference type because
/// the count is written from the animation completions, after `apply` has returned.
@MainActor
private final class MoveBatch {
    var inFlight = 0
    var needsReveal = false
    /// Guards against revealing when the first move happens to finish before the rest
    /// have even been issued.
    var issuedAll = false
}

/// Holds the screen-change token across `deinit`, which is not actor-isolated —
/// `NSObjectProtocol` is not `Sendable`, but a box that owns one and only ever removes it
/// can be. The same shape the monitor sources use for their own tokens.
private final class ObserverBox: @unchecked Sendable {
    var token: (any NSObjectProtocol)?

    func removeIfNeeded() {
        if let token { NotificationCenter.default.removeObserver(token) }
    }
}
