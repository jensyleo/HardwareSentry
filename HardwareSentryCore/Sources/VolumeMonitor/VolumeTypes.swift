import Foundation

/// What a volume could be described as at the moment it mounted.
///
/// Read then and not later: an unmounted path has no live filesystem left to ask.
public struct VolumeDetail: Sendable, Equatable {
    public let fileSystemType: String?
    public let totalBytes: UInt64?
    public let isReadOnly: Bool
    public let kind: VolumeKind?

    /// The drive's own health percentage, for disks that report SMART data.
    public let healthPercent: Int?
    /// Whether the drive itself is warning about its condition, alongside the percentage.
    public let hasHealthWarning: Bool
    public let isEncrypted: Bool?
    /// The volume format as macOS names it — "APFS", "ExFAT", "MS-DOS (FAT32)". A
    /// different, friendlier answer than the raw file-system type.
    public let format: String?
    public let uuid: String?
    public let isRemovable: Bool?
    public let isEjectable: Bool?
    public let isCaseSensitive: Bool?
    /// Which bus the disk is on, and the size of its sectors.
    public let busName: String?
    public let sectorSize: Int?
    /// How the card got here, when it is a card: whether the reader is built in or
    /// plugged in, which is what decides whether it can be forgotten in a slot.
    public let interfaceDescription: String?
    /// Free space including what macOS would reclaim if pushed. Shown alongside the plain
    /// figure on a low-space warning, because the two can differ by a lot and the
    /// difference is the difference between "act now" and "it will sort itself out".
    public let purgeableAwareFreeBytes: UInt64?

    public init(
        fileSystemType: String? = nil,
        totalBytes: UInt64? = nil,
        isReadOnly: Bool = false,
        kind: VolumeKind? = nil,
        healthPercent: Int? = nil,
        hasHealthWarning: Bool = false,
        isEncrypted: Bool? = nil,
        format: String? = nil,
        uuid: String? = nil,
        isRemovable: Bool? = nil,
        isEjectable: Bool? = nil,
        isCaseSensitive: Bool? = nil,
        busName: String? = nil,
        sectorSize: Int? = nil,
        interfaceDescription: String? = nil,
        purgeableAwareFreeBytes: UInt64? = nil
    ) {
        self.fileSystemType = fileSystemType
        self.totalBytes = totalBytes
        self.isReadOnly = isReadOnly
        self.kind = kind
        self.healthPercent = healthPercent
        self.hasHealthWarning = hasHealthWarning
        self.isEncrypted = isEncrypted
        self.format = format
        self.uuid = uuid
        self.isRemovable = isRemovable
        self.isEjectable = isEjectable
        self.isCaseSensitive = isCaseSensitive
        self.busName = busName
        self.sectorSize = sectorSize
        self.interfaceDescription = interfaceDescription
        self.purgeableAwareFreeBytes = purgeableAwareFreeBytes
    }

    /// The health figure, with the drive's own warning appended when it is complaining.
    ///
    /// The warning is the actionable half: a percentage on its own invites arguing about
    /// what counts as low, while a drive saying it is in trouble does not.
    var healthNote: String? {
        guard let healthPercent else { return nil }
        return hasHealthWarning ? "\(healthPercent)% (Warning)" : "\(healthPercent)%"
    }

    var encryptedNote: String? { isEncrypted.map { $0 ? "Yes" : "No" } }
    var caseSensitiveNote: String? { isCaseSensitive.map { $0 ? "Yes" : "No" } }

    /// Removable and ejectable on one line, because they are almost the same question and
    /// two lines of Yes/No for it reads as padding.
    var removableNote: String? {
        guard let isRemovable, let isEjectable else { return nil }
        return "\(isRemovable ? "Yes" : "No")\tEjectable:\t\(isEjectable ? "Yes" : "No")"
    }

    /// The bus and the sector size together — neither is worth a line alone.
    var busNote: String? {
        var parts: [String] = []
        if let busName { parts.append(busName) }
        if let sectorSize { parts.append("Sector size: \(sectorSize) bytes") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    var purgeableAwareFreeLabel: String? {
        purgeableAwareFreeBytes.map {
            ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)
        }
    }

    public var sizeLabel: String? {
        totalBytes.map {
            ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)
        }
    }

    /// `fileSystemType` as macOS reports it is the right value to detect a network share
    /// with, but the wrong one to show somebody — "smbfs" names an implementation detail,
    /// not the protocol a person recognises. Only the network filesystems get a friendlier
    /// name; everything else (apfs, exfat, msdos…) is shown exactly as macOS names it,
    /// unchanged, since nothing here claims those need translating too.
    public var fileSystemLabel: String? {
        guard let fileSystemType else { return nil }
        switch fileSystemType.lowercased() {
        case "smbfs": return "SMB"
        case "afpfs": return "AFP"
        case "nfs": return "NFS"
        case "webdav": return "WebDAV"
        case "ftp": return "FTP"
        default: return fileSystemType
        }
    }
}

