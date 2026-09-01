import AVFoundation
import CoreAudio
import CoreMediaIO
import Foundation

/// Watches AVFoundation/CoreMediaIO for cameras connecting, disconnecting, starting or
/// stopping being used by any app, and Control Center's video effects changing.
///
/// Deliberately thin and untested, for the same reason `IOKitUSBDeviceSource` is: none of
/// it can run without real hardware/app activity. Everything worth reasoning about — in
/// particular the "stop" debounce, which exists because activating a camera briefly cycles
/// CoreMediaIO's running-state property during stream setup — lives in `CameraMonitor`,
/// behind `CameraSource`.
public final class AVFoundationCameraSource: NSObject, CameraSource, @unchecked Sendable {
    public override init() { super.init() }

    public func changes() -> AsyncStream<CameraSourceEvent> {
        AsyncStream { continuation in
            let watcher = Watcher(continuation: continuation)
            continuation.onTermination = { _ in watcher.stop() }
            watcher.start()
        }
    }

    /// `AVCaptureDevice.transportType` reuses the exact same `FourCharCode` constants as
    /// CoreAudio's `kAudioDeviceTransportType*` — a camera on one of these transports is
    /// already reported by USB/Bluetooth Monitor, so this monitor stays out of its way.
    static func isAlreadyCoveredByAnotherMonitor(_ transport: Int32) -> Bool {
        transport == kAudioDeviceTransportTypeUSB
            || transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
    }
}

private final class Watcher: NSObject, @unchecked Sendable {
    private let continuation: AsyncStream<CameraSourceEvent>.Continuation
    private var deviceListChangedBlock: CMIOObjectPropertyListenerBlock?
    private var inUseListenerBlock: CMIOObjectPropertyListenerBlock?
    private var deviceIDsWithListener: Set<CMIODeviceID> = []
    private var kvoTokens: [NSKeyValueObservation] = []
    private var connectToken: NSObjectProtocol?
    private var disconnectToken: NSObjectProtocol?

    init(continuation: AsyncStream<CameraSourceEvent>.Continuation) {
        self.continuation = continuation
    }

    func start() {
        let center = NotificationCenter.default
        connectToken = center.addObserver(forName: AVCaptureDevice.wasConnectedNotification, object: nil, queue: nil) { [weak self] note in
            self?.reportConnection(note, connected: true)
        }
        disconnectToken = center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: nil) { [weak self] note in
            self?.reportConnection(note, connected: false)
        }

        registerRunningStateListeners()
        refreshRunningState()

