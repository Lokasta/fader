import CoreAudio
import AudioToolbox
import Foundation

struct CoreAudioError: Error, CustomStringConvertible {
    let status: OSStatus
    let context: String

    var description: String { "\(context) (OSStatus \(status))" }
}

@discardableResult
func check(_ status: OSStatus, _ context: @autoclosure () -> String) throws -> OSStatus {
    guard status == noErr else { throw CoreAudioError(status: status, context: context()) }
    return status
}

func propertyAddress(
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
}

extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = AudioObjectID(kAudioObjectUnknown)

    var isValid: Bool { self != .unknown }

    func has(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> Bool {
        var address = propertyAddress(selector, scope: scope)
        return AudioObjectHasProperty(self, &address)
    }

    func isSettable(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> Bool {
        var address = propertyAddress(selector, scope: scope)
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(self, &address, &settable) == noErr else { return false }
        return settable.boolValue
    }

    func read<T: BitwiseCopyable>(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, default value: T) throws -> T {
        var address = propertyAddress(selector, scope: scope)
        var size = UInt32(MemoryLayout<T>.size)
        var result = value
        try check(AudioObjectGetPropertyData(self, &address, 0, nil, &size, &result), "read \(selector.fourCC) on \(self)")
        return result
    }

    func readArray<T: BitwiseCopyable>(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, element: T) throws -> [T] {
        var address = propertyAddress(selector, scope: scope)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size), "size of \(selector.fourCC) on \(self)")
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        var result = [T](repeating: element, count: count)
        let status = result.withUnsafeMutableBytes { AudioObjectGetPropertyData(self, &address, 0, nil, &size, $0.baseAddress!) }
        try check(status, "read \(selector.fourCC) on \(self)")
        return Array(result.prefix(Int(size) / MemoryLayout<T>.stride))
    }

    func readString(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> String {
        var address = propertyAddress(selector, scope: scope)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        try check(AudioObjectGetPropertyData(self, &address, 0, nil, &size, &value), "read \(selector.fourCC) on \(self)")
        guard let value else { throw CoreAudioError(status: kAudioHardwareUnspecifiedError, context: "nil string \(selector.fourCC)") }
        return value.takeRetainedValue() as String
    }

    func write<T: BitwiseCopyable>(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, value: T) throws {
        var address = propertyAddress(selector, scope: scope)
        var value = value
        try check(AudioObjectSetPropertyData(self, &address, 0, nil, UInt32(MemoryLayout<T>.size), &value), "write \(selector.fourCC) on \(self)")
    }
}

extension UInt32 {
    /// Renders a Core Audio selector like 'dOut' for readable error messages.
    var fourCC: String {
        let bytes = [24, 16, 8, 0].map { UInt8((self >> $0) & 0xFF) }
        guard bytes.allSatisfy({ (32..<127).contains($0) }) else { return "\(self)" }
        return "'\(String(decoding: bytes, as: UTF8.self))'"
    }
}

// MARK: - Devices

enum AudioDevices {
    static let ownAggregatePrefix = "com.lokasta.fader.aggregate."

    static func defaultDevice(_ direction: AudioDirection) -> AudioObjectID {
        (try? AudioObjectID.system.read(direction.defaultDeviceSelector, default: AudioObjectID.unknown)) ?? .unknown
    }

    static func setDefaultDevice(_ device: AudioObjectID, _ direction: AudioDirection) throws {
        try AudioObjectID.system.write(direction.defaultDeviceSelector, value: device)
    }

    static func uid(of device: AudioObjectID) -> String? {
        try? device.readString(kAudioDevicePropertyDeviceUID)
    }

    static func name(of device: AudioObjectID) -> String {
        (try? device.readString(kAudioObjectPropertyName)) ?? "Saída \(device)"
    }

    static func streamCount(of device: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        (try? device.readArray(kAudioDevicePropertyStreams, scope: scope, element: AudioStreamID(0)).count) ?? 0
    }

