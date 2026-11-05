import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import SystemIcons

/// A throwaway folder laid out like `/System/Library`, so the catalogue can be tested
/// against files that are exactly what each test says, on any Mac.
private final class FakeSystem {
    let root: String

    init() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SystemIconCatalogTests-\(UUID().uuidString)").path
    }

    deinit { try? FileManager.default.removeItem(atPath: root) }

    /// Writes a real, decodable picture of the given width.
    func picture(at path: String, width: Int = 512) {
        let context = CGContext(
            data: nil, width: width, height: width, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: width))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        write(data as Data, at: path)
    }

    func write(_ data: Data, at path: String) {
        let full = root + path
        try! FileManager.default.createDirectory(
            atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: full, contents: data)
    }

    func plist(_ value: [String: Any], at path: String) {
        write(try! PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0), at: path)
    }

    func catalog(_ table: [String: [String]] = [:]) -> SystemIconCatalog {
        SystemIconCatalog(table: table, root: root)
    }
}

private func width(of png: Data?) -> Int? {
    guard let png, let source = CGImageSourceCreateWithData(png as CFData, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    else { return nil }
    return properties[kCGImagePropertyPixelWidth] as? Int
}

@Suite("SystemIconCatalog")
struct SystemIconCatalogTests {
    private let index = AppleAccessoryIndex.directory

    @Test("a kind's picture comes back as a PNG no bigger than asked for")
    func rendersAndShrinks() async {
        let fake = FakeSystem()
        fake.picture(at: "/System/Library/Icons/keyboard.png", width: 1024)
        let image = await fake.catalog(["usb.keyboard": ["/System/Library/Icons/keyboard.png"]])
            .image(forKind: "usb.keyboard")
        #expect(width(of: image) == 256)
    }

    @Test("a missing first choice falls through to the next")
    func fallsThroughMissingFiles() async {
        let fake = FakeSystem()
        fake.picture(at: "/System/Library/Icons/second.png")
        let catalog = fake.catalog(["k.k": ["/System/Library/Icons/first.png", "/System/Library/Icons/second.png"]])
        #expect(await catalog.image(forKind: "k.k") != nil)
    }

    @Test("a file that is not a picture is passed over, not trusted")
    func skipsCorruptFiles() async {
        let fake = FakeSystem()
        fake.write(Data("not an image".utf8), at: "/System/Library/Icons/broken.icns")
        fake.picture(at: "/System/Library/Icons/good.png")
        let catalog = fake.catalog(["k.k": ["/System/Library/Icons/broken.icns", "/System/Library/Icons/good.png"]])
        #expect(await catalog.image(forKind: "k.k") != nil)

        let onlyBroken = fake.catalog(["k.k": ["/System/Library/Icons/broken.icns"]])
        #expect(await onlyBroken.image(forKind: "k.k") == nil)
    }

    @Test("nothing found means no picture — the caller keeps its own")
    func nothingFound() async {
        let catalog = FakeSystem().catalog(["k.k": ["/System/Library/Nope.icns"]])
        #expect(await catalog.image(forKind: "k.k") == nil)
        #expect(await catalog.hasImage(forKind: "k.k") == false)
        #expect(await catalog.image(forKind: "unknown.kind") == nil)
    }

    @Test("nothing outside /System/Library is ever read")
    func refusesOtherFolders() async {
        let fake = FakeSystem()
        fake.picture(at: "/Users/someone/evil.png")
        fake.picture(at: "/System/Library/Icons/ok.png")
        let catalog = fake.catalog([
            "a.a": ["/Users/someone/evil.png"],
            "b.b": ["/System/Library/../Users/someone/evil.png"],
            "c.c": ["/System/Library/Icons/ok.png"]
        ])
        #expect(await catalog.image(forKind: "a.a") == nil)
        #expect(await catalog.image(forKind: "b.b") == nil)
        #expect(await catalog.image(forKind: "c.c") != nil)
    }

    // MARK: - Exact models

    @Test("an Apple accessory gets the picture of its own model")
    func exactModel() async {
        let fake = FakeSystem()
        fake.picture(at: index + "/MagicKeyboard.png", width: 100)
        fake.picture(at: "/System/Library/Icons/generic.png", width: 600)
        fake.plist(["0x0322": ["ImageName": "MagicKeyboard.png", "Name": "Magic Keyboard"]], at: index + "/AssetPaths-A284.plist")
        let catalog = fake.catalog(["bluetooth.keyboard": ["/System/Library/Icons/generic.png"]])

        // Told apart by size: the model's picture is 100 wide, the generic one shrinks to 256.
        #expect(width(of: await catalog.image(forKind: "bluetooth.keyboard", model: "004c:0322")) == 100)
        #expect(width(of: await catalog.image(forKind: "bluetooth.keyboard", model: "05ac:0322")) == 100)
        #expect(width(of: await catalog.image(forKind: "bluetooth.keyboard")) == 256)
    }

    @Test("a model that borrows another's picture is followed to it")
    func clone() async {
        let fake = FakeSystem()
        fake.picture(at: index + "/Mouse.png")
        fake.plist([
            "0x0269": ["ImageName": "Mouse.png"],
            "0x030D": ["Clone": "0x0269"]
        ], at: index + "/AssetPaths.plist")
        #expect(await fake.catalog().image(forKind: "x.x", model: "004c:030d") != nil)
    }

    @Test("a list that clones in a circle ends instead of looping")
    func cloneCycle() async {
        let fake = FakeSystem()
        fake.plist(["0x0001": ["Clone": "0x0002"], "0x0002": ["Clone": "0x0001"]], at: index + "/AssetPaths.plist")
        #expect(await fake.catalog().image(forKind: "x.x", model: "004c:0001") == nil)
    }

    @Test("another maker's product ID is never looked up in Apple's list")
    func otherVendors() async {
        let fake = FakeSystem()
        fake.picture(at: index + "/Thing.png")
        fake.plist(["0x0322": ["ImageName": "Thing.png"]], at: index + "/AssetPaths.plist")
        #expect(await fake.catalog().image(forKind: "x.x", model: "046d:0322") == nil)
    }

    @Test("an entry cannot point outside its own folder or outside /System/Library")
    func entriesStayContained() async {
        let fake = FakeSystem()
        fake.picture(at: "/Users/someone/evil.png")
        fake.plist([
            "0x0001": ["ImageName": "../../../../Users/someone/evil.png"],
            "0x0002": ["ImageName": "evil.png", "Bundle": "/Users/someone"]
        ], at: index + "/AssetPaths.plist")
        let catalog = fake.catalog()
        #expect(await catalog.image(forKind: "x.x", model: "004c:0001") == nil)
        #expect(await catalog.image(forKind: "x.x", model: "004c:0002") == nil)
    }

    @Test("a model with no picture falls back to the kind's")
    func unknownModelFallsBack() async {
        let fake = FakeSystem()
        fake.picture(at: "/System/Library/Icons/generic.png")
        let catalog = fake.catalog(["k.k": ["/System/Library/Icons/generic.png"]])
        #expect(await catalog.image(forKind: "k.k", model: "004c:9999") != nil)
        #expect(await catalog.image(forKind: "k.k", model: "garbage") != nil)
    }

    @Test("no kind is both given a picture and listed as having none")
    func tableIsConsistent() {
        let given = Set(SystemIconCatalog.defaultTable.keys)
        #expect(given.isDisjoint(with: SystemIconCatalog.withoutSystemImage))
        for paths in SystemIconCatalog.defaultTable.values {
            #expect(!paths.isEmpty)
            #expect(paths.allSatisfy { $0.hasPrefix("/System/Library/") })
        }
    }
}

@Suite("SystemIconTable")
struct SystemIconTableTests {
    @Test("each module's stand-in picture is a kind the table can actually draw")
    func moduleKindsAreInTheTable() {
        for (module, kind) in SystemIconCatalog.moduleKinds {
            #expect(SystemIconCatalog.defaultTable[kind] != nil, "\(module) → \(kind)")
            #expect(kind.hasPrefix(module.lowercased() + "."), "\(module) → \(kind)")
        }
    }

    @Test("no Finder-sidebar template is offered: drawn untinted they vanish on a dark banner")
    func noSidebarTemplates() {
        for paths in SystemIconCatalog.defaultTable.values {
            #expect(!paths.contains { ($0 as NSString).lastPathComponent.hasPrefix("Sidebar") })
        }
    }
}
