import SwiftUI

struct MixerView: View {
    @EnvironmentObject private var mixer: Mixer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                DeviceSection(direction: .output)
                DeviceSection(direction: .input)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 12)

            Divider()

            if mixer.permission != .authorized {
                PermissionBanner()
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
            }

            AppsSection()

            Divider()

            FooterSection()
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
        .frame(width: 340)
        .background(WindowVisibility { visible in
            visible ? mixer.beginMetering() : mixer.endMetering()
        })
    }
}

// MARK: - Devices

/// Output or microphone: pick the default device and set its system volume.
/// Same thing Sound settings does, nothing more; Fader never records the microphone.
private struct DeviceSection: View {
    @EnvironmentObject private var mixer: Mixer
    let direction: AudioDirection

    private var state: DeviceState { mixer.state(direction) }
    private var isOutput: Bool { direction == .output }
    private var shownVolume: Float { state.muted ? 0 : state.volume ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(isOutput ? String(localized: "OUTPUT") : String(localized: "MICROPHONE"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Spacer()
                Menu {
                    ForEach(state.devices) { device in
                        Button {
                            mixer.select(device.id, direction)
                        } label: {
                            if device.id == state.current {
                                Label(device.name, systemImage: "checkmark")
                            } else {
                                Text(device.name)
                            }
                        }
                    }
                } label: {
                    Text(state.currentDevice?.name ?? (isOutput ? String(localized: "No output") : String(localized: "No microphone")))
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(state.devices.isEmpty)
                .help(isOutput ? String(localized: "Change the audio output") : String(localized: "Change the default microphone"))
            }

            HStack(spacing: 8) {
                Button { mixer.toggleDeviceMute(direction) } label: {
                    Image(systemName: symbol)
                        .frame(width: 18)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .foregroundStyle(state.muted ? Color.red : .secondary)
                .disabled(!state.muteSettable)
                .help(state.muted ? String(localized: "Unmute") : (isOutput ? String(localized: "Mute everything") : String(localized: "Mute microphone")))

                Slider(
                    value: Binding(get: { Double(shownVolume) }, set: { mixer.setDeviceVolume(Float($0), direction) }),
                    in: 0...1
                )
                .controlSize(.small)
                .disabled(!state.volumeSettable)

                Text(state.muted ? String(localized: "muted") : state.volumeSettable ? "\(Int((shownVolume * 100).rounded()))%" : String(localized: "fixed"))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .trailing)
            }
            .help(state.volumeSettable ? "" : String(localized: "This device doesn't let macOS change its volume"))

            DeviceLevel(levels: mixer.levels, direction: direction)
                .padding(.leading, 26)
                .padding(.trailing, 46)
        }
    }

    private var symbol: String {
        if isOutput { return VolumeSymbol.name(for: shownVolume) }
        return state.muted || shownVolume < 0.001 ? "mic.slash.fill" : "mic.fill"
    }
}

/// Output: the loudest app right now. Microphone: the mic itself (only while the panel is open).
private struct DeviceLevel: View {
    @ObservedObject var levels: LevelMeters
    let direction: AudioDirection

    var body: some View {
        if direction == .output {
            LevelBar(level: levels.output)
        } else {
            switch levels.micAvailability {
            case .on, .unavailable:
                LevelBar(level: levels.mic)
            case .bluetooth:
                note(String(localized: "Meter off for Bluetooth mics (keeps your headset sounding good)"))
            case .noPermission:
                note(String(localized: "Allow microphone access to see the level"))
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9.5))
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .truncationMode(.tail)
    }
}

// MARK: - Permission

private struct PermissionBanner: View {
    @EnvironmentObject private var mixer: Mixer

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield")
                .font(.system(size: 16))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text("One permission missing")
                    .font(.system(size: 12, weight: .semibold))
                Text(mixer.permission == .denied
                     ? String(localized: "Allow Fader in System Settings > Privacy & Security > Screen & System Audio Recording.")
                     : String(localized: "macOS needs to let Fader access app audio. Nothing is recorded."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(mixer.permission == .denied ? String(localized: "Open Settings") : String(localized: "Allow"), action: mixer.requestPermission)
                    .controlSize(.small)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Apps

private struct AppsSection: View {
    @EnvironmentObject private var mixer: Mixer

    var body: some View {
        if mixer.apps.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "waveform")
                    .font(.system(size: 22))
                    .foregroundStyle(.tertiary)
                Text("No app is playing audio")
                    .font(.system(size: 12, weight: .medium))
                Text("Play something and it shows up here.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
        } else {
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(mixer.apps) { entry in
                        if entry.id == ChromeAutomation.bundleID {
                            ChromeAppRow(entry: entry, chrome: mixer.chromeTabs)
                        } else {
                            AppRow(entry: entry)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
            .frame(maxHeight: 440)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Footer

private struct FooterSection: View {
    @EnvironmentObject private var mixer: Mixer

    var body: some View {
        HStack {
            Menu {
                Toggle("Open at login", isOn: Binding(get: { mixer.launchAtLogin }, set: mixer.setLaunchAtLogin))
                Toggle("Remember each app's volume", isOn: Binding(get: { mixer.rememberVolumes }, set: mixer.setRememberVolumes))
                Toggle("Dictation key (F5) opens Fader", isOn: Binding(get: { mixer.dictationKeyOpensPanel }, set: mixer.setDictationKeyOpensPanel))
                ChromeTabsToggle(chrome: mixer.chromeTabs)
                Text("Shortcut: ⌃⌥V")
                Divider()
                Button("Open Sound Settings…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!)
                }
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Options")

            Spacer()

            Text(verbatim: "Lokasta's Fader \(Bundle.main.shortVersion)")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)

            Spacer()

            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .keyboardShortcut("q")
        }
    }
}

private struct ChromeTabsToggle: View {
    @ObservedObject var chrome: ChromeTabs

    var body: some View {
        Toggle("Chrome tab controls", isOn: Binding(get: { chrome.isEnabled }, set: chrome.setEnabled))
    }
}

enum VolumeSymbol {
    static func name(for volume: Float) -> String {
        switch volume {
        case ..<0.001: return "speaker.slash.fill"
        case ..<0.34: return "speaker.wave.1.fill"
        case ..<0.67: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }
}

extension Bundle {
    var shortVersion: String { infoDictionary?["CFBundleShortVersionString"] as? String ?? "" }
}
