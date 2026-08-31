import AppKit
import SwiftUI

/// A panel that shows a banner without ever taking focus.
///
/// Notifications must not interrupt: clicking one should not pull the host application
/// forward, and a banner appearing must not take the keyboard away from whatever the
/// person is doing. Hence a non-activating panel that floats above ordinary windows and
/// follows the person between spaces.
final class BannerPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Owns one banner's window: putting it up, moving it as the stack shifts, taking it down.
@MainActor
final class BannerWindowController {
    private let panel: BannerPanel

    /// How tall this banner turned out once its text was laid out.
    let height: CGFloat

    init(
        content: BannerContent,
        onActivate: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        let hosting = NSHostingView(
            rootView: BannerView(content: content, onActivate: onActivate, onDismiss: onDismiss)
        )
        // The width is fixed, so laying out the text is what settles the height — which
        // the stacking policy needs before it can decide whether this banner fits.
        let size = hosting.fittingSize
        self.height = size.height
        hosting.frame = NSRect(origin: .zero, size: size)

        panel = BannerPanel(
            contentRect: hosting.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.animationBehavior = .none
    }

    /// Slides the banner in from beyond the right edge, so it reads as arriving rather
    /// than as appearing out of nowhere.
    func present(at origin: NSPoint, enteringFrom offscreenX: CGFloat) {
        panel.setFrameOrigin(NSPoint(x: offscreenX, y: origin.y))
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            // A window's animator moves it by its whole frame. Asking it for a new
            // origin alone is accepted and then quietly ignored, which leaves the banner
            // parked just off the edge of the screen where it was told to start.
            panel.animator().setFrame(frame(at: origin), display: true)
            panel.animator().alphaValue = 1
        }
    }

    func move(to origin: NSPoint) {
        guard panel.frame.origin != origin else { return }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(frame(at: origin), display: true)
        }
    }

    private func frame(at origin: NSPoint) -> NSRect {
        NSRect(origin: origin, size: panel.frame.size)
    }

    func dismiss() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        } completionHandler: { [panel] in
            // The completion handler is not declared as running on the main actor, but
            // the animation system always calls it on the main thread.
            MainActor.assumeIsolated { panel.orderOut(nil) }
        }
    }
}