/// What kind of thing a volume lives on, when that can be said with any confidence.
///
/// Deliberately incomplete. There is no public API that reliably tells a pendrive from an
/// external disk enclosure — both appear as plain USB mass storage with nothing to separate
/// them on much real hardware. HG4MAC learned this the hard way: a fallback of "plain USB
/// storage under the size threshold is essentially always a pendrive" was added after one
/// live test and removed after the very next, when a real SD card in a USB reader
/// (reporting itself as "STORAGE DEVICE", protocol USB, 64 GB) was confidently mislabelled.
///
/// So this returns nil whenever there is no honest signal, and the caller falls back to the
/// plain volume icon. A wrong specific icon is worse than a right generic one.
public enum VolumeKind: String, Sendable, Equatable, CaseIterable {
    case sdCard, usbDrive, externalDisk, optical, nas

    /// How the row is named in Settings, in the original's words.
    var settingsTitle: String {
        switch self {
        case .sdCard: return "SD Card"
        case .usbDrive: return "USB Drive"
        case .externalDisk: return "External Disk"
        case .optical: return "Optical"
        case .nas: return "NAS"
        }
    }

    /// The event raised when a volume of this kind mounts, and when one goes.
    ///
    /// Three rows per kind rather than one, as the original has it: mounting, unmounting
    /// and running out of space are three different pieces of news about the same drive,
    /// and somebody who wants the low-space warning on an external disk does not
    /// necessarily want to be told every time they plug it in.
    var mountedEvent: VolumeEvent {
        switch self {
        case .optical: return .mountedOptical
        case .nas: return .mountedNAS
        case .externalDisk: return .mountedExternalDisk
        case .sdCard: return .mountedSDCard
        case .usbDrive: return .mountedUSBDrive
        }
    }

    var unmountedEvent: VolumeEvent {
        switch self {
        case .optical: return .unmountedOptical
        case .nas: return .unmountedNAS
        case .externalDisk: return .unmountedExternalDisk
        case .sdCard: return .unmountedSDCard
        case .usbDrive: return .unmountedUSBDrive
        }
    }

    var lowSpaceEvent: VolumeEvent {
        switch self {
        case .optical: return .lowSpaceOptical
        case .nas: return .lowSpaceNAS
        case .externalDisk: return .lowSpaceExternalDisk
        case .sdCard: return .lowSpaceSDCard
        case .usbDrive: return .lowSpaceUSBDrive
        }
    }

    public var iconBaseName: String {
        switch self {
        case .sdCard: return "Device-SDCard"
        case .usbDrive: return "Device-USBDrive"
        case .externalDisk: return "Device-ExternalDisk"
        case .optical: return "Device-Optical"
        case .nas: return "Device-NAS"
        }
    }

    /// The filesystems macOS mounts a network share with. `webdav` and `ftp` belong here
    /// as much as the three that were listed before: all four are somewhere else on the
    /// network, which is the only thing this row claims.
    private static func namesANetworkFilesystem(_ kind: String?) -> Bool {
        guard let kind = kind?.lowercased() else { return false }
        return ["smbfs", "afpfs", "nfs", "webdav", "ftp"].contains(kind)
    }

    /// `autofs` is the automounter's own placeholder, and it reports itself as being on
    /// the network — `/System/Volumes/Data/home` is one on every Mac, mounted with no
    /// share behind it. Nobody connected to it, so announcing it as a NAS would be
    /// announcing the operating system's own plumbing.
    private static func isAutomounterPlaceholder(_ kind: String?) -> Bool {
        kind?.lowercased() == "autofs"
    }

    /// Unnamed USB storage this size or larger is guessed to be an enclosure rather than a
    /// flash drive. Only ever consulted when the name says nothing — a 1 TB flash drive is
    /// a real product, so an explicit name always wins over the size.
    static let externalDiskThresholdBytes: UInt64 = 400 * 1024 * 1024 * 1024

