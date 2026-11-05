import Foundation

/// Swaps in the icon someone picked for an event, in place of the one the monitor chose.
///
/// A pipeline stage rather than something the delivery layer does, so the choice applies
/// to every way a notification can be shown and so it can be tested without a screen. It
/// belongs late in the pipeline, after the filters: there is no point resolving an icon —
/// let alone reading a file from disk — for an event that is about to be dropped.
///
/// An actor because it holds two pieces of mutable state: the current set of choices,
/// which the host replaces when someone edits them, and a small cache of image files it
/// has already read.
public actor IconOverrideMiddleware: NotificationMiddleware {
    private var overrides: IconOverrides
    private var fileCache: [String: Data] = [:]
    private let readFile: @Sendable (String) -> Data?

    public init(
        overrides: IconOverrides = IconOverrides(),
        readFile: @escaping @Sendable (String) -> Data? = { FileManager.default.contents(atPath: $0) }
    ) {
        self.overrides = overrides
        self.readFile = readFile
    }

    /// Replaces the set of choices — called by the host when someone edits them.
    public func update(_ overrides: IconOverrides) {
        guard overrides != self.overrides else { return }
        self.overrides = overrides
        // Dropped wholesale rather than diffed: a person who has just been editing icons
        // is also the person most likely to have edited the picture itself, and a stale
        // image shown after they changed it would look like the setting did not take.
        fileCache.removeAll()
    }

    public func process(_ event: NotificationEvent, context: DispatchContext) async -> MiddlewareDecision {
        guard let override = overrides[event.name, in: event.category] else {
            return .deliver(event)
        }

        var event = event
        // Chosen by a person, so final: no later stage should swap it for "another picture
        // of the same device". Clearing what the icon depicts is how that is said — it is
        // the only thing such a stage looks for.
        event.iconKind = nil
        event.iconModel = nil
        // A picture somebody chose is one picture for every state, so the state is marked
        // on it instead of being lost.
        event.showsIconBadge = true
        switch override {
        case .original:
            // The monitor's own artwork, which paints its state in already.
            event.showsIconBadge = false
        case .symbol(let name):
            event.icon = .symbol(name)
        case .file(let path):
            guard let data = data(atPath: path) else {
                // The file moved, or was deleted. The monitor's own icon is a better
                // answer than no icon, and far better than refusing to show the
                // notification over a decoration — and that icon carries its own state.
                event.showsIconBadge = false
                return .deliver(event)
            }
            event.icon = .imageData(data)
        }
        return .deliver(event)
    }

    private func data(atPath path: String) -> Data? {
        if let cached = fileCache[path] { return cached }
        guard let data = readFile(path) else { return nil }
        fileCache[path] = data
        return data
    }
}
