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

    /// What a composite device's interfaces turned out to be, remembered by vendor,
    /// product and port location, for departure to read back.
    ///
    /// A device whose own class names nothing depends on its interfaces to say what kind
    /// it is — a USB audio interface most often, reporting `0x00` at the device level and
    /// its real class only on a child. Those children are gone by the time the departure
    /// notification fires (confirmed live: empty, not just slow), so a departing device
    /// this ambiguous would otherwise resolve to no kind at all, fall outside
    /// `kindsCoveredElsewhere` regardless of what it is set to, and always raise USB
    /// Monitor's own generic notice — reported live as exactly that: Audio's "Notify for
    /// USB devices independently of USB Monitor" switch doing nothing, because the
    /// redundant generic disconnect notice was never the switch's to suppress in the
    /// first place, whichever way it was set. Filled in when the arrival side resolves
    /// the same identity, by whichever path — immediately, or after the async retry.
    private var resolvedInterfaceClasses: [String: [UInt8]] = [:]

    init(continuation: AsyncStream<USBDeviceChange>.Continuation) {
        self.continuation = continuation
    }

    /// A device's physical identity, stable across the registry-entry replacement a
    /// composite device goes through while it is enumerated and across the gap between
    /// its arrival and its eventual departure. Nil when any part is missing — nothing
    /// safe to key a cache on.
    private static func identity(vendorID: UInt16?, productID: UInt16?, locationID: UInt32?) -> String? {
        guard let vendorID, let productID, let locationID else { return nil }
        return "\(vendorID):\(productID):\(locationID)"
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

            // A composite device's interfaces are not children of it yet at the instant
            // this notification fires — confirmed live: still empty a full 5 seconds
            // later, on this same registry entry. They exist within milliseconds, but by
            // the time they do, IOKit has quietly replaced this entry with a new one for
            // the same physical device, so waiting and asking `service` again never
            // helps. Re-finding the device by what does not change across that
            // replacement — its vendor, product and port — and asking a period of *those*
            // instead is what `enrichedInterfaceClasses` does; the delay this adds is
            // paid only by a device this ambiguous, never by an ordinary one.

            let key = Self.identity(
                vendorID: device.detail.vendorID,
                productID: device.detail.productID,
                locationID: device.detail.locationID
            )

            guard arriving else {
                // The departure side of the same ambiguity `isAmbiguous` guards against
                // on arrival, except there is no fresh registry entry left to re-query by
                // the time it fires — the device is on its way out. What arrival already
                // worked out for this same physical identity is the only place left to
                // ask, so a still-ambiguous read is enriched from that cache instead of
                // being yielded as the no-kind-at-all device it would otherwise resolve
                // to — and with it gone, silently and needlessly outliving the device.
                if Self.isAmbiguous(device), let key, let cached = resolvedInterfaceClasses.removeValue(forKey: key), !cached.isEmpty {
                    continuation.yield(.detached(USBDevice(
                        name: device.name,
                        vendorName: device.vendorName,
                        isHub: device.isHub,
                        deviceClass: device.deviceClass,
                        interfaceClasses: cached,
                        detail: device.detail
                    )))
                } else {
                    if let key { resolvedInterfaceClasses.removeValue(forKey: key) }
                    continuation.yield(.detached(device))
                }
                continue
            }

            guard Self.isAmbiguous(device) else {
                if let key, !device.interfaceClasses.isEmpty {
                    resolvedInterfaceClasses[key] = device.interfaceClasses
                }
                continuation.yield(.attached(device))
                continue
            }

            let vendorID = device.detail.vendorID
            let productID = device.detail.productID
            let locationID = device.detail.locationID
            let continuation = self.continuation
            let queue = self.queue

            Task.detached {
                let classes = await Self.enrichedInterfaceClasses(
                    vendorID: vendorID, productID: productID, locationID: locationID
                )
                let enriched = classes.isEmpty ? device : USBDevice(
                    name: device.name,
                    vendorName: device.vendorName,
                    isHub: device.isHub,
                    deviceClass: device.deviceClass,
                    interfaceClasses: classes,
                    detail: device.detail
                )
                if let key, !classes.isEmpty {
                    // Written back on `queue`, the only place this dictionary is ever
                    // touched, so this and every `drain` call stay serialized against it
                    // without a lock of their own.
                    queue.async { [weak self] in self?.resolvedInterfaceClasses[key] = classes }
                }
                continuation.yield(.attached(enriched))
            }
        }
    }

    /// Whether a device's own class names nothing — `0x00`, meaning "ask the
    /// interfaces", or `0xEF`, the standard marker for a composite device that does the
    /// same for a different reason — and its interfaces, read at the same moment, agree.
    /// Only this shape is worth the retry below; a device with an ordinary class, or one
    /// that already answered from its interfaces on the first read, is yielded exactly as
    /// it always was.
    private static func isAmbiguous(_ device: USBDevice) -> Bool {
        (device.deviceClass == nil || device.deviceClass == 0x00 || device.deviceClass == 0xEF)
            && device.interfaceClasses.isEmpty
    }

    /// Polls for the same physical device's interfaces under a fresh registry entry, since
    /// the one this device was first read from will not grow them no matter how long it is
    /// asked. Identified by vendor, product and port location — not by name or serial,
    /// which are not always present — because those three survive the entry being
    /// replaced when everything else about a freshly published device might not yet.
    ///
    /// Bounded at 400ms, in roughly ten tries: measured live, the interfaces are visible
    /// within about 10ms of the device finishing driver matching, so this is a wide
    /// margin, not a tuned minimum. A device that still cannot be found or still answers
    /// nothing by the deadline is left exactly as ambiguous as it always would have been —
    /// this can only improve on today's classification, never make it worse.
    private static func enrichedInterfaceClasses(
        vendorID: UInt16?,
        productID: UInt16?,
        locationID: UInt32?
    ) async -> [UInt8] {
        guard vendorID != nil || productID != nil || locationID != nil else { return [] }

        for _ in 0..<10 {
            if let found = matchingInterfaceClasses(vendorID: vendorID, productID: productID, locationID: locationID),
               !found.isEmpty {
                return found
            }
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        return []
    }

    /// A fresh, one-shot scan of every currently published device of this class, for the
    /// one matching the identity given — deliberately not the `io_service_t` this device
    /// was first read from, which is exactly what has gone stale by the time this runs.
    private static func matchingInterfaceClasses(
        vendorID: UInt16?,
        productID: UInt16?,
        locationID: UInt32?
    ) -> [UInt8]? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(Self.deviceClass), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        while case let candidate = IOIteratorNext(iterator), candidate != 0 {
            defer { IOObjectRelease(candidate) }
            let candidateVendor = number(candidate, "idVendor").map(UInt16.init(truncatingIfNeeded:))
            let candidateProduct = number(candidate, "idProduct").map(UInt16.init(truncatingIfNeeded:))
            let candidateLocation = number(candidate, "locationID").map(UInt32.init(truncatingIfNeeded:))
            guard candidateVendor == vendorID, candidateProduct == productID, candidateLocation == locationID else { continue }
            return Self.interfaceClasses(candidate)
        }
        return nil
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
            interfaceClasses: Self.interfaceClasses(service),
            detail: Self.detail(service)
        )
    }

    /// Every interface's own `bInterfaceClass`, for the composite device whose device
    /// class names nothing — see `USBDevice.interfaceClasses`.
    ///
    /// Interfaces appear in the registry as `IOUSBHostInterface` children of the device,
    /// one level down; the recursion this shares with `storageMedium` goes no further
    /// than that in practice; the depth limit is only ever a backstop against a
    /// malformed tree, the same reason it exists there.
    private static func interfaceClasses(_ service: io_service_t) -> [UInt8] {
        var found: [UInt8] = []
        var iterator: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(
            service, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator
        ) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var depth = 0
        while case let child = IOIteratorNext(iterator), child != 0, depth < 64 {
            defer { IOObjectRelease(child); depth += 1 }
            if let interfaceClass = byte(child, "bInterfaceClass") {
                found.append(interfaceClass)
            }
        }
        return found
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
