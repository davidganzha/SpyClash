#!/usr/bin/env swift

import AppKit
import Foundation

let fileManager = FileManager.default
let root = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
let defaultRelativePaths = [
    "AppStoreAssets/Screenshots/en-US/01-online-playing.png",
    "AppStoreAssets/Screenshots/en-US/02-local-results.png",
    "AppStoreAssets/Screenshots/en-US/03-word-packs.png",
    "AppStoreAssets/Screenshots/en-US/04-home.png",
    "AppStoreAssets/Screenshots/en-US/05-community.png",
]

let requestedPaths = Array(CommandLine.arguments.dropFirst())
let paths = requestedPaths.isEmpty ? defaultRelativePaths : requestedPaths

for path in paths {
    let sourceURL = URL(fileURLWithPath: path, relativeTo: root).standardizedFileURL
    guard let image = NSImage(contentsOf: sourceURL) else {
        fputs("Cannot read image: \(sourceURL.path)\n", stderr)
        exit(1)
    }
    guard let source = image.representations
        .compactMap({ $0 as? NSBitmapImageRep })
        .max(by: { $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh })
    else {
        fputs("Image has no bitmap representation: \(sourceURL.path)\n", stderr)
        exit(1)
    }

    var proposedRect = NSRect(
        x: 0,
        y: 0,
        width: source.pixelsWide,
        height: source.pixelsHigh
    )
    guard let sourceImage = image.cgImage(
        forProposedRect: &proposedRect,
        context: nil,
        hints: nil
    ) else {
        fputs("Cannot decode image pixels: \(sourceURL.path)\n", stderr)
        exit(1)
    }
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let bitmap = CGContext(
              data: nil,
              width: source.pixelsWide,
              height: source.pixelsHigh,
              bitsPerComponent: 8,
              bytesPerRow: source.pixelsWide * 4,
              space: colorSpace,
              bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue |
                  CGImageAlphaInfo.noneSkipLast.rawValue
          )
    else {
        fputs("Cannot allocate RGB bitmap: \(sourceURL.path)\n", stderr)
        exit(1)
    }
    bitmap.setFillColor(CGColor(gray: 0, alpha: 1))
    bitmap.fill(
        CGRect(x: 0, y: 0, width: source.pixelsWide, height: source.pixelsHigh)
    )
    bitmap.interpolationQuality = .high
    bitmap.draw(
        sourceImage,
        in: CGRect(x: 0, y: 0, width: source.pixelsWide, height: source.pixelsHigh)
    )
    guard let flattenedImage = bitmap.makeImage() else {
        fputs("Cannot flatten image pixels: \(sourceURL.path)\n", stderr)
        exit(1)
    }
    let flattened = NSBitmapImageRep(cgImage: flattenedImage)

    guard let png = flattened.representation(using: .png, properties: [:]) else {
        fputs("Cannot encode PNG: \(sourceURL.path)\n", stderr)
        exit(1)
    }
    do {
        try png.write(to: sourceURL, options: .atomic)
    } catch {
        fputs("Cannot write \(sourceURL.path): \(error)\n", stderr)
        exit(1)
    }
    print("Flattened \(sourceURL.path) (\(source.pixelsWide)x\(source.pixelsHigh))")
}
