import AppKit
import SwiftUI

/// Draws a `NotificationIcon`, wherever one needs drawing.
///
/// Shared between the banner and the settings screen on purpose: the icon shown next to an
/// event in preferences has to be the icon that will actually arrive, and two separate
/// pieces of drawing code would drift apart the first time either was touched.
public struct NotificationIconView: View {
    private let icon: NotificationIcon

    public init(_ icon: NotificationIcon) {
        self.icon = icon
    }

    public var body: some View {
        switch icon {
        case .symbol(let name):
            Image(systemName: name)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(.secondary)
        case .imageData(let data):
            // An image built from unusable bytes comes back non-nil but invalid, so being
            // handed something is not enough to know it can be drawn.
            if let image = NSImage(data: data), image.isValid {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Self.applicationIcon
            }
        case .none:
            Self.applicationIcon
        }
    }

    /// What a notification with no icon of its own falls back to — the application's, which
    /// is honest about where the message came from.
    @ViewBuilder
    static var applicationIcon: some View {
        if let image = NSApplication.shared.applicationIconImage {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "bell").resizable().aspectRatio(contentMode: .fit)
        }
    }
}

public extension NotificationIcon {
    /// The icon as an image of a definite size.
    ///
    /// Resized rather than merely displayed small, which is what an `NSImageView` with
    /// fixed width and height constraints does and what this replaces. A SwiftUI
    /// `.resizable()` image has no intrinsic size of its own, so any container that asks
    /// its content how big it wants to be — a `Menu` label, a `.fixedSize()`, a toolbar —
    /// is told "as large as you will give me", and the icon fills the window.
    @MainActor
    func image(side: CGFloat) -> NSImage? {
        let source: NSImage?
        switch self {
        case .symbol(let name):
            source = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        case .imageData(let data):
            // An image built from unusable bytes comes back non-nil but invalid, so being
            // handed something is not enough to know it can be drawn.
            let candidate = NSImage(data: data)
            source = (candidate?.isValid ?? false) ? candidate : nil
        case .none:
            source = nil
        }
        guard let source else { return nil }
        return source.resized(toFit: side)
    }
}

public extension NSImage {
    /// A copy scaled to fit a square of `side`, keeping its proportions — a wide image is
    /// letterboxed rather than squashed.
    func resized(toFit side: CGFloat) -> NSImage {
        let scale = min(side / max(size.width, 1), side / max(size.height, 1))
        let drawn = NSSize(width: size.width * scale, height: size.height * scale)
        let result = NSImage(size: NSSize(width: side, height: side))
        result.lockFocus()
        draw(in: NSRect(
            x: (side - drawn.width) / 2,
            y: (side - drawn.height) / 2,
            width: drawn.width,
            height: drawn.height
        ))
        result.unlockFocus()
        return result
    }
}
