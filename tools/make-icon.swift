#!/usr/bin/env swift
import AppKit
import Foundation

// Source: the Android adaptive-icon foreground (transparent PNG/WebP).
// Background colour: matches odit_sync_ic_launcher_background.xml (#252B34).
let foregroundPath = "/Users/robi/StudioProjects/odit_sync/app/src/main/res/mipmap-xxxhdpi/odit_sync_ic_launcher_foreground.webp"
let outputDir = "/Users/robi/StudioProjects/odit_sync_ios/odit-bridge/OditBridge/Assets.xcassets/AppIcon.appiconset"
let logoOutputDir = "/Users/robi/StudioProjects/odit_sync_ios/odit-bridge/OditBridge/Assets.xcassets/AppLogo.imageset"

let bgColor = NSColor(red: 0x25/255.0, green: 0x2B/255.0, blue: 0x34/255.0, alpha: 1.0)

guard let foreground = NSImage(contentsOfFile: foregroundPath) else {
    fputs("ERROR: could not load foreground at \(foregroundPath)\n", stderr)
    exit(1)
}

// Android adaptive-icon spec: foreground asset is 108dp square; only the
// inner 72dp (~67%) is the "safe zone" visible after the launcher mask.
// On macOS we want the visible content to occupy ~80% of the canvas, so
// scale the source up to compensate.
let safeFraction: CGFloat = 72.0 / 108.0
let targetFraction: CGFloat = 0.80
let foregroundScale: CGFloat = targetFraction / safeFraction  // ~1.2

func makeBitmap(size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 32
    )!
    rep.size = NSSize(width: size, height: size)  // 1pt = 1px (no Retina doubling)
    return rep
}

func renderIcon(size: Int) -> Data {
    let rep = makeBitmap(size: size)
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    bgColor.setFill()
    NSRect(x: 0, y: 0, width: size, height: size).fill()

    let drawSize = CGFloat(size) * foregroundScale
    let origin = NSPoint(x: (CGFloat(size) - drawSize) / 2,
                         y: (CGFloat(size) - drawSize) / 2)
    foreground.draw(in: NSRect(origin: origin, size: NSSize(width: drawSize, height: drawSize)),
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1.0)
    return rep.representation(using: .png, properties: [:])!
}

func renderLogo(size: Int) -> Data {
    let rep = makeBitmap(size: size)
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    foreground.draw(in: NSRect(x: 0, y: 0, width: size, height: size),
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1.0)
    return rep.representation(using: .png, properties: [:])!
}

// (logical size, scale, filename)
let appIconEntries: [(Int, Int, String)] = [
    (16, 1, "icon_16x16.png"),
    (16, 2, "icon_16x16@2x.png"),
    (32, 1, "icon_32x32.png"),
    (32, 2, "icon_32x32@2x.png"),
    (128, 1, "icon_128x128.png"),
    (128, 2, "icon_128x128@2x.png"),
    (256, 1, "icon_256x256.png"),
    (256, 2, "icon_256x256@2x.png"),
    (512, 1, "icon_512x512.png"),
    (512, 2, "icon_512x512@2x.png"),
]

let fm = FileManager.default
try? fm.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
try? fm.createDirectory(atPath: logoOutputDir, withIntermediateDirectories: true)

for (logical, scale, filename) in appIconEntries {
    let pixels = logical * scale
    let data = renderIcon(size: pixels)
    let url = URL(fileURLWithPath: "\(outputDir)/\(filename)")
    try? data.write(to: url)
    print("wrote \(filename) (\(pixels)×\(pixels))")
}

var contents: [String: Any] = [
    "info": ["version": 1, "author": "xcode"],
    "images": appIconEntries.map { logical, scale, filename in
        [
            "filename": filename,
            "idiom": "mac",
            "scale": "\(scale)x",
            "size": "\(logical)x\(logical)"
        ]
    }
]
let contentsData = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted])
try contentsData.write(to: URL(fileURLWithPath: "\(outputDir)/Contents.json"))
print("wrote AppIcon Contents.json")

// AppLogo: 1x/2x/3x at logical 128pt for inside the app
for scale in [1, 2, 3] {
    let pixels = 128 * scale
    let data = renderLogo(size: pixels)
    let suffix = scale == 1 ? "" : "@\(scale)x"
    let filename = "logo\(suffix).png"
    try? data.write(to: URL(fileURLWithPath: "\(logoOutputDir)/\(filename)"))
    print("wrote \(filename) (\(pixels)×\(pixels))")
}

let logoContents: [String: Any] = [
    "info": ["version": 1, "author": "xcode"],
    "images": [
        ["filename": "logo.png", "idiom": "universal", "scale": "1x"],
        ["filename": "logo@2x.png", "idiom": "universal", "scale": "2x"],
        ["filename": "logo@3x.png", "idiom": "universal", "scale": "3x"]
    ]
]
let logoContentsData = try JSONSerialization.data(withJSONObject: logoContents, options: [.prettyPrinted])
try logoContentsData.write(to: URL(fileURLWithPath: "\(logoOutputDir)/Contents.json"))
print("wrote AppLogo Contents.json")
