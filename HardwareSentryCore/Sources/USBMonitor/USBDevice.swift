import Foundation

/// A USB device, as much of one as is worth telling someone about.
public struct USBDevice: Sendable, Equatable {
    public let name: String
    public let vendorName: String?
    public let isHub: Bool
    /// The USB-IF `bDeviceClass` byte. `0x00` means "look at the interfaces instead", and
    /// `0xEF` means the same thing for a different reason — it is the standard marker for
    /// a composite device (an Interface Association Descriptor) rather than a class of
    /// its own. Either way, a device saying one of those has told us nothing on its own.
    public let deviceClass: UInt8?
    /// `bDeviceSubClass`/`bDeviceProtocol`, read only to tell apart the handful of
    /// device classes whose class byte alone is ambiguous — today, only `0xE0`
    /// ("Wireless Controller"), where subclass `0x01`/protocol `0x01` is USB-IF's own
    /// standard signature for "this is specifically a Bluetooth radio" (see
    /// `USBDeviceKind`'s Bluetooth branch). Nil for a device this never mattered for.
    public let deviceSubClass: UInt8?
    public let deviceProtocol: UInt8?
    /// Every interface's own `bInterfaceClass`, read for exactly the case above: a
    /// composite device — a webcam that is also a microphone, most often — names its real
    /// classes here instead. Empty for the ordinary device that already said what it is.
    public let interfaceClasses: [UInt8]

    /// Everything else the device says about itself.
    public let detail: USBDeviceDetail

    public init(
        name: String,
        vendorName: String? = nil,
        isHub: Bool = false,
        deviceClass: UInt8? = nil,
        deviceSubClass: UInt8? = nil,
        deviceProtocol: UInt8? = nil,
        interfaceClasses: [UInt8] = [],
        detail: USBDeviceDetail = USBDeviceDetail()
    ) {
        self.name = name
        self.vendorName = vendorName
        self.isHub = isHub
        self.deviceClass = deviceClass
        self.deviceSubClass = deviceSubClass
        self.deviceProtocol = deviceProtocol
        self.interfaceClasses = interfaceClasses
        self.detail = detail
    }

