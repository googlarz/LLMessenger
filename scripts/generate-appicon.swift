#!/usr/bin/env swift
// Generates the AppIcon asset catalog from the Wire Desk design system.
// Deterministic and reproducible: the icon is code, not a binary artifact.
//
//   swift scripts/generate-appicon.swift
//
// Design: the brief glyph — three typeset lines on deep ink, the top line in
// signal vermilion (the one that needs you). Mirrors the menu bar glyph so the
// dock, Finder, and menu bar read as one product.

import AppKit
import CoreGraphics

// Wire Desk tokens (Theme.swift)
let inkTop     = CGColor(red: 0.075, green: 0.094, blue: 0.125, alpha: 1) // #131820
let inkBottom  = CGColor(red: 0.039, green: 0.051, blue: 0.067, alpha: 1) // #0A0D11
let paper      = CGColor(red: 0.929, green: 0.910, blue: 0.871, alpha: 1) // #EDE8DE
let vermilion  = CGColor(red: 0.886, green: 0.310, blue: 0.196, alpha: 1) // #E24F32
let hairline   = CGColor(red: 0.227, green: 0.247, blue: 0.271, alpha: 0.9)

func drawMaster(size: Int) -> CGImage {
    let s = CGFloat(size)
    let ctx = CGContext(
        data: nil, width: size, height: size,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!

    // macOS icon grid: 1024 canvas, 824pt rounded square, ~185pt corner radius.
    let plate = CGRect(x: s * 100/1024, y: s * 100/1024, width: s * 824/1024, height: s * 824/1024)
    let radius = s * 185/1024
    let platePath = CGPath(roundedRect: plate, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Ink plate with a quiet vertical gradient.
    ctx.saveGState()
    ctx.addPath(platePath)
    ctx.clip()
    let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [inkTop, inkBottom] as CFArray, locations: [0, 1]
    )!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: plate.midX, y: plate.maxY),
                           end: CGPoint(x: plate.midX, y: plate.minY),
                           options: [])

    // Hairline plate edge — the printed border of a card.
    ctx.addPath(CGPath(roundedRect: plate.insetBy(dx: s * 3/1024, dy: s * 3/1024),
                       cornerWidth: radius - s * 3/1024, cornerHeight: radius - s * 3/1024,
                       transform: nil))
    ctx.setStrokeColor(hairline)
    ctx.setLineWidth(s * 4/1024)
    ctx.strokePath()

    // The brief: three lines, top one vermilion. Left-aligned block, centered.
    let lineHeight = s * 64/1024
    let gap        = s * 92/1024
    let leftX      = s * 312/1024
    let widths: [CGFloat] = [s * 400/1024, s * 400/1024, s * 252/1024]
    let colors: [CGColor] = [vermilion, paper, paper]
    let blockHeight = 3 * lineHeight + 2 * gap
    var y = (s - blockHeight) / 2 + blockHeight - lineHeight  // top line first

    for (width, color) in zip(widths, colors) {
        let bar = CGRect(x: leftX, y: y, width: width, height: lineHeight)
        ctx.addPath(CGPath(roundedRect: bar, cornerWidth: lineHeight / 2,
                           cornerHeight: lineHeight / 2, transform: nil))
        ctx.setFillColor(color)
        ctx.fillPath()
        y -= lineHeight + gap
    }

    ctx.restoreGState()
    return ctx.makeImage()!
}

func resize(_ image: CGImage, to size: Int) -> CGImage {
    let ctx = CGContext(
        data: nil, width: size, height: size,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: image.width, height: image.height)
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

// MARK: - Main

let scriptDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let repoRoot = scriptDir.deletingLastPathComponent()
let iconset = repoRoot.appendingPathComponent("LLMessenger/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let master = drawMaster(size: 1024)
let entries: [(point: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2),
]

var images: [[String: String]] = []
for (point, scale) in entries {
    let pixels = point * scale
    let name = "icon_\(point)x\(point)\(scale == 2 ? "@2x" : "").png"
    try writePNG(pixels == 1024 ? master : resize(master, to: pixels),
                 to: iconset.appendingPathComponent(name))
    images.append([
        "filename": name,
        "idiom": "mac",
        "scale": "\(scale)x",
        "size": "\(point)x\(point)",
    ])
    print("wrote \(name)")
}

let contents: [String: Any] = [
    "images": images,
    "info": ["author": "xcode", "version": 1],
]
let data = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try data.write(to: iconset.appendingPathComponent("Contents.json"))

// Root catalog Contents.json
let catalogContents = try JSONSerialization.data(
    withJSONObject: ["info": ["author": "xcode", "version": 1]], options: [.prettyPrinted])
try catalogContents.write(to: repoRoot.appendingPathComponent("LLMessenger/Assets.xcassets/Contents.json"))

print("AppIcon catalog written to \(iconset.path)")
