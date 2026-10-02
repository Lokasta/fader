import SwiftUI

@main
struct FaderApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @StateObject private var mixer: Mixer

    init() {
        let mixer = Mixer()
        _mixer = StateObject(wrappedValue: mixer)
        AppDelegate.mixer = mixer
        if let path = Snapshot.requestedPath { Snapshot.run(to: path, mixer: mixer) }
    }

    var body: some Scene {
        MenuBarExtra {
            MixerView()
                .environmentObject(mixer)
        } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .menuBarExtraStyle(.window)
    }
}

/// Handles `fader://panel`, sent by the Control Center control. Registered as a raw Apple Event
/// handler because SwiftUI swallows URLs before `application(_:open:)` in menu bar-only apps.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var mixer: Mixer?
    @MainActor private lazy var panel: FloatingPanel? = Self.mixer.map(FloatingPanel.init)
    private var hotKey: GlobalHotKey?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURL(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        hotKey = GlobalHotKey { [weak self] in
            MainActor.assumeIsolated { self?.panel?.toggle() }
        }
    }

    /// Opening Fader again (Spotlight, Finder, Dock) shows the panel: the reliable way in
    /// when a crowded menu bar hides the icon behind the notch.
    @MainActor
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel?.show()
        return false
    }

    @MainActor @objc
    private func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              URL(string: text)?.scheme == "fader" else { return }
        panel?.toggle()
    }
}
