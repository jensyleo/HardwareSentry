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
        apply(admission.change, in: frame, newlyAdmitted: admission.id, controller: controller)
        playSound(for: context)

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
        BannerStack(
            availableHeight: frame.height - appearance.margin * 2,
            spacing: appearance.spacing,
            visibleLifetime: appearance.visibleLifetime,
            maximumVisible: appearance.maximumVisible,
            revealSpacing: appearance.revealSpacing
        )
    }

    /// Makes a noise, if one was asked for and this is a moment for it.
    ///
    /// Silent during the opening sweep on purpose: everything already plugged in is
    /// announced at launch, and a dozen chimes in two seconds is not a notification, it is
    /// an alarm. The phase is already tracked for exactly this kind of distinction.
    private func playSound(for context: DispatchContext) {
        guard context.phase != .launching,
              let name = appearance.sound.systemName
        else { return }

        let now = Date()
        if let lastSoundAt, now.timeIntervalSince(lastSoundAt) < Self.soundInterval { return }
        lastSoundAt = now

        NSSound(named: name)?.play()
    }

    /// Turns the policy's answer into windows appearing, moving and going away.
    private func apply(
        _ change: StackChange,
        in frame: NSRect,
        newlyAdmitted: BannerID? = nil,
        controller newController: BannerWindowController? = nil
    ) {
        for id in change.removed + change.dropped {
            controllers.removeValue(forKey: id)?.dismiss()
            events.removeValue(forKey: id)
        }

        guard let stack else { return }

        let corner = appearance.corner
        let margin = appearance.margin

        // Banners walk away from their corner: downward from a top one, upward from a
        // bottom one, so the newest is always the one nearest the corner it came from.
        var edge = corner.isTop ? frame.maxY - margin : frame.minY + margin

        for slot in stack.visible {
            guard let controller = controllers[slot.id] ?? newController else { continue }

            // Placed by the width the banner was actually built at, which is only the
            // current setting for banners raised since it last changed.
            let width = (slot.id == newlyAdmitted ? newController?.width : controllers[slot.id]?.width) ?? appearance.width
            let x = corner.isLeading ? frame.minX + margin : frame.maxX - width - margin
            let y = corner.isTop ? edge - slot.height : edge
            let origin = NSPoint(x: x, y: y)

            // It slides in from whichever edge is nearer, so the movement always reads as
            // coming from outside rather than across the screen.
            let offscreenX = corner.isLeading ? frame.minX - width - 4 : frame.maxX + 4

            if slot.id == newlyAdmitted, let newController {
                newController.present(at: origin, enteringFrom: offscreenX)
            } else if change.revealed.contains(slot.id) {
                controller.present(at: origin, enteringFrom: offscreenX)
            } else {
                controller.move(to: origin)
            }

            edge += (corner.isTop ? -1 : 1) * (slot.height + appearance.spacing)
        }

        // A separate pass, after every banner already has its correct, non-overlapping
        // frame: re-asserts window front-to-back order to match the stack's own order,
        // oldest first so the newest — nearest the corner — ends up frontmost. Confirmed
        // live, reproduced on screen, as the fix for a banner left behind a newer one:
        // `move(to:)` repositions a window but was never the thing that also re-fronted
        // it, so a stale front-to-back order from however the windows happened to be
        // created could survive even once every frame was correct again.
        for slot in stack.visible.reversed() {
            controllers[slot.id]?.bringToFront()
        }

        scheduleNextTick()
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

/// Holds the screen-change token across `deinit`, which is not actor-isolated —
/// `NSObjectProtocol` is not `Sendable`, but a box that owns one and only ever removes it
/// can be. The same shape the monitor sources use for their own tokens.
private final class ObserverBox: @unchecked Sendable {
    var token: (any NSObjectProtocol)?

    func removeIfNeeded() {
        if let token { NotificationCenter.default.removeObserver(token) }
    }
}
