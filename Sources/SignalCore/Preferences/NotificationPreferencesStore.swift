import Foundation

/// An event type a module can be asked about by name.
///
/// A module declares its events as an enum conforming to this, which is what lets a
/// preferences screen enumerate them, and what keeps the stored key tied to the event
/// rather than to a string written out by hand in several places.
///
///     enum PowerEvent: String, NotificationEventKey {
///         case lowPowerMode, adapterChanged, batteryHealth
///         static let category: NotificationCategory = "Power"
///     }
public protocol NotificationEventKey: RawRepresentable, Hashable, Sendable where RawValue == String {
    static var category: NotificationCategory { get }
}

/// Remembers which notifications the user wants, in the user's defaults.
///
/// Replaces an arrangement where every module wrote out its own preference key strings
/// and its own lookup helper — the same code thirteen times over, each free to drift.
/// Here the key is derived from the event, so it cannot be misspelled in one place and
/// not another, and the same store answers both the pipeline (which asks by name) and a
/// preferences screen (which asks with a typed event).
///
/// Anything never set and never registered counts as wanted: a notification a module
/// went to the trouble of raising should not vanish because nobody said it was allowed.
public final class NotificationPreferencesStore: NotificationPreferences, @unchecked Sendable {
    // UserDefaults is documented as thread-safe; the unchecked conformance is about that
    // guarantee living in prose rather than in the type system.
    private let defaults: UserDefaults
    private let keyPrefix: String

    public init(defaults: UserDefaults = .standard, keyPrefix: String = "SignalCore") {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }

    // MARK: - Asked by the pipeline

    public func isCategoryEnabled(_ category: NotificationCategory) async -> Bool {
        wanted(at: key(for: category))
    }

    public func isEventEnabled(_ name: String, in category: NotificationCategory) async -> Bool {
        wanted(at: key(for: name, in: category))
    }

    // MARK: - Asked and set by a preferences screen

    public func isEnabled<E: NotificationEventKey>(_ event: E) -> Bool {
        wanted(at: key(for: event.rawValue, in: E.category))
    }

    public func setEnabled<E: NotificationEventKey>(_ enabled: Bool, for event: E) {
        defaults.set(enabled, forKey: key(for: event.rawValue, in: E.category))
    }

    public func isEnabled(_ category: NotificationCategory) -> Bool {
        wanted(at: key(for: category))
    }

    public func setEnabled(_ enabled: Bool, for category: NotificationCategory) {
        defaults.set(enabled, forKey: key(for: category))
    }

    /// Forgets a choice, so the event goes back to whatever it defaults to.
    public func reset<E: NotificationEventKey>(_ event: E) {
        defaults.removeObject(forKey: key(for: event.rawValue, in: E.category))
    }

    /// Forgets a choice about an event known only by name.
    ///
    /// Removing the key rather than writing the default over it: the default belongs to
    /// the monitor that declared it, and a monitor that changes its mind in a later
    /// version should reach someone who never chose otherwise.
    public func reset(_ name: String, in category: NotificationCategory) {
        defaults.removeObject(forKey: key(for: name, in: category))
    }

    /// Forgets whether a whole module was wanted.
    public func reset(_ category: NotificationCategory) {
        defaults.removeObject(forKey: key(for: category))
    }

    // MARK: - Defaults

    /// Declares what an event should be when the user has never said. Registering does
    /// not write anything: a choice the user later makes still takes precedence, and
    /// clearing that choice falls back here rather than to nothing.
    ///
    /// Note that registered values live in a domain shared by the whole process, not by
    /// the defaults this store was handed. Two stores using the same key prefix will
    /// therefore see each other's registrations, whichever defaults each was given.
    public func registerDefaults<E: NotificationEventKey>(_ values: [E: Bool]) {
        var registration: [String: Any] = [:]
        for (event, enabled) in values {
            registration[key(for: event.rawValue, in: E.category)] = enabled
        }
        defaults.register(defaults: registration)
    }

    /// Declares defaults for events known only by name.
    ///
    /// A monitor describes its events for a preferences screen without handing over its
    /// enum, so the assembly that registers those defaults has names and a category
    /// rather than a type. Same storage, same keys.
    public func registerDefaults(_ values: [String: Bool], in category: NotificationCategory) {
        var registration: [String: Any] = [:]
        for (name, enabled) in values {
            registration[key(for: name, in: category)] = enabled
        }
        defaults.register(defaults: registration)
    }

    /// Reads and writes an event known only by name, for a preferences screen built from
    /// what a monitor declares rather than from its enum.
    public func isEnabled(_ name: String, in category: NotificationCategory) -> Bool {
        wanted(at: key(for: name, in: category))
    }

    public func setEnabled(_ enabled: Bool, for name: String, in category: NotificationCategory) {
        defaults.set(enabled, forKey: key(for: name, in: category))
    }

    public func registerDefaults(_ values: [NotificationCategory: Bool]) {
        var registration: [String: Any] = [:]
        for (category, enabled) in values {
            registration[key(for: category)] = enabled
        }
        defaults.register(defaults: registration)
    }

    // MARK: - Keys

    func key(for category: NotificationCategory) -> String {
        "\(keyPrefix).\(category.rawValue)"
    }

    func key(for name: String, in category: NotificationCategory) -> String {
        "\(keyPrefix).\(category.rawValue).\(name)"
    }

    private func wanted(at key: String) -> Bool {
        guard defaults.object(forKey: key) != nil else { return true }
        return defaults.bool(forKey: key)
    }
}
