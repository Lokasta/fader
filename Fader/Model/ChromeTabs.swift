import AppKit
import Foundation

struct ChromeTab: Decodable, Identifiable, Equatable {
    let id: String
    let windowID: Int
    let documentID: String
    let title: String
    let url: String
    let playingCount: Int
    let hasVideo: Bool
    var volume: Double
    var muted: Bool

    var site: String { URL(string: url)?.host?.replacingOccurrences(of: "www.", with: "") ?? "Chrome" }
    var update: ChromeTabUpdate {
        ChromeTabUpdate(id: id, windowID: windowID, documentID: documentID, volume: volume, muted: muted)
    }
}

/// Only playing audio/video is listed. Tab identities and settings live in memory, never on disk.
@MainActor
final class ChromeTabs: ObservableObject {
    enum Status { case disabled, connecting, ready, automationDenied, javascriptDisabled, unavailable }
    @Published private(set) var tabs: [ChromeTab] = []
    @Published private(set) var status = Status.disabled
    @Published private(set) var isEnabled: Bool

    private let client: ChromeTabClient
    private let defaults: UserDefaults
    private let leaseID = UUID().uuidString
    private var managed: [String: ChromeTabUpdate] = [:]
    private var pending: [String: ChromeTabUpdate] = [:]
    private var inFlight = false
    private var authorizing = false
    private var lastRefresh = Date.distantPast
    private var debounce: Task<Void, Never>?
    private static let enabledKey = "chromeTabControlsEnabled"

    init(client: ChromeTabClient = ChromeAutomation(), defaults: UserDefaults = .standard) {
        self.client = client
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        if isEnabled { status = .connecting }
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
        if enabled { retry() }
        else {
            tabs = []
            status = .disabled
            Task { await restore() }
        }
    }

    func retry() {
        guard isEnabled else { return setEnabled(true) }
        guard !authorizing else { return }
        status = .connecting
        authorizing = true
        Task { [weak self] in
            guard let self else { return }
            do {
                try await client.authorize()
                authorizing = false
                if isEnabled { refresh(visible: true, force: true) }
            } catch {
                authorizing = false
                if isEnabled { status = .automationDenied }
            }
        }
    }

    func setVolume(_ volume: Double, for id: String) {
        change(id) { $0.volume = min(max(volume, 0), 1) }
    }

    func toggleMute(_ id: String) { change(id) { $0.muted.toggle() } }

    func reset(_ id: String) { change(id) { $0.volume = 1; $0.muted = false } }

    private func change(_ id: String, _ edit: (inout ChromeTab) -> Void) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        edit(&tabs[index])
        var update = tabs[index].update
        update.restore = update.volume == 1 && !update.muted
        pending[id] = update
        if update.restore { managed.removeValue(forKey: id) } else { managed[id] = update }
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            self?.refresh(visible: true, force: true)
        }
    }

    func refresh(visible: Bool, force: Bool = false) {
        guard isEnabled, !inFlight, !authorizing else { return }
        guard force || status == .ready || status == .connecting else { return }
        guard visible || !managed.isEmpty || !pending.isEmpty else { return }
        guard force || Date().timeIntervalSince(lastRefresh) >= (visible ? 1 : 3) else { return }
        guard client.isRunning else {
            tabs = []
            managed = [:]
            pending = [:]
            status = .ready
            return
        }
        lastRefresh = Date()
        inFlight = true
        let sent = pending
        var updates = managed
        updates.merge(sent) { _, new in new }
        Task { [weak self] in
            guard let self else { return }
            do {
                let reply = try await client.execute(updates: Array(updates.values), scanAll: visible, leaseID: leaseID)
                let unavailable = Set(reply.unavailableTabIDs)
                for (id, update) in sent where pending[id] == update && !unavailable.contains(id) { pending.removeValue(forKey: id) }
                if isEnabled {
                    // Never let an older poll overwrite a slider movement made while it ran.
                    tabs = Self.playingTabs(reply.tabs).map { tab in
                        guard let update = self.pending[tab.id], update.documentID == tab.documentID else { return tab }
                        var next = tab
                        next.volume = update.volume
                        next.muted = update.muted
                        return next
                    }
                    let documents = Dictionary(reply.tabs.map { ($0.id, $0.documentID) }, uniquingKeysWith: { _, new in new })
                    managed = managed.filter { unavailable.contains($0.key) || documents[$0.key] == $0.value.documentID }
                    status = reply.javascriptBlocked ? .javascriptDisabled : .ready
                }
            } catch {
                if isEnabled {
                    tabs = []
                    switch error {
                    case ChromeAutomation.Failure.automationDenied: status = .automationDenied
                    case ChromeAutomation.Failure.javascriptDisabled: status = .javascriptDisabled
                    default: status = .unavailable
                    }
                }
            }
            inFlight = false
            // Failed tabs retry on the normal timer, rather than spinning without delay.
            if pending.contains(where: { sent[$0.key] != $0.value }), isEnabled, status == .ready { refresh(visible: visible, force: true) }
        }
    }

    static func playingTabs(_ tabs: [ChromeTab]) -> [ChromeTab] {
        tabs.filter { $0.playingCount > 0 }.sorted {
            let comparison = $0.title.localizedStandardCompare($1.title)
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        }
    }

    func restore() async {
        debounce?.cancel()
        var updates = managed
        updates.merge(pending) { _, new in new }
        let releases = updates.values.map { update -> ChromeTabUpdate in
            var next = update
            next.restore = true
            return next
        }
        if !releases.isEmpty, client.isRunning {
            _ = try? await client.execute(updates: releases, scanAll: false, leaseID: leaseID)
        }
        managed = [:]
        pending = [:]
    }

    func prepareForQuit() async {
        // Stop polling without forgetting the user's opt-in for the next launch.
        isEnabled = false
        await restore()
    }

    func openAutomationSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
    }

    func loadPreview() {
        isEnabled = true
        status = .ready
        tabs = [
            ChromeTab(id: "preview-music", windowID: 1, documentID: "preview", title: "Late night jazz · live radio", url: "https://www.youtube.com", playingCount: 1, hasVideo: true, volume: 0.35, muted: false),
            ChromeTab(id: "preview-podcast", windowID: 1, documentID: "preview", title: "Building better software: conversations with makers and designers", url: "https://example.com", playingCount: 1, hasVideo: false, volume: 0.8, muted: true),
        ]
    }
}
