import Foundation
import Observation
import SignalCore

/// Where a module's notification icons come from.
public enum IconSource: String, Sendable, Equatable, CaseIterable {
    /// The artwork this application ships. Always there.
    case app
    /// The operating system's own picture of each device, where macOS has one — and the
    /// application's artwork, unchanged, where it does not. The default: those pictures
    /// are what the rest of the Mac uses for the same devices, so a notification about one
    /// looks like it belongs.
    case system

    /// What a module uses until somebody chooses otherwise.
    public static let `default`: IconSource = .system
}

/// Which modules someone has switched to the operating system's pictures, as one value
/// that can be handed to the dispatch pipeline.
public struct IconSourceChoices: Sendable, Equatable {
    private var byCategory: [String: IconSource]

    public init(_ byCategory: [String: IconSource] = [:]) {
        self.byCategory = byCategory
    }

    /// `IconSource.default` for any module nobody has touched.
    public subscript(category: NotificationCategory) -> IconSource {
        get { byCategory[category.rawValue] ?? .default }
        set { byCategory[category.rawValue] = newValue == .default ? nil : newValue }
    }
}

/// Remembers each module's icon source.
///
/// One preferences key per module holding the source's name, readable with `defaults read`.
/// Only a departure from the default is written: a module set back to the default loses
/// its key entirely, so the absence of a key and the default can never disagree.
@MainActor
@Observable
public final class IconSourceStore {
    private let defaults: UserDefaults
    private let keyPrefix: String

    public private(set) var choices: IconSourceChoices
    /// Bumped on every change, for a host that pushes the new value somewhere.
    public private(set) var revision = 0

    public init(defaults: UserDefaults = .standard, keyPrefix: String = "HardwareSentry.IconSource") {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
        var loaded = IconSourceChoices()
        let prefix = keyPrefix + "."
        for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix(prefix) {
            // An unrecognised value — a later version's, or a typo made by hand — is no
            // choice at all rather than a guess.
            guard let raw = value as? String, let source = IconSource(rawValue: raw) else { continue }
            loaded[NotificationCategory(String(key.dropFirst(prefix.count)))] = source
        }
        choices = loaded
    }

    public func source(for category: NotificationCategory) -> IconSource {
        choices[category]
    }

    public func setSource(_ source: IconSource, for category: NotificationCategory) {
        choices[category] = source
        let key = "\(keyPrefix).\(category.rawValue)"
        if source == .default {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(source.rawValue, forKey: key)
        }
        revision += 1
    }

    /// Puts every module back on the default.
    public func resetAll() {
        let prefix = keyPrefix + "."
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            defaults.removeObject(forKey: key)
        }
        choices = IconSourceChoices()
        revision += 1
    }
}

/// Swaps a notification's icon for the operating system's picture of the same device, for
/// modules switched to `.system`.
///
/// Belongs after the stage that applies icons someone picked by hand. That stage clears
/// `iconKind` on every icon it decides — a symbol, a file, or "keep the app's own" — and
/// an icon with no kind is one this stage leaves alone; so a hand-picked icon always wins.
/// Choosing "System" for a module is a broad wish, choosing for one of its events a
/// specific one.
///
/// Leaves the event exactly as it was whenever there is nothing to swap in — a module on
/// `.app`, an icon that depicts an idea rather than a device, or a device macOS has no
/// picture of. Never suppresses anything: an icon is decoration, not a reason to drop news.
public actor SystemIconMiddleware: NotificationMiddleware {
    private var choices: IconSourceChoices
    private let catalog: SystemIconCatalog

    public init(choices: IconSourceChoices = IconSourceChoices(), catalog: SystemIconCatalog = SystemIconCatalog()) {
        self.choices = choices
        self.catalog = catalog
    }

    public func update(_ choices: IconSourceChoices) {
        self.choices = choices
    }

    public func process(_ event: NotificationEvent, context: DispatchContext) async -> MiddlewareDecision {
        guard choices[event.category] == .system,
              let kind = event.iconKind,
              let image = await catalog.image(forKind: kind, model: event.iconModel)
        else { return .deliver(event) }

        var event = event
        event.icon = .imageData(image)
        // macOS's picture is one picture whatever happened, so the state goes on it.
        event.showsIconBadge = true
        return .deliver(event)
    }
}
