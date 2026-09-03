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
    private let appearance: BannerAppearance

    /// How tall this banner turned out once its text was laid out.
    let height: CGFloat

    /// The width this banner was actually built at. Read back rather than taken from the
    /// current appearance, so that banners still on screen from before a width change are
    /// placed by their own size instead of one they never had.
    var width: CGFloat { panel.frame.width }

    init(
        content: BannerContent,
        appearance: BannerAppearance,
        onActivate: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.appearance = appearance
        let hosting = NSHostingView(
            rootView: BannerView(
                content: content,
                appearance: appearance,
                onActivate: onActivate,
                onDismiss: onDismiss
            )
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

    /// Slides the banner in from beyond the nearest screen edge, so it reads as arriving
    /// rather than as appearing out of nowhere — or simply appears, for anyone who would
    /// rather it did not move.
    func present(at origin: NSPoint, enteringFrom offscreenX: CGFloat) {
        guard appearance.isAnimated else {
            panel.setFrame(frame(at: origin), display: true)
            panel.alphaValue = appearance.opacity
            panel.orderFrontRegardless()
            return
        }

        panel.setFrameOrigin(NSPoint(x: offscreenX, y: origin.y))
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { [appearance] context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            // A window's animator moves it by its whole frame. Asking it for a new
            // origin alone is accepted and then quietly ignored, which leaves the banner
            // parked just off the edge of the screen where it was told to start.
            panel.animator().setFrame(frame(at: origin), display: true)
            panel.animator().alphaValue = appearance.opacity
        }
    }

    func move(to origin: NSPoint) {
        guard panel.frame.origin != origin else { return }

        guard appearance.isAnimated else {
            panel.setFrame(frame(at: origin), display: true)
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(frame(at: origin), display: true)
        }
    }

    /// Re-asserts this banner's place in front-to-back order, without touching its
    /// position or restarting its own reveal animation.
    ///
    /// Confirmed live, reproduced on screen: a burst of banners arriving close enough
    /// together — exactly what independent USB and Camera/Audio notices for one physical
    /// connect now produce — could leave one banner's window behind a newer one even
    /// after its frame moved to the correct, non-overlapping slot. `present(at:enteringFrom:)`
    /// calls `orderFrontRegardless()` for a banner that is newly appearing, but `move(to:)`
    /// never did, so an existing banner's place in the window server's own front-to-back
    /// order was fixed the moment it first appeared and never touched again — correct only
    /// as long as no later banner's brief construction work (building the SwiftUI content,
    /// which can pump AppKit's run loop) let a second `present`/`apply` pass interleave
    /// before the first had finished. Called for every visible banner on every
    /// repositioning pass, oldest first, so the stack's own order — newest nearest the
    /// corner — is also always the window order, independent of whatever briefly
    /// interleaved to produce a stale one.
    func bringToFront() {
        panel.orderFrontRegardless()
    }

    private func frame(at origin: NSPoint) -> NSRect {
        NSRect(origin: origin, size: panel.frame.size)
    }

    func dismiss() {
        guard appearance.isAnimated else {
            panel.orderOut(nil)
            return
        }

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
