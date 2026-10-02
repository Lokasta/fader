#!/usr/bin/env swift
// Renders the Fader app icon (three mixer faders on a deep gradient) into the asset catalog.
// Usage: swift scripts/make-icon.swift
import AppKit

let output = URL(fileURLWithPath: "Fader/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func render(size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // macOS icon grid: 824/1024 body with ~185/1024 corner radius.
    let inset = s * 100 / 1024
    let body = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let shape = NSBezierPath(roundedRect: body, xRadius: s * 185 / 1024, yRadius: s * 185 / 1024)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = s * 20 / 1024
    shadow.shadowOffset = NSSize(width: 0, height: -s * 8 / 1024)
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(colors: [
        NSColor(calibratedRed: 0.36, green: 0.22, blue: 0.95, alpha: 1),
        NSColor(calibratedRed: 0.10, green: 0.07, blue: 0.30, alpha: 1),
    ])!.draw(in: shape, angle: -90)

    // Three fader tracks with knobs at different heights.
    let levels: [CGFloat] = [0.68, 0.35, 0.82]
    let trackHeight = body.height * 0.56
    let trackBottom = body.midY - trackHeight / 2
    let spacing = body.width * 0.22
    for (index, level) in levels.enumerated() {
        let x = body.midX + CGFloat(index - 1) * spacing
        let trackWidth = s * 22 / 1024
        let track = NSBezierPath(roundedRect: NSRect(x: x - trackWidth / 2, y: trackBottom, width: trackWidth, height: trackHeight),
                                 xRadius: trackWidth / 2, yRadius: trackWidth / 2)
        NSColor.white.withAlphaComponent(0.22).setFill()
        track.fill()

        let filled = NSBezierPath(roundedRect: NSRect(x: x - trackWidth / 2, y: trackBottom, width: trackWidth, height: trackHeight * level),
                                  xRadius: trackWidth / 2, yRadius: trackWidth / 2)
        NSColor(calibratedRed: 0.55, green: 0.85, blue: 1, alpha: 0.9).setFill()
        filled.fill()

        let knobSize = NSSize(width: s * 120 / 1024, height: s * 58 / 1024)
        let knobRect = NSRect(x: x - knobSize.width / 2, y: trackBottom + trackHeight * level - knobSize.height / 2,
                              width: knobSize.width, height: knobSize.height)
        NSGraphicsContext.saveGraphicsState()
        let knobShadow = NSShadow()
        knobShadow.shadowColor = NSColor.black.withAlphaComponent(0.4)
        knobShadow.shadowBlurRadius = s * 10 / 1024
        knobShadow.shadowOffset = NSSize(width: 0, height: -s * 4 / 1024)
        knobShadow.set()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: knobRect, xRadius: knobSize.height / 2, yRadius: knobSize.height / 2).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try render(size: pixels).write(to: output.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}

let contents: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: output.appendingPathComponent("Contents.json"))
try #"{"info":{"author":"xcode","version":1}}"#.data(using: .utf8)!
    .write(to: output.deletingLastPathComponent().appendingPathComponent("Contents.json"))
print("Icon written to \(output.path)")
