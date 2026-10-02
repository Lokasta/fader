import AppKit
import SwiftUI

/// Thin live level meter drawn under a volume slider. Green, then yellow near -6 dB, red near clipping.
struct LevelBar: View {
    let level: Float

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(
                        stops: [
                            .init(color: .green, location: 0),
                            .init(color: .green, location: 0.78),
                            .init(color: .yellow, location: 0.9),
                            .init(color: .red, location: 1),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    ))
                    // The gradient spans the full track; the mask reveals only the current level.
                    .mask(alignment: .leading) {
                        Capsule().frame(width: geometry.size.width * CGFloat(level))
                    }
            }
        }
        .frame(height: 3)
        .accessibilityHidden(true)
    }
}

/// Reports whether the hosting window is actually on screen. Drives metering on/off for
/// both the menu bar popover and the floating panel, so the mic is never read while hidden.
struct WindowVisibility: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> VisibilityView {
        let view = VisibilityView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: VisibilityView, context: Context) {
        view.onChange = onChange
    }

    final class VisibilityView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observer: Any?
        private var isShown = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            if let window {
                observer = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                    self?.update()
                }
            }
            update()
        }

        private func update() {
            let shown = window.map { $0.isVisible && $0.occlusionState.contains(.visible) } ?? false
            guard shown != isShown else { return }
            isShown = shown
            onChange?(shown)
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}
