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
                Text(isOutput ? "SAÍDA" : "MICROFONE")
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
                    Text(state.currentDevice?.name ?? (isOutput ? "Sem saída" : "Sem microfone"))
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(state.devices.isEmpty)
                .help(isOutput ? "Trocar a saída de áudio" : "Trocar o microfone padrão")
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
                .help(state.muted ? "Ativar" : (isOutput ? "Silenciar tudo" : "Silenciar microfone"))

                Slider(
                    value: Binding(get: { Double(shownVolume) }, set: { mixer.setDeviceVolume(Float($0), direction) }),
                    in: 0...1
                )
                .controlSize(.small)
                .disabled(!state.volumeSettable)

                Text(state.muted ? "mudo" : state.volumeSettable ? "\(Int((shownVolume * 100).rounded()))%" : "fixo")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .trailing)
            }
            .help(state.volumeSettable ? "" : "Esse dispositivo não deixa o macOS mudar o volume")
        }
    }

    private var symbol: String {
        if isOutput { return VolumeSymbol.name(for: shownVolume) }
        return state.muted || shownVolume < 0.001 ? "mic.slash.fill" : "mic.fill"
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
                Text("Falta uma permissão")
                    .font(.system(size: 12, weight: .semibold))
                Text(mixer.permission == .denied
                     ? "Libere o Fader em Ajustes > Privacidade e Segurança > Gravação de Tela e Áudio do Sistema."
                     : "O macOS precisa deixar o Fader acessar o áudio dos apps. Nada é gravado.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(mixer.permission == .denied ? "Abrir Ajustes" : "Permitir", action: mixer.requestPermission)
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
                Text("Nenhum app tocando áudio")
                    .font(.system(size: 12, weight: .medium))
                Text("Dá play em alguma coisa e ela aparece aqui.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
        } else {
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(mixer.apps) { entry in
                        AppRow(entry: entry)
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
                Toggle("Abrir ao iniciar o Mac", isOn: Binding(get: { mixer.launchAtLogin }, set: mixer.setLaunchAtLogin))
                Toggle("Lembrar o volume de cada app", isOn: Binding(get: { mixer.rememberVolumes }, set: mixer.setRememberVolumes))
                Divider()
                Button("Abrir Ajustes de Som…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!)
                }
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Opções")

            Spacer()

            Text("Fader \(Bundle.main.shortVersion)")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)

            Spacer()

            Button("Sair") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .keyboardShortcut("q")
        }
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
