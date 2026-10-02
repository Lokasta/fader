import Foundation
import os

/// Turns the MacBook's Dictation key (F5, HID consumer usage 0xCF) into F18, which Fader listens for.
///
/// Uses `hidutil`'s user key mapping: no driver, no root, and it resets on reboot, so Fader
/// reapplies it at launch. Mappings set by anything else are preserved.
enum DictationKeyRemap {
    static let dictationKey: UInt64 = 0xC_0000_00CF // Consumer page, Voice Command
    static let f18Key: UInt64 = 0x7_0000_006D // Keyboard page, F18

    private static let log = Logger(subsystem: "com.lokasta.fader", category: "keys")

    static func apply(_ enabled: Bool) {
        var mappings = currentMappings().filter { $0.src != dictationKey }
        if enabled { mappings.append((dictationKey, f18Key)) }

        let entries = mappings
            .map { "{\"HIDKeyboardModifierMappingSrc\":\($0.src),\"HIDKeyboardModifierMappingDst\":\($0.dst)}" }
            .joined(separator: ",")
        let output = hidutil(["property", "--set", "{\"UserKeyMapping\":[\(entries)]}"])
        log.info("dictation key remap \(enabled ? "on" : "off", privacy: .public): \(output.isEmpty ? "ok" : "done", privacy: .public)")
    }

    /// Parses `hidutil property --get UserKeyMapping`, which prints an old-style plist.
    private static func currentMappings() -> [(src: UInt64, dst: UInt64)] {
        let output = hidutil(["property", "--get", "UserKeyMapping"])
        func values(_ key: String) -> [UInt64] {
            guard let regex = try? NSRegularExpression(pattern: key + #"\s*=\s*(\d+)"#) else { return [] }
            return regex.matches(in: output, range: NSRange(output.startIndex..., in: output)).compactMap {
                Range($0.range(at: 1), in: output).flatMap { UInt64(output[$0]) }
            }
        }
        return Array(zip(values("HIDKeyboardModifierMappingSrc"), values("HIDKeyboardModifierMappingDst")))
    }

    @discardableResult
    private static func hidutil(_ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            log.error("hidutil failed: \(String(describing: error), privacy: .public)")
            return ""
        }
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
}
