import Foundation

/// Live levels for the meters, 0...1 on a dB scale. Lives apart from `Mixer` so 30 updates
/// a second only redraw the meter bars, not the whole panel.
@MainActor
final class LevelMeters: ObservableObject {
    @Published private(set) var apps: [String: Float] = [:]
    @Published private(set) var mic: Float = 0
    @Published var micAvailability = MicMeter.Availability.unavailable

    /// What's going out right now: the loudest app (each already at its own volume).
    var output: Float { apps.values.max() ?? 0 }

    /// Meter floor. Quieter than this reads as empty.
    nonisolated static let floorDB: Float = -60
    /// How far a bar may fall per update (30 Hz), so it decays smoothly instead of flickering.
    nonisolated static let fallPerUpdate: Float = 0.035

    func update(apps peaks: [String: Float], mic micPeak: Float) {
        var next: [String: Float] = [:]
        for (key, peak) in peaks {
            next[key] = Self.smooth(Self.normalized(peak), previous: apps[key] ?? 0)
        }
        if next != apps { apps = next }
        let nextMic = Self.smooth(Self.normalized(micPeak), previous: mic)
        if nextMic != mic { mic = nextMic }
    }

    func reset() {
        apps = [:]
        mic = 0
    }

    /// Linear sample peak to a 0...1 position on a -60...0 dBFS scale.
    nonisolated static func normalized(_ peak: Float) -> Float {
        guard peak > 0 else { return 0 }
        let db = 20 * log10(peak)
        return min(max((db - floorDB) / -floorDB, 0), 1)
    }

    /// Instant attack, gradual release.
    nonisolated static func smooth(_ value: Float, previous: Float) -> Float {
        let next = max(value, previous - fallPerUpdate)
        return next < 0.001 ? 0 : next
    }
}
