import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import SystemIcons

@Suite("CustomIconLibrary")
struct CustomIconLibraryTests {
    private let base = FileManager.default.temporaryDirectory.appending(path: "CIL-\(UUID().uuidString)")
    private var library: CustomIconLibrary { CustomIconLibrary(directory: base.appending(path: "CustomIcons")) }

    private func picture(width: Int, named name: String = "pic.png") -> URL {
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let url = base.appending(path: name)
        let context = CGContext(data: nil, width: width, height: width, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let writer = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(writer, context.makeImage()!, nil)
        CGImageDestinationFinalize(writer)
        return url
    }

    private func width(at path: String) -> Int? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }
        return properties[kCGImagePropertyPixelWidth] as? Int
    }

    @Test("a chosen picture is copied in, shrunk, and survives the original being deleted")
    func importsACopy() throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let original = picture(width: 2000)
        let stored = try library.importImage(from: original)

        #expect(library.contains(path: stored))
        #expect(width(at: stored) == 512)
        try FileManager.default.removeItem(at: original)
        #expect(FileManager.default.fileExists(atPath: stored))
    }

    @Test("a small picture is kept at its own size, not blown up")
    func smallStaysSmall() throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let stored = try library.importImage(from: picture(width: 64))
        #expect(width(at: stored) == 64)
    }

    @Test("a file that is not a picture is refused, and nothing is left behind")
    func refusesNonImages() {
        defer { try? FileManager.default.removeItem(at: base) }
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let text = base.appending(path: "notes.png")
        FileManager.default.createFile(atPath: text.path, contents: Data("hello".utf8))
        #expect(throws: CustomIconLibrary.ImportError.notAnImage) { try library.importImage(from: text) }
        let left = (try? FileManager.default.contentsOfDirectory(atPath: library.directory.path)) ?? []
        #expect(left.isEmpty)
    }

    @Test("a missing file is refused")
    func refusesMissing() {
        #expect(throws: CustomIconLibrary.ImportError.notAnImage) {
            try library.importImage(from: base.appending(path: "nope.png"))
        }
    }

    @Test("copies nothing refers to are deleted; referenced ones and other folders are not")
    func cleansUp() throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let keep = try library.importImage(from: picture(width: 32, named: "a.png"))
        let drop = try library.importImage(from: picture(width: 32, named: "b.png"))
        let outside = picture(width: 32, named: "outside.png")

        library.removeUnreferenced(keeping: [keep, outside.path])

        #expect(FileManager.default.fileExists(atPath: keep))
        #expect(!FileManager.default.fileExists(atPath: drop))
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }

    @Test("a path outside the library is not one of its copies")
    func containsOnlyItsOwn() {
        #expect(!library.contains(path: "/Users/someone/Pictures/x.png"))
        #expect(!library.contains(path: library.directory.path + "/../x.png"))
        #expect(library.contains(path: library.directory.path + "/x.png"))
    }

    @Test("the standard folder is inside the application's own Application Support folder")
    func standardLocation() {
        let path = CustomIconLibrary.standard()?.directory.path ?? ""
        #expect(path.hasSuffix("/Library/Application Support/HardwareSentry/CustomIcons"))
    }
}
