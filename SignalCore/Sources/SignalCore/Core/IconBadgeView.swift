import SwiftUI

/// The small mark in the corner of an icon that says which way something went.
///
/// Drawn the way macOS marks a shared folder or an alias: a filled glyph in the bottom
/// corner, ringed in white so it reads on a dark picture and a light one alike. Colour
/// carries the meaning and the glyph repeats it, so it still reads for someone who cannot
/// tell the colours apart.
public struct IconBadgeView: View {
    let badge: IconBadge
    let iconSide: CGFloat

    public init(badge: IconBadge, iconSide: CGFloat) {
        self.badge = badge
        self.iconSide = iconSide
    }

    /// Big enough to read at a glance, small enough to leave the device recognisable.
    private var side: CGFloat { max(10, iconSide * 0.42) }

    public var body: some View {
        Image(systemName: Self.symbol(for: badge))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .symbolRenderingMode(.palette)
            .foregroundStyle(badge == .warning ? Color.black.opacity(0.85) : .white, Self.color(for: badge))
            .frame(width: side, height: side)
            // A circle is ringed in white; the warning triangle keeps its own outline.
            .background {
                if badge == .warning {
                    Image(systemName: "triangle.fill").resizable().aspectRatio(contentMode: .fit)
                        .foregroundStyle(.white).scaleEffect(1.12)
                } else {
                    Circle().fill(.white).padding(-1.5)
                }
            }
            .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
            // Pulled slightly past the corner, as macOS's own badges sit, so it covers
            // less of the picture it is marking.
            .offset(x: side * 0.15, y: side * 0.15)
            .accessibilityLabel(Self.label(for: badge))
    }

    static func symbol(for badge: IconBadge) -> String {
        switch badge {
        case .positive: "checkmark.circle.fill"
        case .negative: "xmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        }
    }

    static func color(for badge: IconBadge) -> Color {
        switch badge {
        case .positive: .green
        case .negative: .red
        case .warning: .yellow
        }
    }

    static func label(for badge: IconBadge) -> String {
        switch badge {
        case .positive: "Connected"
        case .negative: "Disconnected"
        case .warning: "Needs attention"
        }
    }
}
