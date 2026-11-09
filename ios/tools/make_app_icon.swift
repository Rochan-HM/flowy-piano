#!/usr/bin/env swift
// Draws the 1024×1024 app icon: piano keys under a saffron "सा" (Sa).
// Usage: swift tools/make_app_icon.swift IndianPiano/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png
import AppKit

let output = CommandLine.arguments.dropFirst().first ?? "AppIcon.png"
let size = 1024
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0) else { fatalError("bitmap") }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let canvas = NSRect(x: 0, y: 0, width: size, height: size)
NSGradient(colors: [NSColor(calibratedRed: 0.13, green: 0.09, blue: 0.24, alpha: 1),
                    NSColor(calibratedRed: 0.05, green: 0.05, blue: 0.10, alpha: 1)])!
    .draw(in: canvas, angle: -90)

// Keys
let keyTop: CGFloat = 430
let whiteWidth: CGFloat = 1024 / 7
for index in 0..<7 {
    let rect = NSRect(x: CGFloat(index) * whiteWidth + 6, y: -40, width: whiteWidth - 12, height: keyTop + 40)
    let path = NSBezierPath(roundedRect: rect, xRadius: 26, yRadius: 26)
    (index == 0 ? NSColor(calibratedRed: 1, green: 0.62, blue: 0.22, alpha: 1) : NSColor(white: 0.96, alpha: 1)).setFill()
    path.fill()
}
for boundary in [1, 2, 4, 5, 6] {
    let width = whiteWidth * 0.58
    let rect = NSRect(x: CGFloat(boundary) * whiteWidth - width / 2, y: keyTop - 250, width: width, height: 250)
    NSColor(white: 0.08, alpha: 1).setFill()
    NSBezierPath(roundedRect: rect, xRadius: 18, yRadius: 18).fill()
}

// Glyph
let font = NSFont(name: "KohinoorDevanagari-Semibold", size: 380) ?? NSFont.systemFont(ofSize: 380, weight: .semibold)
let attributes: [NSAttributedString.Key: Any] = [
    .font: font,
    .foregroundColor: NSColor(calibratedRed: 1, green: 0.66, blue: 0.27, alpha: 1),
]
let glyph = NSAttributedString(string: "सा", attributes: attributes)
let glyphSize = glyph.size()
glyph.draw(at: NSPoint(x: (CGFloat(size) - glyphSize.width) / 2, y: keyTop + (CGFloat(size) - keyTop - glyphSize.height) / 2 + 10))

NSGraphicsContext.restoreGraphicsState()
guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("png") }
try png.write(to: URL(fileURLWithPath: output))
print("wrote \(output)")
