import Foundation

/// An icon someone chose for one kind of event, in place of the one the monitor picked.
///
/// Two kinds, because they answer two different wishes: a symbol for "the built-in artwork
/// is fine, I just want a different one", and a file for "I have my own".
public enum IconOverride: Sendable, Equatable, Hashable {
    /// An SF Symbol name. Always available, no artwork to manage, scales and recolours
    /// with the banner.
    case symbol(String)
    /// An image somewhere on disk, by path. A host that wants the choice to survive the
    /// person's own file being moved keeps a copy and stores the copy's path.
    case file(String)
    /// The icon the event was raised with, kept on purpose — so that a later stage that
    /// would otherwise swap it for another picture of the same thing leaves it alone.
    case original

    /// How the choice is written into preferences. A single string per event rather than
    /// an encoded blob, so it can be read and fixed with `defaults read`.
    public var storedValue: String {
        switch self {
        case .symbol(let name): return "symbol:\(name)"
        case .file(let path): return "file:\(path)"
        case .original: return "original"
        }
    }

    public init?(storedValue: String) {
        if storedValue == "original" {
            self = .original
        } else if let name = storedValue.dropPrefix("symbol:") {
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

    /// Every choice made, in no particular order.
    public var allChoices: [IconOverride] { Array(byKey.values) }

    /// The storage keys of every choice equal to `choice`, for the store.
    func storageKeys(choosing choice: IconOverride) -> [String] {
        byKey.filter { $0.value == choice }.map(\.key)
    }

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
