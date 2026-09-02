import Foundation

/// What a display could be described as when it arrived.
///
/// Read at connect and carried only on the connect notification. Everything here is a
/// fixed property of the panel — how big it is, what it can show, who made it — so
/// repeating it every time the resolution changed would be the same paragraph again.
/// The mode-change message stays about what moved.
public struct DisplayDetail: Sendable, Equatable {
    /// The display's stable identity, which survives a reboot and a re-plug. The numeric
    /// ID in the notification's subject does not.
    public let uuid: String?
    /// The panel's physical size in millimetres.
    public let widthMillimetres: Double?
    public let heightMillimetres: Double?
    /// The colour space macOS is driving it in — "Display P3", "sRGB IEC61966-2.1".
    public let colorSpaceName: String?
    public let isBuiltIn: Bool
    /// Which display this one is mirroring, when it is.
    public let mirrorSourceName: String?
    /// Vendor, model and serial as the display's own EDID reports them.
    public let vendorNumber: UInt32?
    public let modelNumber: UInt32?
    public let serialNumber: UInt32?
    /// The refresh range a variable-rate display will move between, in Hz.
    public let minimumRefreshHz: Double?
    public let maximumRefreshHz: Double?
    /// How much brighter than white this display can currently go — 1.0 means no headroom.
    public let currentEDRHeadroom: Double?
    /// How much it could go if the system allowed it.
    public let potentialEDRHeadroom: Double?
    /// A panel with a camera housing cut into it.
    public let hasNotch: Bool
    public let isStereo: Bool
    /// Points against pixels: 2.0 is a Retina display driven at HiDPI.
    public let backingScaleFactor: Double?
    /// The mode's own point size, for working out whether it is scaled.
    public let pointWidth: Int?
    public let pointHeight: Int?
    public let coversDisplayP3: Bool

    public init(
        uuid: String? = nil,
        widthMillimetres: Double? = nil,
        heightMillimetres: Double? = nil,
        colorSpaceName: String? = nil,
        isBuiltIn: Bool = false,
        mirrorSourceName: String? = nil,
        vendorNumber: UInt32? = nil,
        modelNumber: UInt32? = nil,
        serialNumber: UInt32? = nil,
        minimumRefreshHz: Double? = nil,
        maximumRefreshHz: Double? = nil,
        currentEDRHeadroom: Double? = nil,
        potentialEDRHeadroom: Double? = nil,
        hasNotch: Bool = false,
        isStereo: Bool = false,
        backingScaleFactor: Double? = nil,
        pointWidth: Int? = nil,
        pointHeight: Int? = nil,
        coversDisplayP3: Bool = false
    ) {
        self.uuid = uuid
        self.widthMillimetres = widthMillimetres
        self.heightMillimetres = heightMillimetres
        self.colorSpaceName = colorSpaceName
        self.isBuiltIn = isBuiltIn
        self.mirrorSourceName = mirrorSourceName
        self.vendorNumber = vendorNumber
        self.modelNumber = modelNumber
        self.serialNumber = serialNumber
        self.minimumRefreshHz = minimumRefreshHz
        self.maximumRefreshHz = maximumRefreshHz
        self.currentEDRHeadroom = currentEDRHeadroom
        self.potentialEDRHeadroom = potentialEDRHeadroom
        self.hasNotch = hasNotch
        self.isStereo = isStereo
        self.backingScaleFactor = backingScaleFactor
        self.pointWidth = pointWidth
        self.pointHeight = pointHeight
        self.coversDisplayP3 = coversDisplayP3
    }

    /// Inches on the diagonal, the way displays are actually sold, with the millimetres
    /// after it for anyone who wants to check.
    ///
    /// A projector and some capture devices report a size of zero, which would come out as
    /// a 0-inch display; those say nothing instead.
    var physicalSizeNote: String? {
        guard let widthMillimetres, let heightMillimetres,
              widthMillimetres > 0, heightMillimetres > 0
        else { return nil }

        let diagonalInches = (widthMillimetres * widthMillimetres + heightMillimetres * heightMillimetres).squareRoot() / 25.4
        return String(
            format: "%.1f-inch (%.0f × %.0f mm)",
            diagonalInches, widthMillimetres, heightMillimetres
        )
    }

