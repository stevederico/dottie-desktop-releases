//
//  ThemeColors.swift
//  Dottie
//
//  Shared Color(hex:), aurora palette, and dottie design tokens
//

import SwiftUI

// MARK: - Hex Color Extension
extension Color {
    /// Creates a `Color` from a hex string (3, 6, or 8 character RGB/ARGB format).
    /// - Parameter hex: Hex color string, e.g. `"FF2D92"` or `"#FF2D92"`. Leading `#` is stripped automatically.
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - Aurora Color Palette
extension Color {
    static let auroraPink = Color(hex: "FF2D92")
    static let auroraPurple = Color(hex: "8B5CF6")
    static let auroraCyan = Color(hex: "06B6D4")
    static let auroraBlue = Color(hex: "52B4E4")
}

// MARK: - Dottie Design Tokens (docs/DESIGN.md)
// Dark-first "jewel on dark velvet" palette. Use these instead of raw SwiftUI
// colors (.red/.green/.blue) so brand + semantic colors stay consistent and
// track DESIGN.md. The orb is the only bright object; everything else recedes.
extension Color {
    static let dottieBackground = Color(hex: "0B1120") // navy
    static let dottieSurface = Color(hex: "111B2E")    // elevated panels
    static let dottieBorder = Color(hex: "1E2D45")     // subtle separation
    static let dottieTextPrimary = Color(hex: "E2E8F0")
    static let dottieTextMuted = Color(hex: "64748B")
    static let dottieAccent = Color(hex: "4AADE8")     // Dottie blue
    static let dottieAccentDim = Color(hex: "2E8BC0")
    static let dottieAccentGlow = Color(hex: "7DD3FC")
    static let dottieSuccess = Color(hex: "34D399")
    static let dottieWarning = Color(hex: "FBBF24")
    static let dottieError = Color(hex: "F87171")
}
