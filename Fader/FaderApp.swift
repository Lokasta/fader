import SwiftUI

@main
struct FaderApp: App {
    @StateObject private var mixer: Mixer

    init() {
        let mixer = Mixer()
        _mixer = StateObject(wrappedValue: mixer)
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
