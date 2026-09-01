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
        case corner, width, margin, spacing, visibleLifetime, opacity, textScale, material, isAnimated, sound
    }

    private func key(_ key: Key) -> String { "\(keyPrefix).\(key.rawValue)" }

    private func save() {
        defaults.set(appearance.corner.rawValue, forKey: key(.corner))
        defaults.set(Double(appearance.width), forKey: key(.width))
        defaults.set(Double(appearance.margin), forKey: key(.margin))
        defaults.set(Double(appearance.spacing), forKey: key(.spacing))
        defaults.set(appearance.visibleLifetime, forKey: key(.visibleLifetime))
        defaults.set(appearance.opacity, forKey: key(.opacity))
        defaults.set(appearance.textScale.rawValue, forKey: key(.textScale))
        defaults.set(appearance.material.rawValue, forKey: key(.material))
        defaults.set(appearance.isAnimated, forKey: key(.isAnimated))
        defaults.set(appearance.sound.rawValue, forKey: key(.sound))
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
            opacity: number(.opacity, standard.opacity),
            textScale: (defaults.string(forKey: key(.textScale)).flatMap(BannerTextScale.init(rawValue:))) ?? standard.textScale,
            material: (defaults.string(forKey: key(.material)).flatMap(BannerMaterial.init(rawValue:))) ?? standard.material,
            isAnimated: defaults.object(forKey: key(.isAnimated)) as? Bool ?? standard.isAnimated,
            sound: (defaults.string(forKey: key(.sound)).flatMap(BannerSound.init(rawValue:))) ?? standard.sound
        )
    }
}