        let deviceListChangedBlock: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
            // Deferred to the next run-loop turn: calling CMIOObjectRemovePropertyListenerBlock
            // synchronously from inside this exact callback is an unsafe reentrant call into
            // CoreMediaIO's internal DAL, confirmed to crash in HG4MAC's own history.
            DispatchQueue.main.async {
                self?.unregisterRunningStateListeners()
                self?.registerRunningStateListeners()
                self?.refreshRunningState()
            }
        }
        self.deviceListChangedBlock = deviceListChangedBlock
        var devicesAddress = CMIOObjectPropertyAddress(
            mSelector: UInt32(kCMIOHardwarePropertyDevices),
            mScope: UInt32(kCMIOObjectPropertyScopeGlobal),
            mElement: UInt32(kCMIOObjectPropertyElementMain)
        )
        CMIOObjectAddPropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &devicesAddress, DispatchQueue.main, deviceListChangedBlock)

        observeVideoEffect(keyPath: "portraitEffectEnabled", effect: .portraitEffect) { AVCaptureDevice.isPortraitEffectEnabled }
        if #available(macOS 13.0, *) {
            observeVideoEffect(keyPath: "studioLightEnabled", effect: .studioLight) { AVCaptureDevice.isStudioLightEnabled }
        }
        if #available(macOS 14.0, *) {
            observeVideoEffect(keyPath: "reactionEffectsEnabled", effect: .reactions) { AVCaptureDevice.reactionEffectsEnabled }
        }
        if #available(macOS 15.0, *) {
            observeVideoEffect(keyPath: "backgroundReplacementEnabled", effect: .backgroundReplacement) { AVCaptureDevice.isBackgroundReplacementEnabled }
        }
    }

    func stop() {
        if let connectToken { NotificationCenter.default.removeObserver(connectToken) }
        if let disconnectToken { NotificationCenter.default.removeObserver(disconnectToken) }
        kvoTokens.forEach { $0.invalidate() }
        kvoTokens.removeAll()
        unregisterRunningStateListeners()
        if let deviceListChangedBlock {
            var devicesAddress = CMIOObjectPropertyAddress(
                mSelector: UInt32(kCMIOHardwarePropertyDevices),
                mScope: UInt32(kCMIOObjectPropertyScopeGlobal),
                mElement: UInt32(kCMIOObjectPropertyElementMain)
            )
            CMIOObjectRemovePropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &devicesAddress, DispatchQueue.main, deviceListChangedBlock)
        }
        continuation.finish()
    }

    // MARK: Connect/disconnect

    private func reportConnection(_ note: Notification, connected: Bool) {
        guard let device = note.object as? AVCaptureDevice, device.hasMediaType(.video) else { return }
        guard !AVFoundationCameraSource.isAlreadyCoveredByAnotherMonitor(device.transportType) else { return }
        continuation.yield(
            connected
                ? .connected(uid: device.uniqueID, name: device.localizedName, detail: CameraDetail(device: device))
                : .disconnected(uid: device.uniqueID, name: device.localizedName)
        )
    }

    // MARK: Running state (CoreMediaIO)

    private func allCMIODeviceIDs() -> [CMIODeviceID] {
        var address = CMIOObjectPropertyAddress(
            mSelector: UInt32(kCMIOHardwarePropertyDevices),
            mScope: UInt32(kCMIOObjectPropertyScopeGlobal),
            mElement: UInt32(kCMIOObjectPropertyElementMain)
        )
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, &size) == kCMIOHardwareNoError, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<CMIODeviceID>.size
        var deviceIDs = [CMIODeviceID](repeating: 0, count: count)
        guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, size, &size, &deviceIDs) == kCMIOHardwareNoError else { return [] }
        return deviceIDs
    }

    private func uid(for deviceID: CMIODeviceID) -> String? {
        var address = CMIOObjectPropertyAddress(
            mSelector: UInt32(kCMIODevicePropertyDeviceUID),
            mScope: UInt32(kCMIOObjectPropertyScopeGlobal),
            mElement: UInt32(kCMIOObjectPropertyElementMain)
        )
        var uidRef: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard CMIOObjectGetPropertyData(deviceID, &address, 0, nil, size, &size, &uidRef) == kCMIOHardwareNoError else { return nil }
        return uidRef?.takeRetainedValue() as String?
    }

    private func isRunningSomewhere(_ deviceID: CMIODeviceID) -> Bool {
        var address = CMIOObjectPropertyAddress(
            mSelector: UInt32(kCMIODevicePropertyDeviceIsRunningSomewhere),
            mScope: UInt32(kCMIOObjectPropertyScopeGlobal),
            mElement: UInt32(kCMIOObjectPropertyElementMain)
        )
        guard CMIOObjectHasProperty(deviceID, &address) else { return false }
        var isRunning: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        CMIOObjectGetPropertyData(deviceID, &address, 0, nil, size, &size, &isRunning)
        return isRunning != 0
    }

    private func registerRunningStateListeners() {
        let block: CMIOObjectPropertyListenerBlock
        if let existing = inUseListenerBlock {
            block = existing
        } else {
            block = { [weak self] _, _ in self?.refreshRunningState() }
            inUseListenerBlock = block
        }
        var address = CMIOObjectPropertyAddress(
            mSelector: UInt32(kCMIODevicePropertyDeviceIsRunningSomewhere),
            mScope: UInt32(kCMIOObjectPropertyScopeGlobal),
            mElement: UInt32(kCMIOObjectPropertyElementMain)
        )
        for deviceID in allCMIODeviceIDs() where !deviceIDsWithListener.contains(deviceID) {
            guard CMIOObjectHasProperty(deviceID, &address) else { continue }
            CMIOObjectAddPropertyListenerBlock(deviceID, &address, DispatchQueue.main, block)
            deviceIDsWithListener.insert(deviceID)
        }
    }

    private func unregisterRunningStateListeners() {
        guard let block = inUseListenerBlock else { return }
        var address = CMIOObjectPropertyAddress(
            mSelector: UInt32(kCMIODevicePropertyDeviceIsRunningSomewhere),
            mScope: UInt32(kCMIOObjectPropertyScopeGlobal),
            mElement: UInt32(kCMIOObjectPropertyElementMain)
        )
        // Only for IDs still in the current device list — removing a listener from an
        // already-torn-down ID (the common reason this runs at all: a camera just
        // disconnected) is what crashed in HG4MAC's own history.
        let currentIDs = Set(allCMIODeviceIDs())
        for deviceID in deviceIDsWithListener where currentIDs.contains(deviceID) {
            CMIOObjectRemovePropertyListenerBlock(deviceID, &address, DispatchQueue.main, block)
        }
        deviceIDsWithListener.removeAll()
    }

    private func refreshRunningState() {
        var running: [String: String] = [:]
        for deviceID in allCMIODeviceIDs() {
            guard let uid = uid(for: deviceID), isRunningSomewhere(deviceID) else { continue }
            running[uid] = AVCaptureDevice(uniqueID: uid)?.localizedName ?? "Camera"
        }
        continuation.yield(.runningStateChanged(running: running))
    }

    // MARK: Video effects (class-level KVO)

    // Video effects are CLASS-level KVO (`[AVCaptureDevice addObserver:...]`, relying on
    // Class objects falling back to NSObject's KVO machinery via the root metaclass) —
    // Swift's typed `NSKeyValueObservation`/`observe(_:options:)` only expresses
    // instance-level KVO, so this goes through the plain Objective-C runtime API instead.
    private func observeVideoEffect(keyPath: String, effect: CameraVideoEffect, currentValue: @escaping () -> Bool) {
        AVCaptureDevice.addObserver(self, forKeyPath: keyPath, options: [], context: nil)
        pendingEffectKeyPaths[keyPath] = effect
        effectValueReaders[keyPath] = currentValue
    }

    private var pendingEffectKeyPaths: [String: CameraVideoEffect] = [:]
    private var effectValueReaders: [String: () -> Bool] = [:]

    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        guard let keyPath, let effect = pendingEffectKeyPaths[keyPath], let reader = effectValueReaders[keyPath] else { return }
        continuation.yield(.videoEffectChanged(effect, enabled: reader()))
    }

    deinit {
        for keyPath in pendingEffectKeyPaths.keys {
            AVCaptureDevice.removeObserver(self, forKeyPath: keyPath)
        }
    }
}
