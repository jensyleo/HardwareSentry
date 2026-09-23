import Foundation

/// One partition the system could see but could not read.
public struct UnreadablePartition: Sendable, Equatable {
    /// The partition's own BSD name — "disk4s1".
    public let bsdName: String
    /// The whole disk it belongs to — "disk4". Several partitions share one.
    public let wholeDiskName: String
    /// What to call it in the message: the volume name if it has one, else the device.
    public let displayName: String
    /// Whether it is inside the Mac. Internal disks are excluded: the recovery and
    /// preboot partitions of the startup disk are unreadable by design, and warning about
    /// them at every launch would be pure noise.
    public let isInternal: Bool

    public init(bsdName: String, wholeDiskName: String, displayName: String, isInternal: Bool) {
        self.bsdName = bsdName
        self.wholeDiskName = wholeDiskName
        self.displayName = displayName
        self.isInternal = isInternal
    }
}

/// Decides when to say a disk could not be read, and how to word it.
///
/// The hard part is not noticing — Disk Arbitration says so plainly — but not saying it
/// four times. Insert one SD card with four partitions and the system reports four
/// unreadable partitions in quick succession; a person inserted one card and wants one
/// notification about it.
///
/// Two rules do that work. Partitions are grouped by the whole disk they sit on, so one
/// card is one notification. And a card with *some* readable partition is described
/// differently, because "this card is unreadable" would be wrong when half of it mounted
/// fine.
public struct UnreadableDiskTracker: Sendable {
    /// Whole disks already reported, so a card sitting in a slot is not announced again
    /// every time something re-probes it.
    private var reported: Set<String> = []

    public init() {}

    /// What to say about a settled batch of readings, or nil to stay quiet.
    public struct Report: Sendable, Equatable {
        public let wholeDiskName: String
        public let displayName: String
        /// Whether something else on the same disk did mount.
        public let hasReadableSibling: Bool

        /// The original's two wordings. The distinction is the point: telling somebody
        /// their whole card is unreadable when half of it mounted is worse than saying
        /// nothing, because they will go looking for a fault that is not there.
        public var message: String {
            hasReadableSibling
                ? "Part of this device (\(displayName)) could not be read. It may be unformatted or use an unsupported file system."
                : "\(displayName) could not be read. It may be unformatted or use an unsupported file system."
        }
    }

    /// - Parameters:
    ///   - unreadable: every partition currently seen but unreadable.
    ///   - readableWholeDisks: whole disks that have at least one partition mounted fine.
    public mutating func consider(
        unreadable: [UnreadablePartition],
        readableWholeDisks: Set<String>
    ) -> [Report] {
        let external = unreadable.filter { !$0.isInternal }
        let byDisk = Dictionary(grouping: external, by: \.wholeDiskName)

        // Sorted so a machine with two unreadable cards reads the same way every time.
        var reports: [Report] = []
        for (wholeDisk, partitions) in byDisk.sorted(by: { $0.key < $1.key }) {
            guard reported.insert(wholeDisk).inserted else { continue }
            guard let first = partitions.sorted(by: { $0.bsdName < $1.bsdName }).first else { continue }

            reports.append(Report(
                wholeDiskName: wholeDisk,
                // The whole disk's name where one exists, since that is the object
                // somebody physically inserted.
                displayName: first.displayName,
                hasReadableSibling: readableWholeDisks.contains(wholeDisk)
            ))
        }
        return reports
    }

    /// Forgets a whole disk, so re-inserting the same card warns again.
    ///
    /// Called when the disk disappears entirely rather than when one partition goes: a
    /// partition vanishing while its siblings remain is the disk being re-probed, not
    /// removed.
    public mutating func forget(wholeDiskName: String) {
        reported.remove(wholeDiskName)
    }
}
