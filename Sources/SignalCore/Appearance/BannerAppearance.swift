import CoreGraphics
import Foundation

/// Which corner banners appear in, and therefore which way they stack and slide in from.
public enum BannerCorner: String, Sendable, Equatable, CaseIterable {
    case topLeading
    case topTrailing
    case bottomLeading
    case bottomTrailing

    public var isTop: Bool { self == .topLeading || self == .topTrailing }
    public var isLeading: Bool { self == .topLeading || self == .bottomLeading }

    public var label: String {
        switch self {
        case .topLeading: return "Top left"
        case .topTrailing: return "Top right"
        case .bottomLeading: return "Bottom left"
        case .bottomTrailing: return "Bottom right"
        }
    }
}

/// How large a banner's text is drawn, relative to the system's own notification text.
public enum BannerTextScale: String, Sendable, Equatable, CaseIterable {
    case small
    case medium
    case large

    /// Multiplies the font sizes the banner would otherwise use.
    public var factor: CGFloat {
        switch self {
        case .small: return 0.85
        case .medium: return 1
        case .large: return 1.2
        }
    }

    public var label: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        }
    }
}

/// The surface a banner is drawn on.
///
/// Offered as a choice of the system's own materials rather than as a free colour: a
/// banner should look like it belongs to macOS, and each of these already adapts itself
/// to light and dark. A flat colour picked by hand would do neither.
public enum BannerMaterial: String, Sendable, Equatable, CaseIterable {
    case popover
    case hud
    case windowBackground

    public var label: String {
        switch self {
        case .popover: return "Popover (default)"
        case .hud: return "Heads-up display"
        case .windowBackground: return "Window background"
        }
    }
}

/// What a banner sounds like, if anything.
///
/// The macOS system sounds rather than anything shipped here: they are what a person
/// already recognises as their computer speaking, and they follow the sound settings and
/// output device without this package doing anything about it.
public enum BannerSound: String, Sendable, Equatable, CaseIterable {
    case none
    case basso = "Basso", blow = "Blow", bottle = "Bottle", frog = "Frog"
    case funk = "Funk", glass = "Glass", hero = "Hero", morse = "Morse"
    case ping = "Ping", pop = "Pop", purr = "Purr", sosumi = "Sosumi"
    case submarine = "Submarine", tink = "Tink"

    public var label: String { self == .none ? "None" : rawValue }

    /// The name to ask the system for, or nil when silence was chosen.
    public var systemName: String? { self == .none ? nil : rawValue }
}

/// How banners look and where they appear.
///
/// Everything here is a presentation choice, deliberately separate from which
/// notifications a person wants to receive — that is what `NotificationPreferences`
/// answers. An application can therefore offer this screen without knowing anything
/// about its own events, which is what lets the same editor serve every application
/// built on this package.
///
/// Values are clamped rather than trusted. They are read back from a store anyone can
/// edit, and a banner zero points wide is not a preference — it is a banner nobody can
/// see, from an application that appears to have stopped working.
public struct BannerAppearance: Sendable, Equatable {
    public var corner: BannerCorner
    public var textScale: BannerTextScale
    public var material: BannerMaterial
    public var isAnimated: Bool
    public var sound: BannerSound
    /// How long the slide-in, reposition and fade-out animations take.
    ///
    /// One knob for the three of them rather than one each: they read as a single
    /// movement — arrive, settle into the stack, leave — and letting them drift apart
    /// would make that movement look like three separate things happening to be timed
    /// close together instead of the one thing it is.
    public var animationDuration: TimeInterval { didSet { animationDuration = animationDuration.clamped(to: Self.animationDurationRange) } }
    /// Which display banners appear on. Only distinguishable with more than one.
    public var screen: BannerScreen

