import AppKit
import CoreAudio
import ServiceManagement
import os

struct AppEntry: Identifiable, Equatable {
    let id: String
    var name: String
    var icon: NSImage
    var processes: [AudioObjectID]
    var isPlaying: Bool
    var volume: Float
    var muted: Bool
    var failure: String?

    var effectiveGain: Float { muted ? 0 : volume }

    static func == (a: AppEntry, b: AppEntry) -> Bool {
        a.id == b.id && a.name == b.name && a.processes == b.processes && a.isPlaying == b.isPlaying
            && a.volume == b.volume && a.muted == b.muted && a.failure == b.failure
    }
}

@MainActor
final class Mixer: ObservableObject {
    static let maxVolume: Float = 2
    /// A `--snapshot` run is a second copy of the app: it must never tap audio.
    static let touchesAudio = Snapshot.requestedPath == nil

    @Published private(set) var apps: [AppEntry] = []
    @Published private(set) var output = DeviceState(direction: .output)
    @Published private(set) var input = DeviceState(direction: .input)
    @Published private(set) var permission = AudioCapturePermission.status
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published private(set) var rememberVolumes: Bool
    @Published private(set) var dictationKeyOpensPanel: Bool

    private let store = VolumeStore()
    private var taps: [String: AppTap] = [:]
    /// Apps that played during this session stay listed while they're open, so pausing a video
    /// doesn't yank its slider away mid-adjustment.
    private var recentlyPlaying: Set<String> = []
    /// A tap that failed isn't retried until the app's processes or the output device change.
    private var failedAttempts: [String: String] = [:]
    private var identities: [pid_t: AudioAppIdentity] = [:]
    private var timer: Timer?
    private let log = Logger(subsystem: "com.lokasta.fader", category: "mixer")

