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
            manufacturer: device.manufacturer.isEmpty ? nil : device.manufacturer,
            position: Self.describe(position: device.position),
            maxResolution: widest.map { "\($0.width) × \($0.height)" },
            maxFrameRate: fastest.map { String(format: "%.0f fps", $0) },
            isContinuityCamera: device.deviceType == .continuityCamera,
            isDeskViewCamera: device.deviceType == .deskViewCamera,
            isCenterStageActive: device.isCenterStageActive,
            isSystemPreferred: AVCaptureDevice.systemPreferredCamera?.uniqueID == device.uniqueID,
            linkedDevices: Self.describe(linked: device.linkedDevices)
        )
    }

    private static func describe(position: AVCaptureDevice.Position) -> String? {
        switch position {
        case .front: return "Front"
        case .back: return "Back"
        // The framework's own "no definite direction" — most external webcams. Saying
        // "Unspecified" would be dressing up a non-answer as an answer.
        case .unspecified: return nil
        @unknown default: return nil
        }
    }

    private static func describe(linked devices: [AVCaptureDevice]) -> String? {
        devices.isEmpty ? nil : devices.map(\.localizedName).sorted().joined(separator: ", ")
    }

    /// `transportType` is a `FourCharCode` shared with CoreAudio's transport constants.
    /// The USB and Bluetooth ones are absent on purpose: a camera on either of those is
    /// filtered out upstream, so it never reaches here to be described.
    private static func describe(transport: Int32) -> String? {
        // Compared as unsigned: the constants are `UInt32` four-character codes, and the
        // ones with the high bit set are negative when read back as `Int32`.
        switch UInt32(bitPattern: transport) {
        case kAudioDeviceTransportTypeBuiltIn: return "Built-in"
        case kAudioDeviceTransportTypeVirtual: return "Virtual"
        case kAudioDeviceTransportTypeContinuityCaptureWired,
             kAudioDeviceTransportTypeContinuityCaptureWireless: return "Continuity"
        case kAudioDeviceTransportTypeThunderbolt: return "Thunderbolt"
        case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
        case kAudioDeviceTransportTypePCI: return "PCI"
        case kAudioDeviceTransportTypeAirPlay: return "AirPlay"
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
