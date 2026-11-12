import AppKit
import Observation
import SignalCore
import SystemIcons

/// What the Icons tab needs to offer "App" or "System" for a module and show the result:
/// the stored choice, and the operating system's pictures to preview it with.
///
/// The pictures are loaded off the main thread, a module at a time, as its tab is opened,
/// and kept: there are a few dozen at most, a few kilobytes each.
@MainActor
@Observable
final class IconSourceModel {
    let store: IconSourceStore
    @ObservationIgnored private let catalog: SystemIconCatalog

    /// The operating system's picture for each kind that has one. A kind that has been
    /// looked up and has none is in `unavailable` instead, so "not loaded yet" and "macOS
    /// has no picture of this" never look the same.
    private(set) var images: [String: NSImage] = [:]
    private(set) var unavailable: Set<String> = []

    init(store: IconSourceStore, catalog: SystemIconCatalog) {
        self.store = store
        self.catalog = catalog
    }

    func source(for category: NotificationCategory) -> IconSource {
        store.source(for: category)
    }

    func setSource(_ source: IconSource, for category: NotificationCategory) {
        store.setSource(source, for: category)
    }

    /// Looks up every kind a module's rows mention that has not been looked up already.
    func load(kinds: [String]) async {
        for kind in kinds where images[kind] == nil && !unavailable.contains(kind) {
            if let data = await catalog.image(forKind: kind), let image = NSImage(data: data), image.isValid {
                images[kind] = image
            } else {
                unavailable.insert(kind)
            }
        }
    }

    /// The picture standing for a whole module set to `.system`, or nil to keep its own.
    func moduleImage(for category: NotificationCategory) -> NSImage? {
        guard source(for: category) == .system,
              let kind = SystemIconCatalog.moduleKinds[category.rawValue]
        else { return nil }
        return images[kind]
    }

    /// Loads every module's stand-in picture, for the list of modules.
    func loadModuleImages() async {
        await load(kinds: Array(SystemIconCatalog.moduleKinds.values))
    }

    /// macOS's picture for a kind, whatever the module's saved choice.
    func image(forKind kind: String?) -> NSImage? {
        kind.flatMap { images[$0] }
    }

    /// The picture a row should preview when its module is on `.system`, or nil when it
    /// keeps the application's own.
    func previewImage(forKind kind: String?, in category: NotificationCategory) -> NSImage? {
        guard source(for: category) == .system, let kind else { return nil }
        return images[kind]
    }
}
