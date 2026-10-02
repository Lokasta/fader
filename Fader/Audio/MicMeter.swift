import AVFoundation
import CoreAudio
import Synchronization
import os

/// Measures the default microphone's level while the panel is open, and only then.
///
/// Reading the mic is the one thing that can't be done silently: macOS shows its orange
/// indicator, and a Bluetooth headset switches to call mode (bad audio). So this runs only
/// while someone is looking at the meter, and never on Bluetooth inputs.
final class MicMeter {
    enum Availability: Equatable { case on, bluetooth, noPermission, unavailable }

    private let peak = PeakBox()
    private var device = AudioObjectID.unknown
    private var ioProcID: AudioDeviceIOProcID?
    private let log = Logger(subsystem: "com.lokasta.fader", category: "mic")

    private(set) var availability = Availability.unavailable

    var isRunning: Bool { ioProcID != nil }

    /// Starts (or retargets) metering on `device`. Calls back on main when availability changes.
    func start(on device: AudioObjectID, transport: UInt32?) {
        guard device != self.device || !isRunning else { return }
        stop()
        guard device.isValid else { return availability = .unavailable }

        if transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE {
            return availability = .bluetooth
        }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            availability = .noPermission
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            return
        default:
            return availability = .noPermission
        }

        let box = peak
        let status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, device, nil) { _, input, _, _, _ in
            box.raise(to: GainRenderer.peak(of: UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)), firstBuffer: 0))
        }
        guard status == noErr, let ioProcID, AudioDeviceStart(device, ioProcID) == noErr else {
            log.error("mic meter could not start: \(status)")
            stop()
            return availability = .unavailable
        }
        self.device = device
        availability = .on
    }

    func stop() {
        if let ioProcID, device.isValid {
            AudioDeviceStop(device, ioProcID)
            AudioDeviceDestroyIOProcID(device, ioProcID)
        }
        ioProcID = nil
        device = .unknown
        _ = peak.take()
    }

    func takePeak() -> Float { peak.take() }

    deinit { stop() }
}

/// A peak level written by an audio thread and drained by the UI. Lock-free.
final class PeakBox: @unchecked Sendable {
    private let bits = Atomic<UInt32>(Float(0).bitPattern)

    func raise(to value: Float) {
        let clamped = min(value, 1)
        if clamped > Float(bitPattern: bits.load(ordering: .relaxed)) {
            bits.store(clamped.bitPattern, ordering: .relaxed)
        }
    }

    func take() -> Float {
        Float(bitPattern: bits.exchange(Float(0).bitPattern, ordering: .relaxed))
    }
}
