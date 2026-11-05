import SentryContract
import SystemIcons
import Testing
@testable import MonitorRegistry

/// Checks the kinds every module declares, across all of them at once — the one place
/// that can see the whole list.
@Suite("Device icon kinds")
struct DeviceIconKindCatalogueTests {
    /// Which prefix each module files its kinds under. A module missing from here, or a
    /// kind filed under somebody else's prefix, fails below.
    private static let prefixByModule: [String: String] = [
        "USB": "usb", "Bluetooth": "bluetooth", "Thunderbolt": "thunderbolt",
        "Volume": "volume", "Gamepad": "gamepad", "Display": "display",
        "Printer": "printer", "Scanner": "scanner", "Audio": "audio",
        "Camera": "camera", "Network": "network"
    ]

    private var declared: [(module: String, kind: DeviceIconKind)] {
        MonitorRegistry.catalogue.flatMap { module in
            module.events.compactMap { event in event.iconKind.map { (module.category.rawValue, $0) } }
        }
    }

    @Test("every kind is written module.name, with nothing else in it")
    func wellFormed() {
        for (_, kind) in declared {
            let parts = kind.rawValue.split(separator: ".", omittingEmptySubsequences: false)
            #expect(parts.count == 2, "\(kind)")
            #expect(parts.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber } }, "\(kind)")
        }
    }

    @Test("each module files its kinds under its own prefix")
    func ownPrefix() {
        let categories = Set(MonitorRegistry.catalogue.map(\.category.rawValue))
        for module in Self.prefixByModule.keys {
            #expect(categories.contains(module), "no module called \(module)")
        }
        for (module, kind) in declared {
            #expect(Self.prefixByModule[module] == kind.module, "\(module) declared \(kind)")
        }
    }

    @Test("modules whose icons are all ideas declare no kinds")
    func ideaOnlyModules() {
        let withKinds = Set(declared.map(\.module))
        #expect(!withKinds.contains("Power"))
        #expect(!withKinds.contains("Thermal"))
    }

    /// The whole list, written out. Fails when a kind appears or disappears, which is the
    /// moment the operating-system icon table needs the same change — so nothing new
    /// slips through with no decision made about what it should look like.
    @Test("the full set of kinds is the one the icon table was written against")
    func inventory() {
        let kinds = Set(declared.map(\.kind.rawValue))
        #expect(kinds == Self.expected, "added: \(kinds.subtracting(Self.expected).sorted()), removed: \(Self.expected.subtracting(kinds).sorted())")
    }

    @Test("every kind has had a decision made about the operating system's picture")
    func everyKindIsInTheSystemIconTable() {
        let kinds = Set(declared.map(\.kind.rawValue))
        let decided = Set(SystemIconCatalog.defaultTable.keys).union(SystemIconCatalog.withoutSystemImage)
        #expect(kinds == decided, "undecided: \(kinds.subtracting(decided).sorted()), stale: \(decided.subtracting(kinds).sorted())")
    }

    static let expected: Set<String> = [
        "usb.hub", "usb.massStorage", "usb.hid", "usb.webcam", "usb.scanner", "usb.printer",
        "usb.smartCard", "usb.audio", "usb.healthcare", "usb.audioVideo", "usb.typeCBridge",
        "usb.wireless", "usb.communications", "usb.usbDrive", "usb.sdCardReader",
        "usb.externalDisk", "usb.serialAdapter", "usb.bluetoothAdapter", "usb.wifiAdapter",
        "usb.gamepad", "usb.remoteControl", "usb.graphicsTablet", "usb.keyboard", "usb.mouse",
        "usb.generic",
        "bluetooth.computer", "bluetooth.phone", "bluetooth.accessPoint", "bluetooth.wearable",
        "bluetooth.health", "bluetooth.keyboard", "bluetooth.mouse", "bluetooth.combo",
        "bluetooth.headset", "bluetooth.microphone", "bluetooth.speaker", "bluetooth.headphones",
        "bluetooth.gamepad", "bluetooth.remote", "bluetooth.tablet", "bluetooth.cardReader",
        "bluetooth.barcodeScanner", "bluetooth.sensor", "bluetooth.printer", "bluetooth.scanner",
        "bluetooth.camera", "bluetooth.display", "bluetooth.generic",
        "thunderbolt.egpu", "thunderbolt.dock", "thunderbolt.disk", "thunderbolt.networkAdapter",
        "thunderbolt.capture", "thunderbolt.communication", "thunderbolt.inputDevice",
        "thunderbolt.serialBus", "thunderbolt.wirelessController", "thunderbolt.generic",
        "volume.sdCard", "volume.usbDrive", "volume.externalDisk", "volume.optical", "volume.nas",
        "volume.generic",
        "gamepad.controller", "gamepad.racingWheel",
        "display.monitor", "printer.printer", "scanner.scanner",
        "audio.speaker", "audio.microphone", "audio.headphones", "audio.midi",
        "camera.camera", "camera.webcam", "camera.continuity", "camera.deskView",
        "network.wifi", "network.wired", "network.adapter"
    ]
}
