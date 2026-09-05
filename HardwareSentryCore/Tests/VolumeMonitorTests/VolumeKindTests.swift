import Foundation
import Testing
@testable import VolumeMonitor

@Suite("VolumeKind")
struct VolumeKindTests {
    private func infer(_ proto: String? = nil, _ media: String? = nil, _ mediaKind: String? = nil, _ size: UInt64? = nil, isInternal: Bool = false) -> VolumeKind? {
        VolumeKind.infer(protocolName: proto, mediaName: media, mediaKind: mediaKind, sizeBytes: size, isInternal: isInternal)
    }

    @Test("internal storage is never guessed external, however large it reports itself")
    func internalStorageIsNeverGuessedExternal() {
        // Confirmed live in this application's own notification history: every APFS
        // sibling of the boot container ("Preboot", "VM", "Update", "xarts", "Hardware")
        // reports the SAME size as the container as a whole — on this Mac, comfortably
        // over the 400 GB threshold below — and arrived as "External Disk Mounted" until
        // this was fixed. HG4MAC hit and fixed the identical bug on 23-jul-2026.
        let containerSize: UInt64 = 494_384_795_648 // this Mac's actual container size
        #expect(infer(nil, nil, nil, containerSize) == .externalDisk)
        #expect(infer(nil, nil, nil, containerSize, isInternal: true) == nil)

        // Internal storage is excluded unconditionally, ahead of every other signal —
        // matching HG4MAC's own ordering — not merely exempted from the size guess.
        #expect(infer("USB", "External HDD", nil, nil, isInternal: true) == nil)
        #expect(infer(nil, "Secure Digital", nil, nil, isInternal: true) == nil)
    }

    @Test("optical media and network shares are read from standard fields, not guessed")
    func unambiguousSignals() {
        #expect(infer(nil, nil, "DVD-ROM") == .optical)
        #expect(infer(nil, nil, "Blu-ray Disc") == .optical)
        #expect(infer("SMB") == .nas)
        #expect(infer("AFP") == .nas)
        #expect(infer("Secure Digital") == .sdCard)
    }

    @Test("microSD is recognised as an SD card too, by name, old branding included")
    func microSDIsStillAnSDCard() {
        // microSDXC/microSDHC already match the plain "sdxc"/"sdhc" tokens as substrings;
        // these are the ones that would not: a bare "microSD" with no capacity suffix, and
        // "TransFlash", the format's own original name before the SD Association renamed
        // it — some readers and cards still print it.
        #expect(infer("USB", "Generic MicroSD Card Reader") == .sdCard)
        #expect(infer("USB", "Kingston Micro SD") == .sdCard)
        #expect(infer("USB", "TransFlash Card") == .sdCard)
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
