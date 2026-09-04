import AVFoundation
import CoreAudio
import CoreMIDI
import Foundation

/// Watches CoreAudio for device list/default changes and mic-in-use state, and CoreMIDI
/// for MIDI device add/remove.
///
/// Deliberately thin and untested, for the same reason `IOKitUSBDeviceSource` is: none of
/// it can run without real audio hardware events. Everything worth reasoning about lives
/// in `AudioMonitor`, behind `AudioSource`.
///
/// Uses `AudioObjectPropertyListenerBlock` (not AVFoundation) — this is system-wide device
/// enumeration/defaults, squarely CoreAudio's domain; AVFoundation's device APIs are scoped
/// to what the current app/session can use, not "what's on the system", per HG4MAC's own
/// history.
public struct CoreAudioSource: AudioSource {
    public init() {}

    public func changes() -> AsyncStream<AudioSourceEvent> {
        AsyncStream { continuation in
            let watcher = Watcher(continuation: continuation)
            continuation.onTermination = { _ in watcher.stop() }
            watcher.start()
        }
    }
}

private let devicesAddress = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
)
private let defaultOutputAddress = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
)
private let defaultInputAddress = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
)
private let runningSomewhereAddress = AudioObjectPropertyAddress(
    mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
)

private final class Watcher: @unchecked Sendable {
    private let continuation: AsyncStream<AudioSourceEvent>.Continuation
    private var devicesBlock: AudioObjectPropertyListenerBlock?
    private var defaultOutputBlock: AudioObjectPropertyListenerBlock?
    private var defaultInputBlock: AudioObjectPropertyListenerBlock?
    private var micInUseBlock: AudioObjectPropertyListenerBlock?
    private var deviceIDsWithMicListener: Set<AudioDeviceID> = []
    private var midiClient = MIDIClientRef()

    init(continuation: AsyncStream<AudioSourceEvent>.Continuation) {
        self.continuation = continuation
    }

    func start() {
        Self.requestMicrophoneAccessIfNeeded()
        emitDevices()
        emitDefault(address: defaultOutputAddress, isOutput: true)
        emitDefault(address: defaultInputAddress, isOutput: false)
        emitMicRunning()

        let devicesBlock: AudioObjectPropertyListenerBlock = { [self] _, _ in
            self.emitDevices()
            self.updateMicListeners()
        }
        self.devicesBlock = devicesBlock
        var devicesAddr = devicesAddress
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &devicesAddr, DispatchQueue.main, devicesBlock)

