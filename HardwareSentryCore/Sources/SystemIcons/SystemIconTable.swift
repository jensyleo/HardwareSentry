import Foundation

/// Where macOS keeps its picture of each kind of device, as far as anyone outside Apple
/// can tell.
///
/// The Finder sidebar's pictures (`Sidebar…`) are deliberately absent: they are black
/// templates meant to be tinted, and drawn as they are they vanish on a dark banner.
///
/// Written down as file paths and nothing else — the pictures themselves stay on the Mac
/// they came with. Several candidates per kind where macOS has them, best first, so a
/// release that drops or moves one file still leaves the next. A kind missing from here
/// has no operating-system picture, and keeps this application's own.
///
/// Every kind a module can declare must be either here or in `withoutSystemImage`; a test
/// holds the two lists against the modules, so a new kind cannot arrive undecided.
public extension SystemIconCatalog {
    static let defaultTable: [String: [String]] = {
        var table: [String: [String]] = [:]
        func set(_ paths: [String], for kinds: String...) {
            for kind in kinds { table[kind] = paths }
        }

        // Apple's own keyboard and mouse first: the generic pictures beside them are 64
        // pixels, drawn for the Bluetooth menu, and go soft at banner size on a Retina
        // screen, where these are 1024.
        set([Path.bluetoothUI + "/A284_Silver.icns", Path.bluetoothUI + "/Generic-Keyboard.icns"],
            for: "usb.keyboard", "bluetooth.keyboard", "bluetooth.combo")
        set([Path.bluetoothUI + "/A125-White.icns", Path.bluetoothUI + "/Generic-Mouse.icns", Path.ioBluetoothUI + "/MightyMouse.icns"],
            for: "usb.mouse", "bluetooth.mouse")
        set([Path.bluetoothUI + "/Generic-Speakers.png", Path.coreTypes + "/GenericSpeaker.icns"],
            for: "bluetooth.speaker")
        set([Path.coreTypes + "/GenericSpeaker.icns", Path.bluetoothUI + "/Generic-Speakers.png"],
            for: "audio.speaker", "usb.audio")
        set([Path.bluetoothUI + "/Generic-GameController.png"],
            for: "usb.gamepad", "bluetooth.gamepad", "gamepad.controller")
        set([Path.coreTypes + "/com.apple.iphone.icns"],
            for: "bluetooth.phone", "camera.continuity")
        set([Path.coreTypes + "/com.apple.macbookpro-14-2021-silver.icns", Path.coreTypes + "/com.apple.macbookair.icns"],
            for: "bluetooth.computer")
        set([Path.coreTypes + "/public.generic-lcd.icns", Path.coreTypes + "/com.apple.studio-display.icns"],
            for: "bluetooth.display", "display.monitor")
        set([Path.printCore + "/GenericInkjetPrinter.icns", Path.printCore + "/GenericPostscriptPrinter.icns"],
            for: "usb.printer", "bluetooth.printer", "printer.printer")
        set([Path.printCore + "/GenericScanner.icns"],
            for: "usb.scanner", "bluetooth.scanner", "scanner.scanner")
        set([Path.scsi + "/USBHD.icns", Path.storage + "/External.icns"],
            for: "usb.massStorage", "usb.usbDrive", "volume.usbDrive")
        set([Path.storage + "/External.icns", Path.scsi + "/USBHD.icns"],
            for: "usb.externalDisk", "volume.externalDisk", "volume.generic", "thunderbolt.disk")
        set([Path.scsi + "/SD.icns"],
            for: "usb.sdCardReader", "volume.sdCard")
        set([Path.cd + "/CD.icns", Path.coreTypes + "/CDAudioVolumeIcon.icns"],
            for: "volume.optical")
        set([Path.ioBluetoothUI + "/Bluetooth.icns", Path.bluetoothUI + "/Bluetooth.icns"],
            for: "bluetooth.generic", "usb.bluetoothAdapter")
        set([Path.coreTypes + "/GenericNetworkIcon.icns"],
            for: "network.wired", "network.adapter", "thunderbolt.networkAdapter")
        return table
    }()

    /// The kind whose picture stands for a whole module when it is set to System — in the
    /// list of modules and as the module's own icon. A module missing here (Thunderbolt,
    /// Camera, and the ones that draw ideas) keeps its own artwork: macOS has nothing that
    /// says "Thunderbolt" or "camera" in general.
    ///
    /// USB is left out on purpose: its notifications for a drive use the same yellow disk
    /// as Volume's, so the two modules would sit in the list with identical pictures, and
    /// the application's USB symbol is the one that says which module is which.
    static let moduleKinds: [String: String] = [        "Bluetooth": "bluetooth.generic",
        "Volume": "volume.externalDisk",
        "Display": "display.monitor",
        "Printer": "printer.printer",
        "Scanner": "scanner.scanner",
        "Audio": "audio.speaker",
        "Gamepad": "gamepad.controller",
        "Network": "network.wired"
    ]

    /// Kinds that keep this application's artwork. Listed rather than merely absent, so that
    /// leaving one out of the table above is a decision someone made and not a kind nobody
    /// noticed.
    ///
    /// Mostly kinds macOS has no picture of. `volume.nas` is the exception, on purpose: the
    /// closest thing macOS ships is a disk with a Wi-Fi symbol on it — the old AirPort disk
    /// — which reads as a wireless drive rather than a network share, so a NAS keeps this
    /// application's own picture of one. The headphones are the other: macOS's are black, and
    /// on a dark banner they all but vanish, while this application's are coloured.
    static let withoutSystemImage: Set<String> = [
        "volume.nas",
        "bluetooth.headphones", "bluetooth.headset", "audio.headphones",
        "usb.hub", "usb.hid", "usb.webcam", "usb.smartCard", "usb.healthcare", "usb.audioVideo",
        "usb.typeCBridge", "usb.wireless", "usb.communications", "usb.serialAdapter",
        "usb.wifiAdapter", "usb.remoteControl", "usb.graphicsTablet", "usb.generic",
        "bluetooth.accessPoint", "bluetooth.wearable", "bluetooth.health", "bluetooth.microphone",
        "bluetooth.remote", "bluetooth.tablet", "bluetooth.cardReader", "bluetooth.barcodeScanner",
        "bluetooth.sensor", "bluetooth.camera",
        "thunderbolt.egpu", "thunderbolt.dock", "thunderbolt.capture", "thunderbolt.communication",
        "thunderbolt.inputDevice", "thunderbolt.serialBus", "thunderbolt.wirelessController",
        "thunderbolt.generic",
        "gamepad.racingWheel",
        "audio.microphone", "audio.midi",
        "camera.camera", "camera.webcam", "camera.deskView",
        "network.wifi"
    ]
}

enum Path {
    static let coreTypes = "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources"
    static let bluetoothUI = AppleAccessoryIndex.directory
    static let ioBluetoothUI = "/System/Library/Frameworks/IOBluetoothUI.framework/Versions/A/Resources"
    static let printCore = "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/PrintCore.framework/Versions/A/Resources"
    static let scsi = "/System/Library/Extensions/IOSCSIArchitectureModelFamily.kext/Contents/Resources"
    static let storage = "/System/Library/Extensions/IOStorageFamily.kext/Contents/Resources"
    static let cd = "/System/Library/Extensions/IOCDStorageFamily.kext/Contents/Resources"
}
