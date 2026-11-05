import CoreGraphics
import Foundation
import ImageIO
import SignalCore
import Testing
import UniformTypeIdentifiers
@testable import SystemIcons

private func freshDefaults() -> UserDefaults {
    let name = "IconSourceTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

@Suite("IconSourceStore")
@MainActor
struct IconSourceStoreTests {
    @Test("every module starts on macOS's own pictures")
    func defaultsToSystem() {
        let store = IconSourceStore(defaults: freshDefaults())
        #expect(IconSource.default == .system)
        #expect(store.source(for: "USB") == .system)
    }

    @Test("a choice survives a relaunch")
    func roundTrip() {
        let defaults = freshDefaults()
        IconSourceStore(defaults: defaults).setSource(.app, for: "Bluetooth")
        let reloaded = IconSourceStore(defaults: defaults)
        #expect(reloaded.source(for: "Bluetooth") == .app)
        #expect(reloaded.source(for: "USB") == .system)
    }

    @Test("going back to the default removes the key rather than writing it")
    func appRemovesKey() {
        let defaults = freshDefaults()
        let store = IconSourceStore(defaults: defaults, keyPrefix: "P")
        store.setSource(.app, for: "USB")
        #expect(defaults.string(forKey: "P.USB") == "app")
        store.setSource(.system, for: "USB")
        #expect(defaults.object(forKey: "P.USB") == nil)
    }

    @Test("a value nobody understands is no choice at all")
    func garbageIsIgnored() {
        let defaults = freshDefaults()
        defaults.set("sparkly", forKey: "P.USB")
        defaults.set(42, forKey: "P.Audio")
        let store = IconSourceStore(defaults: defaults, keyPrefix: "P")
        #expect(store.source(for: "USB") == .default)
        #expect(store.source(for: "Audio") == .default)
    }

    @Test("reset puts every module back and moves the revision on")
    func reset() {
        let defaults = freshDefaults()
        let store = IconSourceStore(defaults: defaults, keyPrefix: "P")
        store.setSource(.app, for: "USB")
        let before = store.revision
        store.resetAll()
        #expect(store.source(for: "USB") == .default)
        #expect(defaults.object(forKey: "P.USB") == nil)
        #expect(store.revision > before)
    }
}

@Suite("SystemIconMiddleware")
struct SystemIconMiddlewareTests {
    private static let appIcon = NotificationIcon.imageData(Data([1, 2, 3]))

    /// A catalogue with exactly one picture, for "usb.keyboard".
    private static func catalog() -> (SystemIconCatalog, root: String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SIM-\(UUID().uuidString)").path
        let path = "/System/Library/Icons/keyboard.png"
        try! FileManager.default.createDirectory(atPath: root + "/System/Library/Icons", withIntermediateDirectories: true)
        let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: root + path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return (SystemIconCatalog(table: ["usb.keyboard": [path]], root: root), root)
    }

    private func event(kind: String?, category: NotificationCategory = "USB", name: String = "USBConnectedKeyboard") -> NotificationEvent {
        NotificationEvent(name: name, category: category, title: "t", body: "b", icon: Self.appIcon, iconKind: kind)
    }

    private func run(_ middleware: some NotificationMiddleware, _ event: NotificationEvent) async -> NotificationEvent? {
        guard case .deliver(let out) = await middleware.process(event, context: DispatchContext(phase: .steady, firedAt: Date())) else { return nil }
        return out
    }

    @Test("a module on .system gets the operating system's picture")
    func swapsOnSystem() async {
        let (catalog, root) = Self.catalog()
        defer { try? FileManager.default.removeItem(atPath: root) }
        var choices = IconSourceChoices()
        choices["USB"] = .system
        let out = await run(SystemIconMiddleware(choices: choices, catalog: catalog), event(kind: "usb.keyboard"))
        #expect(out != nil)
        #expect(out?.icon != Self.appIcon)
        #expect(out?.showsIconBadge == true)
    }

    @Test("a module switched to .app is left exactly as it was")
    func leavesAppAlone() async {
        let (catalog, root) = Self.catalog()
        defer { try? FileManager.default.removeItem(atPath: root) }
        var choices = IconSourceChoices()
        choices["USB"] = .app
        let out = await run(SystemIconMiddleware(choices: choices, catalog: catalog), event(kind: "usb.keyboard"))
        #expect(out?.icon == Self.appIcon)
        #expect(out?.showsIconBadge == false)
    }

    @Test("an icon of an idea, or a device macOS has no picture of, keeps the app's")
    func noKindOrNoPicture() async {
        let (catalog, root) = Self.catalog()
        defer { try? FileManager.default.removeItem(atPath: root) }
        var choices = IconSourceChoices()
        choices["USB"] = .system
        let middleware = SystemIconMiddleware(choices: choices, catalog: catalog)
        #expect(await run(middleware, event(kind: nil))?.icon == Self.appIcon)
        #expect(await run(middleware, event(kind: "usb.hub"))?.icon == Self.appIcon)
    }

    @Test("the choice is per module: one switched to .app is untouched while the rest stay on System")
    func perModule() async {
        let (catalog, root) = Self.catalog()
        defer { try? FileManager.default.removeItem(atPath: root) }
        var choices = IconSourceChoices()
        choices["USB"] = .app
        let out = await run(SystemIconMiddleware(choices: choices, catalog: catalog), event(kind: "usb.keyboard"))
        #expect(out?.icon == Self.appIcon)
        #expect(choices["Bluetooth"] == .system)
    }

    @Test("an update takes effect for the next notification")
    func update() async {
        let (catalog, root) = Self.catalog()
        defer { try? FileManager.default.removeItem(atPath: root) }
        var appOnly = IconSourceChoices()
        appOnly["USB"] = .app
        let middleware = SystemIconMiddleware(choices: appOnly, catalog: catalog)
        #expect(await run(middleware, event(kind: "usb.keyboard"))?.icon == Self.appIcon)
        await middleware.update(IconSourceChoices())
        #expect(await run(middleware, event(kind: "usb.keyboard"))?.icon != Self.appIcon)
    }

    @Test("a picture chosen by hand for one event beats the module's System setting")
    func customWins() async {
        let (catalog, root) = Self.catalog()
        defer { try? FileManager.default.removeItem(atPath: root) }
        var choices = IconSourceChoices()
        choices["USB"] = .system
        var overrides = IconOverrides()
        overrides["USBConnectedKeyboard", in: "USB"] = .symbol("star")

        // The order the application assembles them in: hand-picked first, System second.
        let afterCustom = await run(IconOverrideMiddleware(overrides: overrides), event(kind: "usb.keyboard"))!
        let afterSystem = await run(SystemIconMiddleware(choices: choices, catalog: catalog), afterCustom)
        #expect(afterSystem?.icon == .symbol("star"))
    }

    @Test("keeping the app's icon for one notification beats the module's System setting")
    func originalWins() async {
        let (catalog, root) = Self.catalog()
        defer { try? FileManager.default.removeItem(atPath: root) }
        var overrides = IconOverrides()
        overrides["USBConnectedKeyboard", in: "USB"] = .original

        let afterCustom = await run(IconOverrideMiddleware(overrides: overrides), event(kind: "usb.keyboard"))!
        let afterSystem = await run(SystemIconMiddleware(catalog: catalog), afterCustom)
        #expect(afterSystem?.icon == Self.appIcon)
        #expect(afterSystem?.showsIconBadge == false)

        // And a notification nobody chose for still gets macOS's picture.
        let untouched = await run(SystemIconMiddleware(catalog: catalog),
                                  await run(IconOverrideMiddleware(overrides: overrides), event(kind: "usb.keyboard", name: "Other"))!)
        #expect(untouched?.icon != Self.appIcon)
    }
}