    /// What this device says it is, or nil when it has not said anything specific.
    ///
    /// Nil is less common than it used to be: a composite device that names nothing at
    /// the device level — the BRIO among them, reported live as showing up generic rather
    /// than as the webcam it is — still gets a kind from its interfaces, tried second. It
    /// stays nil only for a device that names nothing at either level.
    public var kind: USBDeviceKind? {
        if isHub { return .hub }
        // USB-IF's own signature for "this `0xE0` device is specifically a Bluetooth
        // radio" — subclass `0x01`, protocol `0x01` — checked before the generic class
        // resolution below, which would otherwise file every `0xE0` device, Bluetooth or
        // not, under the same plain "Wireless Controller" row. Toggled off, this falls
        // through to that same generic resolution instead, exactly as it did before this
        // distinction existed.
        if deviceClass == 0xE0, deviceSubClass == 0x01, deviceProtocol == 0x01,
           USBWirelessDetectionSettings.shared.detectsBluetoothAdapters {
            return .bluetoothAdapter
        }
        // `0x00` carries the same "look at the interfaces" meaning `0xEF` does, so an
        // absent device class is treated the same way rather than skipping straight to
        // the interfaces without also giving `0x00` itself a chance to (harmlessly) fail.
        let resolved = USBDeviceKind(deviceClass: deviceClass ?? 0x00, interfaceClasses: interfaceClasses)
        // Before any vendor-ID guess: what the device calls itself, when it says outright
        // what sort of network adapter it is. This is the same shape as the card-reader
        // name fallback further down — a narrow read of the product string, used only
        // where nothing better is available — and it exists because of a real failure
        // mode found while auditing, 2026-09-07, against hardware connected at the time.
        //
        // A Realtek "USB 10/100/1000 LAN" adapter reports device class `0x00` ("ask the
        // interfaces") and identifies itself as Ethernet only through its interfaces —
        // Communications/ECM plus CDC Data. Those are normally waited for, so it lands on
        // `.communications` correctly. But that wait is bounded: if it times out, the
        // device arrives with class `0x00` and no interfaces, `resolved` is nil, and the
        // vendor-ID guess below claims it — Realtek being on the WiFi-chip list — and a
        // wired Ethernet adapter gets announced as "WiFi Adapter". Its own name says LAN;
        // that beats guessing from the vendor, so it is read first.
        if resolved == nil, !isMeaningfullyIdentified {
            // Order matters: "WLAN" contains "lan". Wireless is checked first so a WLAN
            // dongle is never read as wired, and both are matched on whole words rather
            // than substrings so neither can be found inside an unrelated one.
            if Self.namesAWirelessAdapter(name) {
                if USBWirelessDetectionSettings.shared.detectsWiFiAdapters { return .wifiAdapter }
            } else if Self.namesAWiredNetworkAdapter(name) {
                return .communications
            }
        }
        // A device the class byte alone says nothing about (`0xFF`/`0xEF`/`0x00` with no
        // recognised interface either) is still often identifiable by who made it: FTDI,
        // Silicon Labs, WCH and the other USB-serial/debug-probe vendors all use their own
        // vendor-specific class, so nothing above ever resolves them. Checked only once the
        // class byte itself has nothing to say, so an actually-classified device is never
        // second-guessed by a vendor that happens to also sell serial chips.
        //
        // `!isMeaningfullyIdentified` is the second half of that guard, not a redundant
        // one: `resolved` only knows the classes `USBDeviceKind` has a row for, so a
        // class `className` can already name — Billboard (`0x11`) chief among them, no
        // row of its own since the Type-C Bridge fix — reads as `resolved == nil` too,
        // even though the device is not remotely unclassified. Reported live, 2026-09-06,
        // right after the `usb.ids` widening: a VIA Labs USB 2.0 BILLBOARD chip, VIA
        // Labs now a "known vendor" via that update, was misread as "Serial/Debug
        // Adapter" — a real, named class losing to a vendor-ID guess it was never meant
        // to be second-guessed by, the exact failure mode this line exists to close.
        if resolved == nil, !isMeaningfullyIdentified, let vendorID = detail.vendorID {
            // Checked before the serial-vendor lookup below, on purpose: once that lookup
            // has been widened by a `usb.ids` update (see `USBSerialVendorDatabase`'s own
            // doc comment), it recognises essentially every real vendor there is,
            // including every one of these — a small, specifically-WiFi-chip list would
            // otherwise never get a turn, since the much broader check would always claim
            // the vendor first. Unlike Bluetooth above, nothing on a WiFi USB dongle's own
            // descriptor says "this is WiFi" — there is no USB-IF class for it — so this
            // is still only a vendor-ID guess, and these vendors sell plenty that is not
            // WiFi too (card readers, GPUs, phones); documented, and why this has its own
            // toggle, separate from Bluetooth's more reliable one.
            if USBWirelessDetectionSettings.shared.detectsWiFiAdapters, USBWiFiVendorDatabase.isKnownVendor(vendorID) {
                return .wifiAdapter
            }
            if USBSerialVendorDatabase.shared.isKnownVendor(vendorID) { return .serialAdapter }
        }
        // HID (`0x03`) is one class for a keyboard, a mouse, a gamepad, a joystick and
        // more — the class byte cannot tell them apart, only the HID Report Descriptor's
        // own Usage Page/Usage can, which is why `detail.hidUsagePage`/`hidUsage` exist at
        // all. Generic Desktop (page `0x01`) usage Joystick (`0x04`), Gamepad (`0x05`) or
        // Multi-axis Controller (`0x08`) is the one refinement made here — reported live,
        // 2026-09-06, against a real generic USB gamepad that macOS's own GameController
        // framework already recognised (`GamepadHIDServiceSupport`), while this module
        // still filed it under the same "Keyboard/Mouse" row a real keyboard gets.
        // Keyboard and mouse stay merged under `.hid`, unchanged: that combined row is the
        // original's own, not something this refinement was asked to split apart.
        if resolved == .hid, detail.hidUsagePage == 0x01, let usage = detail.hidUsage {
            switch usage {
            case 0x04, 0x05, 0x08: return .gamepad
            // Reported live, 2026-09-07, with both plugged in at once: a keyboard and a
            // mouse produced two identical "USB Keyboard/Mouse Connected" notifications,
            // each saying "HID (Keyboard/Mouse)", with nothing to say which was which.
            // The class byte cannot tell them apart — but the usage they lead with can,
            // and always could; this is the same read the gamepad split above uses.
            case 0x06: return .keyboard
            case 0x02: return .mouse
            default: break
            }
        }
        // The same refinement, for the two other usage pages a real USB device leads with
        // that mean something quite unlike a keyboard or a mouse. A media remote, a volume
        // knob or a presentation clicker leads with Consumer (`0x0C`); a graphics tablet or
        // a pen leads with Digitizers (`0x0D`). Both used to answer "HID
        // (Keyboard/Mouse)", which is the class byte's own answer and not a wrong one, but
        // is as unspecific as this module ever gets about something it can actually name.
        //
        // Read from `PrimaryUsagePage`, which is what the device *leads* with, so a
        // keyboard that also carries a Consumer Control collection for its media keys —
        // most of them do — is unaffected: it still leads with Generic Desktop/Keyboard
        // and still resolves above.
        if resolved == .hid, let usage = detail.hidUsage {
            // Consumer Control (`0x01`) only. The rest of that page is numeric keypads and
            // microphone/telephony controls, which are not remotes.
            if detail.hidUsagePage == 0x0C, usage == 0x01 { return .remoteControl }
            // Digitizer (`0x01`) and Pen (`0x02`) only — deliberately not Touch Screen
            // (`0x04`) or Touch Pad (`0x05`), which really are pointing devices and belong
            // exactly where they already are.
            if detail.hidUsagePage == 0x0D, [0x01, 0x02].contains(usage) { return .graphicsTablet }
        }
        // Mass Storage covers three different things somebody plugs in — a flash drive, an
        // SD card reader, a portable HDD/SSD enclosure — and the class byte alone cannot
        // tell them apart; it is one class for all of them. Refined only when a heuristic
        // read of the disk itself (borrowed from Volume Monitor's own, independently
        // reimplemented since a monitor may not import another monitor) recognised
        // something more specific. An enclosure or an unrecognised disk stays `.massStorage`,
        // which is the honest answer when the heuristic has nothing to say.
        guard resolved == .massStorage else { return resolved }
        if let hint = detail.massStorageHint {
            switch hint {
            case .sdCard: return .sdCardReader
            case .usbDrive: return .usbDrive
            case .externalDisk: return .externalDisk
            }
        }
        // The heuristic above reads the disk's own description — its BSD protocol/media
        // name — which does not exist at all without a card actually inserted: an empty
        // card-reader slot publishes no `IOMedia` for it to read, so `massStorageHint`
        // stays nil and this device would otherwise sit at the plain `.massStorage` row,
        // wearing the same generic disk/flash-drive icon a real pendrive gets. Reported
        // live, 2026-09-06: a genuine multi-card reader, empty, read exactly like a
        // pendrive would have. Its own USB product string is available regardless of
        // whether anything is inserted, and commonly names it outright — "USB3.0 Card
        // Reader" in the reported case — so it is checked here as a second, narrower
        // source of the same "recognise it, don't guess" reasoning `massStorageHint`
        // itself rests on.
        if Self.namesACardReader(name) { return .sdCardReader }
        return .massStorage
    }

