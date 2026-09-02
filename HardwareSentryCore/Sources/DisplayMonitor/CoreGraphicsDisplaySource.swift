import AppKit
import ColorSync
import CoreGraphics
import Foundation

/// Watches CoreGraphics for display reconfigurations and ColorSync for ICC profile
/// changes.
///
/// Deliberately thin and untested, for the same reason `IOKitUSBDeviceSource` is: none of
/// it can run without a real display being plugged in, put to sleep, or reconfigured.
/// Everything worth reasoning about — the connect/mode/role/sleep diffing — lives in
/// `DisplayMonitor`, behind `DisplaySource`.
///
/// Detection is driven by `CGDisplayRegisterReconfigurationCallback` +
/// `CGGetOnlineDisplayList`, not `NSScreen`/`NSApplicationDidChangeScreenParametersNotification`:
/// `NSScreen` only exposes displays AppKit can address a window to, so a display macOS puts
/// in Mirror mode never gets its own `NSScreen` entry — confirmed in HG4MAC's own history.
public struct CoreGraphicsDisplaySource: DisplaySource {
    private let videoLinkPolling: Duration?

    /// - Parameter videoLinkPolling: how often to look in the kernel log for a video link
    ///   coming up, or nil not to look at all. Nil is the right default for a host that
    ///   does not want an experimental feature polling in the background; the application
    ///   passes an interval only when the notification is switched on.
    public init(videoLinkPolling: Duration? = nil) {
        self.videoLinkPolling = videoLinkPolling
    }

    public func changes() -> AsyncStream<DisplaySourceEvent> {
        AsyncStream { continuation in
            let watcher = Watcher(continuation: continuation, videoLinkPolling: videoLinkPolling)
            continuation.onTermination = { _ in watcher.stop() }
            watcher.start()
        }
    }
}

private final class Watcher: @unchecked Sendable {
    private let continuation: AsyncStream<DisplaySourceEvent>.Continuation
    private var colorProfileToken: NSObjectProtocol?
    private let videoLinkPolling: Duration?
    private var videoLinkTask: Task<Void, Never>?

    init(continuation: AsyncStream<DisplaySourceEvent>.Continuation, videoLinkPolling: Duration?) {
        self.continuation = continuation
        self.videoLinkPolling = videoLinkPolling
    }

    func start() {
        emitSnapshot()
        let context = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRegisterReconfigurationCallback({ _, _, userInfo in
            guard let userInfo else { return }
            let watcher = Unmanaged<Watcher>.fromOpaque(userInfo).takeUnretainedValue()
            // Fires on an arbitrary thread, and once per display per reconfiguration event
            // (sometimes several times for one hotplug) — hop to main and just re-read the
            // full list each time; re-diffing an unchanged list is harmless.
            DispatchQueue.main.async {
                watcher.emitSnapshot()
            }
        }, context)

        // `kColorSyncDisplayDeviceProfilesNotification`'s value, per its own header comment
        // (ColorSyncDevice.h) — read as a plain string literal rather than the imported
        // global, which Swift 6 flags as not concurrency-safe (it's an `Unmanaged<CFString>`
        // global var, not a `let`) even though its value never actually changes at runtime.
        startVideoLinkPoll()

        colorProfileToken = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.ColorSync.DisplayProfileNotification"),
            object: nil, queue: nil
        ) { [weak self] _ in
            self?.continuation.yield(.colorProfileChanged)
        }
    }

    func stop() {
        videoLinkTask?.cancel()
        if let colorProfileToken { DistributedNotificationCenter.default().removeObserver(colorProfileToken) }
        continuation.finish()
    }

    /// Looks in the kernel log for a video link, if this host asked for it.
    ///
    /// Polling, because `OSLogStore` offers no push callback — only a historical
    /// enumerator. Each pass reads from where the last one stopped rather than from a
    /// fixed window, so nothing is seen twice and nothing falls between two passes.
    private func startVideoLinkPoll() {
        guard let interval = videoLinkPolling else { return }

        videoLinkTask = Task { [continuation] in
            let detector = VideoLinkDetector()
            var since = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }

                let now = Date()
                if detector.sawLink(since: since) {
                    continuation.yield(.videoLinkDetected)
                }
                since = now
            }
        }
    }

    private func emitSnapshot() {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        guard count > 0 else { continuation.yield(.snapshot([])); return }

        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)

        let screensByID: [CGDirectDisplayID: NSScreen] = Dictionary(
            uniqueKeysWithValues: NSScreen.screens.compactMap { screen in
                guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
                return (CGDirectDisplayID(number.uint32Value), screen)
            }
        )

        // Named up front so a mirroring display can be described by the name of the
        // display it mirrors, rather than by its numeric ID.
        let nameOfDisplay = { (other: CGDirectDisplayID) -> String? in
            screensByID[other]?.localizedName
        }

        let snapshots = ids.map { id -> DisplaySnapshot in
            let screen = screensByID[id]
            let name = screen?.localizedName ?? "External Display"
            let mode = CGDisplayCopyDisplayMode(id)
            return DisplaySnapshot(
                id: String(id),
                name: name,
                width: mode.map { Int($0.pixelWidth) } ?? 0,
                height: mode.map { Int($0.pixelHeight) } ?? 0,
                refreshHz: mode.map { $0.refreshRate } ?? 0,
                rotation: CGDisplayRotation(id),
                role: CGDisplayIsMain(id) != 0 ? .main : (CGDisplayIsInMirrorSet(id) != 0 ? .mirrored : .extended),
                isAsleep: CGDisplayIsAsleep(id) != 0,
                detail: DisplayDetail(id: id, screen: screen, mode: mode, nameOfDisplay: nameOfDisplay)
            )
        }
        continuation.yield(.snapshot(snapshots))
    }
}
