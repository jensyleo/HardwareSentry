import AppKit
import DiskArbitration
import CNVMeSMART
import Foundation
import IOKit

/// Watches `NSWorkspace` for volume mount/unmount, and polls local mounted volumes' free
/// space every 5 minutes (matching HG4MAC's own interval).
///
/// Deliberately thin and untested, for the same reason `IOKitUSBDeviceSource` is: none of
/// it can run without a real volume mounting/unmounting. Everything worth reasoning about
/// lives in `VolumeMonitor`, behind `VolumeSource`.
public struct NSWorkspaceVolumeSource: VolumeSource {
    private let freeSpacePollInterval: Duration

    public init(freeSpacePollInterval: Duration = .seconds(300)) {
        self.freeSpacePollInterval = freeSpacePollInterval
    }

    public func changes() -> AsyncStream<VolumeSourceEvent> {
        AsyncStream { continuation in
            let watcher = Watcher(continuation: continuation, freeSpacePollInterval: freeSpacePollInterval)
            continuation.onTermination = { _ in watcher.stop() }
            watcher.start()
        }
    }
}

private final class Watcher: @unchecked Sendable {
    private let continuation: AsyncStream<VolumeSourceEvent>.Continuation
    private let freeSpacePollInterval: Duration
    private var tokens: [NSObjectProtocol] = []
    private var pollTask: Task<Void, Never>?
    private var unreadableWatcher: UnreadableDiskWatcher?

    init(continuation: AsyncStream<VolumeSourceEvent>.Continuation, freeSpacePollInterval: Duration) {
        self.continuation = continuation
        self.freeSpacePollInterval = freeSpacePollInterval
    }

    /// The last component of the mount path, which is what a volume is called in the one
    /// place it is guaranteed to have a name.
    ///
    /// Deliberately not the volume's localized name: reading that needs file access macOS
    /// gates, and it disagrees with the path for exactly the volumes that have no Finder
    /// presence anyway. The startup disk comes out as "/", which is what it is.
    static func displayName(of path: String) -> String {
        (path as NSString).lastPathComponent
    }

    private func announceAlreadyMounted() {
        // No `.skipHiddenVolumes`: the system volumes macOS hides from Finder — Preboot,
        // VM, Update, xarts, iSCPreboot, Hardware, Data/home — are mounted volumes, and a
        // tool whose job is to say what is mounted should say so. Somebody who does not
        // want them can switch the module or the launch announcement off.
        for url in FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? [] {
            let path = url.path
            continuation.yield(.mounted(
                path: path,
                name: Self.displayName(of: path),
                detail: Self.detail(of: path)
            ))
        }
    }

