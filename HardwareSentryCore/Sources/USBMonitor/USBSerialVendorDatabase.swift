import Foundation

/// A lookup of USB vendor IDs known to make serial-bridge and debug-probe chips — FTDI,
/// Silicon Labs, WCH and the rest — none of which use a standard, informative USB-IF
/// class (see `USBDevice.isMeaningfullyIdentified`). Unlike every other classification in
/// this module, this one cannot be read off the device's own USB descriptor at all: a
/// vendor ID is just a number USB-IF assigned to whoever asked for one, and saying what a
/// given vendor actually makes requires a lookup table from somewhere outside the device.
///
/// A shared, synchronous, in-memory table (`@unchecked Sendable`, guarded by a lock) so
/// `USBDevice.kind`, a plain synchronous computed property, can consult it without
/// becoming async. Seeded at compile time with a fixed list of well-known vendors;
/// extendable without a new build of the application by `refresh()`, which merges in
/// `usb.ids` — the Linux USB ID Repository's own vendor list, community-maintained for
/// decades and mirrored at `updateURL` — run manually from Settings, or on a schedule
/// `MonitorTuningModel` controls.
///
/// Widens what "known vendor" means, on purpose, once `refresh()` has run: `usb.ids`
/// names every USB vendor USB-IF has ever assigned an ID to, not only the ones that make
/// serial/debug chips — this application still only ever *consults* it for a device whose
/// class byte already said nothing (`USBDevice.kind`'s own guard), so a printer or a
/// phone with an uninformative class byte and a name `usb.ids` happens to recognise can
/// now read as "Serial/Debug Adapter" too, same as this feature's original, narrower,
/// built-in list already did for FTDI and the rest. Accepted deliberately: a small,
/// hand-maintained list this application alone was responsible for keeping current was
/// judged worse than a much broader one somebody else already maintains.
public final class USBSerialVendorDatabase: @unchecked Sendable {
    public static let shared = USBSerialVendorDatabase()

    private let lock = NSLock()
    private var vendors: [UInt16: String]

    /// Well-known USB vendor IDs for serial-bridge and debug-probe chips, current as of
    /// 2026-09-06. Not exhaustive — there is no way for a fixed list ever to be, which is
    /// the entire reason `refresh()` exists — but wide enough to cover the common cases:
    /// generic USB-serial bridges (FTDI, Silicon Labs, Prolific, WCH, Microchip) and
    /// dedicated debug probes (SEGGER J-Link, ST-Link, Cypress/Infineon KitProg, TI's
    /// XDS/ICDI probes, NXP/mbed's DAPLink, Atmel/Microchip's AVR probes, Digilent's
    /// JTAG/Adept interfaces, Black Magic Probe, Espressif's native USB-CDC on newer
    /// ESP32 variants).
    static let builtIn: [UInt16: String] = [
        0x0403: "FTDI",
        0x10C4: "Silicon Labs",
        0x067B: "Prolific",
        0x1A86: "WCH (QinHeng Electronics)",
        0x04D8: "Microchip Technology",
        0x1366: "SEGGER",
        0x0483: "STMicroelectronics",
        0x04B4: "Cypress Semiconductor",
        0x1CBE: "Texas Instruments (ICDI/XDS)",
        0x0451: "Texas Instruments",
        0x1FC9: "NXP Semiconductors",
        0x0D28: "ARM mbed / NXP DAPLink",
        0x03EB: "Atmel/Microchip",
        0x1443: "Digilent",
        0x1D50: "OpenMoko shared pool (Black Magic Probe and others)",
        0x303A: "Espressif Systems",
        0x045B: "Renesas/Hitachi",
        0x058B: "Infineon Technologies"
    ]

    init() {
        vendors = Self.builtIn
        if let cached = Self.loadCache() {
            vendors.merge(cached) { _, new in new }
        }
    }

    public func isKnownVendor(_ vendorID: UInt16) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return vendors[vendorID] != nil
    }

    public var vendorCount: Int {
        lock.lock(); defer { lock.unlock() }
        return vendors.count
    }

    private func merge(_ additions: [UInt16: String]) {
        lock.lock(); defer { lock.unlock() }
        vendors.merge(additions) { _, new in new }
    }

    // MARK: - Updating

    private static var cacheURL: URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let ours = dir.appendingPathComponent("HardwareSentry", isDirectory: true)
        return ours.appendingPathComponent("usb.ids")
    }

    private static func loadCache() -> [UInt16: String]? {
        guard let url = cacheURL, let data = try? Data(contentsOf: url) else { return nil }
        return decode(data)
    }

    /// Parses `usb.ids`' own format: one vendor per line, `"XXXX  Vendor Name"` (four hex
    /// digits, two spaces, the name), comments starting with `#`, and every device- or
    /// interface-level sub-entry indented under a vendor with a leading tab — skipped
    /// here, since only the vendor's own name is wanted. `UInt16(_:radix:16)` already
    /// rejects anything that is not four hex digits, which is what quietly skips every
    /// non-vendor line (`#` comments, `C `/`AT `/... device-class section headers) without
    /// a separate check for each.
    static func decode(_ data: Data) -> [UInt16: String]? {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
        var result: [UInt16: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard !line.hasPrefix("#"), line.first != "\t", line.count > 6 else { continue }
            guard let vid = UInt16(line.prefix(4), radix: 16) else { continue }
            let name = line.dropFirst(4).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            result[vid] = name
        }
        return result
    }

    /// The Linux USB ID Repository's `usb.ids`, mirrored by Gentoo's `hwids` repository —
    /// community-maintained since long before this application existed, rather than a
    /// file this application alone would be responsible for keeping current. See this
    /// type's own doc comment for what that widens "known vendor" to mean once this has
    /// run at least once.
    public static let updateURL = URL(
        string: "https://raw.githubusercontent.com/gentoo/hwids/master/usb.ids"
    )!

    /// Downloads the latest known-vendor list and merges it in, in memory and on disk.
    /// Additive over the built-in list, never destructive: a network failure, a bad
    /// response, or an empty file all leave whatever was already known exactly as it was.
    @discardableResult
    public func refresh(from url: URL = USBSerialVendorDatabase.updateURL) async -> Bool {
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let parsed = Self.decode(data), !parsed.isEmpty
        else { return false }

        merge(parsed)

        if let cacheURL = Self.cacheURL {
            try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: cacheURL)
        }
        return true
    }
}