    /// Whether a device's own name says "card reader" — checked only once the disk-level
    /// heuristic has nothing to read from, as the narrower, later-checked signal. Shares
    /// `USBMassStorageHint.infer`'s own card-reader keywords, applied to the USB product
    /// string instead of the disk's media name, since the product string is the one
    /// naming available before any card is ever inserted.
    private static func namesACardReader(_ text: String) -> Bool {
        let text = text.lowercased()
        return ["secure digital", " sd/", "sd card", "sdxc", "sdhc", "mmc",
                "compactflash", " cf ", "cardreader", "card reader"].contains(where: text.contains)
    }

    /// The words in a product string, lowercased, split on everything that is not a
    /// letter or a digit.
    ///
    /// Whole words rather than substrings, because the words that matter here contain
    /// each other: "WLAN" ends in "lan", and reading a wireless dongle as wired is the
    /// exact mistake these two checks exist to avoid. Underscores count as separators
    /// too — IOKit reports this adapter's name as "USB 10_100_1000 LAN".
    private static func words(in text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }

    /// Whether the product string says outright that this is a wireless adapter.
    private static func namesAWirelessAdapter(_ text: String) -> Bool {
        let words = words(in: text)
        if !words.isDisjoint(with: ["wlan", "wifi", "wireless", "802"]) { return true }
        // "Wi-Fi" splits into two words on the hyphen.
        return words.contains("wi") && words.contains("fi")
    }

    /// Whether the product string says outright that this is a wired network adapter.
    ///
    /// Deliberately narrow: only words that mean Ethernet and nothing else. "Network"
    /// on its own is not one of them — a wireless dongle calls itself that just as
    /// readily — and neither is "gigabit", which is equally at home on a disk enclosure.
    private static func namesAWiredNetworkAdapter(_ text: String) -> Bool {
        !words(in: text).isDisjoint(with: ["lan", "ethernet", "rj45", "gbe"])
    }

    /// The artwork for what this device says it is.
    public var iconBaseName: String? { kind?.iconBaseName }
}

/// The device classes that have artwork and a row of their own.
///
/// One row per class, as the original has it: a Mac with a hub, a keyboard and a webcam
/// permanently attached should be able to silence the hub without silencing the webcam,
/// and give each the icon its owner recognises. The USB-IF assigns many more class codes
/// than these; the ones without artwork fall back to the generic row, because an honest
/// generic icon beats a wrong specific one.
public enum USBDeviceKind: String, Sendable, Equatable, CaseIterable {
    case hub, massStorage, hid, webcam, scanner, printer, smartCard
    case audio, healthcare, audioVideo, typeCBridge, wireless, communications
    case usbDrive, sdCardReader, externalDisk, serialAdapter
    case bluetoothAdapter, wifiAdapter, gamepad, remoteControl, graphicsTablet
    // Split out of the combined `.hid` row, which stays for a HID that leads with
    // neither — a combo receiver, or a usage nothing here recognises.
    case keyboard, mouse

    /// The USB-IF base class code, as the device reports it.
    public init?(deviceClass: UInt8) {
        switch deviceClass {
        case 0x01: self = .audio
        case 0x02: self = .communications
        case 0x03: self = .hid
        case 0x06: self = .scanner
        case 0x07: self = .printer
        case 0x08: self = .massStorage
        case 0x09: self = .hub
        case 0x0B: self = .smartCard
        case 0x0E: self = .webcam
        case 0x0F: self = .healthcare
        case 0x10: self = .audioVideo
        case 0x12: self = .typeCBridge
        case 0xE0: self = .wireless
        default: return nil
        }
    }

