import AppKit
import Foundation

/// The "System Audio Recording" privacy permission that process taps require.
///
/// There is no public API to query it, so this uses the TCC framework's preflight/request calls
/// (the same approach as Apple's own sample tooling). Knowing the state up front matters:
/// a tap created without permission still mutes the app but delivers silence.
enum AudioCapturePermission {
    enum Status { case unknown, denied, authorized }

    private typealias PreflightFunction = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFunction = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    private static let service = "kTCCServiceAudioCapture" as CFString
    private static let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    private static let preflight: PreflightFunction? = {
        guard let handle, let symbol = dlsym(handle, "TCCAccessPreflight") else { return nil }
        return unsafeBitCast(symbol, to: PreflightFunction.self)
    }()

    private static let request: RequestFunction? = {
        guard let handle, let symbol = dlsym(handle, "TCCAccessRequest") else { return nil }
        return unsafeBitCast(symbol, to: RequestFunction.self)
    }()

    static var status: Status {
        // If Apple ever moves these symbols, fall back to trying: the OS will prompt on first tap.
        guard let preflight else { return .authorized }
        switch preflight(service, nil) {
        case 0: return .authorized
        case 1: return .denied
        default: return .unknown
        }
    }

    static func request(_ completion: @escaping (Bool) -> Void) {
        guard let request else { return completion(true) }
        request(service, nil) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    static func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!
        NSWorkspace.shared.open(url)
    }
}
