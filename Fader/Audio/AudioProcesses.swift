import AppKit
import CoreAudio
import Darwin

/// One audio client as Core Audio sees it (a browser tab's audio service, a game, `afplay`...).
struct AudioProcess {
    let objectID: AudioObjectID
    let pid: pid_t
    let isPlaying: Bool
}

/// The app a user thinks of as "the thing making sound": helpers are folded into their owner,
/// so Chrome's audio service shows up as Chrome and Safari's WebKit GPU process as Safari.
struct AudioAppIdentity {
    let key: String
    let name: String
    let bundleID: String?
    let icon: NSImage
}

enum AudioProcesses {
    private typealias ResponsiblePIDFunction = @convention(c) (pid_t) -> pid_t

    /// `responsibility_get_pid_responsible_for_pid` is the same lookup Activity Monitor uses
    /// to attribute helper processes to their app. Private, so it's resolved at runtime.
    private static let responsiblePID: ResponsiblePIDFunction? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: ResponsiblePIDFunction.self)
    }()

    static func list() -> [AudioProcess] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ids = (try? AudioObjectID.system.readArray(kAudioHardwarePropertyProcessObjectList, element: AudioObjectID.unknown)) ?? []
        return ids.compactMap { id in
            guard let pid: pid_t = try? id.read(kAudioProcessPropertyPID, default: pid_t(-1)), pid > 0, pid != ownPID else { return nil }
            let running: UInt32 = (try? id.read(kAudioProcessPropertyIsRunningOutput, default: UInt32(0))) ?? 0
            return AudioProcess(objectID: id, pid: pid, isPlaying: running != 0)
        }
    }

    static func identity(for pid: pid_t) -> AudioAppIdentity {
        let ownerPID = responsiblePID?(pid) ?? pid
        for candidate in [ownerPID, pid] where candidate > 0 {
            if let app = NSRunningApplication(processIdentifier: candidate), let name = app.localizedName {
                let icon = app.icon ?? NSWorkspace.shared.icon(for: .application)
                let key = app.bundleIdentifier ?? "pid:\(candidate)"
                return AudioAppIdentity(key: key, name: name, bundleID: app.bundleIdentifier, icon: icon)
            }
        }
        let name = processName(ownerPID) ?? processName(pid) ?? "Processo \(pid)"
        return AudioAppIdentity(key: "name:\(name)", name: name, bundleID: nil, icon: NSWorkspace.shared.icon(for: .unixExecutable))
    }

    private static func processName(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXCOMLEN) * 4)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let name = String(cString: buffer)
        return name.isEmpty ? nil : name
    }
}
