import Foundation

/// Remembers each app's volume and mute by bundle ID, so Spotify comes back at 40% next time.
struct VolumeStore {
    private let defaults: UserDefaults
    private let volumesKey = "appVolumes"
    private let mutedKey = "appMuted"
    private let rememberKey = "rememberVolumes"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [rememberKey: true])
    }

    var remembers: Bool {
        get { defaults.bool(forKey: rememberKey) }
        nonmutating set { defaults.set(newValue, forKey: rememberKey) }
    }

    func volume(for key: String) -> Float {
        guard remembers, let stored = defaults.dictionary(forKey: volumesKey)?[key] as? Double else { return 1 }
        return Float(stored)
    }

    func isMuted(_ key: String) -> Bool {
        remembers && (defaults.stringArray(forKey: mutedKey) ?? []).contains(key)
    }

    func save(volume: Float, muted: Bool, for key: String) {
        var volumes = defaults.dictionary(forKey: volumesKey) ?? [:]
        volumes[key] = abs(volume - 1) < 0.001 ? nil : Double(volume)
        defaults.set(volumes, forKey: volumesKey)

        var mutedKeys = Set(defaults.stringArray(forKey: mutedKey) ?? [])
        if muted { mutedKeys.insert(key) } else { mutedKeys.remove(key) }
        defaults.set(mutedKeys.sorted(), forKey: mutedKey)
    }

    func forgetAll() {
        defaults.removeObject(forKey: volumesKey)
        defaults.removeObject(forKey: mutedKey)
    }
}
