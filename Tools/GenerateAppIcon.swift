// Draws the Agentic app icon and writes the three appearance variants the
// asset catalog expects. Run from the repo root:
//
//     swift Tools/GenerateAppIcon.swift
//
// Not part of the app target: Agentic/ is a synchronized folder group, so a
// source file placed there would be compiled into the app.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let side = 1024.0

struct Palette {
    let fileName: String
    let groundCenter: UInt32
    let groundEdge: UInt32
    let beanLight: UInt32
    let beanDark: UInt32
}

/// Roast brown on warm paper, matching the `Theme` tokens the app draws with.
/// The tinted variant is greyscale because the system supplies the hue.
let palettes = [
    Palette(
        fileName: "AppIcon-light.png",
        groundCenter: 0xFDFB_F7,
        groundEdge: 0xEDE4_D8,
        beanLight: 0xB4_603A,
        beanDark: 0x7E_3921
    ),
    Palette(
        fileName: "AppIcon-dark.png",
        groundCenter: 0x1F1A_14,
        groundEdge: 0x0E0C_09,
        beanLight: 0xE0_8A5C,
        beanDark: 0x9C_4A2A
    ),
    Palette(
        fileName: "AppIcon-tinted.png",
        groundCenter: 0x1A1A_1A,
        groundEdge: 0x0707_07,
        beanLight: 0xF0_F0F0,
        beanDark: 0x8A_8A8A
    ),
]

let rgb = CGColorSpaceCreateDeviceRGB()

func components(_ hex: UInt32) -> [CGFloat] {
    [
        CGFloat((hex >> 16) & 0xFF) / 255,
        CGFloat((hex >> 8) & 0xFF) / 255,
        CGFloat(hex & 0xFF) / 255,
        1,
    ]
}

func color(_ hex: UInt32) -> CGColor {
    CGColor(colorSpace: rgb, components: components(hex))!
}

func gradient(from: UInt32, to: UInt32) -> CGGradient {
    CGGradient(
        colorSpace: rgb,
        colorComponents: components(from) + components(to),
        locations: [0, 1],
        count: 2
    )!
}

/// The bean sits on its long axis, tilted so it reads as an object resting on
/// the page rather than a symmetrical badge.
let beanTilt = -22.0 * .pi / 180
let beanHalfWidth = side * 0.234
let beanHalfHeight = side * 0.328

/// The fissure is what separates a coffee bean from a plain ellipse, so it
/// carries the whole silhouette. Two mirrored curves give it the off-centre
/// wander a real bean has; a straight line reads as a leaf.
func fissurePath() -> CGPath {
    let a = beanHalfWidth
    let b = beanHalfHeight
    let path = CGMutablePath()
    path.move(to: CGPoint(x: a * 0.05, y: -b * 0.88))
    path.addCurve(
        to: CGPoint(x: 0, y: 0),
        control1: CGPoint(x: a * 0.21, y: -b * 0.62),
        control2: CGPoint(x: a * 0.17, y: -b * 0.22)
    )
    path.addCurve(
        to: CGPoint(x: -a * 0.05, y: b * 0.88),
        control1: CGPoint(x: -a * 0.17, y: b * 0.22),
        control2: CGPoint(x: -a * 0.21, y: b * 0.62)
    )
    return path
}

func drawIcon(_ palette: Palette, into ctx: CGContext) {
    let bounds = CGRect(x: 0, y: 0, width: side, height: side)

    ctx.setFillColor(color(palette.groundEdge))
    ctx.fill(bounds)

    ctx.saveGState()
    ctx.clip(to: bounds)
    ctx.drawRadialGradient(
        gradient(from: palette.groundCenter, to: palette.groundEdge),
        startCenter: CGPoint(x: side / 2, y: side * 0.56),
        startRadius: 0,
        endCenter: CGPoint(x: side / 2, y: side * 0.56),
        endRadius: side * 0.62,
        options: [.drawsAfterEndLocation]
    )
    ctx.restoreGState()

    ctx.saveGState()
    ctx.translateBy(x: side / 2, y: side / 2)
    ctx.rotate(by: beanTilt)

    let bean = CGRect(
        x: -beanHalfWidth,
        y: -beanHalfHeight,
        width: beanHalfWidth * 2,
        height: beanHalfHeight * 2
    )

    ctx.saveGState()
    ctx.addEllipse(in: bean)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient(from: palette.beanLight, to: palette.beanDark),
        start: CGPoint(x: -beanHalfWidth, y: -beanHalfHeight),
        end: CGPoint(x: beanHalfWidth, y: beanHalfHeight),
        options: []
    )

    // Clipped to the bean so the round caps cannot spill past the silhouette.
    ctx.setStrokeColor(color(palette.groundCenter))
    ctx.setLineWidth(side * 0.044)
    ctx.setLineCap(.round)
    ctx.addPath(fissurePath())
    ctx.strokePath()
    ctx.restoreGState()

    ctx.restoreGState()
}

func render(_ palette: Palette) -> CGImage {
    // No alpha: app icons must be fully opaque.
    let ctx = CGContext(
        data: nil,
        width: Int(side),
        height: Int(side),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: rgb,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )!
    ctx.setAllowsAntialiasing(true)
    drawIcon(palette, into: ctx)
    return ctx.makeImage()!
}

let iconSet = URL(fileURLWithPath: "Agentic/Assets.xcassets/AppIcon.appiconset")

for palette in palettes {
    let url = iconSet.appendingPathComponent(palette.fileName)
    guard
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        )
    else {
        fatalError("could not open \(url.path) for writing")
    }
    CGImageDestinationAddImage(destination, render(palette), nil)
    guard CGImageDestinationFinalize(destination) else {
        fatalError("could not write \(url.path)")
    }
    print("wrote \(palette.fileName)")
}
