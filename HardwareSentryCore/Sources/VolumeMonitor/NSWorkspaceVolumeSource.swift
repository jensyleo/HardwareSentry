import AppKit
import DiskArbitration
import Foundation

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

    init(continuation: AsyncStream<VolumeSourceEvent>.Continuation, freeSpacePollInterval: Duration) {
        self.continuation = continuation
        self.freeSpacePollInterval = freeSpacePollInterval
    }

    /// The volume's own name, which is what somebody calls it.
    ///
    /// The last path component is right for "/Volumes/Backup" but not for the startup
    /// disk, whose path is "/" — that has no last component worth showing, and a
    /// notification reading just "/" says nothing about which disk it means.
    private static func displayName(of url: URL) -> String {
        if let name = try? url.resourceValues(forKeys: [.localizedNameKey]).localizedName, !name.isEmpty {
            return name
        }
        let path = url.path
        let last = (path as NSString).lastPathComponent
        return last == "/" ? path : last
    }

    private func announceAlreadyMounted() {
        for url in FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: nil,
            options: [.skipHiddenVolumes]
        ) ?? [] {
            let path = url.path
            continuation.yield(.mounted(
                path: path,
                name: Self.displayName(of: url),
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
                name: (path as NSString).lastPathComponent,
                detail: Self.detail(of: path)
            ))
        })
        tokens.append(center.addObserver(forName: NSWorkspace.willUnmountNotification, object: nil, queue: nil) { [weak self] note in
            guard let path = note.userInfo?["NSDevicePath"] as? String else { return }
            self?.continuation.yield(.willUnmount(path: path, name: (path as NSString).lastPathComponent))
        })
        tokens.append(center.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: nil) { [weak self] note in
            guard let path = note.userInfo?["NSDevicePath"] as? String else { return }
            self?.continuation.yield(.unmounted(path: path, name: (path as NSString).lastPathComponent))
        })

        // `didMountNotification` only ever fires for a volume that mounts while this is
        // listening, so without this sweep the volumes that were already mounted when the
        // application launched are invisible to it — which is most of them, most of the
        // time.
        announceAlreadyMounted()

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
        continuation.finish()
    }

    /// Read at mount time, while there is still a filesystem there to ask. Plain `statfs`
    /// rather than `NSFileManager`, for the same reason the free-space poll uses
    /// `getmntinfo`: it never touches the file access macOS gates behind a prompt.
    private static func detail(of path: String) -> VolumeDetail {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return VolumeDetail() }

        let type = withUnsafeBytes(of: info.f_fstypename) { raw -> String? in
            let value = String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            return value.isEmpty ? nil : value
        }
        let total = UInt64(info.f_blocks) * UInt64(info.f_bsize)

        return VolumeDetail(
            fileSystemType: type,
            totalBytes: total > 0 ? total : nil,
            isReadOnly: info.f_flags & UInt32(MNT_RDONLY) != 0,
            kind: kind(of: path, sizeBytes: total > 0 ? total : nil)
        )
    }

    /// Asks Disk Arbitration what the volume sits on. Everything here is best-effort: an
    /// unreadable description simply means no specific artwork, which is the honest
    /// outcome rather than a guess.
    private static func kind(of path: String, sizeBytes: UInt64?) -> VolumeKind? {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, URL(fileURLWithPath: path) as CFURL),
              let description = DADiskCopyDescription(disk) as? [String: Any]
        else { return nil }

        return VolumeKind.infer(
            protocolName: description[kDADiskDescriptionDeviceProtocolKey as String] as? String,
            mediaName: [
                description[kDADiskDescriptionMediaNameKey as String] as? String,
                description[kDADiskDescriptionDeviceModelKey as String] as? String
            ].compactMap { $0 }.joined(separator: " "),
            mediaKind: description[kDADiskDescriptionMediaKindKey as String] as? String,
            sizeBytes: sizeBytes
        )
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
            let fsType = withUnsafeBytes(of: mount.f_fstypename) { raw -> String in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
            guard fsType != "devfs", fsType != "autofs" else { continue }
            guard mount.f_flags & UInt32(MNT_LOCAL) != 0 else { continue }
            guard mount.f_blocks > 0 else { continue }

            let path = withUnsafeBytes(of: mount.f_mntonname) { raw -> String in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
            result[path] = 100.0 * Double(mount.f_bavail) / Double(mount.f_blocks)
        }
        return result
    }
}
