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
        set([Path.bluetoothUI + "/Generic-Headphones.png"],
            for: "bluetooth.headphones", "bluetooth.headset", "audio.headphones")
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
        set([Path.coreTypes + "/GenericAirDiskIcon.icns", Path.coreTypes + "/GenericNetworkIcon.icns"],
            for: "volume.nas")
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
    static let moduleKinds: [String: String] = [
        "USB": "usb.massStorage",
        "Bluetooth": "bluetooth.generic",
        "Volume": "volume.externalDisk",
        "Display": "display.monitor",
        "Printer": "printer.printer",
        "Scanner": "scanner.scanner",
        "Audio": "audio.speaker",
        "Gamepad": "gamepad.controller",
        "Network": "network.wired"
    ]

    /// Kinds macOS has no picture of. Listed rather than merely absent, so that leaving
    /// one out of the table above is a decision someone made and not a kind nobody noticed.
    static let withoutSystemImage: Set<String> = [
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
