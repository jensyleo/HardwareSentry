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

    /// The Mac's own USB controllers report themselves under names from the driver, not
    /// names for people: "XHCI Root Hub SS Simulation" is the USB 3 bus. Renamed here so
    /// a notification about the machine's own hardware reads like one.
    static func friendlyBusName(_ name: String) -> String {
        switch name {
        case "OHCI Root Hub Simulation", "UHCI Root Hub Simulation":
            return "USB Bus"
        case "EHCI Root Hub Simulation", "XHCI Root Hub USB 2.0 Simulation":
            return "USB 2.0 Bus"
        case "XHCI Root Hub SS Simulation":
            return "USB 3.0 Bus"
        default:
            return name
        }
    }


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

        // `kIOFirstPublishNotification`, not `kIOMatchedNotification`: reported live as
        // HardwareSentry taking over a second longer than HG4MAC to say anything about a
        // hub that was just plugged in. `kIOMatchedNotification` waits for the whole
        // driver-matching process to finish — probing, selecting a driver, starting it —
        // which for a hub, coordinating downstream port power, is real, measurable time.
        // `kIOFirstPublishNotification` fires the moment the object first appears in the
        // registry, already after USB enumeration has read the device descriptor, so the
        // name/vendor/class/VID:PID properties read below are unaffected. HG4MAC uses this
        // exact notification for exactly this reason.
        //
        // The one honest trade: `USBDeviceRequiredCurrent`/`AvailableCurrent` are set by
        // the host driver as it negotiates power, a step `kIOFirstPublishNotification`
        // fires ahead of — HG4MAC does not read these at all, so there is no prior
        // behaviour to compare against. If they are not there yet, `detail(_:)` below
        // already leaves the "Power" line out rather than showing a wrong number; the
        // trade is a "Power" line that occasionally does not appear on the very first
        // announcement, against a delay of over a second on every one.
        //
        // A matching dictionary is consumed by each registration, so each one gets its own.
        IOServiceAddMatchingNotification(
            port, kIOFirstPublishNotification, IOServiceMatching(Self.deviceClass),
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
            name: IOKitUSBDeviceSource.friendlyBusName(name),
            vendorName: string(service, "USB Vendor Name") ?? string(service, kUSBVendorString),
            isHub: IOObjectConformsTo(service, "IOUSBHostHubDevice") != 0,
            deviceClass: byte(service, "bDeviceClass"),
            detail: Self.detail(service)
        )
    }

    /// Everything else the registry entry will answer.
    ///
    /// Every read is best-effort. Most USB devices answer a handful of these and nothing
    /// else, and a line that cannot be filled is left out rather than guessed at.
    private static func detail(_ service: io_service_t) -> USBDeviceDetail {
        let required = number(service, "USBDeviceRequiredCurrent") ?? number(service, "MaxPowerRequired")
        let available = number(service, "USBDeviceAvailableCurrent")

        // A hub can never itself be a storage medium, and it is exactly the device this
        // walk used to run for on every hub arrival — reported live as part of why
        // connecting one took over a second: `storageMedium` recurses the whole registry
        // subtree below the device, and a hub's subtree is its downstream devices, which
        // during the very burst being reported are still busy enumerating. Skipped by a
        // class-conformance check, which is a fast C++ check with no registry IPC of its
        // own, rather than a registry property read.
        let isHub = IOObjectConformsTo(service, "IOUSBHostHubDevice") != 0

        return USBDeviceDetail(
            productName: string(service, "USB Product Name") ?? string(service, kUSBProductString),
            vendorID: number(service, "idVendor").map(UInt16.init(truncatingIfNeeded:)),
            productID: number(service, "idProduct").map(UInt16.init(truncatingIfNeeded:)),
            speedCode: byte(service, "Device Speed"),
            requiredCurrent: required,
            availableCurrent: available,
            // The port answering with less than was asked for is the refusal itself; the
            // registry has no separate "denied" flag.
            requestedMoreThanAvailable: (required ?? 0) > (available ?? Int.max),
            mediumType: isHub ? nil : Self.storageMedium(service),
            serialNumber: string(service, "USB Serial Number") ?? string(service, kUSBSerialNumberString),
            releaseVersion: number(service, "bcdDevice").map(UInt16.init(truncatingIfNeeded:)),
            locationID: number(service, "locationID").map(UInt32.init(truncatingIfNeeded:)),
            configurationCount: number(service, "bNumConfigurations"),
            specVersion: number(service, "bcdUSB").map(UInt16.init(truncatingIfNeeded:)),
            isTunnelled: boolean(service, "IOUSBHostControllerIsTunnelled")
                ?? boolean(service, "Tunnelled") ?? false,
            // Unlike `mediumType` above, this one can genuinely apply to a hub — a hub
            // has a port too, and can be removable or built-in same as anything else. The
            // "Port info" checkbox in Settings → USB is what decides whether this line
            // shows; that promise has to hold for every device the checkbox covers,
            // hub included, so this is read unconditionally rather than skipped for
            // hubs the way the storage-medium walk is.
            isPortRemovable: Self.portProperty(service, "removable"),
            connectorType: Self.connectorType(service)
        )
    }

    private static func storageMedium(_ service: io_service_t) -> String? {
        // The medium is a property of the disk, which hangs several levels below the USB
        // device — an enclosure, then a mass-storage driver, then the disk itself. Six
        // levels is deeper than any real enclosure nests, and stops the walk being
        // unbounded on a malformed tree.
        var found: String?
        var iterator: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(
            service, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator
        ) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var depth = 0
        while case let child = IOIteratorNext(iterator), child != 0, depth < 64 {
            defer { IOObjectRelease(child); depth += 1 }
            if let medium = IORegistryEntryCreateCFProperty(
                child, "Device Characteristics" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? [String: Any],
               let type = medium["Medium Type"] as? String {
                found = type
                break
            }
        }
        return found
    }

    /// A property that lives on the *port* rather than on the device, so the walk goes up.
    ///
    /// Four levels: device, port, hub, controller. Anything further up is not this
    /// device's port any more.
    private static func portProperty(_ service: io_service_t, _ key: String) -> Bool? {
        var current = service
        IOObjectRetain(current)
        defer { IOObjectRelease(current) }

        for _ in 0..<4 {
            if let value = IORegistryEntryCreateCFProperty(current, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSNumber {
                return value.boolValue
            }
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS else { return nil }
            IOObjectRelease(current)
            current = parent
        }
        return nil
    }

    private static func connectorType(_ service: io_service_t) -> Int? {
        var current = service
        IOObjectRetain(current)
        defer { IOObjectRelease(current) }

        for _ in 0..<4 {
            if let value = IORegistryEntryCreateCFProperty(current, "UsbConnector" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSNumber {
                return value.intValue
            }
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS else { return nil }
            IOObjectRelease(current)
            current = parent
        }
        return nil
    }

    private static func number(_ service: io_service_t, _ key: String) -> Int? {
        (IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber)?.intValue
    }

    private static func boolean(_ service: io_service_t, _ key: String) -> Bool? {
        (IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber)?.boolValue
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
