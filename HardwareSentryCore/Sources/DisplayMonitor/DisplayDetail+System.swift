import AppKit
import CoreGraphics
import Foundation

/// Reads a display that has just appeared for everything CoreGraphics and AppKit will
/// answer about it.
///
/// Untested for the same reason `CoreGraphicsDisplaySource` is: every branch needs a real
/// panel of a specific kind attached to a real Mac. What is worth reasoning about — which
/// lines appear, in what order, under which preferences, and how millimetres and pixels
/// become an inch measurement and a ppi figure — lives in `DisplayDetail` and
/// `DisplayMonitor`, and is tested there.
extension DisplayDetail {
    init(id: CGDirectDisplayID, screen: NSScreen?, mode: CGDisplayMode?, nameOfDisplay: (CGDirectDisplayID) -> String?) {
        let size = CGDisplayScreenSize(id)

        // Zero is CoreGraphics declining to answer, which is what a mirror target and some
        // capture devices report — kept as nil so a 0-inch display is never described.
        let mirrorSource = CGDisplayMirrorsDisplay(id)

        // `maximumRefreshInterval` is the LONGEST frame the display will hold, so it is the
        // LOWEST rate; the two swap round when they become Hz. Read the other way, every
        // variable-refresh panel would report its range backwards.
        let slowestInterval = screen.map { Double($0.maximumRefreshInterval) }
        let fastestInterval = screen.map { Double($0.minimumRefreshInterval) }

        self.init(
            uuid: Self.uuid(of: id),
            widthMillimetres: size.width > 0 ? size.width : nil,
            heightMillimetres: size.height > 0 ? size.height : nil,
            colorSpaceName: screen?.colorSpace?.localizedName,
            isBuiltIn: CGDisplayIsBuiltin(id) != 0,
            mirrorSourceName: mirrorSource != kCGNullDirectDisplay ? nameOfDisplay(mirrorSource) : nil,
            vendorNumber: CGDisplayVendorNumber(id),
            modelNumber: CGDisplayModelNumber(id),
            serialNumber: CGDisplaySerialNumber(id),
            minimumRefreshHz: slowestInterval.flatMap { $0 > 0 ? 1 / $0 : nil },
            maximumRefreshHz: fastestInterval.flatMap { $0 > 0 ? 1 / $0 : nil },
            currentEDRHeadroom: screen.map { Double($0.maximumExtendedDynamicRangeColorComponentValue) },
            potentialEDRHeadroom: screen.map { Double($0.maximumPotentialExtendedDynamicRangeColorComponentValue) },
            // A notch is not exposed as a flag anywhere; the inset the menu bar leaves for
            // it is the only signal macOS gives, and it is only non-zero on a panel that
            // has one.
            hasNotch: (screen?.safeAreaInsets.top ?? 0) > 0,
            isStereo: CGDisplayIsStereo(id) != 0,
            backingScaleFactor: screen.map { Double($0.backingScaleFactor) },
            pointWidth: mode.map { $0.width },
            pointHeight: mode.map { $0.height },
            coversDisplayP3: screen?.canRepresent(.p3) ?? false
        )
    }

    /// The identity that survives a reboot, a re-plug and a change of port.
    ///
    /// Worth having because the numeric display ID does not: macOS hands out a fresh one
    /// each session, so it cannot be used to recognise "that monitor" across launches.
    private static func uuid(of id: CGDirectDisplayID) -> String? {
        guard let reference = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, reference) as String?
    }
}
