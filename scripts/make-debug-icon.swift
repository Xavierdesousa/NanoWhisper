#!/usr/bin/env swift
// Generates the "NanoWhisper Debug" app icon: the production icon with an orange
// "DEBUG" banner across its lower part.
//
// Usage: swift scripts/make-debug-icon.swift <source AppIcon.png> <output directory>
//
// Writes <output>/AppIcon.png (1024 px master), <output>/AppIcon.iconset/ and
// <output>/AppIcon.icns (via iconutil). Uses only AppKit/CoreGraphics so no extra
// tools are needed. The Makefile runs it only when the source icon or this script changes.

import AppKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write("usage: make-debug-icon.swift <AppIcon.png> <output-dir>\n".data(using: .utf8)!)
    exit(64)
}
let sourceURL = URL(fileURLWithPath: arguments[1])
let outputURL = URL(fileURLWithPath: arguments[2], isDirectory: true)

guard let source = NSImage(contentsOf: sourceURL) else {
    FileHandle.standardError.write("cannot read \(sourceURL.path)\n".data(using: .utf8)!)
    exit(1)
}

let masterSize = 1024

/// A bitmap context of `pixels` x `pixels` with NSGraphicsContext set as current.
func render(pixels: Int, _ draw: (NSRect) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    context.imageInterpolation = .high
    NSGraphicsContext.current = context
    draw(NSRect(x: 0, y: 0, width: pixels, height: pixels))
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

/// Grayscale mask of the icon's opaque body. The source PNG has a soft drop shadow
/// (alpha <= ~0.25) around a hard-edged squircle (alpha 1), so remapping alpha
/// 0.3...1 to 0...1 keeps the squircle with its anti-aliased edge and drops the shadow.
func silhouetteMask(of icon: NSBitmapImageRep) -> CGImage {
    // `icon` comes from `render`: 8-bit RGBA, non-planar, alpha last, rows top to bottom.
    let width = icon.pixelsWide, height = icon.pixelsHigh, rowBytes = icon.bytesPerRow
    let data = icon.bitmapData!
    var pixels = [UInt8](repeating: 0, count: width * height)
    for y in 0..<height {
        for x in 0..<width {
            let alpha = Double(data[y * rowBytes + x * 4 + 3]) / 255
            let value = min(max((alpha - 0.3) / 0.7, 0), 1)
            pixels[y * width + x] = UInt8((value * 255).rounded())
        }
    }
    let provider = CGDataProvider(data: Data(pixels) as CFData)!
    return CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
        provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
    )!
}

/// The production icon with the banner composited on top (1024 px, origin bottom-left).
func makeMaster() -> NSBitmapImageRep {
    let base = render(pixels: masterSize) { rect in
        source.draw(in: rect, from: .zero, operation: .copy, fraction: 1)
    }
    let mask = silhouetteMask(of: base)
    return render(pixels: masterSize) { rect in
        base.draw(in: rect)
        let cg = NSGraphicsContext.current!.cgContext
        let s = rect.width / 1024

        // Banner: full-width band below the glyph, clipped to the icon's squircle so it
        // follows the rounded corners and never paints into the drop shadow.
        let band = NSRect(x: 0, y: 150 * s, width: rect.width, height: 168 * s)
        cg.saveGState()
        cg.clip(to: rect, mask: mask)
        let gradient = NSGradient(
            starting: NSColor(srgbRed: 1.00, green: 0.62, blue: 0.10, alpha: 1),
            ending: NSColor(srgbRed: 0.96, green: 0.42, blue: 0.00, alpha: 1)
        )!
        gradient.draw(in: band, angle: -90)
        // Thin darker edges keep the band crisp against the purple when scaled down.
        NSColor(srgbRed: 0.70, green: 0.27, blue: 0.00, alpha: 1).setFill()
        NSRect(x: 0, y: band.minY, width: rect.width, height: 6 * s).fill()
        NSRect(x: 0, y: band.maxY - 6 * s, width: rect.width, height: 6 * s).fill()
        cg.restoreGState()

        // Label
        let font = NSFont.systemFont(ofSize: 132 * s, weight: .black)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(srgbRed: 0.45, green: 0.15, blue: 0.0, alpha: 0.55)
        shadow.shadowOffset = NSSize(width: 0, height: -4 * s)
        shadow.shadowBlurRadius = 6 * s
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
            .kern: 10 * s,
            .shadow: shadow,
        ]
        let text = NSAttributedString(string: "DEBUG", attributes: attributes)
        let bounds = text.boundingRect(with: .zero, options: [.usesLineFragmentOrigin, .usesFontLeading])
        // Center on the band using cap height so the optical center ignores descenders.
        let baselineY = band.midY - font.capHeight / 2
        let origin = NSPoint(x: rect.midX - (bounds.width - 10 * s) / 2, y: baselineY + font.descender)
        text.draw(with: NSRect(origin: origin, size: bounds.size), options: [.usesLineFragmentOrigin, .usesFontLeading])
    }
}

func writePNG(_ rep: NSBitmapImageRep, to url: URL) throws {
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "make-debug-icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "PNG encoding failed"])
    }
    try data.write(to: url)
}

do {
    let fm = FileManager.default
    try fm.createDirectory(at: outputURL, withIntermediateDirectories: true)
    let master = makeMaster()
    try writePNG(master, to: outputURL.appendingPathComponent("AppIcon.png"))

    let masterImage = NSImage(size: NSSize(width: masterSize, height: masterSize))
    masterImage.addRepresentation(master)

    let iconset = outputURL.appendingPathComponent("AppIcon.iconset", isDirectory: true)
    try? fm.removeItem(at: iconset)
    try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
    for points in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let pixels = points * scale
            let rep = pixels == masterSize ? master : render(pixels: pixels) { rect in
                masterImage.draw(in: rect, from: .zero, operation: .copy, fraction: 1)
            }
            let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
            try writePNG(rep, to: iconset.appendingPathComponent(name))
        }
    }

    let icns = outputURL.appendingPathComponent("AppIcon.icns")
    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = ["-c", "icns", "-o", icns.path, iconset.path]
    try iconutil.run()
    iconutil.waitUntilExit()
    guard iconutil.terminationStatus == 0 else {
        FileHandle.standardError.write("iconutil failed (\(iconutil.terminationStatus))\n".data(using: .utf8)!)
        exit(1)
    }
    print("Generated \(icns.path)")
} catch {
    FileHandle.standardError.write("make-debug-icon: \(error.localizedDescription)\n".data(using: .utf8)!)
    exit(1)
}
