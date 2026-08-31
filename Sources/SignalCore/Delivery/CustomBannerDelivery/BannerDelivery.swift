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

    private let margin: CGFloat
    private let spacing: CGFloat
    private let visibleFrame: @MainActor () -> NSRect?

    public init(
        margin: CGFloat = 12,
        spacing: CGFloat = 8,
        visibleFrame: @escaping @MainActor () -> NSRect? = { NSScreen.main?.visibleFrame }
    ) {
        self.margin = margin
        self.spacing = spacing
        self.visibleFrame = visibleFrame
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
            availableHeight: frame.height - margin * 2,
            spacing: spacing
        )
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

        let offscreenX = frame.maxX + 4
        var top = frame.maxY - margin

        for slot in stack.visible {
            guard let controller = controllers[slot.id] else { continue }
            let origin = NSPoint(x: frame.maxX - BannerView.width - margin, y: top - slot.height)

            if slot.id == newlyAdmitted, let newController {
                newController.present(at: origin, enteringFrom: offscreenX)
            } else if change.revealed.contains(slot.id) {
                controller.present(at: origin, enteringFrom: offscreenX)
            } else {
                controller.move(to: origin)
            }

            top -= slot.height + spacing
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
