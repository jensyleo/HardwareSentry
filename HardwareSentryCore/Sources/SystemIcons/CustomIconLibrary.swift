import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Keeps a private copy of every picture somebody chooses as an icon.
///
/// A copy rather than a pointer to their file, so the icon survives the original being
/// moved, renamed or deleted — which is what somebody tidying their Downloads folder does
/// without a thought for which of those files a notification was using.
///
/// Each copy is re-encoded as a PNG no larger than `maximumPixelSize`: whatever was chosen
/// — a 40-megapixel photo, a HEIC, a PDF — what is kept is small, in one format, and has
/// been proven to decode once already.
///
/// Everything lives in one folder inside the application's own Application Support
/// folder, so removing the application removes these with it.
public struct CustomIconLibrary: Sendable {
    public let directory: URL
    let maximumPixelSize: Int
    /// Anything bigger is not an icon somebody meant to choose.
    static let maximumFileSize = 50 * 1024 * 1024

    public init(directory: URL, maximumPixelSize: Int = 512) {
        self.directory = directory.standardizedFileURL
        self.maximumPixelSize = maximumPixelSize
    }

    /// The application's own: `~/Library/Application Support/HardwareSentry/CustomIcons`.
    public static func standard() -> CustomIconLibrary? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ) else { return nil }
        return CustomIconLibrary(directory: base.appending(path: "HardwareSentry/CustomIcons"))
    }

    public enum ImportError: LocalizedError, Equatable {
        case tooLarge
        case notAnImage
        case couldNotSave

        public var errorDescription: String? {
            switch self {
            case .tooLarge: "That file is too large to use as an icon."
            case .notAnImage: "That file is not a picture HardwareSentry can read."
            case .couldNotSave: "The picture could not be saved."
            }
        }
    }

    /// Copies a picture in and returns the path of the copy, to be stored as the choice.
    public func importImage(from source: URL) throws -> String {
        let size = (try? source.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size <= Self.maximumFileSize else { throw ImportError.tooLarge }
        guard size > 0, let image = Self.decode(source, maximumPixelSize: maximumPixelSize) else {
            throw ImportError.notAnImage
        }

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appending(path: "\(UUID().uuidString).png")
        guard let writer = CGImageDestinationCreateWithURL(destination as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ImportError.couldNotSave
        }
        CGImageDestinationAddImage(writer, image, nil)
        guard CGImageDestinationFinalize(writer) else { throw ImportError.couldNotSave }
        return destination.path
    }

    /// Whether a stored path is one of this library's own copies.
    public func contains(path: String) -> Bool {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        return url.deletingLastPathComponent().path == directory.path
    }

    /// Deletes every copy nothing refers to any more — the one an icon used before it was
    /// changed or reset. Only ever touches this library's own folder.
    public func removeUnreferenced(keeping referenced: Set<String>) {
        let kept = Set(referenced.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        for file in files where file.pathExtension == "png" && !kept.contains(file.standardizedFileURL.path) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private static func decode(_ url: URL, maximumPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
