import DiskArbitration
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
    /// Insertion order for `resolvedInterfaceClasses`, so an entry whose departure is
    /// missed — the Mac slept through the unplug, or a hub re-enumerated without one —
    /// does not sit there forever. Bounded rather than unbounded: a real desk does not
    /// carry hundreds of composite devices through one process's lifetime, but a Mac left
    /// running for weeks should not grow this without limit either.
    private var resolvedInterfaceClassesOrder: [String] = []
    private static let maxResolvedInterfaceClasses = 256

    /// The still-polling ambiguous-device enrichment tasks, so `stop()` can cancel them
    /// instead of leaving them to keep hitting IOKit for up to 400ms after the watcher —
    /// and the stream it feeds — is already gone.
    private var pendingEnrichments: [UUID: Task<Void, Never>] = [:]

    init(continuation: AsyncStream<USBDeviceChange>.Continuation) {
        self.continuation = continuation
    }

    /// Remembers a device's interfaces under its identity, evicting the oldest entry once
    /// the cache is full rather than growing it forever.
    private func rememberInterfaceClasses(_ classes: [UInt8], for key: String) {
        if resolvedInterfaceClasses.updateValue(classes, forKey: key) == nil {
            resolvedInterfaceClassesOrder.append(key)
        }
        while resolvedInterfaceClassesOrder.count > Self.maxResolvedInterfaceClasses {
            let oldest = resolvedInterfaceClassesOrder.removeFirst()
            resolvedInterfaceClasses.removeValue(forKey: oldest)
        }
    }

    private func forgetInterfaceClasses(for key: String) -> [UInt8]? {
        resolvedInterfaceClassesOrder.removeAll { $0 == key }
        return resolvedInterfaceClasses.removeValue(forKey: key)
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
        for (_, task) in pendingEnrichments { task.cancel() }
        pendingEnrichments.removeAll()
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
                if Self.isAmbiguous(device), let key, let cached = forgetInterfaceClasses(for: key), !cached.isEmpty {
                    continuation.yield(.detached(USBDevice(
                        name: device.name,
                        vendorName: device.vendorName,
                        isHub: device.isHub,
                        deviceClass: device.deviceClass,
                        interfaceClasses: cached,
                        detail: device.detail
                    )))
                } else {
                    if let key { _ = forgetInterfaceClasses(for: key) }
                    continuation.yield(.detached(device))
                }
                continue
            }

            guard Self.isAmbiguous(device) else {
                if let key, !device.interfaceClasses.isEmpty {
                    rememberInterfaceClasses(device.interfaceClasses, for: key)
                }

                // Reported live, 2026-09-06: an external HDD enclosure that declares
                // Mass Storage on an *interface* (device class `0x00`, same as the
                // composite devices above) already has that interface visible at the
                // very first read — `isAmbiguous` is false, so this is the branch it
                // takes — but its own disk (the SCSI translation layer, then the
                // block-storage driver, then the BSD name) is still attaching
                // underneath. Retried by identity, the same way the composite-device
                // branch below retries interfaces: this device's own registry entry can
                // be replaced during the same driver-matching dance a composite device's
                // is, confirmed live once already for interfaces — a same-handle retry,
                // tried first, was reported unchanged, because it stayed a stale handle
                // through the wait rather than a live one.
                if Self.isUnresolvedMassStorage(device) {
                    let vendorID = device.detail.vendorID
                    let productID = device.detail.productID
                    let locationID = device.detail.locationID
                    let continuation = self.continuation
                    let queue = self.queue
                    let taskID = UUID()

                    let task = Task.detached { [weak self] in
                        let hint = await Self.enrichedMassStorageHint(
                            vendorID: vendorID, productID: productID, locationID: locationID
                        )
                        guard !Task.isCancelled else { return }
                        let enriched = hint == nil ? device : USBDevice(
                            name: device.name,
                            vendorName: device.vendorName,
                            isHub: device.isHub,
                            deviceClass: device.deviceClass,
                            interfaceClasses: device.interfaceClasses,
                            detail: device.detail.withMassStorageHint(hint)
                        )
                        continuation.yield(.attached(enriched))
                        queue.async { [weak self] in self?.pendingEnrichments.removeValue(forKey: taskID) }
                    }
                    pendingEnrichments[taskID] = task
                    continue
                }

                continuation.yield(.attached(device))
                continue
            }

            let vendorID = device.detail.vendorID
            let productID = device.detail.productID
            let locationID = device.detail.locationID
            let continuation = self.continuation
            let queue = self.queue
            let taskID = UUID()

            let task = Task.detached { [weak self] in
                let classes = await Self.enrichedInterfaceClasses(
                    vendorID: vendorID, productID: productID, locationID: locationID
                )
                // The watcher may have been stopped while this was polling — nothing left
                // to write back to or yield into.
                guard !Task.isCancelled else { return }
                var enriched = classes.isEmpty ? device : USBDevice(
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
                    queue.async { [weak self] in self?.rememberInterfaceClasses(classes, for: key) }
                }
                // A device this ambiguous at the device level can resolve, once its
                // interfaces arrive, to a Mass Storage device whose own disk is still
                // attaching too — the same wait `isUnresolvedMassStorage` guards against
                // on an otherwise-ordinary device, chained on here rather than yielding
                // once now and again later for what is still one arrival.
                if Self.isUnresolvedMassStorage(enriched) {
                    let hint = await Self.enrichedMassStorageHint(
                        vendorID: vendorID, productID: productID, locationID: locationID
                    )
                    if let hint {
                        enriched = USBDevice(
                            name: enriched.name,
                            vendorName: enriched.vendorName,
                            isHub: enriched.isHub,
                            deviceClass: enriched.deviceClass,
                            interfaceClasses: enriched.interfaceClasses,
                            detail: enriched.detail.withMassStorageHint(hint)
                        )
                    }
                }
                continuation.yield(.attached(enriched))
                queue.async { [weak self] in self?.pendingEnrichments.removeValue(forKey: taskID) }
            }
            pendingEnrichments[taskID] = task
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

    /// A Mass Storage device whose disk the heuristic could not yet say anything about —
    /// worth a retry, since "nothing yet" and "never will" look identical from a single
    /// read and only time tells them apart.
    ///
    /// Reads `device.kind` — the *resolved* class — rather than the raw `deviceClass`
    /// byte. Reported live, 2026-09-06: a real external HDD enclosure declares `0x00` at
    /// the device level and Mass Storage only on an interface underneath (`bInterfaceClass
    /// 0x08`), the same composite shape a webcam or an audio device uses; comparing the
    /// raw byte directly, as an earlier version of this check did, never matched it, and
    /// the retry this whole function exists for silently never ran.
    private static func isUnresolvedMassStorage(_ device: USBDevice) -> Bool {
        device.kind == .massStorage
    }

    /// Polls for the same physical device's disk description under a fresh registry
    /// entry each time, exactly the reasoning `enrichedInterfaceClasses` already rests
    /// on: a same-handle version of this retry was tried first and reported live as
    /// still not working, which is itself the confirmation that this device's own entry
    /// goes stale during the same driver-matching dance a composite device's does — not
    /// only a plain composite device's, as first assumed.
    ///
    /// Bounded at 20 tries, 50ms apart (1s total) — generously wider than
    /// `enrichedInterfaceClasses`'s 400ms, since a disk's BSD name has a deeper stack to
    /// wait on (SCSI translation, then block storage, then the partition scheme) than an
    /// interface descriptor does. A device that still answers nothing by the deadline is
    /// left exactly as generic as it always would have been.
    private static func enrichedMassStorageHint(
        vendorID: UInt16?,
        productID: UInt16?,
        locationID: UInt32?
    ) async -> USBMassStorageHint? {
        guard vendorID != nil || productID != nil || locationID != nil else { return nil }

        for _ in 0..<20 {
            if let hint = matchingMassStorageHint(vendorID: vendorID, productID: productID, locationID: locationID) {
                return hint
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return nil
    }

    /// A fresh, one-shot scan of every currently published device of this class, for the
    /// one matching the identity given, the same re-finding `matchingInterfaceClasses`
    /// does and for the same reason — the entry this device was first read from is
    /// exactly what may have gone stale by the time this runs.
    private static func matchingMassStorageHint(
        vendorID: UInt16?,
        productID: UInt16?,
        locationID: UInt32?
    ) -> USBMassStorageHint? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(Self.deviceClass), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        while case let candidate = IOIteratorNext(iterator), candidate != 0 {
            defer { IOObjectRelease(candidate) }
            let candidateVendor = uint16(candidate, "idVendor")
            let candidateProduct = uint16(candidate, "idProduct")
            let candidateLocation = uint32(candidate, "locationID")
            guard candidateVendor == vendorID, candidateProduct == productID, candidateLocation == locationID else { continue }
            return Self.massStorageHint(candidate)
        }
        return nil
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
            let candidateVendor = uint16(candidate, "idVendor")
            let candidateProduct = uint16(candidate, "idProduct")
            let candidateLocation = uint32(candidate, "locationID")
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
            vendorID: uint16(service, "idVendor"),
            productID: uint16(service, "idProduct"),
            speedCode: byte(service, "Device Speed"),
            requiredCurrent: required,
            availableCurrent: available,
            // The port answering with less than was asked for is the refusal itself; the
            // registry has no separate "denied" flag.
            requestedMoreThanAvailable: (required ?? 0) > (available ?? Int.max),
            mediumType: isHub ? nil : Self.storageMedium(service).medium,
            massStorageHint: isHub ? nil : Self.massStorageHint(service),
            serialNumber: string(service, "USB Serial Number") ?? string(service, kUSBSerialNumberString),
            releaseVersion: uint16(service, "bcdDevice"),
            locationID: uint32(service, "locationID"),
            configurationCount: number(service, "bNumConfigurations"),
            specVersion: uint16(service, "bcdUSB"),
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

    private static func storageMedium(_ service: io_service_t) -> (medium: String?, bsdName: String?) {
        // The medium — and the BSD device name alongside it — are properties of the disk,
        // which hangs several levels below the USB device: an enclosure, then a
        // mass-storage driver, then the disk itself. Six levels is deeper than any real
        // enclosure nests, and stops the walk being unbounded on a malformed tree.
        var medium: String?
        var bsdName: String?
        var iterator: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(
            service, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator
        ) == KERN_SUCCESS else { return (nil, nil) }
        defer { IOObjectRelease(iterator) }

        var depth = 0
        while case let child = IOIteratorNext(iterator), child != 0, depth < 64 {
            defer { IOObjectRelease(child); depth += 1 }
            if medium == nil,
               let characteristics = IORegistryEntryCreateCFProperty(
                   child, "Device Characteristics" as CFString, kCFAllocatorDefault, 0
               )?.takeRetainedValue() as? [String: Any],
               let type = characteristics["Medium Type"] as? String {
                medium = type
            }
            if bsdName == nil,
               let name = IORegistryEntryCreateCFProperty(
                   child, "BSD Name" as CFString, kCFAllocatorDefault, 0
               )?.takeRetainedValue() as? String {
                bsdName = name
            }
            if medium != nil, bsdName != nil { break }
        }
        return (medium, bsdName)
    }

    /// A flash drive, an SD card reader, or an external disk enclosure, told apart from a
    /// plain Mass Storage device by asking Disk Arbitration what it knows about the disk —
    /// the same technique Volume Monitor uses on a mounted volume's path, adapted here to
    /// a bare BSD device name (`DADiskCreateFromBSDName` rather than
    /// `DADiskCreateFromVolumePath`), since a USB disk need not have anything mounted for
    /// this to run.
    ///
    /// Independently reimplemented, not imported — see `USBMassStorageHint`'s own doc
    /// comment for why a monitor cannot reuse another monitor's types.
    private static func massStorageHint(_ service: io_service_t) -> USBMassStorageHint? {
        guard let bsdName = storageMedium(service).bsdName else { return nil }
        guard let session = DASessionCreate(kCFAllocatorDefault) else { return nil }
        guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsdName) else { return nil }
        guard let description = DADiskCopyDescription(disk) as? [String: Any] else { return nil }
        let protocolName = description[kDADiskDescriptionDeviceProtocolKey as String] as? String
        let mediaName = [
            description[kDADiskDescriptionMediaNameKey as String] as? String,
            description[kDADiskDescriptionDeviceModelKey as String] as? String
        ].compactMap { $0 }.joined(separator: " ")
        let sizeBytes = (description[kDADiskDescriptionMediaSizeKey as String] as? NSNumber)?.uint64Value
        return USBMassStorageHint.infer(protocolName: protocolName, mediaName: mediaName, sizeBytes: sizeBytes)
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

    /// Reads a property that is meant to fit in 16 bits and answers nil rather than a
    /// wrapped-around number when it does not — a vendor/product ID this is wrong for is
    /// a device this misidentifies, not a device this merely mislabels: `identity(...)`
    /// keys the composite-device interface cache on exactly these fields, so silently
    /// truncating one could fold two different real devices under the same cache entry.
    private static func uint16(_ service: io_service_t, _ key: String) -> UInt16? {
        guard let value = number(service, key), (0...Int(UInt16.max)).contains(value) else { return nil }
        return UInt16(value)
    }

    /// The 32-bit counterpart of `uint16(_:_:)`, for the same reason.
    private static func uint32(_ service: io_service_t, _ key: String) -> UInt32? {
        guard let value = number(service, key), (0...Int(UInt32.max)).contains(value) else { return nil }
        return UInt32(value)
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
