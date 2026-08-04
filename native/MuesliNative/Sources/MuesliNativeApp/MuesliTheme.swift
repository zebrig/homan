import SwiftUI
import MuesliCore

enum MuesliTheme {
    // MARK: - Colors — Backgrounds (layered)

    static let backgroundDeep   = Color.adaptive(dark: 0x101013, light: 0xE8E5DF)  // Night / Deep
    static let backgroundBase   = Color.adaptive(dark: 0x17171B, light: 0xF4F2EE)  // Surface / Paper
    static let backgroundRaised = Color.adaptive(dark: 0x1F1F24, light: 0xFFFFFF)  // Elevated / Raised
    static let backgroundHover  = Color.adaptive(dark: 0x232329, light: 0xECE8E1)  // Subtle border / Hover

    // MARK: - Surfaces (interactive elements)

    static let surfacePrimary   = Color.adaptive(dark: 0x232329, light: 0xE4E0D8)  // raised surface / Primary surface
    static let surfaceSelected  = Color.adaptive(dark: 0x2A2622, light: 0xF1DDC7)  // Ember-tinted / Selected surface
    static let surfaceBorder    = Color.adaptive(dark: 0x2C2C33, light: 0xE0DDD6)  // Strong border / light border

    // MARK: - Text hierarchy

    static let textPrimary   = Color.adaptive(dark: 0xF4F2EE, light: 0x101013)  // Paper / Night
    static let textSecondary = Color.adaptive(dark: 0xB9B7BE, light: 0x545159)  // Secondary text
    static let textTertiary  = Color.adaptive(dark: 0x8E8C94, light: 0x75716A)  // Mist

    // MARK: - Accent

    static let defaultAccentDarkHex = 0xE8A05C   // Ember
    static let defaultAccentLightHex = 0xC67D3F  // darker Ember for light surfaces
    static let defaultAccent    = Color.adaptive(dark: defaultAccentDarkHex, light: defaultAccentLightHex)
    static var accentOverrideHex: String?
    static var accent: Color {
        if let hex = accentOverrideHex, !hex.isEmpty,
           let val = UInt64(hex.replacingOccurrences(of: "#", with: ""), radix: 16) {
            return Color(hex: Int(val))
        }
        return defaultAccent
    }
    static var accentSubtle: Color { accent.opacity(0.15) }

    // MARK: - Semantic

    static let recording        = Color(hex: 0xEF4444)  // Destructive
    static let transcribing     = Color(hex: 0xD6A04A)  // Warning
    static let success          = Color(hex: 0x6FC493)  // Signal

    // MARK: - Homan fixed brand colors (never overridden by accent)

    static let homanEmber  = Color(hex: 0xE8A05C)
    static let homanSignal = Color(hex: 0x6FC493)
    static let homanNight  = Color(hex: 0x101013)
    static let homanPaper  = Color(hex: 0xF4F2EE)

    // MARK: - Typography (SF Pro via .system())

    static func title1() -> Font { .system(size: 28, weight: .bold) }
    static func title2() -> Font { .system(size: 22, weight: .semibold) }
    static func title3() -> Font { .system(size: 18, weight: .semibold) }
    static func headline() -> Font { .system(size: 15, weight: .semibold) }
    static func body() -> Font { .system(size: 14, weight: .regular) }
    static func callout() -> Font { .system(size: 13, weight: .regular) }
    static func caption() -> Font { .system(size: 12, weight: .regular) }
    static func captionMedium() -> Font { .system(size: 12, weight: .medium) }

    // MARK: - Spacing (4pt grid)

    static let spacing4: CGFloat = 4
    static let spacing8: CGFloat = 8
    static let spacing12: CGFloat = 12
    static let spacing16: CGFloat = 16
    static let spacing20: CGFloat = 20
    static let spacing24: CGFloat = 24
    static let spacing32: CGFloat = 32

    // MARK: - Corner radii

    static let cornerSmall: CGFloat = 6
    static let cornerMedium: CGFloat = 10
    static let cornerLarge: CGFloat = 14
    static let cornerXL: CGFloat = 20
}

// MARK: - Color Helpers

extension Color {
    init(hex: Int) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0
        )
    }

    static func adaptive(dark: Int, light: Int) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255.0,
                green: CGFloat((hex >> 8) & 0xFF) / 255.0,
                blue: CGFloat(hex & 0xFF) / 255.0,
                alpha: 1.0
            )
        })
    }

    static func adaptiveAlpha(dark: NSColor, darkAlpha: CGFloat, light: NSColor, lightAlpha: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? dark.withAlphaComponent(darkAlpha)
                : light.withAlphaComponent(lightAlpha)
        })
    }
}
