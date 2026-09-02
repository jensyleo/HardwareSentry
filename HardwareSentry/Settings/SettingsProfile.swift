import Foundation
import SignalCore

/// Every choice somebody has made, as one file they can keep.
///
/// Worth having because the choices are laborious to remake: which modules run, which of
/// their notifications arrive, which extra lines those carry, and an icon picked for any
/// of them. Losing that to a reinstall — or being unable to carry it to a second Mac — is
/// the kind of small loss that stops people customising anything at all.
struct SettingsProfile: Codable {
    /// Bumped only if the shape changes in a way an older reader could misread. A file
    /// from the future is refused rather than half-understood.
    var version = 1
    var preferences: [String: Bool] = [:]
    /// The settings that are sizes rather than switches — banner width, opacity, how long
    /// one stays. Kept apart from `preferences` because `UserDefaults` hands both back as
    /// `NSNumber`, and asking one of those whether it is a `Bool` says yes to every
    /// non-zero number: read that way, an opacity of 1.0 came back as `true` and would
    /// have been restored as a width of 1 point.
    var numbers: [String: Double] = [:]
    var iconOverrides: [String: String] = [:]
    var iconVisibility: Int?
    var announcesWhatIsAlreadyThere: Bool?

    static let currentVersion = 1
}

enum SettingsProfileError: LocalizedError {
    case unreadableFile
    case unsupportedVersion(Int)

    var errorDescription: String? {
        switch self {
        case .unreadableFile:
            return "That file is not a HardwareSentry profile."
        case .unsupportedVersion(let version):
            return "That profile was saved by a newer version of HardwareSentry (format \(version))."
        }
    }
}

/// Reads and writes the profile against `UserDefaults`.
///
/// Works on raw keys rather than through the typed stores: the point is to capture
/// everything somebody has set, including settings added after this code was written, and
/// a list of known keys would silently stop capturing the ones nobody remembered to add.
struct SettingsProfileStore {
    let defaults: UserDefaults
    /// The prefixes worth saving. Everything under them is a choice somebody made; things
    /// outside them are AppKit's own window-position bookkeeping and similar, which would
    /// be actively unhelpful to carry to another Mac.
    let prefixes: [String]

    init(defaults: UserDefaults = .standard, prefixes: [String] = ["HardwareSentry"]) {
        self.defaults = defaults
        self.prefixes = prefixes
    }

    func capture() -> SettingsProfile {
        var profile = SettingsProfile()
        for (key, value) in defaults.dictionaryRepresentation() {
            guard prefixes.contains(where: key.hasPrefix) else { continue }

            if let text = value as? String {
                if IconOverride(storedValue: text) != nil { profile.iconOverrides[key] = text }
                continue
            }
            guard let number = value as? NSNumber else { continue }

            // The only reliable way to tell a stored switch from a stored size: ask what
            // the underlying Core Foundation object actually is, rather than asking the
            // bridged `NSNumber` a question it will answer yes to either way.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                profile.preferences[key] = number.boolValue
            } else if key.hasSuffix(".IconVisibility") {
                profile.iconVisibility = number.intValue
            } else {
                profile.numbers[key] = number.doubleValue
            }
        }
        return profile
    }

    /// Applies a profile over what is already there.
    ///
    /// Additive rather than a replacement: a profile written before a setting existed
    /// should not silently reset that setting, and clearing everything first would mean a
    /// slightly stale file quietly undoes newer choices.
    func apply(_ profile: SettingsProfile) throws {
        guard profile.version <= SettingsProfile.currentVersion else {
            throw SettingsProfileError.unsupportedVersion(profile.version)
        }
        for (key, value) in profile.preferences where prefixes.contains(where: key.hasPrefix) {
            defaults.set(value, forKey: key)
        }
        for (key, value) in profile.numbers where prefixes.contains(where: key.hasPrefix) {
            defaults.set(value, forKey: key)
        }
        for (key, value) in profile.iconOverrides where prefixes.contains(where: key.hasPrefix) {
            defaults.set(value, forKey: key)
        }
        if let visibility = profile.iconVisibility {
            defaults.set(visibility, forKey: "HardwareSentry.IconVisibility")
        }
    }

    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(capture()).write(to: url)
    }

    func read(from url: URL) throws -> SettingsProfile {
        let data = try Data(contentsOf: url)
        guard let profile = try? JSONDecoder().decode(SettingsProfile.self, from: data) else {
            throw SettingsProfileError.unreadableFile
        }
        return profile
    }
}
