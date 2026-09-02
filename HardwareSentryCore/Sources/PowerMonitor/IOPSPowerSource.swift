import AppKit
import Foundation
import IOKit.ps

/// Watches `IOPowerSources` for power source changes, `NSWorkspace` for system/display
/// sleep and wake, and `NSProcessInfo` for Low Power Mode.
///
/// Deliberately thin and untested, for the same reason `IOKitUSBDeviceSource` is: none of
/// it can run without a real power event. Everything worth reasoning about lives in
/// `PowerMonitor`, behind `PowerSource`.
public struct IOPSPowerSource: PowerSource {
    public init() {}

    public func changes() -> AsyncStream<PowerSourceEvent> {
        AsyncStream { continuation in
            let watcher = Watcher(continuation: continuation)
            continuation.onTermination = { _ in watcher.stop() }
            watcher.start()
        }
    }
}

private final class Watcher: @unchecked Sendable {
    private let continuation: AsyncStream<PowerSourceEvent>.Continuation
    private var runLoopSource: CFRunLoopSource?
    private var tokens: [NSObjectProtocol] = []

    init(continuation: AsyncStream<PowerSourceEvent>.Continuation) {
        self.continuation = continuation
    }

    func start() {
        emitSnapshot()
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<Watcher>.fromOpaque(context).takeUnretainedValue().emitSnapshot()
        }, context)?.takeRetainedValue() {
            runLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }

        let center = NSWorkspace.shared.notificationCenter
        tokens.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { [weak self] _ in
            self?.continuation.yield(.systemWillSleep)
        })
        tokens.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.continuation.yield(.systemDidWake)
        })
        tokens.append(center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: nil) { [weak self] _ in
            self?.continuation.yield(.screensDidSleep)
        })
        tokens.append(center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.continuation.yield(.screensDidWake)
        })

        continuation.yield(.lowPowerModeChanged(ProcessInfo.processInfo.isLowPowerModeEnabled))
        tokens.append(NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: nil) { [weak self] _ in
            self?.continuation.yield(.lowPowerModeChanged(ProcessInfo.processInfo.isLowPowerModeEnabled))
        })
    }

    func stop() {
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .defaultMode) }
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let defaultCenter = NotificationCenter.default
        tokens.forEach { token in
            workspaceCenter.removeObserver(token)
            defaultCenter.removeObserver(token)
        }
        continuation.finish()
    }

    fileprivate func emitSnapshot() {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return }

        let providingType = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String?
        let kind: PowerSourceKind
        switch providingType {
        case "AC Power": kind = .ac
        case "Battery Power": kind = .battery
        case "UPS Power": kind = .ups
        default: kind = .unknown
        }

        var percentage: Int?
        if let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] {
            for entry in list {
                guard let description = IOPSGetPowerSourceDescription(blob, entry)?.takeUnretainedValue() as? [String: AnyObject] else { continue }
                // A source that is not physically there reports stale numbers; asking it
                // for a charge level gives an answer about nothing.
                guard description[kIOPSIsPresentKey as String] as? Bool == true else { continue }
                // Worked out as a fraction of the source's own maximum rather than read
                // straight from CurrentCapacity: the internal battery happens to report a
                // max of 100, so the raw value looks like a percentage — but a UPS reports
                // milliamp-hours, and the raw value there is a four-digit number that
                // would be shown as a charge level of "4200%".
                guard let current = description[kIOPSCurrentCapacityKey as String] as? Double,
                      let maximum = description[kIOPSMaxCapacityKey as String] as? Double,
                      maximum > 0
                else { continue }
                percentage = max(percentage ?? 0, Int((current / maximum * 100).rounded()))
            }
        }

        let warningLevel = IOPSGetBatteryWarningLevel()
        let isLowWarning = warningLevel != kIOPSLowBatteryWarningNone

        continuation.yield(.snapshot(PowerSnapshot(kind: kind, percentage: percentage, isLowBatteryWarning: isLowWarning)))
    }
}
