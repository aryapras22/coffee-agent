//
//  Theme.swift
//  Agentic
//

import SwiftUI
import UIKit

/// Every colour, face, and interval the app draws with. Views name these
/// tokens rather than declaring values, so the palette changes in one place.
///
/// Hallmark · genre: editorial · theme: Almanac-adjacent
/// paper: warm off-white · accent: roast brown · display: roman serif
enum Theme {

    static let paper = adaptive(light: 0xFAF7F2, dark: 0x17140F)
    static let paperRaised = adaptive(light: 0xF1EAE0, dark: 0x221D17)
    static let ink = adaptive(light: 0x1F1B16, dark: 0xEFE9E0)
    static let inkMuted = adaptive(light: 0x6F675C, dark: 0xA29889)
    static let accent = adaptive(light: 0x9A4A2B, dark: 0xD77A52)
    static let rule = adaptive(light: 0xE0D8CC, dark: 0x332C24)
    static let danger = adaptive(light: 0x8C2F26, dark: 0xE08A80)

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

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(
            UIColor { traits in
                UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
            }
        )
    }
}

extension UIColor {
    fileprivate convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
