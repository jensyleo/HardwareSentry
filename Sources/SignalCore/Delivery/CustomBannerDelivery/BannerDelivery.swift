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
    private var expiryTask: Task<Void, Never>?

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
            relayout()
        }
    }

    private let visibleFrame: @MainActor () -> NSRect?
    /// When a sound was last played, so a handful of banners arriving together do not
    /// arrive as a burst of chimes.
    private var lastSoundAt: Date?

    /// Two banners closer together than this share one sound. Long enough to collapse the
    /// "several devices woke up at once" case, short enough that separate events an
    /// unhurried person causes each still make a noise.
    private static let soundInterval: TimeInterval = 1

    public init(
        appearance: BannerAppearance = .standard,
        visibleFrame: @escaping @MainActor () -> NSRect? = { NSScreen.main?.visibleFrame }
    ) {
        self.appearance = appearance
        self.visibleFrame = visibleFrame
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

    private func expireDue() {
        guard let frame = visibleFrame(), var stack else { return }

        let change = stack.expire(at: Date())
        self.stack = stack
        guard !change.isEmpty else { return }

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
            visibleLifetime: appearance.visibleLifetime
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

        scheduleNextExpiry()
    }

    /// One timer for the whole stack rather than one per banner: the policy already knows
    /// which banner is due first.
    private func scheduleNextExpiry() {
        expiryTask?.cancel()
        expiryTask = nil

        guard let due = stack?.nextExpiry() else { return }
        let interval = due.timeIntervalSinceNow

        expiryTask = Task { [weak self] in
            if interval > 0 {
                try? await Task.sleep(for: .seconds(interval))
            }
            guard !Task.isCancelled else { return }
            self?.expireDue()
        }
    }
}
