//
//  Theme.swift
//  Agentic
//

import SwiftUI

/// Every colour, face, and interval the app draws with. Views name these
/// tokens rather than declaring values, so the palette changes in one place.
///
/// Light only. `AgenticApp` pins the scheme so the system controls drawn
/// alongside these colours, the keyboard and the pickers, match the paper
/// rather than sitting dark against it.
///
/// Hallmark · genre: editorial · theme: Almanac-adjacent
/// paper: warm off-white · accent: roast brown · display: roman serif
enum Theme {

    static let paper = color(0xFAF7F2)
    static let paperRaised = color(0xF1EAE0)
    static let ink = color(0x1F1B16)
    static let inkMuted = color(0x6F675C)
    static let accent = color(0x9A4A2B)
    static let rule = color(0xE0D8CC)
    static let danger = color(0x8C2F26)

    /// A serif for anything read as prose, SF for controls, mono for the trace.
    static let display = Font.system(.title3, design: .serif).weight(.semibold)
    static let reading = Font.system(.body, design: .serif)
    static let control = Font.system(.subheadline)
    static let label = Font.system(.caption).weight(.medium)
    static let trace = Font.system(.caption2, design: .monospaced)

    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 20
    static let xl: CGFloat = 32

    static let bubbleRadius: CGFloat = 10
    static let hairline: CGFloat = 1
    static let accentRule: CGFloat = 2

    static let enter = Animation.easeOut(duration: 0.22)
    static let press = Animation.easeOut(duration: 0.12)

    private static func color(_ hex: UInt32) -> Color {
        Color(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
