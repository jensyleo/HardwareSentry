import DiskArbitration
import Foundation

/// Watches Disk Arbitration for disks that appear but cannot be read.
///
/// Separate from the mount/unmount watching because it works at a different level: mounts
/// are about volumes the system understood, and this is about the ones it did not. A card
/// with no filesystem never mounts, so `NSWorkspace` never says a word about it.
///
/// Untested for the same reason the other sources are: it needs a real unformatted card in
/// a real slot. The deciding built on top — grouping, wording, not repeating — lives in
/// `UnreadableDiskTracker` and is tested there.
final class UnreadableDiskWatcher: @unchecked Sendable {
    private let continuation: AsyncStream<VolumeSourceEvent>.Continuation
    private var session: DASession?

    /// Every disk currently seen, by BSD name, and what it is.
    private var seen: [String: UnreadablePartition] = [:]
    /// Whole disks with at least one partition that mounted fine.
    private var readableWholeDisks: Set<String> = []
    /// What each whole disk is called — its maker and model — so a message can name the
    /// thing somebody plugged in rather than one of the partitions inside it.
    private var wholeDiskNames: [String: String] = [:]
    /// Whole disks the system has told us about but not yet finished probing.
    private var settleTask: Task<Void, Never>?

    /// How long to wait after the last reading before deciding what to say.
    ///
    /// One card produces a burst of appearances as each partition is probed. Reporting on
    /// the first would announce a card as unreadable before the partition that mounts fine
    /// had a chance to say so.
    private let settleDelay: Duration

    init(continuation: AsyncStream<VolumeSourceEvent>.Continuation, settleDelay: Duration = .seconds(1)) {
        self.continuation = continuation
        self.settleDelay = settleDelay
    }

    func start() {
        guard let session = DASessionCreate(kCFAllocatorDefault) else { return }
        self.session = session

        let context = Unmanaged.passUnretained(self).toOpaque()
        DARegisterDiskAppearedCallback(session, nil, { disk, context in
            Unmanaged<UnreadableDiskWatcher>.fromOpaque(context!).takeUnretainedValue().appeared(disk)
        }, context)
        DARegisterDiskDisappearedCallback(session, nil, { disk, context in
            Unmanaged<UnreadableDiskWatcher>.fromOpaque(context!).takeUnretainedValue().disappeared(disk)
        }, context)

        DASessionSetDispatchQueue(session, .main)
    }

    func stop() {
        settleTask?.cancel()
        if let session { DASessionSetDispatchQueue(session, nil) }
        session = nil
    }

    private func appeared(_ disk: DADisk) {
        guard let description = DADiskCopyDescription(disk) as? [String: Any],
              let bsdName = description[kDADiskDescriptionMediaBSDNameKey as String] as? String
        else { return }

        // A whole disk with no partitions of its own is not itself unreadable; its
        // partitions are what get probed, and reporting the container as well would
        // double every card.
        let isWhole = description[kDADiskDescriptionMediaWholeKey as String] as? Bool ?? false
        let wholeDiskName = Self.wholeDiskName(of: bsdName)

        if isWhole, let name = UnreadableDiskNaming.deviceName(
            vendor: description[kDADiskDescriptionDeviceVendorKey as String] as? String,
            model: description[kDADiskDescriptionDeviceModelKey as String] as? String,
            mediaName: description[kDADiskDescriptionMediaNameKey as String] as? String
        ) {
            wholeDiskNames[bsdName] = name
        }

        // A partition with a recognised filesystem is readable whether or not it happens
        // to be mounted right now — an ejected-but-formatted card is not a fault.
        if description[kDADiskDescriptionVolumeKindKey as String] != nil {
            readableWholeDisks.insert(wholeDiskName)
        } else if !isWhole,
                  // A partition map, a driver or free space was never going to mount.
                  !UnreadableDiskNaming.holdsNoFilesystem(
                    contentType: description[kDADiskDescriptionMediaContentKey as String] as? String
                  ) {
            seen[bsdName] = UnreadablePartition(
                bsdName: bsdName,
                wholeDiskName: wholeDiskName,
                displayName: description[kDADiskDescriptionMediaNameKey as String] as? String ?? wholeDiskName,
                isInternal: description[kDADiskDescriptionDeviceInternalKey as String] as? Bool ?? false
            )
        }
        scheduleSettle()
    }

    private func disappeared(_ disk: DADisk) {
        guard let description = DADiskCopyDescription(disk) as? [String: Any],
              let bsdName = description[kDADiskDescriptionMediaBSDNameKey as String] as? String
        else { return }

        seen.removeValue(forKey: bsdName)
        let wholeDiskName = Self.wholeDiskName(of: bsdName)

        // Only when nothing from that disk is left. A partition going while its siblings
        // remain is the disk being re-probed, not removed — forgetting then would warn
        // about the same card twice.
        let anyLeft = seen.keys.contains { Self.wholeDiskName(of: $0) == wholeDiskName }
        guard !anyLeft else { return }
        readableWholeDisks.remove(wholeDiskName)
        wholeDiskNames.removeValue(forKey: wholeDiskName)
        continuation.yield(.wholeDiskDisappeared(wholeDiskName))
    }

    /// Restarted on each reading, so the batch is reported once the burst stops rather
    /// than once per disk.
    private func scheduleSettle() {
        settleTask?.cancel()
        settleTask = Task { [weak self, settleDelay] in
            try? await Task.sleep(for: settleDelay)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.emitSettled() }
        }
    }

    private func emitSettled() {
        guard !seen.isEmpty else { return }
        // Named after the disk they sit on wherever it said what it is; their own media
        // name only when it did not.
        let named = seen.values.map { partition in
            wholeDiskNames[partition.wholeDiskName].map(partition.named) ?? partition
        }
        continuation.yield(.unreadable(
            partitions: named,
            readableWholeDisks: readableWholeDisks
        ))
    }

    /// "disk4s1" → "disk4". The partition suffix is everything from the `s` after the
    /// device number.
    static func wholeDiskName(of bsdName: String) -> String {
        guard bsdName.hasPrefix("disk") else { return bsdName }
        let digitsAndOn = bsdName.dropFirst(4)
        guard let sIndex = digitsAndOn.firstIndex(of: "s") else { return bsdName }
        return "disk" + digitsAndOn[digitsAndOn.startIndex..<sIndex]
    }
}
