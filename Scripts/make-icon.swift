#!/usr/bin/env swift
// Draws MdEdit's app icon and writes Resources/AppIcon.icns.
// Run with: swift Scripts/make-icon.swift

import AppKit
import Foundation

/// The markdown mark — a rounded rectangle holding "M" and a down arrow — on a
/// squircle the shade of the editor's accent.
func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    let unit = size / 1024
    let bounds = NSRect(x: 0, y: 0, width: size, height: size)

    // macOS icons sit inside a squircle with a little breathing room.
    let plate = bounds.insetBy(dx: 100 * unit, dy: 100 * unit)
    let squircle = NSBezierPath(roundedRect: plate, xRadius: 185 * unit, yRadius: 185 * unit)

    NSGradient(
        colors: [
            NSColor(calibratedRed: 0.36, green: 0.52, blue: 0.96, alpha: 1),
            NSColor(calibratedRed: 0.20, green: 0.32, blue: 0.80, alpha: 1),
        ]
    )?.draw(in: squircle, angle: -90)

    // A soft highlight along the top edge, the way glass catches light.
    NSGraphicsContext.saveGraphicsState()
    squircle.addClip()
    NSGradient(
        colors: [
            NSColor(white: 1, alpha: 0.30),
            NSColor(white: 1, alpha: 0.0),
        ]
    )?.draw(in: NSRect(x: plate.minX, y: plate.midY, width: plate.width, height: plate.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // The mark: a rounded outline with M and a descending arrow.
    let markRect = NSRect(
        x: plate.minX + 130 * unit,
        y: plate.minY + 230 * unit,
        width: plate.width - 260 * unit,
        height: plate.height - 460 * unit
    )
    let mark = NSBezierPath(roundedRect: markRect, xRadius: 46 * unit, yRadius: 46 * unit)
    mark.lineWidth = 40 * unit
    NSColor.white.setStroke()
    mark.stroke()

    let inset = markRect.insetBy(dx: 96 * unit, dy: 78 * unit)
    NSColor.white.setFill()

    // "M" as three strokes.
    let m = NSBezierPath()
    m.move(to: NSPoint(x: inset.minX, y: inset.minY))
    m.line(to: NSPoint(x: inset.minX, y: inset.maxY))
    m.line(to: NSPoint(x: inset.minX + inset.width * 0.22, y: inset.maxY))
    m.line(to: NSPoint(x: inset.minX + inset.width * 0.36, y: inset.midY + inset.height * 0.08))
    m.line(to: NSPoint(x: inset.minX + inset.width * 0.50, y: inset.maxY))
    m.line(to: NSPoint(x: inset.minX + inset.width * 0.72, y: inset.maxY))
    m.line(to: NSPoint(x: inset.minX + inset.width * 0.72, y: inset.minY))
    m.line(to: NSPoint(x: inset.minX + inset.width * 0.50, y: inset.minY))
    m.line(to: NSPoint(x: inset.minX + inset.width * 0.50, y: inset.midY - inset.height * 0.10))
    m.line(to: NSPoint(x: inset.minX + inset.width * 0.36, y: inset.minY + inset.height * 0.22))
    m.line(to: NSPoint(x: inset.minX + inset.width * 0.22, y: inset.midY - inset.height * 0.10))
    m.line(to: NSPoint(x: inset.minX + inset.width * 0.22, y: inset.minY))
    m.close()
    m.fill()

    // The arrow.
    let arrowX = inset.minX + inset.width * 0.88
    let stem = NSRect(
        x: arrowX - 22 * unit,
        y: inset.minY + inset.height * 0.34,
        width: 44 * unit,
        height: inset.height * 0.66
    )
    NSBezierPath(rect: stem).fill()

    let head = NSBezierPath()
    head.move(to: NSPoint(x: arrowX - 78 * unit, y: inset.minY + inset.height * 0.40))
    head.line(to: NSPoint(x: arrowX + 78 * unit, y: inset.minY + inset.height * 0.40))
    head.line(to: NSPoint(x: arrowX, y: inset.minY))
    head.close()
    head.fill()

    return image
}

let root = URL(fileURLWithPath: CommandLine.arguments.first.map {
    URL(fileURLWithPath: $0).deletingLastPathComponent().deletingLastPathComponent().path
} ?? ".")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("MdEdit.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for (size, name) in [
    (16, "icon_16x16"), (32, "icon_16x16@2x"),
    (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"),
    (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x"),
] {
    let image = drawIcon(size: CGFloat(size))
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:])
    else { continue }
    try png.write(to: iconset.appendingPathComponent("\(name).png"))
}

let output = root.appendingPathComponent("Resources/AppIcon.icns")
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try process.run()
process.waitUntilExit()
print(process.terminationStatus == 0 ? "wrote \(output.path)" : "iconutil failed")