    /// Tries the device's own class first, and only then what its interfaces declare.
    ///
    /// Most devices say what they are once, on the device itself. A composite device —
    /// one built from more than one function glued together, like a webcam that is also a
    /// microphone — instead declares `0xEF` ("Miscellaneous", the standard marker for an
    /// Interface Association Descriptor) at the device level and pushes the real classes
    /// onto its interfaces, one per function. Reading only the device class there answers
    /// nothing: a Logitech BRIO reports `0xEF` and was filed under the generic USB event
    /// rather than "USB Webcam Connected", never touching `USB-TypeWebcam`'s icon or its
    /// own row in Settings. Reported live, with the device's own descriptor confirming
    /// the shape: device class `0xEF`/`0x02`/`0x01` (Multi-Interface Function), interfaces
    /// `0x0E` (Video) and `0x01` (Audio) underneath.
    ///
    /// A device genuinely both is neither first — a webcam with a built-in microphone,
    /// the Logitech BRIO among them, is read as `.audioVideo`, the same kind a device
    /// that declares USB-IF's own class `0x10` for exactly this combination gets. Elected
    /// ahead of the single-function picks below because that is the one kind
    /// `kindsCoveredElsewhere` already knows how to treat as neither module's alone: it
    /// only folds USB Monitor's own notice away once *both* Camera's and Audio's own
    /// switches say they have it covered, so silencing one module's switch on this device
    /// never silences the other's say over it. Before this, the interfaces were searched
    /// for video first and the device filed as a plain webcam whenever it had one — right
    /// for a webcam that happens to also carry an incidental audio-control interface, but
    /// wrong for one whose audio interface is a real microphone: reported live, a BRIO
    /// left Audio's own "Notify for USB devices independently" switch with nothing to
    /// silence, because USB Monitor's redundant notice for it was already being decided
    /// by Camera's switch alone.
    ///
    /// Video wins next, when only one of the two is present — a composite webcam with an
    /// incidental non-audio interface is still a webcam first, whatever else it happens
    /// to carry. Audio wins after that, for the same reason on a device that is not also
    /// a webcam: a USB headset or audio interface commonly carries a second, incidental
    /// interface of its own — an HID one, for its volume/mute buttons, most often — and
    /// the registry does not promise to iterate interfaces in ascending interface-number
    /// order, so `interfaceClasses` can just as easily list that HID interface before the
    /// audio one. Reported live: an audio interface's own class picked up second, behind
    /// HID, resolved `kind` to `.hid` instead of `.audio` — a class `kindsCoveredElsewhere`
    /// never has an opinion about, so USB Monitor's own notice for it could never be
    /// folded away, whatever "Notify for USB devices independently of USB Monitor" was
    /// set to. A device that names nothing at all, at either level, is content to stay
    /// generic.
    public init?(deviceClass: UInt8, interfaceClasses: [UInt8]) {
        if let kind = USBDeviceKind(deviceClass: deviceClass) {
            self = kind
            return
        }
        let kinds = interfaceClasses.compactMap { USBDeviceKind(deviceClass: $0) }
        let isHybrid = kinds.contains(.webcam) && kinds.contains(.audio)
        guard let kind: USBDeviceKind = isHybrid ? .audioVideo
            : kinds.first(where: { $0 == .webcam })
            ?? kinds.first(where: { $0 == .audio })
            ?? kinds.first
        else { return nil }
        self = kind
    }

    public var iconBaseName: String {
        switch self {
        case .hub: return "USB-TypeHub"
        // Mass storage borrows the disk artwork rather than the generic USB glyph: a
        // flash drive is a disk, and that is what somebody expects to see.
        case .massStorage: return "Device-USBDrive"
        case .hid: return "USB-TypeHID"
        // Every one of this row's own icons is now the USB glyph paired with the
        // device's own silhouette — "USB, and specifically a webcam" reads as this
        // module's own composite rather than a second, competing picture of a camera,
        // which is what a plain camera glyph on its own would have been.
        case .webcam: return "USB-TypeWebcam"
        case .scanner: return "USB-TypeScanner"
        case .printer: return "USB-TypePrinter"
        case .smartCard: return "USB-TypeSmartCard"
        case .audio: return "USB-TypeAudio"
        case .healthcare: return "USB-TypeHealthcare"
        case .audioVideo: return "USB-TypeAudioVideo"
        case .typeCBridge: return "USB-TypeTypeCBridge"
        case .wireless: return "USB-TypeWireless"
        // Same composite as every other row, paired with the network-adapter artwork
        // already ported for Thunderbolt Monitor's own row of the same shape (H4) — one
        // asset, two monitors, rather than drawing a second one for the same device kind.
        case .communications: return "USB-TypeCommunications"
        // Volume Monitor's own disk artwork for the two mass-storage sub-kinds it
        // already tells apart, reused as-is rather than redrawn for a second time.
        case .usbDrive: return "Device-USBDrive"
        case .sdCardReader: return "Device-SDCard"
        case .externalDisk: return "Device-ExternalDisk"
        case .serialAdapter: return "USB-TypeSerial"
        // Neither has artwork of its own yet — both borrow the same generic wireless
        // glyph `.wireless` already uses, honest for what it is (a wireless controller of
        // some kind) even without saying specifically Bluetooth or WiFi in the picture.
        case .bluetoothAdapter, .wifiAdapter: return "USB-TypeWireless"
        // These three borrowed the HID glyph while they had none of their own. That
        // stopped being honest the moment `.keyboard` was split out and took that same
        // glyph as its own picture: the HID artwork *is* a keyboard, so a gamepad, a
        // remote and a tablet were each being announced with a picture of a keyboard.
        // Each has its own now, drawn to match the ported set.
        case .gamepad: return "USB-TypeGamepad"
        case .remoteControl: return "USB-TypeRemoteControl"
        case .graphicsTablet: return "USB-TypeGraphicsTablet"
        // The ported HID artwork already is a keyboard, so the keyboard row wears it as
        // its own; the mouse row has a picture of a mouse drawn to match it.
        case .keyboard: return "USB-TypeKeyboard"
        case .mouse: return "USB-TypeMouse"
        }
    }

    /// How the row is named in Settings, in the original's words.
    var settingsTitle: String {
        switch self {
        case .hub: return "Hub"
        case .massStorage: return "Mass Storage"
        case .hid: return "Keyboard/Mouse"
        case .webcam: return "Webcam"
        case .scanner: return "Scanner"
        case .printer: return "Printer"
        case .smartCard: return "Smart Card"
        case .audio: return "Audio"
        case .healthcare: return "Healthcare"
        case .audioVideo: return "Audio/Video"
        case .typeCBridge: return "Type-C Bridge"
        case .wireless: return "Wireless"
        // "Network Adapter", not the USB-IF's own "Communications": reported live, this
        // is what a hub's own internal LAN-over-USB chip enumerates as, and "Network
        // Adapter" says what somebody actually sees appear (an `enX` interface) — the
        // "Type" line in the body still says "Communications", the USB-IF's own name for
        // it, so neither wording is lost.
        case .communications: return "Network Adapter"
        case .usbDrive: return "USB Drive"
        case .sdCardReader: return "SD Card Reader"
        case .externalDisk: return "External Disk"
        case .serialAdapter: return "Serial/Debug Adapter"
        case .bluetoothAdapter: return "Bluetooth Adapter"
        case .wifiAdapter: return "WiFi Adapter"
        case .gamepad: return "Gamepad/Joystick"
        case .remoteControl: return "Remote Control"
        case .graphicsTablet: return "Graphics Tablet"
        case .keyboard: return "Keyboard"
        case .mouse: return "Mouse"
        }
    }

