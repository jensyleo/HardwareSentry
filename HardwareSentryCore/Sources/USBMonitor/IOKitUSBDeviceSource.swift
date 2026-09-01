import Foundation
import IOKit
import IOKit.usb

/// Watches the system for USB devices arriving and leaving.
///
/// Deliberately thin, and untested for the same reason the notification service's own
/// adapter is: none of it can run without real hardware events. Everything worth
/// reasoning about lives in `USBMonitor`, behind `USBDeviceSource`.
public struct IOKitUSBDeviceSource: USBDeviceSource {
    public init() {}

    public func changes() -> AsyncStream<USBDeviceChange> {
        AsyncStream { continuation in
            let watcher = RegistryWatcher(continuation: continuation)
            continuation.onTermination = { _ in watcher.stop() }
            watcher.start()
        }
    }
}

/// Holds the IOKit plumbing: a notification port, an iterator for arrivals and another
/// for departures.
private final class RegistryWatcher: @unchecked Sendable {
    private let continuation: AsyncStream<USBDeviceChange>.Continuation
    private let queue = DispatchQueue(label: "com.jensyleo.hardwaresentry.usb")
    private var port: IONotificationPortRef?
    private var arrivals: io_iterator_t = 0
    private var departures: io_iterator_t = 0

    init(continuation: AsyncStream<USBDeviceChange>.Continuation) {
        self.continuation = continuation
    }

    func start() {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        IONotificationPortSetDispatchQueue(port, queue)
        self.port = port

        let context = Unmanaged.passUnretained(self).toOpaque()

        // A matching dictionary is consumed by each registration, so each one gets its own.
        IOServiceAddMatchingNotification(
            port, kIOMatchedNotification, IOServiceMatching(Self.deviceClass),
            { context, iterator in
                Unmanaged<RegistryWatcher>.fromOpaque(context!)
                    .takeUnretainedValue()
                    .drain(iterator, arriving: true)
            },
            context, &arrivals
        )

        IOServiceAddMatchingNotification(
            port, kIOTerminatedNotification, IOServiceMatching(Self.deviceClass),
            { context, iterator in
                Unmanaged<RegistryWatcher>.fromOpaque(context!)
                    .takeUnretainedValue()
                    .drain(iterator, arriving: false)
            },
            context, &departures
        )

        // Draining once is what arms each notification. It also delivers everything
        // already plugged in, which is what a startup sweep is made of.
        drain(arrivals, arriving: true)
        drain(departures, arriving: false)
    }

    func stop() {
        if arrivals != 0 { IOObjectRelease(arrivals); arrivals = 0 }
        if departures != 0 { IOObjectRelease(departures); departures = 0 }
        if let port { IONotificationPortDestroy(port) }
        port = nil
        continuation.finish()
    }

    private func drain(_ iterator: io_iterator_t, arriving: Bool) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let device = Self.read(service) else { continue }
            continuation.yield(arriving ? .attached(device) : .detached(device))
        }
    }

    private static func read(_ service: io_service_t) -> USBDevice? {
        guard let name = string(service, "USB Product Name")
            ?? string(service, kUSBProductString)
            ?? registryName(service)
        else { return nil }

        return USBDevice(
            name: name,
            vendorName: string(service, "USB Vendor Name") ?? string(service, kUSBVendorString),
            isHub: IOObjectConformsTo(service, "IOUSBHostHubDevice") != 0,
            deviceClass: byte(service, "bDeviceClass")
        )
    }

    private static func byte(_ service: io_service_t, _ key: String) -> UInt8? {
        guard let number = IORegistryEntryCreateCFProperty(
            service, key as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? NSNumber else { return nil }
        return UInt8(truncatingIfNeeded: number.intValue)
    }

    private static func string(_ service: io_service_t, _ key: String) -> String? {
        guard let value = IORegistryEntryCreateCFProperty(
            service, key as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func registryName(_ service: io_service_t) -> String? {
        var name = [CChar](repeating: 0, count: 128) // io_name_t
        guard IORegistryEntryGetName(service, &name) == KERN_SUCCESS else { return nil }

        let bytes = name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let value = String(decoding: bytes, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Modern macOS enumerates USB devices under the host family; the older class name
    /// no longer matches on Apple silicon.
    private static let deviceClass = "IOUSBHostDevice"
}
