import Foundation
import IOKit
import IOKit.pwr_mgt

/// Watches the real Mac for thermal state changes and dark-wake thermal emergencies.
///
/// Deliberately thin and untested, for the same reason `IOKitUSBDeviceSource` is: none of
/// it can run without the real hardware condition it observes. Everything worth reasoning
/// about lives in `ThermalMonitor`, behind `ThermalStateSource`.
public struct SystemThermalStateSource: ThermalStateSource {
    public init() {}

    public func currentState() -> ThermalState {
        ThermalState(processInfo: ProcessInfo.processInfo.thermalState)
    }

    public func isLowPowerModeEnabled() -> Bool {
        ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    public func stateChanges() -> AsyncStream<ThermalState> {
        AsyncStream { continuation in
            let box = ObserverBox()
            box.token = NotificationCenter.default.addObserver(
                forName: ProcessInfo.thermalStateDidChangeNotification,
                object: nil,
                queue: nil
            ) { _ in
                continuation.yield(ThermalState(processInfo: ProcessInfo.processInfo.thermalState))
            }
            continuation.onTermination = { _ in
                box.removeIfNeeded()
            }
        }
    }

    public func darkWakeEmergencies() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let watcher = RootDomainWatcher(continuation: continuation)
            continuation.onTermination = { _ in watcher.stop() }
            watcher.start()
        }
    }
}

/// Holds the notification token across the `@Sendable` termination closure — `NSObjectProtocol`
/// itself isn't `Sendable`, but the box that owns it, and only ever touches it, can be.
private final class ObserverBox: @unchecked Sendable {
    var token: NSObjectProtocol?

    func removeIfNeeded() {
        if let token { NotificationCenter.default.removeObserver(token) }
    }
}

private extension ThermalState {
    init(processInfo state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .nominal
        }
    }
}

/// Holds the IOKit plumbing for `kIOPMMessageDarkWakeThermalEmergency`, delivered to any
/// interest notification observer on `IOPMrootDomain` — public API, no entitlement needed.
private final class RootDomainWatcher: @unchecked Sendable {
    private let continuation: AsyncStream<Void>.Continuation
    private var port: IONotificationPortRef?
    private var notifier: io_object_t = 0

    init(continuation: AsyncStream<Void>.Continuation) {
        self.continuation = continuation
    }

    func start() {
        let rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard rootDomain != 0 else { return }
        defer { IOObjectRelease(rootDomain) }

        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
        self.port = port

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOServiceAddInterestNotification(
            port, rootDomain, kIOGeneralInterest,
            { refcon, _, messageType, _ in
                // kIOPMMessageDarkWakeThermalEmergency (IOPM.h) — the macro itself isn't
                // importable into Swift ("structure not supported"), so its value is
                // reproduced here from its definition: iokit_family_msg(sub_iokit_powermanagement, 0x160).
                guard messageType == 0xE003_4160 else { return }
                Unmanaged<RootDomainWatcher>.fromOpaque(refcon!)
                    .takeUnretainedValue()
                    .fire()
            },
            context, &notifier
        )
    }

    func stop() {
        if notifier != 0 { IOObjectRelease(notifier); notifier = 0 }
        if let port { IONotificationPortDestroy(port) }
        port = nil
        continuation.finish()
    }

    fileprivate func fire() {
        continuation.yield(())
    }
}
