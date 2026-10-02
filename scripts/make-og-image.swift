#!/usr/bin/env swift
// Renders the 1200x630 social card for the landing page (site/assets/og.png):
// app icon, title and tagline on the left, the panel screenshot on the right, over a dark gradient.
// Usage (from the repo root): swift scripts/make-og-image.swift
import AppKit

let width = 1200, height = 630
let iconURL = URL(fileURLWithPath: "Fader/Assets.xcassets/AppIcon.appiconset/icon_512x512.png")
// The social card uses a render of the site's interactive panel (clean demo apps, 3x).
let panelURL = URL(fileURLWithPath: "site/assets/demo-panel.png")
let output = URL(fileURLWithPath: "site/assets/og.png")

guard let icon = NSImage(contentsOf: iconURL), let panel = NSImage(contentsOf: panelURL) else {
    fatalError("Run from the repo root: missing \(iconURL.path) or \(panelURL.path)")
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: width, height: height)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.imageInterpolation = .high

let canvas = NSRect(x: 0, y: 0, width: width, height: height)

// Background: near-black indigo with the icon's violet glowing from the right.
NSGradient(colors: [
    NSColor(calibratedRed: 0.05, green: 0.04, blue: 0.11, alpha: 1),
    NSColor(calibratedRed: 0.09, green: 0.06, blue: 0.22, alpha: 1),
])!.draw(in: canvas, angle: -30)
NSGradient(colors: [
    NSColor(calibratedRed: 0.42, green: 0.28, blue: 1.0, alpha: 0.45),
    NSColor(calibratedRed: 0.42, green: 0.28, blue: 1.0, alpha: 0),
])!.draw(fromCenter: NSPoint(x: 900, y: 360), radius: 0, toCenter: NSPoint(x: 900, y: 360), radius: 520, options: [])
NSGradient(colors: [
    NSColor(calibratedRed: 0.55, green: 0.85, blue: 1.0, alpha: 0.12),
    NSColor(calibratedRed: 0.55, green: 0.85, blue: 1.0, alpha: 0),
])!.draw(fromCenter: NSPoint(x: 80, y: 600), radius: 0, toCenter: NSPoint(x: 80, y: 600), radius: 420, options: [])

// Panel screenshot on the right, rounded with a soft shadow.
let panelWidth: CGFloat = 520
let panelHeight = panelWidth * panel.size.height / panel.size.width
let panelRect = NSRect(x: CGFloat(width) - panelWidth - 64, y: (CGFloat(height) - panelHeight) / 2,
                       width: panelWidth, height: panelHeight)
let panelShape = NSBezierPath(roundedRect: panelRect, xRadius: 22, yRadius: 22)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
shadow.shadowBlurRadius = 50
shadow.shadowOffset = NSSize(width: 0, height: -20)
shadow.set()
NSColor(calibratedWhite: 0.11, alpha: 1).setFill()
panelShape.fill()
NSGraphicsContext.restoreGraphicsState()
NSGraphicsContext.saveGraphicsState()
panelShape.addClip()
panel.draw(in: panelRect, from: .zero, operation: .sourceOver, fraction: 1)
NSGraphicsContext.restoreGraphicsState()
NSColor.white.withAlphaComponent(0.08).setStroke()
panelShape.lineWidth = 1.5
panelShape.stroke()

// Left column: icon, title, tagline, footnote.
let left: CGFloat = 72
icon.draw(in: NSRect(x: left - 14, y: 400, width: 150, height: 150), from: .zero, operation: .sourceOver, fraction: 1)

func font(_ size: CGFloat, _ weight: NSFont.Weight, rounded: Bool = false) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    if rounded, let descriptor = base.fontDescriptor.withDesign(.rounded) {
        return NSFont(descriptor: descriptor, size: size) ?? base
    }
    return base
}

func draw(_ text: String, at point: NSPoint, width: CGFloat, font: NSFont, color: NSColor, kern: CGFloat = 0, lineHeight: CGFloat? = nil) {
    let style = NSMutableParagraphStyle()
    if let lineHeight { style.minimumLineHeight = lineHeight; style.maximumLineHeight = lineHeight }
    let attributed = NSAttributedString(string: text, attributes: [
        .font: font, .foregroundColor: color, .kern: kern, .paragraphStyle: style,
    ])
    let bounds = attributed.boundingRect(with: NSSize(width: width, height: 400), options: [.usesLineFragmentOrigin])
    attributed.draw(with: NSRect(x: point.x, y: point.y - bounds.height, width: width, height: bounds.height),
                    options: [.usesLineFragmentOrigin])
}

let textWidth: CGFloat = 520
draw("Lokasta's Fader", at: NSPoint(x: left, y: 392), width: textWidth,
     font: font(62, .heavy, rounded: true), color: .white, kern: -1.5)
draw("Per-app volume for macOS,\nfrom the menu bar or Control Center.", at: NSPoint(x: left, y: 300), width: textWidth,
     font: font(27, .medium), color: NSColor(calibratedRed: 0.80, green: 0.78, blue: 0.92, alpha: 1), lineHeight: 36)
draw("NO DRIVERS  ·  NO VIRTUAL DEVICES  ·  FREE", at: NSPoint(x: left, y: 150), width: textWidth,
     font: NSFont.monospacedSystemFont(ofSize: 15, weight: .medium),
     color: NSColor(calibratedRed: 0.55, green: 0.85, blue: 1.0, alpha: 1), kern: 1.2)

NSGraphicsContext.restoreGraphicsState()
try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
try rep.representation(using: .png, properties: [:])!.write(to: output)
print("Social card written to \(output.path)")
