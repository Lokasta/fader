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
            if CommandLine.arguments.contains("--snapshot-chrome-tabs") { mixer.loadChromeTabsPreview() }
            let host = NSHostingView(rootView: MixerView().environmentObject(mixer).background(Color(nsColor: .windowBackgroundColor)))
            host.frame.size = host.fittingSize
            let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = host
            window.backgroundColor = .windowBackgroundColor
            host.layoutSubtreeIfNeeded()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                // Rendered at 3x so README and social images stay sharp on Retina screens.
                let scale = 3
                guard let rep = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: Int(host.bounds.width) * scale, pixelsHigh: Int(host.bounds.height) * scale,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
                ) else { exit(1) }
                rep.size = host.bounds.size
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                exit(0)
            }
        }
    }
}
