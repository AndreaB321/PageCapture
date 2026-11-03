import SwiftUI

/// Softened versions of the app icon's colours. Text pairs meet WCAG AA (4.5:1) or better:
/// navy on coral 6.5–7.9, navy on field 11.6, placeholder on field 6.4, navy on butter 10.4,
/// cream on navy 11.2.
enum Theme {
    static let coralLight = Color(hex: 0xF7C6BE)  // header top
    static let coral = Color(hex: 0xF2AFA4)       // header bottom, picker accent
    static let navy = Color(hex: 0x1E3A47)        // text, banner and credit background
    static let butter = Color(hex: 0xFBEFB8)      // capture button, banner border, OK button
    static let field = Color(hex: 0xFFFAF3)       // address field
    static let placeholder = Color(hex: 0x4F5F67)
    static let cream = Color(hex: 0xFFF6E8)       // text on navy
}

private extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}