    /// The event raised when a device of this kind arrives.
    var connectedEvent: USBEvent {
        switch self {
        case .hub: return .connectedHub
        case .massStorage: return .connectedMassStorage
        case .hid: return .connectedHID
        case .webcam: return .connectedWebcam
        case .scanner: return .connectedScanner
        case .printer: return .connectedPrinter
        case .smartCard: return .connectedSmartCard
        case .audio: return .connectedAudio
        case .healthcare: return .connectedHealthcare
        case .audioVideo: return .connectedAudioVideo
        case .communications: return .connectedCommunications
        case .typeCBridge: return .connectedTypeCBridge
        case .wireless: return .connectedWireless
        case .usbDrive: return .connectedUSBDrive
        case .sdCardReader: return .connectedSDCard
        case .externalDisk: return .connectedExternalDisk
        case .serialAdapter: return .connectedSerialAdapter
        case .bluetoothAdapter: return .connectedBluetoothAdapter
        case .wifiAdapter: return .connectedWiFiAdapter
        case .gamepad: return .connectedGamepad
        case .remoteControl: return .connectedRemoteControl
        case .graphicsTablet: return .connectedGraphicsTablet
        case .keyboard: return .connectedKeyboard
        case .mouse: return .connectedMouse
        }
    }
}

/// Whether `USBDevice.kind` is allowed to resolve `.bluetoothAdapter`/`.wifiAdapter` at
/// all, rather than falling back to the plain `.wireless` row (Bluetooth) or staying
/// unclassified (WiFi) — see each check's own doc comment in `USBDevice.kind` for why
/// they earned separate toggles: one is a reliable USB-IF signature, the other a
/// vendor-ID guess with real false-positive risk.
///
/// A shared, thread-safe singleton for the same reason `USBSerialVendorDatabase.shared`
/// is: `kind` is a plain synchronous computed property with nowhere to receive settings
/// through, so this is consulted directly rather than threaded through as a parameter.
public final class USBWirelessDetectionSettings: @unchecked Sendable {
    public static let shared = USBWirelessDetectionSettings()

    private let lock = NSLock()
    private var _detectsBluetoothAdapters = true
    private var _detectsWiFiAdapters = true

    public var detectsBluetoothAdapters: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _detectsBluetoothAdapters }
        set { lock.lock(); defer { lock.unlock() }; _detectsBluetoothAdapters = newValue }
    }

    public var detectsWiFiAdapters: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _detectsWiFiAdapters }
        set { lock.lock(); defer { lock.unlock() }; _detectsWiFiAdapters = newValue }
    }
}

/// USB vendor IDs commonly found on WiFi (802.11) USB dongles — there is no USB-IF class
/// for WiFi the way there is for Bluetooth, so every one of these ships under its own
/// vendor-specific class and driver, and the only thing left to recognise it by is who
/// made the chip. Deliberately small and named plainly: every one of these vendors also
/// sells plenty that is not a WiFi adapter, so this is a best-effort guess, not a
/// certainty the way `USBSerialVendorDatabase`'s FTDI-and-friends list mostly is — see
/// `USBWirelessDetectionSettings.detectsWiFiAdapters` for the toggle this earned because
/// of it.
enum USBWiFiVendorDatabase {
    static let knownVendors: Set<UInt16> = [
        0x0BDA, // Realtek
        0x0E8D, // MediaTek
        0x148F, // Ralink Technology
        0x0CF3, // Qualcomm Atheros
        0x0A5C, // Broadcom
        0x2357  // TP-Link
    ]

    static func isKnownVendor(_ vendorID: UInt16) -> Bool {
        knownVendors.contains(vendorID)
    }
}

/// What the disk behind a Mass Storage device looks like, read off the disk itself rather
/// than the USB class byte — which cannot tell a flash drive from an SD card reader from a
/// portable HDD/SSD enclosure, since all three share the one class, `0x08`.
///
/// A disk the heuristic below does not recognise stays nil and therefore `.massStorage` —
/// the honest generic answer, not a wrong specific guess.
///
/// The heuristic itself is a scoped, independently reimplemented copy of Volume Monitor's
/// own `VolumeKind.infer` (a monitor may not import another monitor's types — see the
/// architecture's module-isolation rule), including its size-based fallback for an
/// enclosure that names itself nothing useful. It is admittedly imperfect there already;
/// see `KNOWN-ISSUES.md` for what is left to a future investigation — confirmed live,
/// 2026-09-05, against a real pendrive whose controller chip carries no product string
/// and no vendor registration at all (`idVendor` 0xABCD, the well-known unregistered
/// placeholder), which this heuristic — like Volume Monitor's own — has no text or size
/// signal to identify: too small for the enclosure-sized fallback below, and honestly
/// unidentifiable rather than wrongly guessed at.
public enum USBMassStorageHint: Sendable, Equatable {
    case sdCard, usbDrive, externalDisk

