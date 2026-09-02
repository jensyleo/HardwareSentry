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

    public init(patterns: [String] = []) {
        self.patterns = patterns
    }

    public var isEmpty: Bool { patterns.isEmpty }

    /// Whether this volume should be passed over entirely — both its arrival and its
    /// departure. Silencing only one half would leave a list of departures for things
    /// that never appeared.
    public func excludes(path: String, name: String) -> Bool {
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
