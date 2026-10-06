import SwiftUI

/// Chrome keeps its master slider; compatible playing tabs sit underneath it.
struct ChromeAppRow: View {
    let entry: AppEntry
    @ObservedObject var chrome: ChromeTabs
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AppRow(entry: entry)
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    expanded.toggle()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .frame(width: 10)
                        Text("Tabs with audio")
                            .font(.system(size: 11, weight: .medium))
                        if !chrome.tabs.isEmpty {
                            Text(verbatim: "\(chrome.tabs.count)")
                                .font(.system(size: 10).monospacedDigit())
                        }
                        Spacer()
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(expanded ? String(localized: "Expanded") : String(localized: "Collapsed"))

                if expanded {
                    if !chrome.tabs.isEmpty {
                        VStack(spacing: 10) {
                            ForEach(chrome.tabs) { tab in
                                ChromeTabRow(tab: tab, chrome: chrome)
                            }
                        }
                    }
                    status
                }
            }
            .padding(.leading, 42)
            .padding(.trailing, 8)
            .padding(.bottom, 10)
        }
    }

    @ViewBuilder private var status: some View {
        switch chrome.status {
        case .disabled:
            Text("Control playing audio and video tabs separately.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Button("Enable tab controls") { chrome.setEnabled(true) }
                .controlSize(.small)
        case .connecting:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Looking for playing tabs…")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        case .ready:
            if chrome.tabs.isEmpty {
                Text("No compatible tabs are playing audio.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Text("Audio/video players only. Other tab audio uses Chrome's main slider.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .automationDenied:
            recovery("Allow Fader to control Chrome in System Settings > Privacy & Security > Automation.")
            Button("Open Settings") { chrome.openAutomationSettings() }
                .controlSize(.small)
        case .javascriptDisabled:
            recovery("In Chrome, choose View > Developer > Allow JavaScript from Apple Events, then try again.")
        case .unavailable:
            recovery("Chrome didn't respond. Try again when it finishes loading.")
        }
    }

    private func recovery(_ message: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try again") { chrome.retry() }
                .controlSize(.small)
        }
    }
}

private struct ChromeTabRow: View {
    let tab: ChromeTab
    @ObservedObject var chrome: ChromeTabs

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: tab.hasVideo ? "play.rectangle" : "music.note")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: tab.title.isEmpty ? tab.site : tab.title)
                        .font(.system(size: 11.5, weight: .medium))
                        .lineLimit(1)
                        .help(tab.title)
                    Text(verbatim: tab.site)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Button { chrome.reset(tab.id) } label: {
                    Text(tab.muted ? String(localized: "muted") : "\(Int((tab.volume * 100).rounded()))%")
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(tab.muted ? Color.red : .secondary)
                        .frame(width: 38, alignment: .trailing)
                }
                .buttonStyle(.plain)
                .help("Reset tab volume")
                .accessibilityLabel(String(localized: "Reset tab volume"))
            }
            HStack(spacing: 6) {
                Button { chrome.toggleMute(tab.id) } label: {
                    Image(systemName: VolumeSymbol.name(for: tab.muted ? 0 : Float(tab.volume)))
                        .font(.system(size: 11))
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .foregroundStyle(tab.muted ? Color.red : .secondary)
                .help(tab.muted ? String(localized: "Unmute tab") : String(localized: "Mute tab"))
                .accessibilityLabel(tab.muted ? String(localized: "Unmute tab") : String(localized: "Mute tab"))
                Slider(value: Binding(get: { tab.volume }, set: { chrome.setVolume($0, for: tab.id) }), in: 0...1)
                    .controlSize(.small)
                    .opacity(tab.muted ? 0.4 : 1)
                    .accessibilityLabel(String(localized: "Tab volume"))
                    .accessibilityValue("\(Int((tab.volume * 100).rounded()))%")
            }
        }
    }
}