        let outputBlock: AudioObjectPropertyListenerBlock = { [self] _, _ in self.emitDefault(address: defaultOutputAddress, isOutput: true) }
        self.defaultOutputBlock = outputBlock
        var outputAddr = defaultOutputAddress
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &outputAddr, DispatchQueue.main, outputBlock)

        let inputBlock: AudioObjectPropertyListenerBlock = { [self] _, _ in self.emitDefault(address: defaultInputAddress, isOutput: false) }
        self.defaultInputBlock = inputBlock
        var inputAddr = defaultInputAddress
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &inputAddr, DispatchQueue.main, inputBlock)

        let micBlock: AudioObjectPropertyListenerBlock = { [self] _, _ in self.emitMicRunning() }
        self.micInUseBlock = micBlock
        updateMicListeners()

        MIDIClientCreateWithBlock("com.jensyleo.hardwaresentry.midi" as CFString, &midiClient) { [self] notificationPtr in
            self.handleMIDINotification(notificationPtr)
        }
    }

    func stop() {
        var devicesAddr = devicesAddress
        var outputAddr = defaultOutputAddress
        var inputAddr = defaultInputAddress
        var runningAddr = runningSomewhereAddress
        if let devicesBlock { AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &devicesAddr, DispatchQueue.main, devicesBlock) }
        if let defaultOutputBlock { AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &outputAddr, DispatchQueue.main, defaultOutputBlock) }
        if let defaultInputBlock { AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &inputAddr, DispatchQueue.main, defaultInputBlock) }
        if let micInUseBlock {
            for id in deviceIDsWithMicListener {
                AudioObjectRemovePropertyListenerBlock(id, &runningAddr, DispatchQueue.main, micInUseBlock)
            }
        }
        if midiClient != 0 { MIDIClientDispose(midiClient) }
        continuation.finish()
    }

    /// Asks for microphone access, once, before the mic-in-use listener is armed.
    ///
    /// `kAudioDevicePropertyDeviceIsRunningSomewhere` is HAL metadata about the device —
    /// whether *some* process is using it — not audio content, and this monitor never
    /// opens a capture session of its own. It is not clear that macOS gates this property
    /// behind microphone TCC at all. What is clear, from the exact same class of bug this
    /// application already found and fixed once (`NSBluetoothAlwaysUsageDescription`,
    /// missing, aborting the process outright the moment `CBCentralManager` was
    /// instantiated): a permission surface silently required and never asked for is not a
    /// theoretical risk here, it is a repeat of a real one. Asking costs one dialog, at
    /// most once, ignorable; not asking risks the whole process again for the sake of one
    /// listener. `requestAccess` itself never blocks anything — the listener is armed
    /// either way, exactly as `SystemDelivery.present` never waits on its own permission
    /// dialog before presenting through the channel standing in for it.
    private static func requestMicrophoneAccessIfNeeded() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
    }

    // MARK: Devices

    private func emitDevices() {
        continuation.yield(.deviceSnapshot(Self.readDevices()))
    }

    private static func readDevices() -> [AudioDeviceSnapshot] {
        var address = devicesAddress
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }

        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.compactMap { snapshot(for: $0) }
    }

    private static func snapshot(for id: AudioDeviceID) -> AudioDeviceSnapshot? {
        guard let uid = stringProperty(id, kAudioDevicePropertyDeviceUID) else { return nil }
        let name = stringProperty(id, kAudioObjectPropertyName) ?? uid
        return AudioDeviceSnapshot(
            id: uid,
            name: name,
            transport: transport(for: id),
            isInputCapable: hasStreams(id, scope: kAudioDevicePropertyScopeInput),
            detail: detail(for: id, uid: uid)
        )
    }

    /// Everything the device will say about itself.
    ///
    /// Every read is best-effort: an aggregate device answers almost nothing, a virtual
    /// one answers differently again, and a line that cannot be filled is left out rather
    /// than filled with a placeholder.
    private static func detail(for id: AudioDeviceID, uid: String) -> AudioDeviceDetail {
        let rate = doubleProperty(id, kAudioDevicePropertyNominalSampleRate)
        return AudioDeviceDetail(
            outputChannels: channelCount(id, scope: kAudioDevicePropertyScopeOutput),
            inputChannels: channelCount(id, scope: kAudioDevicePropertyScopeInput),
            sampleRate: rate,
            sampleRateRange: sampleRateRange(id),
            uid: uid,
            modelUID: stringProperty(id, kAudioDevicePropertyModelUID),
            manufacturer: stringProperty(id, kAudioObjectPropertyManufacturer),
            clockSource: clockSourceName(id),
            isMuted: muteState(id),
            bitDepth: bitDepth(id),
            latencyFrames: uint32Property(id, kAudioDevicePropertyLatency).map(Int.init)
        )
    }

    private static func doubleProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func uint32Property(
        _ id: AudioDeviceID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    /// Channels are counted across the buffer list rather than read as one number: a
    /// device presents its channels as several buffers, and only their sum is the answer.
    private static func channelCount(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return nil }

        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return nil }

        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        let total = list.reduce(0) { $0 + Int($1.mNumberChannels) }
        return total > 0 ? total : nil
    }

    private static func sampleRateRange(_ id: AudioDeviceID) -> ClosedRange<Double>? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return nil }

        let count = Int(size) / MemoryLayout<AudioValueRange>.size
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: count)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &ranges) == noErr else { return nil }

        guard let lowest = ranges.map(\.mMinimum).min(),
              let highest = ranges.map(\.mMaximum).max(),
              lowest <= highest
        else { return nil }
        return lowest...highest
    }

    private static func muteState(_ id: AudioDeviceID) -> Bool? {
        uint32Property(id, kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput).map { $0 != 0 }
    }

    /// Read from the stream's physical format, which is what the hardware actually moves —
    /// the virtual format is always 32-bit float regardless of the device.
    private static func bitDepth(_ id: AudioDeviceID) -> Int? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioStreamPropertyPhysicalFormat,
            mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &format) == noErr else { return nil }
        return format.mBitsPerChannel > 0 ? Int(format.mBitsPerChannel) : nil
    }

    /// The clock source's name, looked up from its numeric ID.
    ///
    /// Devices with only one clock report the ID but often have no name list, so an
    /// unnamed source is left out rather than shown as a bare number nobody can use.
    private static func clockSourceName(_ id: AudioDeviceID) -> String? {
        guard let source = uint32Property(id, kAudioDevicePropertyClockSource) else { return nil }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyClockSourceNameForIDCFString,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        // The translation carries pointers to both sides, so both have to outlive the
        // call — hence the nested `withUnsafeMutablePointer` rather than inline `&`.
        var sourceID = source
        var name: CFString?
        var size = UInt32(MemoryLayout<AudioValueTranslation>.size)

        let succeeded = withUnsafeMutablePointer(to: &sourceID) { input in
            withUnsafeMutablePointer(to: &name) { output in
                var value = AudioValueTranslation(
                    mInputData: UnsafeMutableRawPointer(input),
                    mInputDataSize: UInt32(MemoryLayout<UInt32>.size),
                    mOutputData: UnsafeMutableRawPointer(output),
                    mOutputDataSize: UInt32(MemoryLayout<CFString?>.size)
                )
                return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr
            }
        }
        return succeeded ? name as String? : nil
    }

    private static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }

    private static func hasStreams(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr else { return false }
        return size > 0
    }

    private static func transport(for id: AudioDeviceID) -> AudioTransport {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var raw: UInt32 = 0
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &raw) == noErr else { return .other }

        switch raw {
        case kAudioDeviceTransportTypeUSB: return .usb
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return .bluetooth
        case kAudioDeviceTransportTypeBuiltIn: return .builtIn
        case kAudioDeviceTransportTypeHDMI: return .hdmi
        case kAudioDeviceTransportTypeDisplayPort: return .displayPort
        case kAudioDeviceTransportTypeThunderbolt: return .thunderbolt
        case kAudioDeviceTransportTypeAggregate: return .aggregate
        case kAudioDeviceTransportTypeAirPlay: return .airPlay
        case kAudioDeviceTransportTypePCI: return .pci
        case kAudioDeviceTransportTypeFireWire: return .fireWire
        case kAudioDeviceTransportTypeVirtual: return .virtual
        default: return .other
        }
    }

    // MARK: Defaults

    private func emitDefault(address: AudioObjectPropertyAddress, isOutput: Bool) {
        var address = address
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var id: AudioDeviceID = 0
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr else { return }
        guard let uid = Self.stringProperty(id, kAudioDevicePropertyDeviceUID) else { return }
        let name = Self.stringProperty(id, kAudioObjectPropertyName) ?? uid
        continuation.yield(isOutput ? .defaultOutputChanged(id: uid, name: name) : .defaultInputChanged(id: uid, name: name))
    }

    // MARK: Mic in use

    private func updateMicListeners() {
        guard let micInUseBlock else { return }
        let inputCapableIDs = Set(Self.allDeviceIDs().filter { Self.hasStreams($0, scope: kAudioDevicePropertyScopeInput) })

        var runningAddr = runningSomewhereAddress
        for id in inputCapableIDs.subtracting(deviceIDsWithMicListener) {
            AudioObjectAddPropertyListenerBlock(id, &runningAddr, DispatchQueue.main, micInUseBlock)
        }
        for id in deviceIDsWithMicListener.subtracting(inputCapableIDs) {
            AudioObjectRemovePropertyListenerBlock(id, &runningAddr, DispatchQueue.main, micInUseBlock)
        }
        deviceIDsWithMicListener = inputCapableIDs
        emitMicRunning()
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = devicesAddress
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private func emitMicRunning() {
        var running: [String: String] = [:]
        for id in deviceIDsWithMicListener {
            var address = runningSomewhereAddress
            var size = UInt32(MemoryLayout<UInt32>.size)
            var raw: UInt32 = 0
            guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &raw) == noErr, raw != 0 else { continue }
            guard let uid = Self.stringProperty(id, kAudioDevicePropertyDeviceUID) else { continue }
            running[uid] = Self.stringProperty(id, kAudioObjectPropertyName) ?? uid
        }
        continuation.yield(.micRunningSnapshot(running))
    }

    // MARK: MIDI

    private func handleMIDINotification(_ notificationPtr: UnsafePointer<MIDINotification>) {
        guard notificationPtr.pointee.messageID == .msgObjectAdded || notificationPtr.pointee.messageID == .msgObjectRemoved else { return }
        let added = notificationPtr.pointee.messageID == .msgObjectAdded

        notificationPtr.withMemoryRebound(to: MIDIObjectAddRemoveNotification.self, capacity: 1) { note in
            var name: Unmanaged<CFString>?
            let status = MIDIObjectGetStringProperty(note.pointee.child, kMIDIPropertyDisplayName, &name)
            let displayName = (status == noErr) ? (name?.takeRetainedValue() as String?) ?? "MIDI Device" : "MIDI Device"
            continuation.yield(added ? .midiDeviceAdded(name: displayName) : .midiDeviceRemoved(name: displayName))
        }
    }
}
