import Foundation
import Testing
@testable import VolumeMonitor

@Suite("VolumeKind")
struct VolumeKindTests {
    private func infer(_ proto: String? = nil, _ media: String? = nil, _ mediaKind: String? = nil, _ size: UInt64? = nil) -> VolumeKind? {
        VolumeKind.infer(protocolName: proto, mediaName: media, mediaKind: mediaKind, sizeBytes: size)
    }

    @Test("optical media and network shares are read from standard fields, not guessed")
    func unambiguousSignals() {
        #expect(infer(nil, nil, "DVD-ROM") == .optical)
        #expect(infer(nil, nil, "Blu-ray Disc") == .optical)
        #expect(infer("SMB") == .nas)
        #expect(infer("AFP") == .nas)
        #expect(infer("Secure Digital") == .sdCard)
    }

    @Test("an explicit name beats the size guess, so a large flash drive is not filed as an enclosure")
    func nameWinsOverSize() {
        // 1 TB flash drives are a real product. Deciding on size alone would misfile one.
        let oneTerabyte: UInt64 = 1024 * 1024 * 1024 * 1024
        #expect(infer("USB", "SanDisk Extreme USB Flash Drive", nil, oneTerabyte) == .usbDrive)
        #expect(infer("USB", "Samsung Portable SSD", nil, oneTerabyte) == .externalDisk)
    }

    @Test("size is the last resort, only for storage that named itself nothing useful")
    func sizeIsALastResort() {
        let bigAnonymous: UInt64 = 500 * 1024 * 1024 * 1024
        #expect(infer("USB", "STORAGE DEVICE", nil, bigAnonymous) == .externalDisk)
    }

    /// The exact case that made HG4MAC revert its "plain USB under the threshold is a
    /// pendrive" fallback: an SD card in a reader that identifies itself as nothing in
    /// particular. Guessing here is what broke it, so the honest answer is no answer.
    @Test("unidentifiable USB storage gets no specific kind rather than a confident wrong one")
    func unidentifiableStorageStaysGeneric() {
        let sixtyFourGB: UInt64 = 64 * 1024 * 1024 * 1024
        #expect(infer("USB", "STORAGE DEVICE", nil, sixtyFourGB) == nil)
        #expect(infer("USB", nil, nil, nil) == nil)
        #expect(infer() == nil)
    }

    @Test("every kind knows its artwork")
    func everyKindHasArtwork() {
        #expect(VolumeKind.allCases.allSatisfy { $0.iconBaseName.hasPrefix("Device-") })
    }
}
