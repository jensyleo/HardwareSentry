import Foundation
import OSLog

/// Notices a physical video link before macOS has decided what to do with it.
///
/// Deliberately experimental, and labelled so wherever it appears. A display plugged into
/// an Apple Silicon Mac takes a moment between the cable making contact and the system
/// assigning the panel a role — long enough that a notification saying "something was
/// plugged in" is genuinely earlier news than "a display connected". The kernel logs the
/// moment under the display co-processor's own subsystems.
///
/// Three things are wrong with it, and all three are the reason it is off by default:
///
/// 1. It reads **free-form kernel log text**. There is no versioned contract for the word
///    "ReceiverConnected"; Apple can change it in a point release and this would quietly
///    stop working, with nothing to notice the difference.
/// 2. `OSLogStore` offers no push or streaming callback, only a historical enumerator —
///    so this has to poll, and a poll is a compromise between noticing late and doing
///    needless work.
/// 3. It is **Apple Silicon only**. The co-processor this watches does not exist on an
///    Intel Mac, where the feature simply never fires.
///
/// The reading itself is public API (`OSLogStore.local()`), which is why this is possible
/// at all without special entitlements — but public API reading undocumented text is not
/// the same as a supported interface, and this says so rather than pretending otherwise.
public struct VideoLinkDetector: Sendable {
    /// What the kernel writes when a receiver comes up on the display link.
    ///
    /// Matched as a substring of the composed message rather than parsed: the surrounding
    /// text differs between machines and releases, and anything more precise would be more
    /// fragile for no gain.
    static let marker = "ReceiverConnected"

    /// Only the kernel's own entries. The store holds everything every process logged,
    /// and walking all of it every few seconds to find one word would be real work.
    static let process = "kernel"

    public init() {}

    /// Whether the kernel mentioned a new receiver since the given moment.
    ///
    /// - Returns: false when the log cannot be read at all, which is the honest answer
    ///   for a Mac where this is unavailable — better than reporting a link that may not
    ///   exist because a query failed.
    public func sawLink(since: Date) -> Bool {
        guard let store = try? OSLogStore.local() else { return false }
        let position = store.position(date: since)
        guard let entries = try? store.getEntries(
            at: position,
            matching: NSPredicate(format: "process == %@", Self.process)
        ) else { return false }

        for entry in entries {
            guard let log = entry as? OSLogEntryLog else { continue }
            // One is enough. The real "Display Connected" follows within moments, so
            // there is nothing to gain from counting how many times the kernel said it.
            if log.composedMessage.contains(Self.marker) { return true }
        }
        return false
    }
}
