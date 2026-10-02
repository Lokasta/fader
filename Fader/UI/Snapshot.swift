import AppKit
import SwiftUI

/// `Fader --snapshot out.png` renders the live panel to a PNG and exits.
/// Used to check layout without clicking the menu bar, and for README screenshots.
enum Snapshot {
    static var requestedPath: String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    @MainActor
    static func run(to path: String, mixer: Mixer) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            mixer.refresh()
            let host = NSHostingView(rootView: MixerView().environmentObject(mixer).background(Color(nsColor: .windowBackgroundColor)))
            host.frame.size = host.fittingSize
            let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = host
            window.backgroundColor = .windowBackgroundColor
            host.layoutSubtreeIfNeeded()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { exit(1) }
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                exit(0)
            }
        }
    }
}
