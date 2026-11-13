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
public enum BannerTextScale: String, Codable, Sendable, Equatable, CaseIterable {
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
/// A choice of the system's own materials, each of which already adapts itself to light
/// and dark — the reason a flat colour was left out for a long time. Someone who wants
/// one anyway can now have it (`BannerTint.custom`), tinted *over* whichever of these
/// three still supplies the glass underneath it, rather than replacing it — the tint
/// colours the light, it does not become the surface.
public enum BannerMaterial: String, Codable, Sendable, Equatable, CaseIterable {
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

/// A colour tint over the banner's material, for someone who wants more than the three
/// system looks offer.
///
/// `.systemMaterial` — the default — draws exactly what `BannerMaterial` alone always
/// drew. `.custom` overlays a translucent colour on top of that same glass rather than
/// replacing it outright: a flat colour with nothing behind it does not adapt to light and
/// dark and fights the vibrancy that makes a banner read as part of macOS, so the glass
/// stays, tinted, instead of being torn out.
public enum BannerTint: Sendable, Equatable {
    case systemMaterial
    /// Components in 0...1, matching `Color`'s own range, so a stored value is never
    /// something SwiftUI has to be told how to reinterpret.
    case custom(red: Double, green: Double, blue: Double)

    public var isCustom: Bool { if case .custom = self { true } else { false } }
}

/// What a banner sounds like, if anything.
///
/// The macOS system sounds rather than anything shipped here: they are what a person
/// already recognises as their computer speaking, and they follow the sound settings and
/// output device without this package doing anything about it.
public enum BannerSound: String, Codable, Sendable, Equatable, CaseIterable {
    case none
    case basso = "Basso", blow = "Blow", bottle = "Bottle", frog = "Frog"
    case funk = "Funk", glass = "Glass", hero = "Hero", morse = "Morse"
    case ping = "Ping", pop = "Pop", purr = "Purr", sosumi = "Sosumi"
    case submarine = "Submarine", tink = "Tink"

    public var label: String { self == .none ? "None" : rawValue }

    /// The name to ask the system for, or nil when silence was chosen.
    public var systemName: String? { self == .none ? nil : rawValue }
}

/// The kind of news a notification carries, which is what a person tells banners apart by.
public enum BannerSeverity: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Nothing is marked: a plain notice.
    case info
    /// Arrived, mounted, back to normal.
    case connected
    /// Left, unmounted, switched off.
    case gone
    /// Low, failing, too hot, nearly full.
    case attention
    /// Serious trouble: a disk that cannot be read, a volume out of space.
    case critical

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .info: return "Information"
        case .connected: return "Connected / back to normal"
        case .gone: return "Gone / switched off"
        case .attention: return "Needs attention"
        case .critical: return "Critical"
        }
    }

    public init(badge: IconBadge?) {
        switch badge {
        case .positive: self = .connected
        case .negative: self = .gone
        case .warning, .blocked, .ink: self = .attention
        case .critical: self = .critical
        case .favorite: self = .connected
        case nil: self = .info
        }
    }
}

/// What is different about one kind of banner, on top of the look everyone shares.
public struct BannerSeverityStyle: Codable, Sendable, Equatable {
    /// An outline colour, red-green-blue; nil leaves the usual outline.
    public var accent: [Double]?
    /// A sound of its own; nil uses the one chosen for every banner.
    public var sound: BannerSound?
    /// Stays until it is closed instead of leaving by itself.
    public var staysUntilDismissed: Bool

    public init(accent: [Double]? = nil, sound: BannerSound? = nil, staysUntilDismissed: Bool = false) {
        self.accent = accent
        self.sound = sound
        self.staysUntilDismissed = staysUntilDismissed
    }

    public var isDefault: Bool { self == BannerSeverityStyle() }
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
    public var tint: BannerTint
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
    /// How round the banner's corners are, in points.
    public var cornerRadius: CGFloat { didSet { cornerRadius = cornerRadius.clamped(to: Self.cornerRadiusRange) } }
    /// The outline drawn round the banner; zero draws none.
    public var borderWidth: CGFloat { didSet { borderWidth = borderWidth.clamped(to: Self.borderWidthRange) } }
    /// The picture's size relative to the text, so a picture can be made to read from across
    /// a room or made small enough to stay out of the way.
    public var iconScale: CGFloat { didSet { iconScale = iconScale.clamped(to: Self.iconScaleRange) } }
    /// Whether the picture is drawn at all.
    public var showsIcon: Bool
    /// Space between the banner's edge and what is in it.
    public var padding: CGFloat { didSet { padding = padding.clamped(to: Self.paddingRange) } }
    /// The most lines of body text a banner shows; zero is as many as there are.
    public var maximumBodyLines: Int { didSet { maximumBodyLines = maximumBodyLines.clamped(to: Self.bodyLinesRange) } }
    /// What sets each kind of notice apart; a kind missing here looks like all the others.
    public var severityStyles: [BannerSeverity: BannerSeverityStyle]
    public var quietHours: QuietHours
    /// A sound for everything one module says, by the module's name. Beneath a kind of notice's own, above the shared one.
    public var moduleSounds: [String: BannerSound]
    /// How long one module's banners stay, by the module's name, in place of the shared time.
    public var moduleLifetimes: [String: TimeInterval]

    public func style(for severity: BannerSeverity) -> BannerSeverityStyle {
        severityStyles[severity] ?? BannerSeverityStyle()
    }

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
    public static let cornerRadiusRange: ClosedRange<CGFloat> = 0...28
    public static let borderWidthRange: ClosedRange<CGFloat> = 0...4
    public static let iconScaleRange: ClosedRange<CGFloat> = 0.5...1.8
    public static let paddingRange: ClosedRange<CGFloat> = 4...22
    public static let bodyLinesRange: ClosedRange<Int> = 0...12

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
        tint: BannerTint = .systemMaterial,
        isAnimated: Bool = true,
        sound: BannerSound = .none,
        screen: BannerScreen = .withPointer,
        animationDuration: TimeInterval = 0.25,
        cornerRadius: CGFloat = 12,
        borderWidth: CGFloat = 0,
        iconScale: CGFloat = 1,
        showsIcon: Bool = true,
        padding: CGFloat = 10,
        maximumBodyLines: Int = 0,
        severityStyles: [BannerSeverity: BannerSeverityStyle] = [:],
        quietHours: QuietHours = QuietHours(),
        moduleSounds: [String: BannerSound] = [:],
        moduleLifetimes: [String: TimeInterval] = [:]
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
        self.tint = tint
        self.isAnimated = isAnimated
        self.sound = sound
        self.screen = screen
        self.animationDuration = animationDuration.clamped(to: Self.animationDurationRange)
        self.cornerRadius = cornerRadius.clamped(to: Self.cornerRadiusRange)
        self.borderWidth = borderWidth.clamped(to: Self.borderWidthRange)
        self.iconScale = iconScale.clamped(to: Self.iconScaleRange)
        self.showsIcon = showsIcon
        self.padding = padding.clamped(to: Self.paddingRange)
        self.maximumBodyLines = maximumBodyLines.clamped(to: Self.bodyLinesRange)
        self.severityStyles = severityStyles.filter { !$0.value.isDefault }
        self.quietHours = quietHours
        self.moduleSounds = moduleSounds
        self.moduleLifetimes = moduleLifetimes.mapValues { $0.clamped(to: Self.lifetimeRange) }
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
