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

    /// Title and body on one line, for a table cell.
    ///
    /// The monitors lay their bodies out as "Label:<tab>value" over several lines, which
    /// is right for a banner and wrong for a row; the tabs and newlines become spaces and
    /// a dash joins the title to the rest.
    var oneLine: String {
        let flattened = body
            .replacingOccurrences(of: "\n", with: " — ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return flattened.isEmpty ? title : "\(title) — \(flattened)"
    }

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
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    private var revision = 0

    init(limit: Int = 2000, directory: URL? = nil, defaults: UserDefaults = .standard) {
        self.limit = limit
        self.defaults = defaults
        self.fileURL = (directory ?? Self.defaultDirectory).map { $0.appending(path: "history.json") }
        defaults.register(defaults: [
            Self.isEnabledKey: true,
            Self.retentionDaysKey: 7.0
        ])
        self.entries = load()
        pruneByAge()
    }

    // MARK: - What is kept, and for how long

    /// Whether anything is written down at all.
    ///
    /// Somebody who does not want a record of what their hardware did should be able to
    /// say so — and switching it off stops the recording rather than merely hiding it,
    /// because a hidden log is still a log.
    var isEnabled: Bool {
        get {
            _ = revision
            return defaults.bool(forKey: Self.isEnabledKey)
        }
        set {
            defaults.set(newValue, forKey: Self.isEnabledKey)
            revision += 1
            // Switching it off empties what is already there. Keeping a week of history
            // after being told to stop keeping history would be the wrong reading of it.
            if !newValue { clear() }
        }
    }

    /// How many days of history to keep.
    ///
    /// Age rather than a count, which is what somebody actually means by "keep a week":
    /// two hundred entries is a fortnight on a quiet Mac and an afternoon on a busy one.
    /// A count limit still exists behind it, so a pathological day cannot fill a disk.
    var retentionDays: Double {
        get {
            _ = revision
            return defaults.double(forKey: Self.retentionDaysKey)
        }
        set {
            defaults.set(newValue, forKey: Self.retentionDaysKey)
            revision += 1
            pruneByAge()
        }
    }

    /// Which modules are worth remembering.
    ///
    /// Per module rather than all-or-nothing, because the modules differ enormously in how
    /// much they say: a Mac with several volumes writes a dozen lines every launch, and
    /// somebody keeping history to answer "when did that disk last disconnect" would
    /// rather not scroll past them.
    func isRecorded(_ category: String) -> Bool {
        _ = revision
        // Absent means yes: a module added by a later version starts out remembered
        // rather than silently missing from a log somebody is relying on.
        guard let stored = defaults.object(forKey: Self.categoryKey(category)) as? Bool else { return true }
        return stored
    }

    func setRecorded(_ recorded: Bool, for category: String) {
        defaults.set(recorded, forKey: Self.categoryKey(category))
        revision += 1
    }

    func setRecorded(_ recorded: Bool, forAll categories: [String]) {
        for category in categories { defaults.set(recorded, forKey: Self.categoryKey(category)) }
        revision += 1
    }

    func record(_ event: NotificationEvent, at date: Date) {
        guard isEnabled, isRecorded(event.category.rawValue) else { return }
        entries.insert(HistoryEntry(event: event, at: date), at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
        scheduleSave()
    }

    /// Drops anything older than the retention window.
    ///
    /// Run at launch and whenever the window is shortened, rather than on a timer: nothing
    /// reads the history between those two moments, so a background task pruning it would
    /// be work nobody was waiting for.
    func pruneByAge() {
        guard retentionDays > 0 else { return }
        let cutoff = Date().addingTimeInterval(-retentionDays * 24 * 60 * 60)
        let kept = entries.filter { $0.at >= cutoff }
        guard kept.count != entries.count else { return }
        entries = kept
        scheduleSave()
    }

    private static let isEnabledKey = "History.Enabled"
    private static let retentionDaysKey = "History.RetentionDays"

    private static func categoryKey(_ category: String) -> String {
        "History.Record.\(category)"
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