    /// 0-based indices of the device's main left/right channels (most devices: 0 and 1).
    static func stereoChannels(of device: AudioObjectID) -> (left: Int, right: Int) {
        guard let pair = try? device.readArray(kAudioDevicePropertyPreferredChannelsForStereo, scope: kAudioObjectPropertyScopeOutput, element: UInt32(0)),
              pair.count == 2, pair[0] >= 1, pair[1] >= 1 else { return (0, 1) }
        return (Int(pair[0]) - 1, Int(pair[1]) - 1)
    }

    static func devices(_ direction: AudioDirection) -> [AudioDevice] {
        let ids = (try? AudioObjectID.system.readArray(kAudioHardwarePropertyDevices, element: AudioObjectID.unknown)) ?? []
        return ids.compactMap { id in
            guard streamCount(of: id, scope: direction.scope) > 0,
                  let uid = uid(of: id), !uid.hasPrefix(ownAggregatePrefix) else { return nil }
            let hidden: UInt32 = (try? id.read(kAudioDevicePropertyIsHidden, default: UInt32(0))) ?? 0
            guard hidden == 0 else { return nil }
            let transport: UInt32 = (try? id.read(kAudioDevicePropertyTransportType, default: UInt32(0))) ?? 0
            return AudioDevice(id: id, uid: uid, name: name(of: id), transport: transport, direction: direction)
        }
    }

    // MARK: Device volume (what Sound settings' output/input volume sliders change)

    static func volume(of device: AudioObjectID, _ direction: AudioDirection) -> Float? {
        guard device.isValid, device.has(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: direction.scope) else { return nil }
        return try? device.read(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: direction.scope, default: Float32(0))
    }

    static func canSetVolume(of device: AudioObjectID, _ direction: AudioDirection) -> Bool {
        device.isValid && device.isSettable(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: direction.scope)
    }

    static func setVolume(_ volume: Float, of device: AudioObjectID, _ direction: AudioDirection) {
        try? device.write(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: direction.scope, value: Float32(min(max(volume, 0), 1)))
    }

    static func isMuted(_ device: AudioObjectID, _ direction: AudioDirection) -> Bool {
        guard device.isValid, device.has(kAudioDevicePropertyMute, scope: direction.scope) else { return false }
        let muted: UInt32 = (try? device.read(kAudioDevicePropertyMute, scope: direction.scope, default: UInt32(0))) ?? 0
        return muted != 0
    }

    static func canMute(_ device: AudioObjectID, _ direction: AudioDirection) -> Bool {
        device.isValid && device.isSettable(kAudioDevicePropertyMute, scope: direction.scope)
    }

    static func setMuted(_ muted: Bool, _ device: AudioObjectID, _ direction: AudioDirection) {
        try? device.write(kAudioDevicePropertyMute, scope: direction.scope, value: UInt32(muted ? 1 : 0))
    }
}

enum AudioDirection {
    case output, input

    var scope: AudioObjectPropertyScope {
        self == .output ? kAudioObjectPropertyScopeOutput : kAudioObjectPropertyScopeInput
    }

    var defaultDeviceSelector: AudioObjectPropertySelector {
        self == .output ? kAudioHardwarePropertyDefaultOutputDevice : kAudioHardwarePropertyDefaultInputDevice
    }
}

struct AudioDevice: Identifiable, Equatable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let transport: UInt32
    let direction: AudioDirection

    var symbol: String {
        if direction == .input {
            switch transport {
            case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
                return name.localizedCaseInsensitiveContains("airpods") ? "airpods" : "headphones"
            case kAudioDeviceTransportTypeBuiltIn: return "laptopcomputer"
            case kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless: return "iphone"
            default: return "mic"
            }
        }
        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return name.localizedCaseInsensitiveContains("airpods") ? "airpods" : "headphones"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
            return "tv"
        case kAudioDeviceTransportTypeAirPlay:
            return "airplayaudio"
        case kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeThunderbolt:
            return "hifispeaker"
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate:
            return "rectangle.3.group"
        default:
            return "speaker.wave.2"
        }
    }
}
