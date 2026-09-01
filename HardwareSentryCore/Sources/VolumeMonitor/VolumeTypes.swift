import Foundation

/// What a volume could be described as at the moment it mounted.
///
/// Read then and not later: an unmounted path has no live filesystem left to ask.
public struct VolumeDetail: Sendable, Equatable {
    public let fileSystemType: String?
    public let totalBytes: UInt64?
    public let isReadOnly: Bool

    public init(fileSystemType: String? = nil, totalBytes: UInt64? = nil, isReadOnly: Bool = false) {
        self.fileSystemType = fileSystemType
        self.totalBytes = totalBytes
        self.isReadOnly = isReadOnly
    }

    public var sizeLabel: String? {
        totalBytes.map {
            ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)
        }
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
