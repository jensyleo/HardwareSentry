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
        switch override {
        case .symbol(let name):
            event.icon = .symbol(name)
        case .file(let path):
            guard let data = data(atPath: path) else {
                // The file moved, or was deleted. The monitor's own icon is a better
                // answer than no icon, and far better than refusing to show the
                // notification over a decoration.
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
