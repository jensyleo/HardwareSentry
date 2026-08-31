import AppKit
import SwiftUI

/// The surface a banner draws on, matching the frosted look the system uses for its own
/// notifications so that a banner shown this way does not read as foreign.
struct BannerBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = 12
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// One banner.
///
/// The close control stays out of the way until the pointer arrives, so that a banner
/// reads as a notification rather than as a window with furniture.
struct BannerView: View {
    static let width: CGFloat = 300

    let content: BannerContent
    let onActivate: () -> Void
    let onDismiss: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            icon
                .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(content.title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(Array(content.lines.enumerated()), id: \.offset) { _, line in
                    body(for: line)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(width: Self.width, alignment: .leading)
        .background(BannerBackground())
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .topTrailing) { closeButton }
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
            .font(.subheadline)
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
