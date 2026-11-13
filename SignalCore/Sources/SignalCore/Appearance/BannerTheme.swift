import Foundation
import Observation

/// A named way for banners to look.
///
/// Only the look — material, tint, opacity, width, text size, shape, picture — and not where
/// banners appear, how long they stay or what they sound like. Those are about the person's
/// screen and habits rather than about taste, so switching theme never moves a banner to
/// another corner or turns a sound on.
public struct BannerTheme: Codable, Sendable, Equatable, Identifiable {
    public var name: String
    public var material: BannerMaterial
    public var tintRGB: [Double]?
    public var opacity: Double
    public var width: Double
    public var textScale: BannerTextScale
    public var cornerRadius: Double
    public var borderWidth: Double
    public var iconScale: Double
    public var showsIcon: Bool
    public var padding: Double
    public var maximumBodyLines: Int

    public var id: String { name }

    public init(name: String, from appearance: BannerAppearance) {
        self.name = name
        self.material = appearance.material
        if case .custom(let r, let g, let b) = appearance.tint { tintRGB = [r, g, b] } else { tintRGB = nil }
        self.opacity = appearance.opacity
        self.width = Double(appearance.width)
        self.textScale = appearance.textScale
        self.cornerRadius = Double(appearance.cornerRadius)
        self.borderWidth = Double(appearance.borderWidth)
        self.iconScale = Double(appearance.iconScale)
        self.showsIcon = appearance.showsIcon
        self.padding = Double(appearance.padding)
        self.maximumBodyLines = appearance.maximumBodyLines
    }

    /// `appearance` with this theme's look laid over it, everything else left as it was.
    public func applied(to appearance: BannerAppearance) -> BannerAppearance {
        var result = appearance
        result.material = material
        if let rgb = tintRGB, rgb.count == 3 {
            result.tint = .custom(red: rgb[0], green: rgb[1], blue: rgb[2])
        } else {
            result.tint = .systemMaterial
        }
        result.opacity = opacity
        result.width = CGFloat(width)
        result.textScale = textScale
        result.cornerRadius = CGFloat(cornerRadius)
        result.borderWidth = CGFloat(borderWidth)
        result.iconScale = CGFloat(iconScale)
        result.showsIcon = showsIcon
        result.padding = CGFloat(padding)
        result.maximumBodyLines = maximumBodyLines
        return result
    }

    /// Whether `appearance` is exactly this theme's look.
    public func matches(_ appearance: BannerAppearance) -> Bool {
        BannerTheme(name: name, from: appearance) == self
    }

    /// The themes that ship, each a complete look.
    public static let builtIn: [BannerTheme] = [
        BannerTheme(name: "macOS", from: .standard),
        BannerTheme(name: "Glass", from: BannerAppearance(width: 320, opacity: 0.9, material: .hud, cornerRadius: 18, borderWidth: 1, padding: 12)),
        BannerTheme(name: "Compact", from: BannerAppearance(width: 260, textScale: .small, cornerRadius: 8, iconScale: 0.8, padding: 7, maximumBodyLines: 2)),
        BannerTheme(name: "Large", from: BannerAppearance(width: 400, textScale: .large, cornerRadius: 16, iconScale: 1.3, padding: 14)),
        BannerTheme(name: "High contrast", from: BannerAppearance(width: 340, textScale: .large, material: .windowBackground, cornerRadius: 6, borderWidth: 3, iconScale: 1.2, padding: 12)),
        BannerTheme(name: "Minimal", from: BannerAppearance(width: 300, opacity: 0.95, material: .windowBackground, cornerRadius: 4, iconScale: 0.7, showsIcon: false, padding: 8, maximumBodyLines: 1)),
        BannerTheme(name: "Ocean", from: BannerAppearance(opacity: 0.95, tint: .custom(red: 0.05, green: 0.35, blue: 0.75), cornerRadius: 16, borderWidth: 1)),
        BannerTheme(name: "Ember", from: BannerAppearance(opacity: 0.95, tint: .custom(red: 0.8, green: 0.28, blue: 0.1), cornerRadius: 16, borderWidth: 1)),
    ]
}

/// The themes a person has made, kept in their defaults as one encoded list.
@MainActor
@Observable
public final class BannerThemeStore {
    public private(set) var custom: [BannerTheme]

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "SignalCore.Appearance.Themes") {
        self.defaults = defaults
        self.key = key
        if let data = defaults.data(forKey: key), let themes = try? JSONDecoder().decode([BannerTheme].self, from: data) {
            custom = themes
        } else {
            custom = []
        }
        lightThemeName = defaults.string(forKey: key + ".Light")
        darkThemeName = defaults.string(forKey: key + ".Dark")
    }

    /// Called when either automatic choice changes, so the host can apply it at once.
    @ObservationIgnored public var onAutomaticThemeChange: (() -> Void)?

    /// A theme for macOS's light mode and another for its dark mode, by name; nil leaves the
    /// look alone in that mode.
    public var lightThemeName: String? { didSet { defaults.set(lightThemeName, forKey: key + ".Light"); onAutomaticThemeChange?() } }
    public var darkThemeName: String? { didSet { defaults.set(darkThemeName, forKey: key + ".Dark"); onAutomaticThemeChange?() } }

    public var all: [BannerTheme] { BannerTheme.builtIn + custom }

    /// Lays the theme chosen for the current mode over `appearance`; unchanged when none is
    /// chosen or the name no longer exists.
    public func automaticallyApplied(to appearance: BannerAppearance, isDark: Bool) -> BannerAppearance {
        guard let name = isDark ? darkThemeName : lightThemeName, let theme = all.first(where: { $0.name == name }) else {
            return appearance
        }
        return theme.applied(to: appearance)
    }

    public func isBuiltIn(_ theme: BannerTheme) -> Bool { BannerTheme.builtIn.contains { $0.name == theme.name } }

    /// Saves `appearance`'s look under `name`, replacing a theme of the same name the person
    /// made. A name that a shipped theme already has is refused rather than shadowed.
    @discardableResult
    public func save(name: String, from appearance: BannerAppearance) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !BannerTheme.builtIn.contains(where: { $0.name == trimmed }) else { return false }
        let theme = BannerTheme(name: trimmed, from: appearance)
        if let index = custom.firstIndex(where: { $0.name == trimmed }) { custom[index] = theme } else { custom.append(theme) }
        persist()
        return true
    }

    public func delete(_ theme: BannerTheme) {
        custom.removeAll { $0.name == theme.name }
        persist()
    }

    public func exportData() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(custom)
    }

    /// Adds the themes in `data`, skipping any that would shadow a shipped one. Returns how
    /// many were added, or nil if the data was not a list of themes.
    @discardableResult
    public func importData(_ data: Data) -> Int? {
        guard let themes = try? JSONDecoder().decode([BannerTheme].self, from: data) else { return nil }
        var added = 0
        for theme in themes where !BannerTheme.builtIn.contains(where: { $0.name == theme.name }) {
            if let index = custom.firstIndex(where: { $0.name == theme.name }) { custom[index] = theme } else { custom.append(theme) }
            added += 1
        }
        persist()
        return added
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(custom) { defaults.set(data, forKey: key) }
    }
}
