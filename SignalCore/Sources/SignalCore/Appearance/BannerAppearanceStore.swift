import CoreGraphics
import Foundation
import Observation

/// Remembers how banners should look, in the user's defaults.
///
/// Kept apart from `NotificationPreferencesStore` on purpose: that one answers "does this
/// person want to hear about this event", which is a boolean per event and grows with the
/// application's modules. This one answers "what should a banner look like", which is a
/// fixed handful of presentation values and is the same question in every application
/// built on this package.
///
/// Each value is its own key rather than one encoded blob, so that settings can be read
/// and set from the command line, and so that adding a value later cannot fail to decode
/// everything a person had already chosen.
@MainActor
@Observable
public final class BannerAppearanceStore {
    /// Writing to this saves it. Views bind to it directly.
    public var appearance: BannerAppearance {
        didSet {
            guard appearance != oldValue else { return }
            save()
        }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let keyPrefix: String

    public init(defaults: UserDefaults = .standard, keyPrefix: String = "SignalCore.Appearance") {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
        self.appearance = Self.load(from: defaults, keyPrefix: keyPrefix)
    }

    /// Forgets every choice, so banners look the way they do out of the box again.
    ///
    /// The keys are cleared *after* the assignment, not before: assigning saves, so
    /// clearing first would leave today's standard values written out as if they had been
    /// chosen — pinning this person to them even if a later version changes what standard
    /// means.
    public func reset() {
        appearance = .standard
        for key in Key.allCases {
            defaults.removeObject(forKey: "\(keyPrefix).\(key.rawValue)")
        }
    }

    private enum Key: String, CaseIterable {
        case corner, width, margin, spacing, visibleLifetime, maximumVisible, revealSpacing, opacity, textScale, material, isAnimated, sound, screen, animationDuration
        case tintIsCustom, tintRed, tintGreen, tintBlue
        case cornerRadius, borderWidth, iconScale, showsIcon, padding, maximumBodyLines, severityStyles, quietHours, moduleSounds, moduleLifetimes
    }

    private func key(_ key: Key) -> String { "\(keyPrefix).\(key.rawValue)" }

    private func save() {
        defaults.set(appearance.corner.rawValue, forKey: key(.corner))
        defaults.set(Double(appearance.width), forKey: key(.width))
        defaults.set(Double(appearance.margin), forKey: key(.margin))
        defaults.set(Double(appearance.spacing), forKey: key(.spacing))
        defaults.set(appearance.visibleLifetime, forKey: key(.visibleLifetime))
        defaults.set(appearance.maximumVisible, forKey: key(.maximumVisible))
        defaults.set(appearance.revealSpacing, forKey: key(.revealSpacing))
        defaults.set(appearance.opacity, forKey: key(.opacity))
        defaults.set(appearance.textScale.rawValue, forKey: key(.textScale))
        defaults.set(appearance.material.rawValue, forKey: key(.material))
        defaults.set(appearance.isAnimated, forKey: key(.isAnimated))
        defaults.set(appearance.sound.rawValue, forKey: key(.sound))
        defaults.set(appearance.screen.rawValue, forKey: key(.screen))
        defaults.set(appearance.animationDuration, forKey: key(.animationDuration))
        defaults.set(Double(appearance.cornerRadius), forKey: key(.cornerRadius))
        defaults.set(Double(appearance.borderWidth), forKey: key(.borderWidth))
        defaults.set(Double(appearance.iconScale), forKey: key(.iconScale))
        defaults.set(appearance.showsIcon, forKey: key(.showsIcon))
        defaults.set(Double(appearance.padding), forKey: key(.padding))
        defaults.set(appearance.maximumBodyLines, forKey: key(.maximumBodyLines))
        if let data = try? JSONEncoder().encode(appearance.moduleLifetimes) { defaults.set(data, forKey: key(.moduleLifetimes)) }
        if let data = try? JSONEncoder().encode(appearance.moduleSounds) { defaults.set(data, forKey: key(.moduleSounds)) }
        if let data = try? JSONEncoder().encode(appearance.quietHours) { defaults.set(data, forKey: key(.quietHours)) }
        if let data = try? JSONEncoder().encode(appearance.severityStyles.reduce(into: [String: BannerSeverityStyle]()) { $0[$1.key.rawValue] = $1.value }) {
            defaults.set(data, forKey: key(.severityStyles))
        }
        switch appearance.tint {
        case .systemMaterial:
            defaults.set(false, forKey: key(.tintIsCustom))
        case .custom(let red, let green, let blue):
            defaults.set(true, forKey: key(.tintIsCustom))
            defaults.set(red, forKey: key(.tintRed))
            defaults.set(green, forKey: key(.tintGreen))
            defaults.set(blue, forKey: key(.tintBlue))
        }
    }

    /// Anything missing or unrecognised falls back to the standard value for that field
    /// alone — one unreadable setting must not throw away the rest of someone's choices.
    private static func load(from defaults: UserDefaults, keyPrefix: String) -> BannerAppearance {
        func key(_ key: Key) -> String { "\(keyPrefix).\(key.rawValue)" }
        func number(_ k: Key, _ fallback: Double) -> Double {
            defaults.object(forKey: key(k)) as? Double ?? fallback
        }

        let standard = BannerAppearance.standard
        return BannerAppearance(
            corner: (defaults.string(forKey: key(.corner)).flatMap(BannerCorner.init(rawValue:))) ?? standard.corner,
            width: CGFloat(number(.width, Double(standard.width))),
            margin: CGFloat(number(.margin, Double(standard.margin))),
            spacing: CGFloat(number(.spacing, Double(standard.spacing))),
            visibleLifetime: number(.visibleLifetime, standard.visibleLifetime),
            maximumVisible: defaults.object(forKey: key(.maximumVisible)) as? Int ?? standard.maximumVisible,
            revealSpacing: number(.revealSpacing, standard.revealSpacing),
            opacity: number(.opacity, standard.opacity),
            textScale: (defaults.string(forKey: key(.textScale)).flatMap(BannerTextScale.init(rawValue:))) ?? standard.textScale,
            material: (defaults.string(forKey: key(.material)).flatMap(BannerMaterial.init(rawValue:))) ?? standard.material,
            tint: (defaults.object(forKey: key(.tintIsCustom)) as? Bool ?? false)
                ? .custom(
                    red: number(.tintRed, 0),
                    green: number(.tintGreen, 0),
                    blue: number(.tintBlue, 1)
                )
                : .systemMaterial,
            isAnimated: defaults.object(forKey: key(.isAnimated)) as? Bool ?? standard.isAnimated,
            sound: (defaults.string(forKey: key(.sound)).flatMap(BannerSound.init(rawValue:))) ?? standard.sound,
            screen: (defaults.string(forKey: key(.screen)).flatMap(BannerScreen.init(rawValue:))) ?? standard.screen,
            animationDuration: number(.animationDuration, standard.animationDuration),
            cornerRadius: CGFloat(number(.cornerRadius, Double(standard.cornerRadius))),
            borderWidth: CGFloat(number(.borderWidth, Double(standard.borderWidth))),
            iconScale: CGFloat(number(.iconScale, Double(standard.iconScale))),
            showsIcon: defaults.object(forKey: key(.showsIcon)) as? Bool ?? standard.showsIcon,
            padding: CGFloat(number(.padding, Double(standard.padding))),
            maximumBodyLines: defaults.object(forKey: key(.maximumBodyLines)) as? Int ?? standard.maximumBodyLines,
            severityStyles: (defaults.data(forKey: key(.severityStyles))
                .flatMap { try? JSONDecoder().decode([String: BannerSeverityStyle].self, from: $0) } ?? [:])
                .reduce(into: [BannerSeverity: BannerSeverityStyle]()) { result, pair in
                    if let severity = BannerSeverity(rawValue: pair.key) { result[severity] = pair.value }
                },
            quietHours: defaults.data(forKey: key(.quietHours)).flatMap { try? JSONDecoder().decode(QuietHours.self, from: $0) } ?? QuietHours(),
            moduleSounds: defaults.data(forKey: key(.moduleSounds)).flatMap { try? JSONDecoder().decode([String: BannerSound].self, from: $0) } ?? [:],
            moduleLifetimes: defaults.data(forKey: key(.moduleLifetimes)).flatMap { try? JSONDecoder().decode([String: Double].self, from: $0) } ?? [:]
        )
    }
}