    /// Pixels per inch, worked out from the physical size and the pixel count.
    ///
    /// Kept apart from the size rather than folded into it: the size answers "which
    /// monitor is this", and the density answers "will text look sharp on it".
    func densityNote(pixelWidth: Int, pixelHeight: Int) -> String? {
        guard let widthMillimetres, let heightMillimetres,
              widthMillimetres > 0, heightMillimetres > 0,
              pixelWidth > 0, pixelHeight > 0
        else { return nil }

        let diagonalPixels = Double(pixelWidth * pixelWidth + pixelHeight * pixelHeight).squareRoot()
        let diagonalInches = (widthMillimetres * widthMillimetres + heightMillimetres * heightMillimetres).squareRoot() / 25.4
        return String(format: "%.0f ppi", diagonalPixels / diagonalInches)
    }

    /// Present-only: telling somebody their external monitor is not built in is not news.
    var builtInNote: String? { isBuiltIn ? "Yes" : nil }
    var notchNote: String? { hasNotch ? "Yes — the menu bar wraps around it" : nil }
    var stereoNote: String? { isStereo ? "Yes — stereo (3D) display" : nil }
    var displayP3Note: String? { coversDisplayP3 ? "Covers Display P3" : nil }

    var mirrorNote: String? { mirrorSourceName.map { "Mirroring \($0)" } }

    /// Vendor, model and serial as one line. Printed in hex as well as decimal, because
    /// that is how a vendor ID appears in every specification sheet and every other tool.
    var identityNote: String? {
        var parts: [String] = []
        if let vendorNumber { parts.append(String(format: "Vendor 0x%04X", vendorNumber)) }
        if let modelNumber { parts.append(String(format: "Model 0x%04X", modelNumber)) }
        // A serial of zero is a display that does not publish one, not serial number zero.
        if let serialNumber, serialNumber != 0 { parts.append("Serial \(serialNumber)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The variable-refresh range, and only when it is actually a range.
    ///
    /// A fixed 60 Hz panel reports the same figure twice; saying "60–60 Hz" would dress a
    /// display with no variable refresh at all as if it had some.
    var refreshRangeNote: String? {
        guard let minimumRefreshHz, let maximumRefreshHz,
              minimumRefreshHz > 0, maximumRefreshHz > 0,
              minimumRefreshHz.rounded() != maximumRefreshHz.rounded()
        else { return nil }
        return "\(Int(minimumRefreshHz.rounded()))–\(Int(maximumRefreshHz.rounded())) Hz variable"
    }

    /// How far past white the display can go.
    ///
    /// A headroom of 1.0 is "none", which every ordinary display reports, so it is left
    /// unsaid. The potential figure is only added when it differs from the current one —
    /// which is the interesting case: the panel can do more than it is being allowed to.
    var edrNote: String? {
        guard let currentEDRHeadroom, currentEDRHeadroom > 1.01 else {
            guard let potentialEDRHeadroom, potentialEDRHeadroom > 1.01 else { return nil }
            return String(format: "None right now, up to %.1f× available", potentialEDRHeadroom)
        }
        guard let potentialEDRHeadroom, potentialEDRHeadroom > currentEDRHeadroom + 0.01 else {
            return String(format: "%.1f× brighter than white", currentEDRHeadroom)
        }
        return String(
            format: "%.1f× brighter than white (up to %.1f×)",
            currentEDRHeadroom, potentialEDRHeadroom
        )
    }

    /// Whether the picture is being scaled, and by how much.
    ///
    /// Two separate things are folded in here on purpose, because to anybody reading it
    /// they are one question — "is this display running at something other than its own
    /// resolution?". A 2× Retina panel at its native HiDPI mode is the ordinary case and
    /// says so briefly; a scaled mode, where the desktop is rendered at one size and
    /// resampled to another, is the case worth noticing, and is the one people go looking
    /// for when text looks soft.
    func scalingNote(pixelWidth: Int, pixelHeight: Int) -> String? {
        guard let pointWidth, let pointHeight, pointWidth > 0, pointHeight > 0,
              pixelWidth > 0, pixelHeight > 0
        else { return nil }

        let ratio = Double(pixelWidth) / Double(pointWidth)
        let scale = backingScaleFactor ?? ratio

        // The mode's own ratio against what the window server is actually drawing at: when
        // they disagree, the desktop is being resampled rather than drawn to fit.
        if abs(ratio - scale) > 0.01 {
            return String(format: "Scaled — %d × %d desktop on %d × %d pixels", pointWidth, pointHeight, pixelWidth, pixelHeight)
        }
        if scale > 1.01 { return String(format: "%.0f× (HiDPI)", scale) }
        return "1× (no scaling)"
    }
}