    /// Unnamed USB storage this size or larger is guessed to be an enclosure rather than a
    /// flash drive — the same threshold and the same reasoning as `VolumeKind`'s own.
    static let externalDiskThresholdBytes: UInt64 = 400 * 1024 * 1024 * 1024

    public static func infer(protocolName: String?, mediaName: String?, sizeBytes: UInt64? = nil) -> USBMassStorageHint? {
        if protocolName?.caseInsensitiveCompare("Secure Digital") == .orderedSame { return .sdCard }
        let text = (mediaName ?? "").lowercased()
        if ["secure digital", " sd/", "sd card", "sdxc", "sdhc", "mmc",
            "compactflash", " cf ", "cardreader", "card reader"].contains(where: text.contains) {
            return .sdCard
        }
        // An explicit name beats the size guess: checked first so a 1 TB drive that calls
        // itself a flash drive is not filed as an enclosure on size alone.
        if ["hdd", "ssd", "hard disk", "hard drive", "external"].contains(where: text.contains) {
            return .externalDisk
        }
        if ["flash", "thumb", "pen drive", "usb drive", "mass storage"].contains(where: text.contains) {
            return .usbDrive
        }
        if let sizeBytes, sizeBytes >= externalDiskThresholdBytes { return .externalDisk }
        return nil
    }
}

public enum USBDeviceChange: Sendable, Equatable {
    case attached(USBDevice)
    case detached(USBDevice)
}

/// Where news of USB devices comes from.
///
/// A protocol so the monitor's own behaviour — what it says, and about what — can be
/// exercised without any hardware being plugged in or unplugged. The implementation that
/// talks to the system is deliberately thin, for the same reason the notification service
/// sits behind a protocol in `SignalCore`.
public protocol USBDeviceSource: Sendable {
    /// Devices already attached when watching begins, followed by changes as they happen.
    func changes() -> AsyncStream<USBDeviceChange>
}

public extension USBDevice {
    /// The artwork for this device leaving.
    ///
    /// Almost always the connected name with `-Disconnected` on the end. Mass storage is
    /// the exception: it borrows Volume Monitor's disk artwork, whose "gone" variant is
    /// named `-Unmounted`, so the mechanical suffix would ask for a file that does not
    /// exist and the icon would silently fall back to nothing.
    var disconnectedIconName: String {
        guard let base = iconBaseName else { return "USB-Off" }
        switch base {
        case "Device-USBDrive": return "Device-USBDrive-Unmounted"
        case "Device-SDCard": return "Device-SDCard-Unmounted"
        case "Device-ExternalDisk": return "Device-ExternalDisk-Unmounted"
        case "USB-On": return "USB-Off"
        default: return "\(base)-Disconnected"
        }
    }
}

public extension USBDevice {
    /// What the device says it is, in words — "Mass Storage", "HID (Keyboard/Mouse)".
    ///
    /// The USB-IF's published base class codes. Nil for `0x00` with nothing recognised on
    /// its interfaces either: that is the common case, not an error, and there is nothing
    /// useful to say about it.
    ///
    /// `0xEF` gets the same "look at the interfaces instead" treatment as `0x00`, the same
    /// reasoning `USBDeviceKind`'s own fallback rests on: it is the standard marker for a
    /// composite device, not a description of one. Left as `className` describing a BRIO
    /// as "Miscellaneous" while `kind` had already worked out "Webcam" from the same
    /// interfaces — the notification's title and its own body line for "Type" disagreeing
    /// about what it was.
    var className: String? {
        if let deviceClass, deviceClass != 0x00, deviceClass != 0xEF {
            return Self.name(forClassByte: deviceClass)
        }
        let interfaceNames = interfaceClasses.compactMap(Self.name(forClassByte:))
        // Matches `USBDeviceKind`'s own priority exactly — a device genuinely both, then
        // video alone, then whatever else — so this line and the notification's title
        // never again disagree about what a composite device is, which is the mismatch
        // this whole fallback exists to prevent.
        if interfaceNames.contains("Video") && interfaceNames.contains("Audio") {
            return "Audio/Video"
        }
        if let name = interfaceNames.first(where: { $0 == "Video" }) ?? interfaceNames.first {
            return name
        }
        // Nothing recognised on the interfaces either: for 0xEF, naming "more than one
        // function" is at least honest, and better than falling silent about it.
        return deviceClass.flatMap(Self.name(forClassByte:))
    }

    /// Whether `className` names something that actually says what the device is, rather
    /// than one of USB-IF's own three escape hatches — `0xFF`/`0xFE`/`0xEF`, "ask the
    /// vendor", "ask the application", and "this is more than one function" — none of
    /// which say anything about what the device actually *does*.
    ///
    /// Reported live, 2026-09-06: a genuine FTDI USB-serial adapter — declaring `0x00` at
    /// the device level and its real interface class as `0xFF` (FTDI's own chip, like
    /// many vendor-specific USB parts, uses no standard class at all) — was silenced by
    /// "ignore identified devices without their own icon", because `className` resolved
    /// to `"Vendor Specific"` and that switch only ever meant to silence a device that
    /// names a *real* class with no row of its own (Billboard, Communications). A device
    /// that names nothing more informative than "not standard" is, for this switch's own
    /// purpose, exactly as unidentified as one with no class at all, and deserves the
    /// same generic notification rather than silence.
    ///
    /// `"Miscellaneous"` (`0xEF`) belongs in the same set on the same reasoning, not
    /// added for a live report of its own: it is `className`'s own honest label for a
    /// composite device whose interfaces named nothing recognisable either — see its
    /// doc comment above — the identical "not really an answer" shape the other two
    /// escape hatches have, just reached from the device-composite side rather than a
    /// single interface's own vendor-specific one.
    var isMeaningfullyIdentified: Bool {
        guard let className else { return false }
        return !Self.uninformativeClassNames.contains(className)
    }

