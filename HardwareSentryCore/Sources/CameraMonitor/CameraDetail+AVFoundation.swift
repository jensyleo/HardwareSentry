import AVFoundation
import CoreMedia
import Foundation

/// Reads a camera that has just appeared for everything AVFoundation will answer about it.
///
/// Untested for the same reason `AVFoundationCameraSource` is: every branch needs a real
/// camera of a specific kind attached to a real Mac. What is worth reasoning about — which
/// lines appear, in what order, under which preferences — lives in `CameraMonitor` and is
/// tested there against a `CameraDetail` built by hand.
extension CameraDetail {
    init(device: AVCaptureDevice) {
        // Across every format the camera offers, not the one it is using right now: a
        // camera sitting idle usually reports a modest active format, which would read as
        // if that were all it could do.
        let dimensions = device.formats.map { CMVideoFormatDescriptionGetDimensions($0.formatDescription) }
        let widest = dimensions.max { ($0.width, $0.height) < ($1.width, $1.height) }
        let fastest = device.formats
            .flatMap(\.videoSupportedFrameRateRanges)
            .map(\.maxFrameRate)
            .max()

        self.init(
            transport: Self.describe(transport: device.transportType),
            vidPid: Self.vidPid(fromModelID: device.modelID),
            manufacturer: Self.manufacturer(device.manufacturer),
            position: Self.describe(position: device.position),
            maxResolution: widest.map { "\($0.width)x\($0.height)" },
            maxFrameRate: fastest.map { String(format: "%.0f fps", $0) },
            isContinuityCamera: device.deviceType == .continuityCamera,
            isDeskViewCamera: device.deviceType == .deskViewCamera,
            isCenterStageActive: device.isCenterStageActive,
            isSystemPreferred: AVCaptureDevice.systemPreferredCamera?.uniqueID == device.uniqueID,
            linkedDevices: Self.describe(linked: device.linkedDevices)
        )
    }

    /// AVFoundation's own placeholder for "no answer" is the word `Unknown`, not an empty
    /// string, so the emptiness check alone let it straight through: a real Logitech BRIO,
    /// read live 2026-09-07, announced itself as "Manufacturer: Unknown". That is the same
    /// "not really an answer" shape USB Monitor already refuses from USB-IF's own escape
    /// hatches, and it is worse than saying nothing — the maker is right there in the
    /// camera's name.
    static func manufacturer(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !placeholders.contains(trimmed.lowercased()) else { return nil }
        return trimmed
    }

    /// Matched whole, never as a prefix: a real company called "Unknown Devices Ltd" must
    /// still come through. `AudioMonitor` refuses the same phrases at its own read site —
    /// CoreAudio says "Unknown Manufacturer" where AVFoundation says "Unknown", and the
    /// same BRIO hits both. The list is repeated rather than shared because a monitor may
    /// only depend on `SentryContract`.
    private static let placeholders: Set<String> = [
        "unknown", "unknown manufacturer", "unknown model", "unknown device"
    ]

    /// The identifiers a USB camera hides in its model string.
    ///
    /// AVFoundation exposes no vendor/product property, but for a UVC camera `modelID`
    /// reads "UVC Camera VendorID_1133 ProductID_2142" — in decimal. Rendered here the way
    /// every specification sheet, and USB Monitor's own line, writes it: `046D:085E`.
    /// Nil unless both are present, which is every built-in camera.
    static func vidPid(fromModelID modelID: String) -> String? {
        func value(_ label: String) -> Int? {
            guard let range = modelID.range(of: "\(label)_") else { return nil }
            let digits = modelID[range.upperBound...].prefix { $0.isNumber }
            return digits.isEmpty ? nil : Int(digits)
        }
        guard let vendor = value("VendorID"), let product = value("ProductID"),
              vendor <= 0xFFFF, product <= 0xFFFF
        else { return nil }
        return String(format: "%04X:%04X", vendor, product)
    }

    private static func describe(position: AVCaptureDevice.Position) -> String? {
        switch position {
        case .front: return "Front"
        case .back: return "Back"
        // Named rather than dropped: for an external webcam this IS the answer, and
        // saying so is more use than a line that quietly vanishes.
        case .unspecified: return "Unspecified (typical for external webcams)"
        @unknown default: return nil
        }
    }

    private static func describe(linked devices: [AVCaptureDevice]) -> String? {
        devices.isEmpty ? nil : devices.map(\.localizedName).sorted().joined(separator: ", ")
    }

    /// `transportType` is a `FourCharCode` shared with CoreAudio's transport constants.
    ///
    /// Bluetooth is absent on purpose: a camera on it is filtered out upstream and never
    /// reaches here. USB was absent for the same reason until USB cameras started being
    /// announced in their own right — and nobody added the case when that changed, which
    /// is how a USB webcam ended up describing itself as "usb".
    ///
    /// Internal rather than private so a test can pin the spellings: the one that was
    /// missing here silently disabled a setting that compares against it.
    static func describe(transport: Int32) -> String? {
        // Compared as unsigned: the constants are `UInt32` four-character codes, and the
        // ones with the high bit set are negative when read back as `Int32`.
        switch UInt32(bitPattern: transport) {
        case kAudioDeviceTransportTypeBuiltIn: return "Built-in"
        case kAudioDeviceTransportTypeVirtual: return "Virtual"
        // Named explicitly, like every other transport here. Without this case a USB
        // webcam fell through to the four-character code and reported itself as "usb" —
        // lower case, unlike "Built-in" or "Thunderbolt" beside it, and, worse, not the
        // spelling `CameraMonitor` compares against when deciding whether USB cameras
        // should be announced independently. That switch silently did nothing.
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeContinuityCaptureWired,
             kAudioDeviceTransportTypeContinuityCaptureWireless: return "Continuity"
        case kAudioDeviceTransportTypeThunderbolt: return "Thunderbolt"
        case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
        case kAudioDeviceTransportTypePCI: return "PCI"
        case kAudioDeviceTransportTypeAirPlay: return "AirPlay/Continuity"
        case kAudioDeviceTransportTypeFireWire: return "FireWire"
        case kAudioDeviceTransportTypeUnknown: return nil
        // A transport nobody has named here: give back the four characters rather than
        // nothing, so an unfamiliar camera still says something recognisable.
        default: return Self.fourCharacterCode(transport)
        }
    }

    private static func fourCharacterCode(_ value: Int32) -> String? {
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> Int32($0)) }
        guard bytes.allSatisfy({ (0x20...0x7E).contains($0) }) else { return nil }
        return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces)
    }
}
