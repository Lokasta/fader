import CoreAudio
import Foundation
import os

/// Silences one app's original audio and replays it through the current output device at a chosen gain.
///
/// How it works: a Core Audio process tap (macOS 14.2+) captures the app's processes and, with
/// `mutedWhenTapped`, stops their sound from reaching the speakers directly. A private aggregate
/// device bundles that tap with the real output device, and an IO proc copies the tap's samples
/// to the output with our gain applied. No driver is installed; everything dies with this process.
final class AppTap {
    private(set) var processes: [AudioObjectID]
    let outputDeviceID: AudioObjectID

    private var tapID = AudioObjectID.unknown
    private var aggregateID = AudioObjectID.unknown
    private var ioProcID: AudioDeviceIOProcID?
    private var description: CATapDescription?
    private let context: RenderContext

    private static let log = Logger(subsystem: "com.lokasta.fader", category: "tap")

    var gain: Float {
        get { context.targetGain }
        set { context.targetGain = max(0, newValue) }
    }

    init(processes: [AudioObjectID], outputDevice: AudioObjectID, name: String, gain: Float) throws {
        self.processes = processes
        self.outputDeviceID = outputDevice

        guard let outputUID = AudioDevices.uid(of: outputDevice) else {
            throw CoreAudioError(status: kAudioHardwareBadDeviceError, context: "saída sem UID")
        }

        let stereo = AudioDevices.stereoChannels(of: outputDevice)
        context = RenderContext(
            inputBufferOffset: AudioDevices.streamCount(of: outputDevice, scope: kAudioObjectPropertyScopeInput),
            leftChannel: stereo.left,
            rightChannel: stereo.right
        )
        context.targetGain = gain

        do {
            try start(name: name, outputUID: outputUID)
        } catch {
            invalidate()
            throw error
        }
    }

    deinit { invalidate() }

    private func start(name: String, outputUID: String) throws {
        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.uuid = UUID()
        description.name = "Fader (\(name))"
        description.muteBehavior = .mutedWhenTapped
        description.isPrivate = true

        try check(AudioHardwareCreateProcessTap(description, &tapID), "criar tap")
        self.description = description

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Fader (\(name))",
            kAudioAggregateDeviceUIDKey: AudioDevices.ownAggregatePrefix + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "criar dispositivo agregado")

        let context = self.context
        try check(AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) { _, input, _, output, _ in
            context.render(input: input, output: output)
        }, "criar IO proc")

        disableDeviceInputs()
        try check(AudioDeviceStart(aggregateID, ioProcID), "iniciar áudio")
    }

    /// The aggregate also exposes the output device's own inputs (AirPods' mic, an interface's line in).
    /// Telling the HAL we don't read them keeps Bluetooth headsets out of low-quality call mode.
    private func disableDeviceInputs() {
        guard let ioProcID else { return }
        let total = AudioDevices.streamCount(of: aggregateID, scope: kAudioObjectPropertyScopeInput)
        guard context.inputBufferOffset > 0 else { return }
        setStreamUsage(device: aggregateID, procID: ioProcID, scope: kAudioObjectPropertyScopeInput,
                       enabled: (0..<total).map { $0 >= context.inputBufferOffset })
    }

    func takePeak() -> Float { context.takePeak() }

    /// Swaps the tapped process list in place (an app spawned or closed an audio helper),
    /// which avoids the audible gap of rebuilding the tap. Returns false if Core Audio refused.
    func update(processes newProcesses: [AudioObjectID]) -> Bool {
        guard let description, tapID.isValid else { return false }
        description.processes = newProcesses
        var address = propertyAddress(kAudioTapPropertyDescription)
        var reference: CATapDescription = description
        let status = withUnsafeMutablePointer(to: &reference) {
            AudioObjectSetPropertyData(tapID, &address, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), $0)
        }
        guard status == noErr else {
            Self.log.warning("in-place tap update refused: \(status)")
            return false
        }
        processes = newProcesses
        return true
    }

    func invalidate() {
        if aggregateID.isValid {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID.isValid { AudioHardwareDestroyProcessTap(tapID) }
        ioProcID = nil
        aggregateID = .unknown
        tapID = .unknown
    }
}