    /// USB-IF's own three "not a real answer" class names — see `isMeaningfullyIdentified`.
    private static let uninformativeClassNames: Set<String> = [
        "Vendor Specific", "Application Specific", "Miscellaneous"
    ]

    private static func name(forClassByte deviceClass: UInt8) -> String? {
        switch deviceClass {
        case 0x01: return "Audio"
        case 0x02: return "Communications"
        case 0x03: return "HID (Keyboard/Mouse)"
        case 0x05: return "Physical"
        case 0x06: return "Still Imaging"
        case 0x07: return "Printer"
        case 0x08: return "Mass Storage"
        case 0x09: return "Hub"
        case 0x0A: return "CDC Data"
        case 0x0B: return "Smart Card"
        case 0x0D: return "Content Security"
        case 0x0E: return "Video"
        case 0x0F: return "Personal Healthcare"
        case 0x10: return "Audio/Video"
        case 0x11: return "Billboard"
        case 0x12: return "USB Type-C Bridge"
        case 0xDC: return "Diagnostic"
        case 0xE0: return "Wireless Controller"
        case 0xEF: return "Miscellaneous"
        case 0xFE: return "Application Specific"
        case 0xFF: return "Vendor Specific"
        default: return nil
        }
    }
}

/// What a USB device says about itself beyond its name and class.
public struct USBDeviceDetail: Sendable, Equatable {
    public let productName: String?
    public let vendorID: UInt16?
    public let productID: UInt16?
    /// The `Device Speed` the registry reports, 0-5.
    public let speedCode: UInt8?
    /// Milliamps the device asks for, and what the port has to give.
    public let requiredCurrent: Int?
    public let availableCurrent: Int?
    /// Whether the port refused the request outright.
    public let requestedMoreThanAvailable: Bool
    /// "Solid State" or "Rotational", for mass storage.
    public let mediumType: String?
    /// A flash drive or an SD card reader, read heuristically off the disk itself — see
    /// `USBMassStorageHint`. Nil for every device that is not Mass Storage, and for a Mass
    /// Storage device the heuristic did not recognise (most often a disk enclosure).
    public let massStorageHint: USBMassStorageHint?
    public let serialNumber: String?
    /// The device release number, as major and minor halves of a BCD word.
    public let releaseVersion: UInt16?
    public let locationID: UInt32?
    public let configurationCount: Int?
    /// The USB spec revision, also BCD — 0x0320 is USB 3.2.
    public let specVersion: UInt16?
    /// Arrived over a Thunderbolt/USB4 tunnel rather than a real USB port.
    public let isTunnelled: Bool
    public let isPortRemovable: Bool?
    /// The connector type code the port reports — 0 is Type-A, 3 is Type-C.
    public let connectorType: Int?
    /// The HID Usage Page/Usage pair read off the device's own `IOHIDDevice` — the only
    /// place a HID device says anything more specific than "HID" about what it is,
    /// something no USB class or interface byte can. Nil for anything that is not a HID
    /// interface, or one this could not be read for. See `USBDeviceKind`'s own Gamepad
    /// refinement for the one distinction this is used to make.
    public let hidUsagePage: Int?
    public let hidUsage: Int?

    /// A copy with only the mass-storage hint changed — for the arrival-time retry that
    /// re-reads a Mass Storage device once its BSD name/disk description has had time to
    /// attach, without having to repeat or guess at every other field already read.
    func withMassStorageHint(_ hint: USBMassStorageHint?) -> USBDeviceDetail {
        USBDeviceDetail(
            productName: productName, vendorID: vendorID, productID: productID,
            speedCode: speedCode, requiredCurrent: requiredCurrent, availableCurrent: availableCurrent,
            requestedMoreThanAvailable: requestedMoreThanAvailable, mediumType: mediumType,
            massStorageHint: hint, serialNumber: serialNumber, releaseVersion: releaseVersion,
            locationID: locationID, configurationCount: configurationCount, specVersion: specVersion,
            isTunnelled: isTunnelled, isPortRemovable: isPortRemovable, connectorType: connectorType,
            hidUsagePage: hidUsagePage, hidUsage: hidUsage
        )
    }

    /// A copy with only the HID Usage Page/Usage changed — for the arrival-time retry
    /// that re-reads a HID device once its `IOHIDDevice` object has had time to publish
    /// them, the same reasoning above rests on.
    func withHIDUsage(page: Int?, usage: Int?) -> USBDeviceDetail {
        USBDeviceDetail(
            productName: productName, vendorID: vendorID, productID: productID,
            speedCode: speedCode, requiredCurrent: requiredCurrent, availableCurrent: availableCurrent,
            requestedMoreThanAvailable: requestedMoreThanAvailable, mediumType: mediumType,
            massStorageHint: massStorageHint, serialNumber: serialNumber, releaseVersion: releaseVersion,
            locationID: locationID, configurationCount: configurationCount, specVersion: specVersion,
            isTunnelled: isTunnelled, isPortRemovable: isPortRemovable, connectorType: connectorType,
            hidUsagePage: page, hidUsage: usage
        )
    }