    // Clamped on the way in as well as at construction, so the invariant holds however
    // the value was arrived at — loaded from a store, or set field by field by an editor.
    public var width: CGFloat { didSet { width = width.clamped(to: Self.widthRange) } }
    public var margin: CGFloat { didSet { margin = margin.clamped(to: Self.marginRange) } }
    public var spacing: CGFloat { didSet { spacing = spacing.clamped(to: Self.spacingRange) } }
    public var visibleLifetime: TimeInterval { didSet { visibleLifetime = visibleLifetime.clamped(to: Self.lifetimeRange) } }
    public var opacity: Double { didSet { opacity = opacity.clamped(to: Self.opacityRange) } }
    /// The most banners on screen at once.
    ///
    /// A count as well as a height, because a tall display fits about fifteen, and fifteen
    /// banners is not a notification — it is a page of text that appears and vanishes. The
    /// default sits at the top of the allowed range rather than picking a smaller number:
    /// a hub arriving with everything plugged into it announcing itself at once is exactly
    /// the burst this exists to shape, and the count should not be what queues banners —
    /// confirmed live, reported as HardwareSentry taking noticeably longer than HG4MAC to
    /// say a hub had connected, traced to a default of 5 that bit before the real screen
    /// ever ran out of room, where HG4MAC has no count limit at all, only the screen's own
    /// height. Left adjustable rather than removed, for the person who does want fewer.
    public var maximumVisible: Int { didSet { maximumVisible = maximumVisible.clamped(to: Self.maximumVisibleRange) } }
    /// How long to leave between one banner appearing and the next.
    ///
    /// The reason a burst reads as a stack rather than a flash. Banners revealed at the
    /// same instant expire at the same instant, so the whole screenful blinks out together
    /// and the next screenful replaces it; letting them in one at a time makes them leave
    /// one at a time as well.
    public var revealSpacing: TimeInterval { didSet { revealSpacing = revealSpacing.clamped(to: Self.revealSpacingRange) } }

    public static let maximumVisibleRange: ClosedRange<Int> = 1...12
    public static let revealSpacingRange: ClosedRange<TimeInterval> = 0...2
    public static let widthRange: ClosedRange<CGFloat> = 240...520
    public static let marginRange: ClosedRange<CGFloat> = 0...80
    public static let spacingRange: ClosedRange<CGFloat> = 0...32
    public static let lifetimeRange: ClosedRange<TimeInterval> = 2...30
    public static let opacityRange: ClosedRange<Double> = 0.3...1
    public static let animationDurationRange: ClosedRange<TimeInterval> = 0.1...1

    /// What a banner looks like for someone who has never opened the settings — the
    /// behaviour this package had before any of it was configurable.
    public static let standard = BannerAppearance()

    public init(
        corner: BannerCorner = .topTrailing,
        width: CGFloat = 300,
        margin: CGFloat = 12,
        spacing: CGFloat = 8,
        visibleLifetime: TimeInterval = 5,
        maximumVisible: Int = 12,
        revealSpacing: TimeInterval = 0.4,
        opacity: Double = 1,
        textScale: BannerTextScale = .medium,
        material: BannerMaterial = .popover,
        isAnimated: Bool = true,
        sound: BannerSound = .none,
        screen: BannerScreen = .withPointer,
        animationDuration: TimeInterval = 0.25
    ) {
        self.corner = corner
        self.width = width.clamped(to: Self.widthRange)
        self.margin = margin.clamped(to: Self.marginRange)
        self.spacing = spacing.clamped(to: Self.spacingRange)
        self.visibleLifetime = visibleLifetime.clamped(to: Self.lifetimeRange)
        self.maximumVisible = maximumVisible.clamped(to: Self.maximumVisibleRange)
        self.revealSpacing = revealSpacing.clamped(to: Self.revealSpacingRange)
        self.opacity = opacity.clamped(to: Self.opacityRange)
        self.textScale = textScale
        self.material = material
        self.isAnimated = isAnimated
        self.sound = sound
        self.screen = screen
        self.animationDuration = animationDuration.clamped(to: Self.animationDurationRange)
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
