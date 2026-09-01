import Foundation
import IOKit

/// Watches the system for Thunderbolt/PCI devices arriving and leaving.
///
/// Deliberately thin and untested, for the same reason `IOKitUSBDeviceSource` is: none of
/// it can run without real hardware events. Everything worth reasoning about lives in
/// `ThunderboltMonitor`, behind `ThunderboltDeviceSource`.
public struct IOKitThunderboltDeviceSource: ThunderboltDeviceSource {
    public init() {}

    public func changes() -> AsyncStream<ThunderboltDeviceChange> {
        AsyncStream { continuation in
            let watcher = RegistryWatcher(continuation: continuation)
            continuation.onTermination = { _ in watcher.stop() }
            watcher.start()
        }
    }
}

private final class RegistryWatcher: @unchecked Sendable {
    private let continuation: AsyncStream<ThunderboltDeviceChange>.Continuation
    private var port: IONotificationPortRef?
    private var arrivals: io_iterator_t = 0
    private var departures: io_iterator_t = 0
    /// Ignores the launch enumeration — notifying for every pre-existing `IOPCIDevice`
    /// would spam dozens of internal devices the moment watching begins.
    private var primed = false

    init(continuation: AsyncStream<ThunderboltDeviceChange>.Continuation) {
        self.continuation = continuation
    }

    func start() {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
        self.port = port

        let context = Unmanaged.passUnretained(self).toOpaque()

        IOServiceAddMatchingNotification(
            port, kIOPublishNotification, IOServiceMatching("IOPCIDevice"),
            { context, iterator in
                Unmanaged<RegistryWatcher>.fromOpaque(context!)
                    .takeUnretainedValue()
                    .drainArrivals(iterator)
            },
            context, &arrivals
        )
        // Draining once arms the notification and also delivers the launch enumeration,
        // which is discarded below since `primed` is still false at this point.
        drainArrivals(arrivals)

        IOServiceAddMatchingNotification(
            port, kIOTerminatedNotification, IOServiceMatching("IOPCIDevice"),
            { context, iterator in
                Unmanaged<RegistryWatcher>.fromOpaque(context!)
                    .takeUnretainedValue()
                    .drainDepartures(iterator)
            },
            context, &departures
        )
        drainDepartures(departures)

        primed = true
    }

    func stop() {
        if arrivals != 0 { IOObjectRelease(arrivals); arrivals = 0 }
        if departures != 0 { IOObjectRelease(departures); departures = 0 }
        if let port { IONotificationPortDestroy(port) }
        port = nil
        continuation.finish()
    }

    private func drainArrivals(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard primed, let device = Self.read(service) else { continue }
            continuation.yield(.attached(device))
        }
    }

    private func drainDepartures(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard primed, let name = Self.name(service) else { continue }
            continuation.yield(.detached(name: name))
        }
    }

    private static func read(_ service: io_service_t) -> ThunderboltDevice? {
        guard let name = name(service) else { return nil }
        return ThunderboltDevice(
            name: name,
            baseClass: baseClass(service),
            vendorID: identifier(service, "vendor-id"),
            deviceID: identifier(service, "device-id")
        )
    }

    /// "vendor-id"/"device-id" come back as two little-endian bytes on some devices and as
    /// a plain number on others — the same two shapes "class-code" arrives in.
    private static func identifier(_ service: io_service_t, _ key: String) -> UInt16? {
        guard let value = IORegistryEntryCreateCFProperty(
            service, key as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() else { return nil }

        if CFGetTypeID(value) == CFDataGetTypeID(), let data = value as? Data, data.count >= 2 {
            return UInt16(data[0]) | (UInt16(data[1]) << 8)
        }
        if CFGetTypeID(value) == CFNumberGetTypeID(), let number = value as? NSNumber {
            return UInt16(truncatingIfNeeded: number.intValue)
        }
        return nil
    }

    private static func name(_ service: io_service_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 128) // io_name_t
        guard IORegistryEntryGetName(service, &buffer) == KERN_SUCCESS else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let value = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// The PCI-SIG base class is the top byte of the registry's 3-byte "class-code"
    /// property, which macOS hands back as either `CFData` or a `CFNumber` depending on
    /// the device — both forms are read the same way `USBMonitor` reads string properties.
    private static func baseClass(_ service: io_service_t) -> UInt8? {
        guard let value = IORegistryEntryCreateCFProperty(
            service, "class-code" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() else { return nil }

        var classCode: UInt32 = 0
        if CFGetTypeID(value) == CFDataGetTypeID(), let data = value as? Data, data.count >= 3 {
            classCode = UInt32(data[0]) | (UInt32(data[1]) << 8) | (UInt32(data[2]) << 16)
        } else if CFGetTypeID(value) == CFNumberGetTypeID(), let number = value as? NSNumber {
            classCode = number.uint32Value
        } else {
            return nil
        }
        return UInt8((classCode >> 16) & 0xFF)
    }
}
