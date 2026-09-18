import Foundation

/// Volumes to say nothing about.
///
/// Some volumes appear and disappear constantly for reasons nobody wants narrated — a
/// backup disk that mounts on a schedule, a network share that reconnects all day, a
/// virtual machine's disk image. Silencing the whole module would be too blunt; this is
/// the finer instrument.
public struct VolumeExclusions: Sendable, Equatable {
    /// Each pattern matches a mount path or a volume name, case-insensitively. A trailing
    /// `*` matches anything from there on, which is what makes "every disk image under
    /// /Volumes/VM" expressible as one entry rather than one per disk.
    public let patterns: [String]

    /// Whether the volumes macOS mounts for its own purposes are passed over as well.
    ///
    /// On by default — the one place in this application where a default silences
    /// something, and it earns that on the evidence. Measured over the upgrade to macOS
    /// 27: Volume Monitor raised 188 notifications, about 60% of everything it said in
    /// the period, and not one was a disk anybody plugged in. Forty of them read "Volume
    /// Ejected Unsafely" — alarming wording for something nobody did and nobody can act
    /// on.
    ///
    /// Kept separate from `patterns` rather than seeded into it, for two reasons: a list
    /// somebody wrote by hand should stay theirs, and a built-in list that is merely
    /// copied in once can never be corrected for anyone who already ran the application.
    public let ignoresSystemManagedVolumes: Bool

    public init(patterns: [String] = [], ignoresSystemManagedVolumes: Bool = true) {
        self.patterns = patterns
        self.ignoresSystemManagedVolumes = ignoresSystemManagedVolumes
    }

    /// Whether anybody wrote a pattern. The built-in set is not part of this: it is not
    /// something somebody configured, and reporting "no exclusions" while silencing the
    /// system's own volumes would be untrue.
    public var isEmpty: Bool { patterns.isEmpty }

    /// What macOS mounts and unmounts for itself, which no one connected and no one can
    /// act on. Read live 2026-09-15 from this application's own history, over a macOS
    /// upgrade.
    ///
    /// Matched by *path* wherever a path will do: `/System/Volumes/` and the cryptex
    /// directory belong to the system and nothing of anybody's own mounts there, whereas
    /// a volume *named* "Update" or "Hardware" could plausibly be somebody's own disk.
    /// `/Volumes/` — where a person's disks actually mount — is deliberately absent.
    ///
    /// The three name patterns are the ones that cannot be expressed any other way: each
    /// mount is named afresh with a random suffix (`tmp-mount-HUnUd0`, `tmp-mount-0pLNqq`),
    /// so only the prefix is stable. That is also why this cannot be left to the list
    /// above: nobody can write by hand a pattern for a name that is different every time.
    static let systemManagedPatterns: [String] = [
        // Every synthetic APFS volume — Preboot, VM, xarts, iSCPreboot, Hardware — and
        // the software-update staging mount, `/System/Volumes/Update/mnt1`.
        "/System/Volumes/*",
        // System extensions delivered as signed disk images. These mount on every boot on
        // current macOS, not only during an upgrade.
        "/private/var/run/com.apple.security.cryptexd/*",
        // The software updater's own target and temporary mounts.
        "msu-target-*",
        "msutargetcontroller-mount-*",
        "tmp-mount-*"
    ]

    /// Whether this volume should be passed over entirely — both its arrival and its
    /// departure. Silencing only one half would leave a list of departures for things
    /// that never appeared.
    public func excludes(path: String, name: String) -> Bool {
        if matchesAny(patterns, path: path, name: name) { return true }
        guard ignoresSystemManagedVolumes else { return false }
        return matchesAny(Self.systemManagedPatterns, path: path, name: name)
    }

    private func matchesAny(_ patterns: [String], path: String, name: String) -> Bool {
        patterns.contains { pattern in
            Self.matches(pattern: pattern, path) || Self.matches(pattern: pattern, name)
        }
    }

    static func matches(pattern: String, _ subject: String) -> Bool {
        let pattern = pattern.trimmingCharacters(in: .whitespaces)
        guard !pattern.isEmpty else { return false }

        if pattern.hasSuffix("*") {
            let prefix = String(pattern.dropLast())
            // A bare "*" would match everything, which is a way to silence the module by
            // accident while it still appears to be running.
            guard !prefix.isEmpty else { return false }
            return subject.lowercased().hasPrefix(prefix.lowercased())
        }
        return subject.caseInsensitiveCompare(pattern) == .orderedSame
    }
}
