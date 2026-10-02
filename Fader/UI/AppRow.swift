import SwiftUI

struct AppRow: View {
    @EnvironmentObject private var mixer: Mixer
    let entry: AppEntry
    @State private var hovering = false

    private var percent: Int { Int((entry.effectiveGain * 100).rounded()) }
    private var isAdjusted: Bool { entry.muted || abs(entry.volume - 1) > 0.001 }

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: entry.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 30, height: 30)
                .opacity(entry.isPlaying ? 1 : 0.5)
                .saturation(entry.muted ? 0 : 1)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                    if let failure = entry.failure {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.yellow)
                            .help(failure)
                    } else if !entry.isPlaying {
                        Text("paused")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 4)
                    if isAdjusted && hovering {
                        Button { mixer.reset(entry.id) } label: {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Reset volume")
                    }
                    Text(entry.muted ? String(localized: "muted") : "\(percent)%")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(entry.volume > 1.001 && !entry.muted ? Color.orange : .secondary)
                        .frame(width: 38, alignment: .trailing)
                        .onTapGesture(count: 2) { mixer.reset(entry.id) }
                        .help("Double-click to reset")
                }

                HStack(spacing: 6) {
                    Button { mixer.toggleMute(entry.id) } label: {
                        Image(systemName: VolumeSymbol.name(for: entry.muted ? 0 : min(entry.volume, 1)))
                            .font(.system(size: 11))
                            .frame(width: 16)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(entry.muted ? Color.red : .secondary)
                    .help(entry.muted ? String(localized: "Unmute") : String(localized: "Mute"))

                    VStack(spacing: 3) {
                        VolumeSlider(value: Binding(
                            get: { entry.volume },
                            set: { mixer.setVolume($0, for: entry.id) }
                        ))
                        .opacity(entry.muted ? 0.4 : 1)
                        AppLevel(levels: mixer.levels, id: entry.id)
                            .padding(.horizontal, 2)
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(hovering ? Color.primary.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .onHover { hovering = $0 }
    }
}

/// Observes only the meters, so level updates don't redraw the rest of the row.
private struct AppLevel: View {
    @ObservedObject var levels: LevelMeters
    let id: String

    var body: some View { LevelBar(level: levels.apps[id] ?? 0) }
}

/// 0–200% slider with a soft detent at 100% and a tick marking it, so "normal" is easy to find.
struct VolumeSlider: View {
    @Binding var value: Float

    var body: some View {
        Slider(
            value: Binding(
                get: { Double(value) },
                set: { newValue in
                    value = abs(newValue - 1) < 0.04 ? 1 : Float(newValue)
                }
            ),
            in: 0...Double(Mixer.maxVolume)
        )
        .controlSize(.small)
        .background(alignment: .center) {
            Capsule()
                .fill(Color.secondary.opacity(0.5))
                .frame(width: 1.5, height: 6)
                .offset(y: -8)
                .allowsHitTesting(false)
        }
    }
}
