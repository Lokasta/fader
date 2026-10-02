import CoreAudio
import Foundation
import os

/// Level metering for every app that isn't being mixed, through ONE aggregate device.
///
/// A tap per app plus an aggregate per app costs one HAL IO thread each: with 20 apps that was
/// ~23% CPU here and ~12% in coreaudiod. Here all meter taps (unmuted, audio untouched) share a
/// single aggregate and IO proc, which reads each tap's input buffer into its own `PeakBox`.
/// Rebuilding it is silent, because meter taps never change what you hear.
final class MeterHub {
    struct Source: Equatable {
        let key: String
        let processes: [AudioObjectID]
    }

    private var sources: [Source] = []
    private var outputDevice = AudioObjectID.unknown
    private var taps: [AudioObjectID] = []
    private var aggregateID = AudioObjectID.unknown
    private var ioProcID: AudioDeviceIOProcID?
    private var peaks: [String: PeakBox] = [:]
    private let log = Logger(subsystem: "com.lokasta.fader", category: "meters")

    /// Rebuilds only when the set of metered apps, their processes or the output device changed.
    func update(_ next: [Source], outputDevice device: AudioObjectID) {
        guard next != sources || device != outputDevice else { return }
        stop()
        sources = next
        outputDevice = device
        guard !next.isEmpty, device.isValid else { return }
        do {
            try start()
        } catch {
            log.error("meter hub failed: \(String(describing: error), privacy: .public)")
            stop()
            sources = next // don't retry every refresh until something changes
        }
    }

    func takePeaks() -> [String: Float] {
        peaks.mapValues { $0.take() }
    }

    func stop() {
        if aggregateID.isValid {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        for tap in taps { AudioHardwareDestroyProcessTap(tap) }
        taps = []
        ioProcID = nil
        aggregateID = .unknown
        peaks = [:]
        sources = []
    }

    private func start() throws {
        guard let outputUID = AudioDevices.uid(of: outputDevice) else {
            throw CoreAudioError(status: kAudioHardwareBadDeviceError, context: "output device has no UID")
        }

        var tapList: [[String: Any]] = []
        var boxes: [PeakBox] = []
        for source in sources {
            let description = CATapDescription(stereoMixdownOfProcesses: source.processes)
            description.uuid = UUID()
            description.muteBehavior = .unmuted
            description.isPrivate = true
            var tapID = AudioObjectID.unknown
            try check(AudioHardwareCreateProcessTap(description, &tapID), "create meter tap")
            taps.append(tapID)
            tapList.append([kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true])
            let box = PeakBox()
            boxes.append(box)
            peaks[source.key] = box
        }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Fader (meters)",
            kAudioAggregateDeviceUIDKey: AudioDevices.ownAggregatePrefix + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: tapList,
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "create meter aggregate")

        // Input streams are the output device's own inputs first, then one per tap, in tap-list order.
        let deviceInputs = AudioDevices.streamCount(of: outputDevice, scope: kAudioObjectPropertyScopeInput)
        let totalInputs = AudioDevices.streamCount(of: aggregateID, scope: kAudioObjectPropertyScopeInput)
        guard totalInputs == deviceInputs + boxes.count else {
            throw CoreAudioError(status: kAudioHardwareUnspecifiedError, context: "unexpected layout: \(totalInputs) streams for \(boxes.count) taps")
        }

        try check(AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) { _, input, _, output, _ in
            let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            for (index, box) in boxes.enumerated() {
                box.raise(to: GainRenderer.peak(of: inputs, firstBuffer: deviceInputs + index, count: 1))
            }
            for buffer in UnsafeMutableAudioBufferListPointer(output) {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
        }, "create meter IO proc")

        if let ioProcID {
            // Read only the taps: never the device's own inputs (a headset mic) and write no output.
            setStreamUsage(device: aggregateID, procID: ioProcID, scope: kAudioObjectPropertyScopeInput,
                           enabled: (0..<totalInputs).map { $0 >= deviceInputs })
            let outputs = AudioDevices.streamCount(of: aggregateID, scope: kAudioObjectPropertyScopeOutput)
            setStreamUsage(device: aggregateID, procID: ioProcID, scope: kAudioObjectPropertyScopeOutput,
                           enabled: Array(repeating: false, count: outputs))
        }
        try check(AudioDeviceStart(aggregateID, ioProcID), "start meters")
        log.info("metering \(boxes.count) apps through one aggregate")
    }
}

/// Tells the HAL which of an aggregate's streams an IO proc actually uses.
func setStreamUsage(device: AudioObjectID, procID: AudioDeviceIOProcID, scope: AudioObjectPropertyScope, enabled: [Bool]) {
    guard !enabled.isEmpty else { return }
    let flagsOffset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn)!
    let byteCount = flagsOffset + MemoryLayout<UInt32>.stride * enabled.count
    let raw = UnsafeMutableRawPointer.allocate(byteCount: max(byteCount, MemoryLayout<AudioHardwareIOProcStreamUsage>.size), alignment: 8)
    defer { raw.deallocate() }

    let usage = raw.assumingMemoryBound(to: AudioHardwareIOProcStreamUsage.self)
    usage.pointee.mIOProc = unsafeBitCast(procID, to: UnsafeMutableRawPointer.self)
    usage.pointee.mNumberStreams = UInt32(enabled.count)
    let flags = (raw + flagsOffset).assumingMemoryBound(to: UInt32.self)
    for (index, on) in enabled.enumerated() { flags[index] = on ? 1 : 0 }

    var address = propertyAddress(kAudioDevicePropertyIOProcStreamUsage, scope: scope)
    AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(byteCount), raw)
}