    /// - Parameter filesystemKind: Disk Arbitration's `VolumeKind` — the filesystem's own
    ///   name (`apfs`, `smbfs`, `nfs`, `webdav`…), not to be confused with this type.
    /// - Parameter isNetwork: Disk Arbitration's `VolumeNetwork`.
    public static func infer(
        protocolName: String?,
        mediaName: String?,
        mediaKind: String?,
        sizeBytes: UInt64?,
        isInternal: Bool = false,
        filesystemKind: String? = nil,
        isNetwork: Bool = false
    ) -> VolumeKind? {
        // Every APFS sibling of the boot container — Preboot, VM, Update, xarts,
        // iSCPreboot, Data/home, and "/" itself — reports the SAME large size as the
        // container as a whole, which would otherwise satisfy the size guess below and
        // tag every one of them "External Disk". Internal storage is never any of the
        // four removable kinds this infers, checked first and unconditionally, matching
        // the fix HG4MAC shipped for the identical, dated bug (23-jul-2026).
        guard !isInternal else { return nil }

        // Optical media and network shares are unambiguous: both are standard fields with
        // no guesswork, unlike everything below them.
        if let kind = mediaKind?.lowercased(),
           kind.contains("cd") || kind.contains("dvd") || kind.contains("blu-ray") {
            return .optical
        }
        // A network share is recognised by its filesystem, and by Disk Arbitration saying
        // outright that the volume is on the network — not by the device protocol, which
        // describes the *bus* a disk sits on (USB, SATA, Apple Fabric, Secure Digital)
        // and is `nil` for a share, there being no bus. Read live 2026-09-18 from the one
        // network volume mounted at the time:
        //
        //     /System/Volumes/Data/home
        //     DeviceProtocol: nil   VolumeKind: autofs   VolumeNetwork: true
        //
        // The protocol check is kept as well rather than replaced: it costs nothing, and
        // if some mount does report "SMB" there it still answers.
        if Self.namesANetworkFilesystem(filesystemKind) { return .nas }
        if isNetwork, !Self.isAutomounterPlaceholder(filesystemKind) { return .nas }
        if let proto = protocolName?.uppercased(), ["SMB", "AFP", "NFS", "WEBDAV"].contains(proto) {
            return .nas
        }
        if protocolName?.caseInsensitiveCompare("Secure Digital") == .orderedSame { return .sdCard }

        let text = (mediaName ?? "").lowercased()
        if ["secure digital", " sd/", "sd card", "sdxc", "sdhc", "mmc",
            "compactflash", " cf ", "cardreader", "card reader",
            // microSDXC/microSDHC already match "sdxc"/"sdhc" above; these two catch a
            // bare "microSD" or the format's old "TransFlash" branding, which do not.
            "microsd", "micro sd", "tf card", "transflash"].contains(where: text.contains) { return .sdCard }
        // An explicit name beats the size guess: checked first so a 1 TB drive that calls
        // itself a flash drive is not filed as an enclosure on size alone.
        // Enclosures before thumb drives, the order the original settled on: "external
        // flash SSD" names both, and it is an enclosure.
        if ["hdd", "ssd", "hard disk", "hard drive", "external"].contains(where: text.contains) { return .externalDisk }
        if ["flash", "thumb", "pen drive", "usb drive", "mass storage"].contains(where: text.contains) { return .usbDrive }
        if let sizeBytes, sizeBytes >= externalDiskThresholdBytes { return .externalDisk }

        return nil
    }
}

/// The optional details this monitor can add to a mount notification.
public enum VolumeField: String, CaseIterable {
    case path = "Path"
    case fileSystem = "FileSystem"
    case size = "Size"
    case readOnly = "ReadOnly"
    case health = "Health"
    case fileVault = "FileVault"
    case format = "Format"
    case uuid = "UUID"
    case removable = "Removable"
    case caseSensitive = "CaseSensitive"
    case busInfo = "BusInfo"
    case interfaceType = "InterfaceType"
    case purgeableSpace = "PurgeableSpace"

    /// How the line is named in Settings → Events, under "Include in the message".
    var settingsTitle: String {
        switch self {
        case .path: return "Mount path"
        case .fileSystem: return "File system type"
        case .size: return "Volume size"
        case .readOnly: return "Read-only flag"
        case .health: return "Drive health (disks that report it)"
        case .fileVault: return "Whether it is encrypted"
        case .format: return "Format (APFS, ExFAT, MS-DOS…)"
        case .uuid: return "Volume UUID"
        case .removable: return "Removable and ejectable flags"
        case .caseSensitive: return "Case sensitivity"
        case .busInfo: return "Bus and sector size"
        case .interfaceType: return "Card reader type"
        case .purgeableSpace: return "Free space including what macOS would reclaim"
        }
    }

    /// Path, file system, size, drive health and encryption are on. The first three answer
    /// "which disk is this and how big"; the other two are the ones that would matter and
    /// that nobody thinks to go looking for.
    var shownByDefault: Bool {
        [.path, .fileSystem, .size, .health, .fileVault].contains(self)
    }
}

/// What the system told this monitor just happened.
public enum VolumeSourceEvent: Sendable, Equatable {
    /// A settled batch of partitions the system saw but could not read, with the whole
    /// disks that did have something mount. Settled rather than live: inserting one card
    /// produces a burst of these, and the useful unit is the card.
    case unreadable(partitions: [UnreadablePartition], readableWholeDisks: Set<String>)
    /// A whole disk left entirely, so re-inserting it warns again.
    case wholeDiskDisappeared(String)
    case mounted(path: String, name: String, detail: VolumeDetail = VolumeDetail())
    /// Finder is about to eject this volume gracefully. Distinct from `.unmounted` so the
    /// monitor can tell a graceful eject apart from a surprise removal — a volume that
    /// disappears with no matching `.willUnmount` first was pulled out, not ejected.
    case willUnmount(path: String, name: String)
    case unmounted(path: String, name: String)
    /// Percent free space per currently-mounted local volume — not a delta; the monitor
    /// applies the threshold/hysteresis.
    case freeSpaceSnapshot([String: Double])
}

public protocol VolumeSource: Sendable {
    func changes() -> AsyncStream<VolumeSourceEvent>
}