    init() {
        rememberVolumes = store.remembers
        UserDefaults.standard.register(defaults: [Self.dictationKeyDefault: true])
        dictationKeyOpensPanel = UserDefaults.standard.bool(forKey: Self.dictationKeyDefault)
        DictationKeyRemap.apply(dictationKeyOpensPanel)
        refresh()
        observeCoreAudio()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tearDown() }
        }
        log.info("started, audio capture permission: \(String(describing: self.permission), privacy: .public)")
        if permission == .unknown { requestPermission() }
        enableLaunchAtLoginOnFirstRun()
    }

    /// A volume mixer is only useful if it's always running, so the first launch opts in.
    /// The user can turn it off in the gear menu and that choice sticks.
    private func enableLaunchAtLoginOnFirstRun() {
        let key = "didOfferLaunchAtLogin"
        guard !UserDefaults.standard.bool(forKey: key), Bundle.main.bundlePath.hasPrefix("/Applications") else { return }
        UserDefaults.standard.set(true, forKey: key)
        setLaunchAtLogin(true)
    }

    // MARK: - App volumes

    func setVolume(_ volume: Float, for id: String) {
        update(id) { $0.volume = min(max(volume, 0), Self.maxVolume) }
    }

    func toggleMute(_ id: String) {
        update(id) { $0.muted.toggle() }
    }

    func reset(_ id: String) {
        update(id) {
            $0.volume = 1
            $0.muted = false
        }
    }

    private func update(_ id: String, _ change: (inout AppEntry) -> Void) {
        guard let index = apps.firstIndex(where: { $0.id == id }) else { return }
        var entry = apps[index]
        change(&entry)
        store.save(volume: entry.volume, muted: entry.muted, for: id)
        failedAttempts[id] = nil
        reconcileTap(&entry)
        apps[index] = entry
    }

    // MARK: - Output device

    /// The output device every tap renders into: always the system default.
    private var currentOutput: AudioObjectID { output.current }

    func select(_ device: AudioObjectID, _ direction: AudioDirection) {
        do {
            try AudioDevices.setDefaultDevice(device, direction)
        } catch {
            log.error("could not switch device: \(String(describing: error))")
        }
        refresh()
    }

    func setDeviceVolume(_ volume: Float, _ direction: AudioDirection) {
        let device = state(direction).current
        guard device.isValid else { return }
        if state(direction).muted, volume > 0 { AudioDevices.setMuted(false, device, direction) }
        AudioDevices.setVolume(volume, of: device, direction)
        refreshDevices(direction)
    }

    func toggleDeviceMute(_ direction: AudioDirection) {
        let current = state(direction)
        guard current.current.isValid else { return }
        AudioDevices.setMuted(!current.muted, current.current, direction)
        refreshDevices(direction)
    }

    func state(_ direction: AudioDirection) -> DeviceState {
        direction == .output ? output : input
    }

    // MARK: - Settings

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            log.error("launch at login: \(String(describing: error))")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private static let dictationKeyDefault = "dictationKeyOpensPanel"

    func setDictationKeyOpensPanel(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.dictationKeyDefault)
        dictationKeyOpensPanel = enabled
        DictationKeyRemap.apply(enabled)
    }

    func setRememberVolumes(_ enabled: Bool) {
        store.remembers = enabled
        rememberVolumes = enabled
        if enabled {
            for entry in apps { store.save(volume: entry.volume, muted: entry.muted, for: entry.id) }
        } else {
            store.forgetAll()
        }
    }

    func requestPermission() {
        if permission == .denied { return AudioCapturePermission.openSystemSettings() }
        AudioCapturePermission.request { [weak self] granted in
            guard let self else { return }
            self.log.info("permission request answered: \(granted, privacy: .public)")
            self.permission = AudioCapturePermission.status
            self.failedAttempts.removeAll()
            self.refresh()
        }
    }

    // MARK: - Refresh loop

    func refresh() {
        let permissionNow = AudioCapturePermission.status
        if permissionNow != permission {
            permission = permissionNow
            failedAttempts.removeAll()
        }
        refreshDevices(.output)
        refreshDevices(.input)
        deviceListsStale = false

        let processes = AudioProcesses.list()
        let alive = Set(processes.map(\.pid))
        identities = identities.filter { alive.contains($0.key) }

        var groups: [String: (identity: AudioAppIdentity, processes: [AudioProcess])] = [:]
        for process in processes {
            let identity = identities[process.pid] ?? AudioProcesses.identity(for: process)
            identities[process.pid] = identity
            groups[identity.key, default: (identity, [])].processes.append(process)
        }

        recentlyPlaying.formIntersection(groups.keys)
        for key in Array(taps.keys) where groups[key] == nil {
            taps.removeValue(forKey: key)?.invalidate()
        }

        var next: [AppEntry] = []
        for (key, group) in groups {
            let playing = group.processes.contains(where: \.isPlaying)
            if playing { recentlyPlaying.insert(key) }
            guard playing || recentlyPlaying.contains(key) || taps[key] != nil else { continue }

            var entry = apps.first(where: { $0.id == key }) ?? AppEntry(
                id: key,
                name: group.identity.name,
                icon: group.identity.icon,
                processes: [],
                isPlaying: false,
                volume: store.volume(for: key),
                muted: store.isMuted(key)
            )
            entry.processes = group.processes.map(\.objectID).sorted()
            entry.isPlaying = playing
            reconcileTap(&entry)
            next.append(entry)
        }
        next.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if next != apps { apps = next }
        updateMeterHub()
    }

    /// Device lists only change when hardware comes or goes (Core Audio tells us), so they're
    /// cached; the per-second refresh only re-reads the cheap volume and mute values.
    private var deviceListsStale = true
    private var cachedDevices: [AudioDirection: [AudioDevice]] = [:]

    private func refreshDevices(_ direction: AudioDirection) {
        if deviceListsStale || cachedDevices[direction] == nil {
            cachedDevices[direction] = AudioDevices.devices(direction)
        }
        let next = DeviceState.read(direction, devices: cachedDevices[direction] ?? [])
        switch direction {
        case .output: if next != output { output = next }
        case .input:
            if next != input {
                input = next
                updateMicMeter()
            }
        }
    }

    /// A mixing tap (mutes the original, replays at our gain) exists whenever an app isn't at 100%,
    /// and is kept while it plays even back at 100% (tearing it down mid-song would glitch).
    /// Apps without one run through macOS untouched; their meters come from `MeterHub`.
    private func reconcileTap(_ entry: inout AppEntry) {
        let gain = entry.effectiveGain
        let needsMix = abs(gain - 1) > 0.001

        if let tap = taps[entry.id] {
            if tap.outputDeviceID == currentOutput && (needsMix || entry.isPlaying)
                && (tap.processes == entry.processes || tap.update(processes: entry.processes)) {
                tap.gain = gain
                return
            }
            taps.removeValue(forKey: entry.id)?.invalidate()
        }

        guard needsMix, Self.touchesAudio, permission == .authorized, currentOutput.isValid else { return }
        let attempt = "\(entry.processes)-\(currentOutput)"
        guard failedAttempts[entry.id] != attempt else { return }

        do {
            taps[entry.id] = try AppTap(processes: entry.processes, outputDevice: currentOutput, name: entry.name, gain: gain)
            let name = entry.name
            log.info("mixing tap for \(name, privacy: .public) at \(gain, privacy: .public)")
            entry.failure = nil
            failedAttempts[entry.id] = nil
        } catch {
            let id = entry.id
            log.error("tap for \(id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            entry.failure = String(localized: "Couldn't control this app")
            failedAttempts[entry.id] = attempt
        }
    }

    /// Meters for playing apps that have no mixing tap, all through one shared aggregate.
    private func updateMeterHub() {
        guard isMetering, Self.touchesAudio, permission == .authorized else { return meterHub.update([], outputDevice: .unknown) }
        let sources = apps
            .filter { $0.isPlaying && taps[$0.id] == nil }
            .map { MeterHub.Source(key: $0.id, processes: $0.processes) }
        meterHub.update(sources, outputDevice: currentOutput)
    }

    // MARK: - Level meters

    let levels = LevelMeters()
    private let meterHub = MeterHub()
    private let micMeter = MicMeter()
    private var meteringViewers = 0
    private var meterTimer: Timer?
    private var isMetering: Bool { meteringViewers > 0 }

    /// Called when a panel becomes visible. Meters (and the mic) only run while someone looks.
    func beginMetering() {
        meteringViewers += 1
        guard meteringViewers == 1 else { return }
        refresh()
        updateMicMeter()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollLevels() }
        }
    }

    func endMetering() {
        meteringViewers = max(0, meteringViewers - 1)
        guard meteringViewers == 0 else { return }
        meterTimer?.invalidate()
        meterTimer = nil
        micMeter.stop()
        meterHub.stop()
        levels.reset()
        refresh()
    }

    private func updateMicMeter() {
        guard isMetering else { return }
        micMeter.start(on: input.current, transport: input.currentDevice?.transport)
        levels.micAvailability = micMeter.availability
    }

    private func pollLevels() {
        var peaks = meterHub.takePeaks()
        for (key, tap) in taps { peaks[key] = tap.takePeak() }
        levels.update(apps: peaks, mic: micMeter.takePeak())
        if micMeter.availability == .noPermission { updateMicMeter() }
    }

    // MARK: - Core Audio notifications

    private func observeCoreAudio() {
        let selectors = [
            kAudioHardwarePropertyDefaultOutputDevice,
            kAudioHardwarePropertyDefaultInputDevice,
            kAudioHardwarePropertyDevices,
            kAudioHardwarePropertyProcessObjectList,
        ]
        for selector in selectors {
            var address = propertyAddress(selector)
            AudioObjectAddPropertyListenerBlock(.system, &address, .main) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    if selector == kAudioHardwarePropertyDevices { self?.deviceListsStale = true }
                    self?.scheduleRefresh()
                }
            }
        }
    }

    /// Core Audio fires bursts of notifications (an app starting can add several processes);
    /// fold each burst into a single refresh.
    private var refreshScheduled = false

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshScheduled = false
                self?.refresh()
            }
        }
    }

    private func tearDown() {
        // With Fader gone nothing listens for F18, so give the Dictation key back.
        if dictationKeyOpensPanel { DictationKeyRemap.apply(false) }
        timer?.invalidate()
        meterTimer?.invalidate()
        micMeter.stop()
        meterHub.stop()
        for tap in taps.values { tap.invalidate() }
        taps.removeAll()
    }
}

/// Snapshot of one direction's devices: the list, which is default, and its system volume.
/// Only standard device properties are touched here; Fader never opens an input stream.
struct DeviceState: Equatable {
    let direction: AudioDirection
    var devices: [AudioDevice] = []
    var current = AudioObjectID.unknown
    var volume: Float?
    var volumeSettable = false
    var muted = false
    var muteSettable = false

    var currentDevice: AudioDevice? { devices.first { $0.id == current } }

    static func read(_ direction: AudioDirection, devices: [AudioDevice]) -> DeviceState {
        let device = AudioDevices.defaultDevice(direction)
        return DeviceState(
            direction: direction,
            devices: devices,
            current: device,
            volume: AudioDevices.volume(of: device, direction),
            volumeSettable: AudioDevices.canSetVolume(of: device, direction),
            muted: AudioDevices.isMuted(device, direction),
            muteSettable: AudioDevices.canMute(device, direction)
        )
    }
}