    func start() {
        let center = NSWorkspace.shared.notificationCenter

        tokens.append(center.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: nil) { [weak self] note in
            guard let path = note.userInfo?["NSDevicePath"] as? String else { return }
            self?.continuation.yield(.mounted(
                path: path,
                name: Self.displayName(of: path),
                detail: Self.detail(of: path)
            ))
        })
        tokens.append(center.addObserver(forName: NSWorkspace.willUnmountNotification, object: nil, queue: nil) { [weak self] note in
            guard let path = note.userInfo?["NSDevicePath"] as? String else { return }
            self?.continuation.yield(.willUnmount(path: path, name: Self.displayName(of: path)))
        })
        tokens.append(center.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: nil) { [weak self] note in
            guard let path = note.userInfo?["NSDevicePath"] as? String else { return }
            self?.continuation.yield(.unmounted(path: path, name: Self.displayName(of: path)))
        })

        // `didMountNotification` only ever fires for a volume that mounts while this is
        // listening, so without this sweep the volumes that were already mounted when the
        // application launched are invisible to it — which is most of them, most of the
        // time.
        announceAlreadyMounted()

        // A separate watcher, at a different level: mounts are about volumes the system
        // understood, and this is about the ones it did not.
        unreadableWatcher = UnreadableDiskWatcher(continuation: continuation)
        unreadableWatcher?.start()

        pollTask = Task { [freeSpacePollInterval] in
            while !Task.isCancelled {
                self.continuation.yield(.freeSpaceSnapshot(Self.readFreeSpaceByPath()))
                try? await Task.sleep(for: freeSpacePollInterval)
            }
        }
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        tokens.forEach(center.removeObserver)
        pollTask?.cancel()
        unreadableWatcher?.stop()
        continuation.finish()
    }

    /// Read at mount time, while there is still a filesystem there to ask. Plain `statfs`
    /// rather than `NSFileManager`, for the same reason the free-space poll uses
    /// `getmntinfo`: it never touches the file access macOS gates behind a prompt.
    private static func detail(of path: String) -> VolumeDetail {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return VolumeDetail() }

        let type = withUnsafeBytes(of: info.f_fstypename) { raw -> String? in
            let value = Self.nulTerminatedString(raw)
            return value.isEmpty ? nil : value
        }
        let total = UInt64(info.f_blocks) * UInt64(info.f_bsize)

        let url = URL(fileURLWithPath: path)
        let values = try? url.resourceValues(forKeys: [
            .volumeIsEncryptedKey, .volumeLocalizedFormatDescriptionKey, .volumeUUIDStringKey,
            .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeSupportsCasePreservedNamesKey,
            .volumeAvailableCapacityForImportantUsageKey
        ])
        let arbitration = Self.diskDescription(of: path)
        let health = Self.driveHealth(arbitration)

        return VolumeDetail(
            fileSystemType: type,
            totalBytes: total > 0 ? total : nil,
            isReadOnly: info.f_flags & UInt32(MNT_RDONLY) != 0,
            kind: kind(from: arbitration, sizeBytes: total > 0 ? total : nil),
            healthPercent: health?.percent,
            hasHealthWarning: health?.hasWarning ?? false,
            isEncrypted: values?.volumeIsEncrypted,
            format: values?.volumeLocalizedFormatDescription,
            uuid: values?.volumeUUIDString,
            isRemovable: values?.volumeIsRemovable,
            isEjectable: values?.volumeIsEjectable,
            // The key asks whether names are case-*preserved*; a volume that only
            // preserves case is not case-sensitive, which is the question being answered.
            isCaseSensitive: (info.f_flags & UInt32(MNT_UNKNOWNPERMISSIONS)) == 0
                ? values?.volumeSupportsCasePreservedNames.map { $0 && type == "apfs" }
                : nil,
            busName: arbitration?[kDADiskDescriptionBusNameKey as String] as? String,
            sectorSize: (arbitration?[kDADiskDescriptionMediaBlockSizeKey as String] as? NSNumber)?.intValue,
            interfaceDescription: Self.describeInterface(arbitration),
            purgeableAwareFreeBytes: values?.volumeAvailableCapacityForImportantUsage
                .flatMap { $0 >= 0 ? UInt64($0) : nil }
        )
    }

    /// How worn the drive is, for internal storage that will say.
    ///
    /// Health is the complement of the NVMe spec's PERCENTAGE_USED, so a drive that has
    /// consumed 3% of its rated writes reads as 97% healthy. A drive past its rating
    /// reports over 100% used, which would give a negative figure — clamped to zero, since
    /// "0% healthy" is the honest end of the scale.
    ///
    /// **Verified not to answer on Apple Silicon.** Measured on an M4: the internal disk's
    /// protocol is "Apple Fabric", there is no `IONVMeController`, and the controller that
    /// is there — `AppleANS3CGv2Controller` — does not offer
    /// `IONVMeSMARTUserClient` at any level of the registry above the media. The bridge
    /// tries the interface at each ancestor rather than matching a class name, so it will
    /// work wherever the hardware does expose it (an Intel Mac, a third-party NVMe drive),
    /// and returns nothing here rather than inventing a percentage.
    ///
    /// `diskutil` does report "SMART Status: Verified" on this Mac, but that is a boolean
    /// with no scale behind it — the original examined and rejected the same signal for
    /// that reason, and a health line that only ever says "fine" is not worth a line.
    ///
    /// Scoped to internal disks either way: an external enclosure speaks a bridge protocol
    /// rather than NVMe, and the ATA-SMART path some bridges expose is a different, less
    /// reliable mechanism.
    private static func driveHealth(_ description: [String: Any]?) -> (percent: Int, hasWarning: Bool)? {
        guard let description,
              description[kDADiskDescriptionDeviceInternalKey as String] as? Bool == true,
              let bsdName = description[kDADiskDescriptionMediaBSDNameKey as String] as? String
        else { return nil }

        let health = CNVMeReadHealth(bsdName)
        guard health.available else { return nil }
        return (max(0, 100 - Int(health.percentage_used)), health.critical_warning)
    }

    /// Whether a card is in a reader built into the Mac or in one plugged into it.
    ///
    /// The distinction matters because a card left in a built-in slot is easy to forget
    /// about, while one in an external reader leaves with the reader.
    private static func describeInterface(_ description: [String: Any]?) -> String? {
        guard let description else { return nil }
        let protocolName = description[kDADiskDescriptionDeviceProtocolKey as String] as? String

        guard let kind = VolumeKind.infer(
            protocolName: protocolName,
            mediaName: Self.mediaNameForGuessing(description),
            mediaKind: description[kDADiskDescriptionMediaKindKey as String] as? String,
            sizeBytes: nil
        ), kind == .sdCard else {
            return protocolName
        }

        // "Secure Digital" is the protocol a built-in slot speaks; a card in a USB reader
        // reports the reader's own protocol instead.
        let isIntegrated = protocolName?.caseInsensitiveCompare("Secure Digital") == .orderedSame
        return isIntegrated ? "SD/CF card (integrated reader)" : "SD/CF card (external reader)"
    }

    /// The whole Disk Arbitration description for a mount path.
    private static func diskDescription(of path: String) -> [String: Any]? {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, URL(fileURLWithPath: path) as CFURL)
        else { return nil }
        return DADiskCopyDescription(disk) as? [String: Any]
    }

    /// Works out what kind of drive this is from a description already fetched by the
    /// caller, rather than asking Disk Arbitration a second time for the same disk.
    /// Everything here is best-effort: an unreadable description simply means no specific
    /// artwork, which is the honest outcome rather than a guess.
    private static func kind(from description: [String: Any]?, sizeBytes: UInt64?) -> VolumeKind? {
        guard let description else { return nil }

        // Every APFS sibling in the boot container — Preboot, VM, Update, xarts,
        // iSCPreboot, Data/home, and "/" itself — reports the SAME large size as the
        // container as a whole, which used to satisfy the size guess below and mark all
        // of them "External Disk". Internal storage is never any of the four removable
        // kinds this classifies, so it is excluded before the guess ever runs, the same
        // fix HG4MAC shipped for the identical bug.
        return VolumeKind.infer(
            protocolName: description[kDADiskDescriptionDeviceProtocolKey as String] as? String,
            mediaName: Self.mediaNameForGuessing(description),
            mediaKind: description[kDADiskDescriptionMediaKindKey as String] as? String,
            sizeBytes: sizeBytes,
            isInternal: description[kDADiskDescriptionDeviceInternalKey as String] as? Bool ?? false
        )
    }

    /// Disk Arbitration's own media name and device model, plus — when they say nothing —
    /// the underlying USB device's own product string.
    ///
    /// Confirmed live, 2026-09-05, with a genuine USB microSD reader plugged into a hub:
    /// Disk Arbitration reported `MediaName` "MassStorageClass" and no `DeviceModel` at
    /// all — a generic mass-storage class name with nothing SD-shaped in it, which is why
    /// the card mounted as a plain external disk instead of an SD card. The USB device
    /// one level up in the registry, asked directly, answers "USB3.0 Card Reader" — the
    /// same descriptor `USBMonitor` already reads as `USB Product Name`. Disk Arbitration
    /// simply does not surface that string; IOKit still has it.
    private static func mediaNameForGuessing(_ description: [String: Any]) -> String {
        let fromArbitration = [
            description[kDADiskDescriptionMediaNameKey as String] as? String,
            description[kDADiskDescriptionDeviceModelKey as String] as? String
        ].compactMap { $0 }.joined(separator: " ")
        if !fromArbitration.isEmpty { return fromArbitration }

        let bsdName = description[kDADiskDescriptionMediaBSDNameKey as String] as? String
        return Self.usbProductName(bsdName: bsdName) ?? ""
    }

    /// Walks up from a BSD disk device to the USB device that owns it, looking for its
    /// product string — the one place a USB card reader's real identity survives when
    /// Disk Arbitration's own media name is too generic to say anything (see
    /// `mediaNameForGuessing(_:)`).
    ///
    /// Bounded at 16, measured against a real reader rather than guessed at: `ioreg`
    /// against the exact card reader this was written for shows nine steps from its
    /// `IOMedia` up to the `IOUSBHostDevice` carrying "USB Product Name" — `IOBlockStorageDriver`,
    /// `IOBlockStorageServices`, `IOSCSIPeripheralDeviceType00`, `IOSCSILogicalUnitNub`,
    /// `IOUSBMassStorageDriver`, `IOUSBMassStorageDriverNub`, `IOUSBMassStorageInterfaceNub`,
    /// `IOUSBHostInterface`, then the device itself — considerably deeper than the disk-side
    /// walks elsewhere in this codebase, because a SCSI translation layer sits between a
    /// Mass Storage disk and its own USB device where a plain USB device has no such layer
    /// to cross. 16 leaves room for a reader behind an extra hub or enclosure layer too.
    private static func usbProductName(bsdName: String?) -> String? {
        guard let bsdName, let matching = IOBSDNameMatching(kIOMainPortDefault, 0, bsdName) else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return nil }

        var current = service
        defer { IOObjectRelease(current) }

        for _ in 0..<16 {
            if let name = Self.registryString(current, "USB Product Name") {
                return name
            }
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS else { return nil }
            IOObjectRelease(current)
            current = parent
        }
        return nil
    }

    private static func registryString(_ service: io_service_t, _ key: String) -> String? {
        guard let value = IORegistryEntryCreateCFProperty(
            service, key as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Plain `getmntinfo()` — same POSIX call HG4MAC's own low-space poll uses, not
    /// `NSFileManager`/`NSWorkspace`, so this never touches TCC-gated file access. Skips
    /// virtual/pseudo filesystems (devfs/autofs) and non-local mounts (a network share's
    /// "free space" belongs to the server, not this Mac).
    private static func readFreeSpaceByPath() -> [String: Double] {
        var mountsPointer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&mountsPointer, MNT_NOWAIT)
        guard count > 0, let mounts = mountsPointer else { return [:] }

        var result: [String: Double] = [:]
        for i in 0..<Int(count) {
            let mount = mounts[i]
            let fsType = withUnsafeBytes(of: mount.f_fstypename) { Self.nulTerminatedString($0) }
            guard fsType != "devfs", fsType != "autofs" else { continue }
            guard mount.f_flags & UInt32(MNT_LOCAL) != 0 else { continue }
            guard mount.f_blocks > 0 else { continue }

            let path = withUnsafeBytes(of: mount.f_mntonname) { Self.nulTerminatedString($0) }
            result[path] = 100.0 * Double(mount.f_bavail) / Double(mount.f_blocks)
        }
        return result
    }

    /// Decodes a fixed-size C char buffer (`statfs`'s `f_fstypename`/`f_mntonname` among
    /// them) by searching for the terminator within the buffer's own bounds rather than
    /// trusting `String(cString:)` to find one before it runs off the end — the kernel
    /// always null-terminates these in practice, but the bound costs nothing to keep, and
    /// matches the same pattern already used for a registry entry's name in USB Monitor.
    private static func nulTerminatedString(_ raw: UnsafeRawBufferPointer) -> String {
        let bytes = raw.bindMemory(to: UInt8.self).prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }
}
