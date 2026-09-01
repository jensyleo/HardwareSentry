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
    public init() {}

    public func changes() -> AsyncStream<DisplaySourceEvent> {
        AsyncStream { continuation in
            let watcher = Watcher(continuation: continuation)
            continuation.onTermination = { _ in watcher.stop() }
            watcher.start()
        }
    }
}

private final class Watcher: @unchecked Sendable {
    private let continuation: AsyncStream<DisplaySourceEvent>.Continuation
    private var colorProfileToken: NSObjectProtocol?

    init(continuation: AsyncStream<DisplaySourceEvent>.Continuation) {
        self.continuation = continuation
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
        colorProfileToken = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.ColorSync.DisplayProfileNotification"),
            object: nil, queue: nil
        ) { [weak self] _ in
            self?.continuation.yield(.colorProfileChanged)
        }
    }

    func stop() {
        if let colorProfileToken { DistributedNotificationCenter.default().removeObserver(colorProfileToken) }
        continuation.finish()
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
                isAsleep: CGDisplayIsAsleep(id) != 0
            )
        }
        continuation.yield(.snapshot(snapshots))
    }
}
