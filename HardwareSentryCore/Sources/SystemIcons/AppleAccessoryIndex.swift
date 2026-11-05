import Foundation

/// macOS's own list of which picture belongs to which of Apple's accessories — a Magic
/// Keyboard, a Magic Mouse, AirPods, Beats — keyed by product ID.
///
/// Read from the property lists macOS keeps beside the pictures, never copied: the list
/// grows with every macOS release, and reading it is how a model this code has never heard
/// of still gets its own picture.
///
/// The format is undocumented. Everything is read defensively: an entry that does not have
/// the expected shape is skipped, and a missing directory is an empty index.
struct AppleAccessoryIndex {
    static let directory = "/System/Library/PrivateFrameworks/CoreBluetoothUI.framework/Versions/A/Resources"

    /// Apple's two vendor IDs: the Bluetooth SIG company identifier, and the USB one.
    static let appleVendors: Set<UInt16> = [0x004C, 0x05AC]

    private struct Entry {
        let imageName: String?
        let bundle: String?
        let clone: UInt16?
    }

    private let directory: String
    private var entries: [UInt16: Entry] = [:]

    init(directory: String) {
        self.directory = directory
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        // The main list first, then the per-family ones, which are more specific and so
        // win where both describe the same product.
        let lists = files.filter { $0.hasPrefix("AssetPaths") && $0.hasSuffix(".plist") }
            .sorted { ($0 == "AssetPaths.plist" ? 0 : 1, $0) < ($1 == "AssetPaths.plist" ? 0 : 1, $1) }
        for list in lists {
            guard let data = FileManager.default.contents(atPath: "\(directory)/\(list)"),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            else { continue }
            for (key, value) in plist {
                guard let productID = Self.hex(key), let fields = value as? [String: Any] else { continue }
                let entry = Entry(
                    imageName: fields["ImageName"] as? String,
                    bundle: fields["Bundle"] as? String,
                    clone: (fields["Clone"] as? String).flatMap(Self.hex)
                )
                guard entry.imageName != nil || entry.clone != nil else { continue }
                entries[productID] = entry
            }
        }
    }

    /// The picture for one model, given as `"vvvv:pppp"`. Nil for anything not Apple's,
    /// and for a model this Mac's list does not know.
    func imagePath(forModel model: String) -> String? {
        let parts = model.split(separator: ":")
        guard parts.count == 2,
              let vendor = UInt16(parts[0], radix: 16), Self.appleVendors.contains(vendor),
              var productID = UInt16(parts[1], radix: 16)
        else { return nil }

        // "Clone" points one model at another's picture. Followed a few steps at most, so
        // a list that points in a circle costs nothing.
        for _ in 0..<4 {
            guard let entry = entries[productID] else { return nil }
            if let name = entry.imageName, Self.isPlainFileName(name) {
                let folder = entry.bundle.map { "\($0)/Contents/Resources" } ?? directory
                return "\(folder)/\(name)"
            }
            guard let next = entry.clone else { return nil }
            productID = next
        }
        return nil
    }

    /// A file name with no path in it, so an entry cannot reach outside its own folder.
    private static func isPlainFileName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && name != "." && name != ".."
    }

    private static func hex(_ text: String) -> UInt16? {
        let digits = text.hasPrefix("0x") || text.hasPrefix("0X") ? String(text.dropFirst(2)) : text
        return UInt16(digits, radix: 16)
    }
}
