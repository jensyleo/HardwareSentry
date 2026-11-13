import AppKit
import SwiftUI

/// The surface a banner draws on, matching the frosted look the system uses for its own
/// notifications so that a banner shown this way does not read as foreign.
struct BannerBackground: NSViewRepresentable {
    let material: BannerMaterial
    var cornerRadius: CGFloat = 12

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.masksToBounds = true
        view.material = Self.material(for: material)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = Self.material(for: material)
        nsView.layer?.cornerRadius = cornerRadius
    }

    private static func material(for material: BannerMaterial) -> NSVisualEffectView.Material {
        switch material {
        case .popover: return .popover
        case .hud: return .hudWindow
        case .windowBackground: return .windowBackground
        }
    }
}

/// One banner.
///
/// The close control stays out of the way until the pointer arrives, so that a banner
/// reads as a notification rather than as a window with furniture. It sits in the
/// top-left corner, where macOS itself puts it, rather than the top-right.
struct BannerView: View {
    /// The sizes the banner's two pieces of text are drawn at before the person's chosen
    /// scale is applied — matching what `.headline` and `.subheadline` resolve to on
    /// macOS, so that leaving the scale alone leaves the banner looking as it always did.
    private static let titleSize: CGFloat = 13
    private static let lineSize: CGFloat = 11

    let content: BannerContent
    let appearance: BannerAppearance
    let onActivate: () -> Void
    let onDismiss: () -> Void

    @State private var isHovering = false

    /// The body lines the person asked to see: all of them, or only the first few.
    private var visibleLines: [BannerContent.Line] {
        appearance.maximumBodyLines == 0 ? content.lines : Array(content.lines.prefix(appearance.maximumBodyLines))
    }

    private var iconSide: CGFloat { 36 * appearance.textScale.factor * appearance.iconScale }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if appearance.showsIcon {
                icon
                    .frame(width: iconSide, height: iconSide)
                    .overlay(alignment: .bottomTrailing) {
                        if let badge = content.badge {
                            IconBadgeView(badge: badge, iconSide: iconSide)
                        }
                    }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(content.title)
                    .font(.system(size: Self.titleSize * appearance.textScale.factor, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(Array(visibleLines.enumerated()), id: \.offset) { _, line in
                    body(for: line)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(appearance.padding)
        .frame(width: appearance.width, alignment: .leading)
        .background {
            ZStack {
                BannerBackground(material: appearance.material, cornerRadius: appearance.cornerRadius)
                // Tinted over the glass, not instead of it — a flat colour with nothing
                // behind it would not adapt to light and dark, and would fight the
                // vibrancy that makes a banner read as part of macOS.
                if case .custom(let red, let green, let blue) = appearance.tint {
                    Color(red: red, green: green, blue: blue).opacity(0.55)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: appearance.cornerRadius, style: .continuous))
        .overlay {
            let accent = appearance.style(for: content.severity).accent
            if appearance.borderWidth > 0 || accent != nil {
                RoundedRectangle(cornerRadius: appearance.cornerRadius, style: .continuous)
                    .strokeBorder(
                        accent.flatMap { $0.count == 3 ? Color(red: $0[0], green: $0[1], blue: $0[2]) : nil } ?? Color.primary.opacity(0.35),
                        lineWidth: accent != nil ? max(appearance.borderWidth, 2) : appearance.borderWidth
                    )
            }
        }
        // Top-left, where macOS puts it in Notification Center — over the icon's own
        // corner, which is why it only appears once the pointer is on the banner.
        .overlay(alignment: .topLeading) { closeButton }
        .contentShape(Rectangle())
        .onTapGesture(perform: onActivate)
        .onHover { isHovering = $0 }
    }

    @ViewBuilder
    private var icon: some View {
        switch content.icon {
        case .symbol(let name):
            Image(systemName: name)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(.secondary)
        case .imageData(let data):
            // An image built from unusable bytes comes back non-nil but invalid, so
            // being handed something is not enough to know it can be drawn.
            if let image = NSImage(data: data), image.isValid {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                applicationIcon
            }
        case .none:
            applicationIcon
        }
    }

    @ViewBuilder
    private var applicationIcon: some View {
        if let image = NSApp?.applicationIconImage {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Color.clear
        }
    }

    private func body(for line: BannerContent.Line) -> some View {
        (Text(line.leading).foregroundStyle(.secondary)
            + Text(line.emphasised ?? "").foregroundStyle(Color.accentColor).bold())
            .font(.system(size: Self.lineSize * appearance.textScale.factor))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var closeButton: some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .padding(4)
        .opacity(isHovering ? 1 : 0)
        .animation(.easeInOut(duration: 0.15), value: isHovering)
        .accessibilityLabel("Dismiss")
    }
}
