import AppIntents
import SwiftUI
import WidgetKit

/// Control Center / menu bar control. Third-party controls can only be buttons or toggles
/// (the system Sound slider is Apple-only), so this one opens Fader's full panel.
@main
struct FaderControls: WidgetBundle {
    var body: some Widget {
        OpenFaderControl()
    }
}

struct OpenFaderControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.lokasta.fader.open") {
            ControlWidgetButton(action: OpenURLIntent(URL(string: "fader://panel")!)) {
                Label("Fader", systemImage: "slider.horizontal.3")
            }
        }
        .displayName("Fader")
        .description("Volume de cada app, saída e microfone.")
    }
}
