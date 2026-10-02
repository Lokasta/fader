import AppKit
import CoreAudio
import Darwin

/// One audio client as Core Audio sees it (a browser tab's audio service, a game, `afplay`...).
struct AudioProcess {
    let objectID: AudioObjectID
    let pid: pid_t
    let isPlaying: Bool
    /// Core Audio's own identifier for the client. Readable even for root daemons,
    /// where `proc_name` is refused.
    let bundleID: String?
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

    /// PID and bundle ID never change for a process object, so they're read once.
    /// Only "is it playing" is polled.
    @MainActor private static var known: [AudioObjectID: (pid: pid_t, bundleID: String?)] = [:]

    @MainActor
    static func list() -> [AudioProcess] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ids = (try? AudioObjectID.system.readArray(kAudioHardwarePropertyProcessObjectList, element: AudioObjectID.unknown)) ?? []
        known = known.filter { ids.contains($0.key) }
        return ids.compactMap { id in
            let info: (pid: pid_t, bundleID: String?)
            if let cached = known[id] {
                info = cached
            } else {
                guard let pid: pid_t = try? id.read(kAudioProcessPropertyPID, default: pid_t(-1)), pid > 0 else { return nil }
                info = (pid, try? id.readString(kAudioProcessPropertyBundleID))
                known[id] = info
            }
            guard info.pid != ownPID else { return nil }
            let running: UInt32 = (try? id.read(kAudioProcessPropertyIsRunningOutput, default: UInt32(0))) ?? 0
            return AudioProcess(objectID: id, pid: info.pid, isPlaying: running != 0, bundleID: info.bundleID)
        }
    }

    /// macOS services that play sound on their own, shown with a name a person recognizes.
    private static let systemServices: [String: (name: String, symbol: String)] = [
        "systemsoundserverd": ("Sons do sistema", "bell.fill"),
        "com.apple.systemsoundserverd": ("Sons do sistema", "bell.fill"),
        "com.apple.SpeechSynthesisServerXPC": ("Fala do sistema", "waveform"),
        "com.apple.speech.speechsynthesisd": ("Fala do sistema", "waveform"),
        "com.apple.accessibility.heard": ("Acessibilidade", "accessibility"),
        "com.apple.CoreSpeech": ("Siri", "mic.fill"),
        "com.apple.assistantd": ("Siri", "mic.fill"),
    ]

    static func identity(for process: AudioProcess) -> AudioAppIdentity {
        let pid = process.pid
        let ownerPID = responsiblePID?(pid) ?? pid
        for candidate in [ownerPID, pid] where candidate > 0 {
            if let app = NSRunningApplication(processIdentifier: candidate), let name = app.localizedName {
                let icon = app.icon ?? NSWorkspace.shared.icon(for: .application)
                let key = app.bundleIdentifier ?? "pid:\(candidate)"
                return AudioAppIdentity(key: key, name: name, bundleID: app.bundleIdentifier, icon: icon)
            }
        }
        if let bundleID = process.bundleID, let service = systemServices[bundleID] {
            return AudioAppIdentity(key: "service:\(service.name)", name: service.name, bundleID: bundleID, icon: symbolIcon(service.symbol))
        }
        let fallbackName = process.bundleID.flatMap { $0.split(separator: ".").last.map(String.init) }
        let name = processName(ownerPID) ?? processName(pid) ?? fallbackName ?? "Processo \(pid)"
        return AudioAppIdentity(key: "name:\(name)", name: name, bundleID: process.bundleID, icon: NSWorkspace.shared.icon(for: .unixExecutable))
    }

    /// An SF Symbol on a rounded tile, so system services sit nicely next to real app icons.
    private static func symbolIcon(_ symbol: String) -> NSImage {
        let size = NSSize(width: 64, height: 64)
        return NSImage(size: size, flipped: false) { rect in
            let tile = NSBezierPath(roundedRect: rect.insetBy(dx: 4, dy: 4), xRadius: 14, yRadius: 14)
            NSGradient(colors: [NSColor.systemGray, NSColor.darkGray])?.draw(in: tile, angle: -90)
            let config = NSImage.SymbolConfiguration(pointSize: 28, weight: .semibold).applying(.init(paletteColors: [.white]))
            if let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                let origin = NSPoint(x: rect.midX - glyph.size.width / 2, y: rect.midY - glyph.size.height / 2)
                glyph.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
            }
            return true
        }
    }

    private static func processName(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXCOMLEN) * 4)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let name = String(cString: buffer)
        return name.isEmpty ? nil : name
    }
}
