import Foundation

/// An icon someone chose for one kind of event, in place of the one the monitor picked.
///
/// Two kinds, because they answer two different wishes: a symbol for "the built-in artwork
/// is fine, I just want a different one", and a file for "I have my own".
public enum IconOverride: Sendable, Equatable, Hashable {
    /// An SF Symbol name. Always available, no artwork to manage, scales and recolours
    /// with the banner.
    case symbol(String)
    /// An image somewhere on disk, by path.
    ///
    /// Stored as a path rather than a copy, so the picture stays the file the person
    /// pointed at — renaming or editing it changes the icon, which is what someone
    /// pointing at a file of their own generally expects. The cost is that moving the file
    /// breaks the override, which `resolve` handles by falling back rather than failing.
    case file(String)

    /// How the choice is written into preferences. A single string per event rather than
    /// an encoded blob, so it can be read and fixed with `defaults read`.
    public var storedValue: String {
        switch self {
        case .symbol(let name): return "symbol:\(name)"
        case .file(let path): return "file:\(path)"
        }
    }

    public init?(storedValue: String) {
        if let name = storedValue.dropPrefix("symbol:") {
            guard !name.isEmpty else { return nil }
            self = .symbol(name)
        } else if let path = storedValue.dropPrefix("file:") {
            guard !path.isEmpty else { return nil }
            self = .file(path)
        } else {
            // Anything else was written by a version that meant something different, or by
            // hand. Treated as no choice at all rather than guessed at.
            return nil
        }
    }
}

/// Every icon choice that has been made, as one immutable value.
///
/// Separate from the store that edits it so it can cross into the dispatch pipeline, which
/// runs nowhere near the main actor, without dragging observation machinery along.
public struct IconOverrides: Sendable, Equatable {
    private var byKey: [String: IconOverride]

    public init(_ byKey: [String: IconOverride] = [:]) {
        self.byKey = byKey
    }

    public var isEmpty: Bool { byKey.isEmpty }

    /// The key an event's choice is filed under. Category and name together, because two
    /// monitors may well both have an event called `Connected`.
    public static func key(_ event: String, in category: NotificationCategory) -> String {
        "\(category.rawValue).\(event)"
    }

    public subscript(event: String, in category: NotificationCategory) -> IconOverride? {
        get { byKey[Self.key(event, in: category)] }
        set { byKey[Self.key(event, in: category)] = newValue }
    }
}

private extension String {
    /// The remainder after `prefix`, or nil when this string does not start with it.
    func dropPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
