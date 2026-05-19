#!/usr/bin/env swift
// render-app-icon.swift
//
// Rasterise the brand logo SVG into the PNG sizes required by the macOS
// App Icon catalog (16/32/64/128/256/512/1024) and write a matching
// Contents.json.
//
// The single source of truth lives inside the app's Asset Catalog at
// `Apps/.../Assets.xcassets/MaycastLogo.imageset/maycast-logo.svg`; that
// keeps the brand mark inside the app target (where it's actually used)
// and out of `docs/design/`, which is regenerated from an external source
// and would clobber any logo placed there.
//
// Usage: swift Tools/render-app-icon.swift
//   (run from the repo root; paths below are relative to it)

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let repoRoot   = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let assetsRoot = repoRoot.appendingPathComponent(
    "Apps/MaycastStudio/Maycast Studio/Maycast Studio/Assets.xcassets"
)
let svgURL = assetsRoot
    .appendingPathComponent("MaycastLogo.imageset/maycast-logo.svg")
let outDir = assetsRoot.appendingPathComponent("AppIcon.appiconset")

guard let svg = NSImage(contentsOf: svgURL) else {
    FileHandle.standardError.write(Data("Failed to load SVG at \(svgURL.path)\n".utf8))
    exit(1)
}

// Required AppIcon entries: (declared size, scale) → output pixel size.
// macOS App Icon set ships 5 base sizes × {@1x, @2x}.
struct Entry { let size: Int; let scale: Int; var pixels: Int { size * scale } }
let entries: [Entry] = [
    Entry(size: 16,  scale: 1),
    Entry(size: 16,  scale: 2),
    Entry(size: 32,  scale: 1),
    Entry(size: 32,  scale: 2),
    Entry(size: 128, scale: 1),
    Entry(size: 128, scale: 2),
    Entry(size: 256, scale: 1),
    Entry(size: 256, scale: 2),
    Entry(size: 512, scale: 1),
    Entry(size: 512, scale: 2),
]

try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

/// Render the SVG into a `px × px` RGBA8 CGImage by drawing it into a custom
/// CGBitmapContext. We can't rely on `NSImage.draw(in:…)` for an SVG-backed
/// image — `_NSSVGImageRep` only honours its rep's intrinsic size and the
/// result lands in a 0×0 region, producing fully-transparent output. Going
/// through a CGContext + the rep's `draw(in:)` (which the rep itself overrides
/// for vector drawing) avoids that.
func rasterise(_ image: NSImage, toPixelSize px: Int) -> CGImage {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
        | CGImageAlphaInfo.premultipliedLast.rawValue
    guard let ctx = CGContext(
        data: nil,
        width: px, height: px,
        bitsPerComponent: 8,
        bytesPerRow: px * 4,
        space: colorSpace,
        bitmapInfo: bitmapInfo
    ) else {
        fatalError("CGContext init failed at \(px)px")
    }

    let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = nsCtx
    image.size = NSSize(width: px, height: px) // force vector rep to rasterise at this size
    image.draw(
        in: NSRect(x: 0, y: 0, width: px, height: px),
        from: .zero,
        operation: .sourceOver,
        fraction: 1.0
    )
    NSGraphicsContext.restoreGraphicsState()

    guard let cg = ctx.makeImage() else {
        fatalError("makeImage failed at \(px)px")
    }
    return cg
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1, nil
    ) else { fatalError("CGImageDestination failed for \(url.lastPathComponent)") }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        fatalError("PNG finalize failed for \(url.lastPathComponent)")
    }
}

// Write per-entry PNGs.
var imagesJSON: [[String: String]] = []
for e in entries {
    let filename = "icon-\(e.size)@\(e.scale)x.png"
    let dest = outDir.appendingPathComponent(filename)
    let cg = rasterise(svg, toPixelSize: e.pixels)
    writePNG(cg, to: dest)
    imagesJSON.append([
        "filename": filename,
        "idiom": "mac",
        "scale": "\(e.scale)x",
        "size": "\(e.size)x\(e.size)",
    ])
    print("wrote \(filename) (\(e.pixels)×\(e.pixels))")
}

// Rebuild Contents.json so the catalog references the PNGs we just wrote.
// Use author "xcode" so the asset catalog UI doesn't flag the file as
// externally edited.
let contents: [String: Any] = [
    "images": imagesJSON,
    "info": ["author": "xcode", "version": 1],
]
let data = try JSONSerialization.data(
    withJSONObject: contents,
    options: [.prettyPrinted, .sortedKeys]
)
try data.write(to: outDir.appendingPathComponent("Contents.json"))
print("wrote Contents.json")
