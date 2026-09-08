#!/usr/bin/env swift

// Regenerates the app icon and the launch mark from code.
//
// The previous icon (ADR 0008, 2026-08-25) was made by a CoreGraphics script
// that was never committed — which is why moving the accent from indigo to
// petrol to forest green left the home-screen icon on the old colour. This
// script is committed so the next colour change is `make icon`.
//
// Output (overwrites in place):
//   client/App/Resources/Assets.xcassets/AppIcon.appiconset/icon-ios-1024.png
//   client/App/Resources/Assets.xcassets/AppIcon.appiconset/icon-macos-{16,32,64,128,256,512,1024}.png
//   client/App/Resources/Assets.xcassets/LaunchMark.imageset/launch-mark@{1,2,3}x.png
//
// The glyph is three ascending rounded bars, echoing the dashboard's own
// `BucketBarsChart`. iOS gets an edge-to-edge, fully opaque square (the OS
// applies its own mask; alpha would also block App Store submission). macOS
// gets the shape baked in — an inset squircle with a transparent surround,
// since macOS does not mask third-party icons — at every size in the classic
// ten-slot set. The launch mark is the bars alone in the accent colour on a
// transparent ground.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: Palette (kept in sync with docs/design/tokens.md by hand)

/// Hero-band gradient stops (`Palette.heroFill` / `Palette.heroFillDeep`,
/// light values) — the icon background.
let heroFill = (r: 0x00 / 255.0, g: 0x4F / 255.0, b: 0x89 / 255.0)
let heroFillDeep = (r: 0x01 / 255.0, g: 0x32 / 255.0, b: 0x58 / 255.0)
/// `Palette.accent` (light) — the launch mark's bar colour.
let accent = (r: 0x05 / 255.0, g: 0x6D / 255.0, b: 0xB8 / 255.0)

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

// MARK: Geometry

/// Draw the three ascending bars, filling `rect` with the given colour.
func drawBars(in ctx: CGContext, rect: CGRect, color: CGColor) {
    let s = rect.width
    let barWidth = 0.140 * s
    let gap = 0.080 * s
    let groupWidth = 3 * barWidth + 2 * gap
    let startX = rect.minX + (s - groupWidth) / 2
    let baseline = rect.minY + 0.230 * s
    let heights = [0.300 * s, 0.440 * s, 0.580 * s]
    let radius = barWidth * 0.34

    ctx.setFillColor(color)
    for (i, h) in heights.enumerated() {
        let x = startX + CGFloat(i) * (barWidth + gap)
        let bar = CGRect(x: x, y: baseline, width: barWidth, height: h)
        ctx.addPath(CGPath(roundedRect: bar, cornerWidth: radius, cornerHeight: radius, transform: nil))
    }
    ctx.fillPath()
}

/// Vertical gradient from `heroFill` (top) to `heroFillDeep` (bottom).
func heroGradient() -> CGGradient {
    let colors = [
        CGColor(colorSpace: sRGB, components: [heroFill.r, heroFill.g, heroFill.b, 1])!,
        CGColor(colorSpace: sRGB, components: [heroFillDeep.r, heroFillDeep.g, heroFillDeep.b, 1])!,
    ]
    return CGGradient(colorsSpace: sRGB, colors: colors as CFArray, locations: [0, 1])!
}

// MARK: Renderers

/// The iOS icon: opaque, edge-to-edge, no alpha.
func renderIOSIcon(size px: Int) -> CGImage {
    let ctx = CGContext(
        data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
        space: sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )!
    let full = CGRect(x: 0, y: 0, width: px, height: px)
    ctx.drawLinearGradient(
        heroGradient(),
        start: CGPoint(x: 0, y: full.maxY), end: CGPoint(x: 0, y: 0), options: []
    )
    drawBars(
        in: ctx, rect: full,
        color: CGColor(colorSpace: sRGB, components: [1, 1, 1, 1])!
    )
    return ctx.makeImage()!
}

/// A macOS icon size: the squircle shape baked in, transparent surround.
func renderMacIcon(size px: Int) -> CGImage {
    let ctx = CGContext(
        data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
        space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    let s = CGFloat(px)
    // Apple's Big Sur+ icon grid: the shape occupies ~81.8% of the canvas,
    // i.e. an inset of ~9.1% on each side.
    let inset = s * 0.0908
    let shape = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    // Continuous-corner squircle approximated by a round-rect at Apple's
    // corner ratio (~0.2237 of the side).
    let corner = shape.width * 0.2237
    let path = CGPath(
        roundedRect: shape, cornerWidth: corner, cornerHeight: corner, transform: nil
    )
    ctx.addPath(path)
    ctx.clip()
    ctx.drawLinearGradient(
        heroGradient(),
        start: CGPoint(x: 0, y: shape.maxY), end: CGPoint(x: 0, y: shape.minY), options: []
    )
    ctx.resetClip()
    drawBars(
        in: ctx, rect: shape,
        color: CGColor(colorSpace: sRGB, components: [1, 1, 1, 1])!
    )
    return ctx.makeImage()!
}

/// The launch mark: accent bars on a transparent ground.
func renderLaunchMark(size px: Int) -> CGImage {
    let ctx = CGContext(
        data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
        space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    let full = CGRect(x: 0, y: 0, width: px, height: px)
    drawBars(
        in: ctx, rect: full,
        color: CGColor(colorSpace: sRGB, components: [accent.r, accent.g, accent.b, 1])!
    )
    return ctx.makeImage()!
}

// MARK: IO

func write(_ image: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path)
    guard
        let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        )
    else {
        FileHandle.standardError.write(Data("cannot create \(path)\n".utf8))
        exit(1)
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        FileHandle.standardError.write(Data("cannot write \(path)\n".utf8))
        exit(1)
    }
    print("wrote \(path)")
}

// Resolve paths relative to this script, so `make icon` works from the repo root.
let scriptDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let repoRoot = scriptDir.deletingLastPathComponent()
let appIconDir = repoRoot
    .appendingPathComponent("client/App/Resources/Assets.xcassets/AppIcon.appiconset")
let launchDir = repoRoot
    .appendingPathComponent("client/App/Resources/Assets.xcassets/LaunchMark.imageset")

write(renderIOSIcon(size: 1024), to: appIconDir.appendingPathComponent("icon-ios-1024.png").path)
for size in [16, 32, 64, 128, 256, 512, 1024] {
    write(
        renderMacIcon(size: size),
        to: appIconDir.appendingPathComponent("icon-macos-\(size).png").path
    )
}
for (scale, px) in [(1, 128), (2, 256), (3, 384)] {
    write(
        renderLaunchMark(size: px),
        to: launchDir.appendingPathComponent("launch-mark@\(scale)x.png").path
    )
}