    /// A copy with only the storage medium changed — for departure falling back to what
    /// arrival already found, the same reasoning `withMassStorageHint` rests on.
    func withMediumType(_ medium: String?) -> USBDeviceDetail {
        USBDeviceDetail(
            productName: productName, vendorID: vendorID, productID: productID,
            speedCode: speedCode, requiredCurrent: requiredCurrent, availableCurrent: availableCurrent,
            requestedMoreThanAvailable: requestedMoreThanAvailable, mediumType: medium,
            massStorageHint: massStorageHint, serialNumber: serialNumber, releaseVersion: releaseVersion,
            locationID: locationID, configurationCount: configurationCount, specVersion: specVersion,
            isTunnelled: isTunnelled, isPortRemovable: isPortRemovable, connectorType: connectorType,
            hidUsagePage: hidUsagePage, hidUsage: hidUsage
        )
    }

    public init(
        productName: String? = nil,
        vendorID: UInt16? = nil,
        productID: UInt16? = nil,
        speedCode: UInt8? = nil,
        requiredCurrent: Int? = nil,
        availableCurrent: Int? = nil,
        requestedMoreThanAvailable: Bool = false,
        mediumType: String? = nil,
        massStorageHint: USBMassStorageHint? = nil,
        serialNumber: String? = nil,
        releaseVersion: UInt16? = nil,
        locationID: UInt32? = nil,
        configurationCount: Int? = nil,
        specVersion: UInt16? = nil,
        isTunnelled: Bool = false,
        isPortRemovable: Bool? = nil,
        connectorType: Int? = nil,
        hidUsagePage: Int? = nil,
        hidUsage: Int? = nil
    ) {
        self.productName = productName
        self.vendorID = vendorID
        self.productID = productID
        self.speedCode = speedCode
        self.requiredCurrent = requiredCurrent
        self.availableCurrent = availableCurrent
        self.requestedMoreThanAvailable = requestedMoreThanAvailable
        self.mediumType = mediumType
        self.massStorageHint = massStorageHint
        self.serialNumber = serialNumber
        self.releaseVersion = releaseVersion
        self.locationID = locationID
        self.configurationCount = configurationCount
        self.specVersion = specVersion
        self.isTunnelled = isTunnelled
        self.isPortRemovable = isPortRemovable
        self.connectorType = connectorType
        self.hidUsagePage = hidUsagePage
        self.hidUsage = hidUsage
    }

    var vidPidNote: String? {
        guard let vendorID, let productID else { return nil }
        return String(format: "%04X:%04X", vendorID, productID)
    }

    /// The speed as a generation people recognise rather than a bare number.
    var speedNote: String? {
        switch speedCode {
        case 0: return "USB 1.0 (Low Speed)"
        case 1: return "USB 1.1 (Full Speed)"
        case 2: return "USB 2.0 (High Speed)"
        case 3: return "USB 3.0/3.1 (SuperSpeed)"
        case 4: return "USB 3.2 (SuperSpeed+, 10 Gb/s)"
        case 5: return "USB 3.2 Gen 2x2 (SuperSpeed+, 20 Gb/s)"
        default: return nil
        }
    }

    /// What it wants against what the port has, with a warning when that does not add up.
    ///
    /// The warning is the reason this line is on by default: a device drawing more than
    /// its port can give is the explanation for a drive that keeps dropping out, and
    /// nothing else in macOS says so.
    var powerNote: String? {
        guard let requiredCurrent else { return nil }
        guard let availableCurrent else { return "\(requiredCurrent)mA" }

        let base = "\(requiredCurrent)mA / \(availableCurrent)mA available"
        return requiredCurrent > availableCurrent ? "\(base) ⚠️ exceeds available" : base
    }

    /// Whether the disk inside spins, which is what decides how it should be treated.
    var mediumNote: String? {
        switch mediumType {
        case "Solid State": return "SSD / Flash"
        case "Rotational": return "HDD (rotational)"
        default: return nil
        }
    }

    /// A BCD version word, decoded a nibble at a time: 0x0320 is 3.20.
    ///
    /// Each nibble is one decimal digit, which is the whole point of binary-coded decimal.
    /// Reading the low byte as an ordinary number instead gives 0x20 = 32, so USB 3.2
    /// comes out as "3.32" — a mistake the original makes and this deliberately does not.
    static func describeBCD(_ value: UInt16) -> String {
        let major = (value >> 12) * 10 + ((value >> 8) & 0xF)
        let minorTens = (value >> 4) & 0xF
        let minorUnits = value & 0xF
        return "\(major).\(minorTens)\(minorUnits)"
    }

    var firmwareNote: String? { releaseVersion.map(Self.describeBCD) }
    var specVersionNote: String? { specVersion.map(Self.describeBCD) }
    var locationNote: String? { locationID.map { String(format: "0x%08X", $0) } }
    var configurationsNote: String? { configurationCount.map(String.init) }
    var tunnelNote: String? { isTunnelled ? "USB4/Thunderbolt tunnel" : nil }

    /// Only ever shown when the port refused: telling somebody their device got the power
    /// it asked for is not news.
    var failedPowerNote: String? {
        requestedMoreThanAvailable ? "⚠️ Device requested more power than the port could provide" : nil
    }

    /// Whether the port is one you can reach, and what shape it is.
    var portNote: String? {
        var parts: [String] = []
        if let isPortRemovable { parts.append(isPortRemovable ? "removable" : "built-in") }
        if let connectorType { parts.append("connector type code \(connectorType)") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// The manufacturer and the product name together, which is how the original reads —
    /// either alone is half an answer.
    func manufacturerNote(vendorName: String?) -> String? {
        let parts = [vendorName, productName].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}
