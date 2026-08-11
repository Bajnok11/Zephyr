#!/usr/bin/env swift
// Renders the Zephyr app icon into an .iconset directory.
// Usage: swift make-icon.swift <output.iconset>

import AppKit

let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : NSTemporaryDirectory() + "/AppIcon.iconset"

func drawFan(radius: CGFloat, angle: CGFloat, bladeCount: Int, color: NSColor) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    context.saveGState()
    context.rotate(by: angle)
    color.setFill()

    for index in 0..<bladeCount {
        context.saveGState()
        context.rotate(by: CGFloat(index) * (.pi * 2 / CGFloat(bladeCount)))
        let inner = radius * 0.24
        let outer = radius * 0.96
        let path = NSBezierPath()
        path.move(to: CGPoint(x: 0, y: inner))
        path.curve(to: CGPoint(x: outer * 0.60, y: outer * 0.62),
                   controlPoint1: CGPoint(x: inner * 1.5, y: radius * 0.66),
                   controlPoint2: CGPoint(x: radius * 0.22, y: outer * 0.88))
        path.curve(to: CGPoint(x: inner * 0.85, y: -inner * 0.20),
                   controlPoint1: CGPoint(x: outer * 0.84, y: outer * 0.28),
                   controlPoint2: CGPoint(x: radius * 0.66, y: -inner * 0.30))
        path.close()
        path.fill()
        context.restoreGState()
    }

    let hubRadius = radius * 0.21
    NSBezierPath(ovalIn: CGRect(x: -hubRadius, y: -hubRadius,
                                width: hubRadius * 2, height: hubRadius * 2)).fill()
    context.restoreGState()
}

func icon(size: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        guard let context = NSGraphicsContext.current?.cgContext else { return true }
        let tile = NSBezierPath(roundedRect: rect.insetBy(dx: rect.width * 0.06, dy: rect.width * 0.06),
                                xRadius: rect.width * 0.20, yRadius: rect.width * 0.20)
        NSGradient(colors: [
            NSColor(calibratedRed: 0.10, green: 0.42, blue: 0.95, alpha: 1),
            NSColor(calibratedRed: 0.32, green: 0.84, blue: 0.88, alpha: 1),
        ])?.draw(in: tile, angle: 240)

        context.saveGState()
        context.translateBy(x: rect.midX, y: rect.midY)
        drawFan(radius: rect.width * 0.30, angle: 0.45, bladeCount: 3, color: .white)
        context.restoreGState()
        return true
    }
}

func writePNG(_ image: NSImage, pixels: Int, to url: URL) throws {
    guard let representation = NSBitmapImageRep(bitmapDataPlanes: nil,
                                                pixelsWide: pixels, pixelsHigh: pixels,
                                                bitsPerSample: 8, samplesPerPixel: 4,
                                                hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB,
                                                bytesPerRow: 0, bitsPerPixel: 0) else { return }
    representation.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    guard let data = representation.representation(using: .png, properties: [:]) else { return }
    try data.write(to: url)
}

let directory = URL(fileURLWithPath: outputPath)
try? FileManager.default.removeItem(at: directory)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for variant in variants {
    let image = icon(size: CGFloat(variant.pixels))
    try writePNG(image, pixels: variant.pixels, to: directory.appendingPathComponent("\(variant.name).png"))
}

print(outputPath)
