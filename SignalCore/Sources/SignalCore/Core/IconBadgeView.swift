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
        if badge == .critical {
            RadiationMark()
                .frame(width: side, height: side)
                .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                .offset(x: side * 0.15, y: side * 0.15)
                .accessibilityLabel(Self.label(for: badge))
        } else {
            symbolBadge
        }
    }

    private var symbolBadge: some View {
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
        case .favorite: "star.circle.fill"
        case .blocked: "minus.circle.fill"
        case .ink: "drop.circle.fill"
        case .critical: "exclamationmark.octagon.fill"
        }
    }

    static func color(for badge: IconBadge) -> Color {
        switch badge {
        case .positive: .green
        case .negative: .red
        case .warning: .yellow
        case .favorite: .yellow
        case .blocked: .red
        case .ink: .red
        case .critical: .yellow
        }
    }

    static func label(for badge: IconBadge) -> String {
        switch badge {
        case .positive: "Connected"
        case .negative: "Disconnected"
        case .warning: "Needs attention"
        case .favorite: "Default"
        case .blocked: "Blocked"
        case .ink: "Running low"
        case .critical: "Critical"
        }
    }
}

/// The radiation trefoil on a yellow disc, ringed in white like the other marks.
///
/// Drawn rather than taken from a symbol set: there is no such symbol, and this is the same
/// mark this application's own critical-disk pictures carry, so a critical notice looks the
/// same whichever way its picture was chosen.
struct RadiationMark: View {
    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                Circle().fill(.white).padding(-1.5)
                Circle().fill(.black)
                Circle().fill(Color(red: 1, green: 0.96, blue: 0.2)).padding(side * 0.05)
                ForEach(0..<3) { index in
                    Sector(start: Double(index) * 120 + 30, span: 60)
                        .fill(.black)
                        .padding(side * 0.12)
                }
                Circle().fill(Color(red: 1, green: 0.96, blue: 0.2)).frame(width: side * 0.24, height: side * 0.24)
                Circle().fill(.black).frame(width: side * 0.16, height: side * 0.16)
            }
            .frame(width: side, height: side)
        }
    }

    private struct Sector: Shape {
        let start: Double
        let span: Double

        func path(in rect: CGRect) -> Path {
            var path = Path()
            let center = CGPoint(x: rect.midX, y: rect.midY)
            path.move(to: center)
            path.addArc(center: center, radius: min(rect.width, rect.height) / 2,
                        startAngle: .degrees(start), endAngle: .degrees(start + span), clockwise: false)
            path.closeSubpath()
            return path
        }
    }
}
