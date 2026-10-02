import AppKit
import Combine
import SwiftUI
import os

/// The mixer as a Control Center-style popover in the top-right corner of the active screen.
/// Opened by the Control Center control (`fader://panel`); closes on click outside or Esc.
@MainActor
final class FloatingPanel {
    private var panel: NSPanel?
    private var outsideClickMonitor: Any?
    private var contentChanges: AnyCancellable?
    private var shownAt = Date.distantPast
    private let mixer: Mixer
    private let log = Logger(subsystem: "com.lokasta.fader", category: "panel")

    init(mixer: Mixer) {
        self.mixer = mixer
    }

    func toggle() {
        if let panel, panel.isVisible { close() } else { show() }
    }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        mixer.refresh()

        panel.contentView?.layoutSubtreeIfNeeded()
        anchorToTopRight(panel)

        shownAt = Date()
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        log.info("panel shown at \(String(describing: panel.frame), privacy: .public) key=\(panel.isKeyWindow)")

        outsideClickMonitor = outsideClickMonitor ?? NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    func close() {
        if panel?.isVisible == true { log.info("panel closed") }
        panel?.orderOut(nil)
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
    }

    /// Pins the panel's top-right corner under the menu bar, like Control Center.
    /// Called again whenever the content resizes (an app starts or stops playing).
    private func anchorToTopRight(_ panel: NSPanel) {
        var size = panel.contentView?.fittingSize ?? .zero
        if size.width < 1 { size = NSSize(width: 340, height: 300) }
        let screen = panel.isVisible ? panel.screen : NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
        guard let visible = (screen ?? NSScreen.main)?.visibleFrame else { return }
        let frame = NSRect(x: visible.maxX - size.width - 10, y: visible.maxY - size.height - 6, width: size.width, height: size.height)
        if frame != panel.frame { panel.setFrame(frame, display: true) }
    }

    private func makePanel() -> NSPanel {
        let panel = KeyablePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.onCancel = { [weak self] in self?.close() }

        let root = MixerView()
            .environmentObject(mixer)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        let host = NSHostingView(rootView: root)
        // The panel owns its frame; letting SwiftUI resize the window too creates a layout loop.
        host.sizingOptions = []
        panel.contentView = host

        // Rows appear and disappear as apps start/stop playing: refit outside the layout pass.
        contentChanges = mixer.objectWillChange
            .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
            .sink { [weak self, weak panel] _ in
                MainActor.assumeIsolated {
                    guard let self, let panel, panel.isVisible else { return }
                    self.anchorToTopRight(panel)
                }
            }
        // Whoever launched us (Spotlight, a terminal) grabs focus back right after opening.
        // That isn't the user leaving, so reclaim focus; real outside clicks still close.
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self, weak panel] _ in
            MainActor.assumeIsolated {
                guard let self, let panel, panel.isVisible else { return }
                if Date().timeIntervalSince(self.shownAt) < 1.5 {
                    NSApp.activate()
                    panel.makeKeyAndOrderFront(nil)
                } else {
                    self.close()
                }
            }
        }
        return panel
    }
}

/// Borderless panels refuse key status by default; sliders and menus need it.
private final class KeyablePanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) { onCancel?() }
}
