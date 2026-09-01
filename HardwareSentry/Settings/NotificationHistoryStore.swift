import Foundation
import Observation
import SignalCore

/// One notification, as it was shown.
struct HistoryEntry: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    let category: String
    let name: String
    let title: String
    let body: String
    let at: Date

    init(event: NotificationEvent, at: Date) {
        self.id = UUID()
        self.category = event.category.rawValue
        self.name = event.name
        self.title = event.title
        self.body = event.body
        self.at = at
    }
}

/// Remembers what was shown, so it can be looked at afterwards.
///
/// A menu-bar application says things while nobody is looking — that is rather the point of
/// it — and until now anything missed was simply gone. The icons are deliberately left out
/// of what is stored: they belong to whichever monitor raised the notification and can be
/// hundreds of kilobytes, which is not what a log should be made of.
@MainActor
@Observable
final class NotificationHistoryStore {
    /// Newest first, which is the order it is read in.
    private(set) var entries: [HistoryEntry] = []

    /// Enough to answer "what did I miss this morning" without becoming an archive. Older
    /// ones fall off the end rather than the file growing without limit.
    private let limit: Int
    @ObservationIgnored private let fileURL: URL?
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init(limit: Int = 200, directory: URL? = nil) {
        self.limit = limit
        self.fileURL = (directory ?? Self.defaultDirectory).map { $0.appending(path: "history.json") }
        self.entries = load()
    }

    func record(_ event: NotificationEvent, at date: Date) {
        entries.insert(HistoryEntry(event: event, at: date), at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
        scheduleSave()
    }

    func clear() {
        entries = []
        scheduleSave()
    }

    // MARK: - Storage

    private static var defaultDirectory: URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ) else { return nil }
        let directory = base.appending(path: "HardwareSentry")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Saving is coalesced rather than done per notification: a startup sweep can record
    /// dozens in a second, and rewriting the whole file each time would be the most
    /// expensive thing this application does.
    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = entries
        let url = fileURL
        saveTask = Task { [snapshot, url] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let url else { return }
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    /// An unreadable or absent file means an empty history, never a failure to launch —
    /// this is a convenience, and losing it must not cost anything else.
    private func load() -> [HistoryEntry] {
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data)
        else { return [] }
        return Array(decoded.prefix(limit))
    }
}
