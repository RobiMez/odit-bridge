import SwiftUI

// Fallback provider colours when the server `/providers` response is missing
// or returns null colours. Hex values mirror Android's
// `ProviderUtils.FALLBACK_PROVIDER_COLORS` so the Mac and Android clients
// render the same provider with the same hue.
enum ProviderPalette {
    static let fallback: [String: Color] = [
        "telebirr":      Color(hex: "#F5A623"),
        "cbe":           Color(hex: "#7B61FF"),
        "cbebirr":       Color(hex: "#7B61FF"),
        "boa":           Color(hex: "#E15B5B"),
        "dashen":        Color(hex: "#4A90E2"),
        "dashenbank":    Color(hex: "#4A90E2"),
        "awash":         Color(hex: "#D7A3DA"),
        "awashbank":     Color(hex: "#D7A3DA"),
        "zemen":         Color(hex: "#5DC2A0"),
        "zemenbank":     Color(hex: "#5DC2A0"),
    ]

    /// Look up by provider key, prefer server-supplied colour if present.
    static func color(for provider: Provider) -> Color {
        if let hex = provider.colors?.light.bg { return Color(hex: hex) }
        let normalized = provider.key.lowercased().replacingOccurrences(of: " ", with: "")
        return fallback[normalized] ?? Color.gray
    }

    static func color(forKey key: String) -> Color {
        let normalized = key.lowercased().replacingOccurrences(of: " ", with: "")
        return fallback[normalized] ?? Color.gray
    }
}

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        var rgb: UInt64 = 0
        Scanner(string: s).scanHexInt64(&rgb)
        let r = Double((rgb >> 16) & 0xFF) / 255
        let g = Double((rgb >> 8) & 0xFF) / 255
        let b = Double(rgb & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
