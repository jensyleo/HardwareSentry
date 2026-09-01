import Foundation
import Observation

/// Remembers which icon someone picked for each kind of event.
///
/// One preferences key per event rather than one encoded blob, for the same reason
/// `BannerAppearanceStore` does it: the choices stay readable with `defaults read`, and a
/// value that cannot be understood costs exactly that one event's icon instead of every
/// icon at once.
@MainActor
@Observable
public final class IconOverrideStore {
    private let defaults: UserDefaults
    private let keyPrefix: String

    /// The whole set as one value, ready to hand to the dispatch pipeline.
    public private(set) var overrides: IconOverrides

    /// Bumped on every change, so a host that wants to push the new set somewhere has one
    /// thing to observe rather than needing to diff.
    public private(set) var revision: Int = 0

    public init(defaults: UserDefaults = .standard, keyPrefix: String = "SignalCore.IconOverride") {
        self.defaults = defaults
        self.keyPrefix = keyPrefix

        var loaded = IconOverrides()
        let prefix = keyPrefix + "."
        for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix(prefix) {
            guard let stored = value as? String,
                  let override = IconOverride(storedValue: stored)
            else { continue }
            loaded.setByStorageKey(String(key.dropFirst(prefix.count)), to: override)
        }
        overrides = loaded
    }

    public func override(for event: String, in category: NotificationCategory) -> IconOverride? {
        overrides[event, in: category]
    }

    public func setOverride(_ override: IconOverride?, for event: String, in category: NotificationCategory) {
        let storageKey = IconOverrides.key(event, in: category)
        overrides.setByStorageKey(storageKey, to: override)

        let key = "\(keyPrefix).\(storageKey)"
        if let override {
            defaults.set(override.storedValue, forKey: key)
        } else {
            // Removed rather than written as an empty string: "no choice" and "chose
            // nothing" would otherwise be indistinguishable next launch.
            defaults.removeObject(forKey: key)
        }
        revision += 1
    }

    /// Forgets every choice, putting each event back to the icon its monitor picked.
    public func resetAll() {
        let prefix = keyPrefix + "."
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            defaults.removeObject(forKey: key)
        }
        overrides = IconOverrides()
        revision += 1
    }
}

extension IconOverrides {
    /// Set by the already-composed storage key, for the store, which works in those terms.
    mutating func setByStorageKey(_ key: String, to override: IconOverride?) {
        guard let separator = key.firstIndex(of: ".") else { return }
        let category = NotificationCategory(String(key[key.startIndex..<separator]))
        let event = String(key[key.index(after: separator)...])
        guard !event.isEmpty else { return }
        self[event, in: category] = override
    }
}
