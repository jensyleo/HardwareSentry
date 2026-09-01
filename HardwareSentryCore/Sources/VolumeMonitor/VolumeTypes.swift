import Foundation

/// What a volume could be described as at the moment it mounted.
///
/// Read then and not later: an unmounted path has no live filesystem left to ask.
public struct VolumeDetail: Sendable, Equatable {
    public let fileSystemType: String?
    public let totalBytes: UInt64?
    public let isReadOnly: Bool
    public let kind: VolumeKind?

    public init(fileSystemType: String? = nil, totalBytes: UInt64? = nil, isReadOnly: Bool = false, kind: VolumeKind? = nil) {
        self.fileSystemType = fileSystemType
        self.totalBytes = totalBytes
        self.isReadOnly = isReadOnly
        self.kind = kind
    }

    public var sizeLabel: String? {
        totalBytes.map {
            ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)
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

    public var iconBaseName: String {
        switch self {
        case .sdCard: return "Device-SDCard"
        case .usbDrive: return "Device-USBDrive"
        case .externalDisk: return "Device-ExternalDisk"
        case .optical: return "Device-Optical"
        case .nas: return "Device-NAS"
        }
    }

    /// Unnamed USB storage this size or larger is guessed to be an enclosure rather than a
    /// flash drive. Only ever consulted when the name says nothing — a 1 TB flash drive is
    /// a real product, so an explicit name always wins over the size.
    static let externalDiskThresholdBytes: UInt64 = 400 * 1024 * 1024 * 1024

    public static func infer(
        protocolName: String?,
        mediaName: String?,
        mediaKind: String?,
        sizeBytes: UInt64?
    ) -> VolumeKind? {
        // Optical media and network shares are unambiguous: both are standard fields with
        // no guesswork, unlike everything below them.
        if let kind = mediaKind?.lowercased(),
           kind.contains("cd") || kind.contains("dvd") || kind.contains("blu-ray") {
            return .optical
        }
        if let proto = protocolName?.uppercased(), ["SMB", "AFP", "NFS"].contains(proto) {
            return .nas
        }
        if protocolName?.caseInsensitiveCompare("Secure Digital") == .orderedSame { return .sdCard }

        let text = (mediaName ?? "").lowercased()
        if ["card reader", "sd card", "sdxc", "cf card"].contains(where: text.contains) { return .sdCard }
        // An explicit name beats the size guess: checked first so a 1 TB drive that calls
        // itself a flash drive is not filed as an enclosure on size alone.
        if ["flash", "thumb", "pen drive", "usb drive", "mass storage"].contains(where: text.contains) { return .usbDrive }
        if ["hdd", "ssd", "hard disk", "hard drive", "external"].contains(where: text.contains) { return .externalDisk }
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
}

/// What the system told this monitor just happened.
public enum VolumeSourceEvent: Sendable, Equatable {
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
