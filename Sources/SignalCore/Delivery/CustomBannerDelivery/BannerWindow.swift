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
    var currentOrigin: NSPoint { panel.frame.origin }

    /// Whether `present(at:enteringFrom:)` has ever run for this banner. `BannerDelivery`
    /// uses this — not "was this the one just admitted" — to decide whether a slot needs
    /// a reveal or a move, which is what lets a still-pending reveal survive an
    /// intervening repositioning pass instead of going stale.
    private(set) var hasAppeared = false

    /// Whether the arrival animation is still running, and where this banner has been
    /// asked to move to in the meantime.
    ///
    /// Both animations drive the same window's frame, and AppKit does not arbitrate
    /// between them: a `move` issued while an arrival is still in flight does not replace
    /// it, it runs alongside it — and the arrival, being the longer of the two, lands
    /// last and wins, dragging the banner back to the slot it arrived at. Confirmed live
    /// against a timed log: the first banner of a burst is asked to move roughly 110ms
    /// into its own 250ms arrival, so it is the one that visibly sticks to the corner
    /// while every later banner — moved only once its arrival is long finished — slides
    /// down correctly. Holding the move until the arrival is done is what makes the last
    /// instruction the one that takes effect.
    private var isArriving = false
    private var isMoving = false

    /// Whether this banner is mid-animation, either arriving or repositioning.
    ///
    /// `BannerDelivery` will not put a new banner into the corner while any banner is
    /// busy: measured against the window server, two banners were otherwise revealed into
    /// the same top slot and overlapped by 146 of their 162 points, the older one only
    /// starting to move down once the newer had fully arrived.
    var isBusy: Bool { isArriving || isMoving }

    private var deferredMove: (origin: NSPoint, completion: @MainActor () -> Void)?

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

        // A throwaway starting size — replaced below once it can be measured for real.
        // Building the panel first and only then measuring, rather than the other way
        // round, is the fix for a real, reproduced-on-screen bug: `fittingSize` read on
        // an `NSHostingView` that has never been attached to a window can undercount
        // wrapped text by a line. Every banner here wraps at least the device name, and
        // Camera's own body regularly wraps a field onto two lines ("Position:
        // Unspecified (typical for external webcams)") — exactly the shape that showed
        // the bug live: the card built one line short, so the next banner's top edge
        // landed over its last line instead of below it.
        panel = BannerPanel(
            contentRect: NSRect(origin: .zero, size: CGSize(width: appearance.width, height: 1)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting

        // Now that the hosting view has a real window behind it, laying it out and
        // asking its *fitting* size answers for the width it will actually render at,
        // not SwiftUI's idea of an unconstrained ideal size.
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        self.height = size.height
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.setContentSize(size)
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
        hasAppeared = true

        guard appearance.isAnimated else {
            panel.setFrame(frame(at: origin), display: true)
            panel.alphaValue = appearance.opacity
            panel.orderFrontRegardless()
            return
        }

        panel.setFrameOrigin(NSPoint(x: offscreenX, y: origin.y))
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        isArriving = true
        NSAnimationContext.runAnimationGroup { [appearance] context in
            context.duration = appearance.animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            // A window's animator moves it by its whole frame. Asking it for a new
            // origin alone is accepted and then quietly ignored, which leaves the banner
            // parked just off the edge of the screen where it was told to start.
            panel.animator().setFrame(frame(at: origin), display: true)
            panel.animator().alphaValue = appearance.opacity
        } completionHandler: { [weak self] in
            // Not declared as running on the main actor, but the animation system always
            // calls it on the main thread — the same assumption `dismiss` already makes.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isArriving = false
                if let deferred = self.deferredMove {
                    self.deferredMove = nil
                    self.move(to: deferred.origin, completion: deferred.completion)
                }
            }
        }
    }

    /// How long a reposition takes to finish — `appearance.animationDuration`, the same
    /// knob the arrival and dismissal animations read. `BannerDelivery` must wait out
    /// this whole duration — not merely start it — before revealing a banner into the
    /// slot this vacates; see the note there.
    var moveDuration: TimeInterval { appearance.animationDuration }

    /// Repositions the banner, calling `completion` once it has actually arrived at
    /// `origin` — including after however long it had to wait for its own arrival
    /// animation to finish first.
    ///
    /// The completion is what a caller waits on before putting a banner into the slot
    /// this one is leaving. A fixed delay cannot stand in for it: a move held back by
    /// `isArriving` finishes a whole arrival later than one that started immediately, and
    /// the newcomer, timed against the fixed delay, lands while the slot is still
    /// occupied. Measured live at ~104ms of genuine overlap on every banner of a burst —
    /// which is what reads, over six banners, as the top one being stuck to the corner
    /// while the rest pile onto it.
    func move(to origin: NSPoint, completion: @escaping @MainActor () -> Void = {}) {
        // Held, not dropped and not run alongside the arrival: see `isArriving`.
        guard !isArriving else {
            // A move already waiting is superseded — its target is stale — but whoever
            // was waiting on it still has to be released.
            deferredMove?.completion()
            deferredMove = (origin, completion)
            return
        }

        guard panel.frame.origin != origin else {
            completion()
            return
        }

        guard appearance.isAnimated else {
            panel.setFrame(frame(at: origin), display: true)
            completion()
            return
        }

        isMoving = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = moveDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(frame(at: origin), display: true)
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.isMoving = false
                completion()
            }
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

        NSAnimationContext.runAnimationGroup { [appearance] context in
            context.duration = appearance.animationDuration
            panel.animator().alphaValue = 0
        } completionHandler: { [panel] in
            // The completion handler is not declared as running on the main actor, but
            // the animation system always calls it on the main thread.
            MainActor.assumeIsolated { panel.orderOut(nil) }
        }
    }
}
