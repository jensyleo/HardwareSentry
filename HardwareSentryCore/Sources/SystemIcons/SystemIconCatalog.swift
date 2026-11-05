import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Finds the operating system's own picture of a device, for someone who would rather see
/// that than this application's artwork.
///
/// Nothing here is shipped with the application: every picture is read, at run time, from
/// the copy of macOS it is running on. That keeps Apple's artwork out of this project
/// entirely, and it is also why every answer is optional. The files live in places Apple
/// has never documented and is free to move, so a picture that is missing, unreadable or
/// not a picture at all is a `nil` — the caller falls back to the application's own icon —
/// and never an error, a crash or a stall.
///
/// An actor because it caches: a rendered icon costs a file read and a resize, and the same
/// keyboard reconnecting all afternoon should cost that once.
public actor SystemIconCatalog {
    /// Kind (`"usb.keyboard"`) to candidate files, best first. The first that loads wins.
    private let table: [String: [String]]
    /// Prefixed to every path, so a test can point the catalogue at a folder of its own.
    /// Empty in the application.
    private let root: String
    private let pixelSize: Int

    private var renderedByPath: [String: Data?] = [:]
    private var accessoryIndex: AppleAccessoryIndex?

    public init(table: [String: [String]] = SystemIconCatalog.defaultTable, root: String = "", pixelSize: Int = 256) {
        self.table = table
        self.root = root
        self.pixelSize = pixelSize
    }

    /// The operating system's picture for this kind of device, as PNG data — or, given the
    /// device's own model, the picture of that exact model when macOS has one.
    ///
    /// `model` is `"vvvv:pppp"`, vendor and product ID in hex; see `DeviceIconModel`.
    public func image(forKind kind: String, model: String? = nil) -> Data? {
        if let model, let path = accessoryIndex(model: model), let data = rendered(path) {
            return data
        }
        for path in table[kind] ?? [] {
            if let data = rendered(path) { return data }
        }
        return nil
    }

    /// Whether this kind has a picture on this Mac at all — for a settings screen that
    /// wants to say "not available" rather than offer a choice that will not take.
    public func hasImage(forKind kind: String) -> Bool {
        image(forKind: kind) != nil
    }

    // MARK: - Exact models

    private func accessoryIndex(model: String) -> String? {
        if accessoryIndex == nil {
            accessoryIndex = AppleAccessoryIndex(directory: root + AppleAccessoryIndex.directory)
        }
        guard let path = accessoryIndex?.imagePath(forModel: model) else { return nil }
        // The index names its own files; strip the test root back off so `rendered` can
        // treat every path the same way.
        return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path
    }

    // MARK: - Loading

    /// Reads and shrinks one file, remembering the answer either way: a file that failed
    /// once will fail again, and there is no point paying for that on every notification.
    private func rendered(_ path: String) -> Data? {
        if let cached = renderedByPath[path] { return cached }
        let data = Self.render(atPath: root + path, pixelSize: pixelSize, allowedPrefix: root + "/System/Library/")
        renderedByPath[path] = data
        return data
    }

    /// The largest picture in the file, scaled to fit `pixelSize` and written out as PNG.
    ///
    /// Only files under `/System/Library` are read. The accessory index names files by
    /// itself, and following it anywhere else would make a property list into a way to
    /// get this application to open arbitrary files.
    static func render(atPath path: String, pixelSize: Int, allowedPrefix: String) -> Data? {
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(allowedPrefix) || url.path.hasPrefix("/private" + allowedPrefix) else { return nil }

        // An icon file is a few megabytes at most; anything far larger is not one.
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
              size > 0, size < 32 * 1024 * 1024
        else { return nil }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }

        // An `.icns` holds the same picture at several sizes; start from the biggest so the
        // shrink is the only resampling it goes through.
        var best = 0
        var bestWidth = 0
        for index in 0..<count {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
            if width > bestWidth { best = index; bestWidth = width }
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: pixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, best, options as CFDictionary) else { return nil }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
