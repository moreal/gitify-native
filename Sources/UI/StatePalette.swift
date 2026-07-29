import AppKit
import SwiftUI

/// Semantic state color roles, matching GitHub Primer's fgColor tokens.
enum StateColorRole {
    case open       // --fgColor-open
    case closed     // --fgColor-closed
    case done       // --fgColor-done
    case attention  // --fgColor-attention
    case muted
}

/// GitHub Primer state colors per color-vision mode. Hex values are taken from
/// @primer/primitives themes: light/dark, *-colorblind, *-tritanopia.
/// Colorblind swaps open green → orange and closed red → muted gray;
/// tritanopia uses red for open and muted gray for closed.
enum StatePalette {
    static func color(_ role: StateColorRole, mode: ColorMode) -> Color {
        switch (mode, role) {
        case (_, .muted):
            return Color(nsColor: .secondaryLabelColor)

        case (.normal, .open): return dynamic(light: 0x1A7F37, dark: 0x3FB950)
        case (.normal, .closed): return dynamic(light: 0xCF222E, dark: 0xF85149)
        case (.normal, .done): return dynamic(light: 0x8250DF, dark: 0xA371F7)
        case (.normal, .attention): return dynamic(light: 0x9A6700, dark: 0xD29922)

        case (.colorblind, .open): return dynamic(light: 0xBC4C00, dark: 0xDB6D28)
        case (.colorblind, .closed): return dynamic(light: 0x59636E, dark: 0x9198A1)
        case (.colorblind, .done): return dynamic(light: 0x8250DF, dark: 0xAB7DF8)
        case (.colorblind, .attention): return dynamic(light: 0x9A6700, dark: 0xD29922)

        case (.tritanopia, .open): return dynamic(light: 0xCF222E, dark: 0xF85149)
        case (.tritanopia, .closed): return dynamic(light: 0x59636E, dark: 0x9198A1)
        case (.tritanopia, .done): return dynamic(light: 0x8250DF, dark: 0xAB7DF8)
        case (.tritanopia, .attention): return dynamic(light: 0x9A6700, dark: 0xD29922)
        }
    }

    /// Resolves per the view's effective appearance so it tracks both the system
    /// theme and the app's manual light/dark override.
    private static func dynamic(light: Int, dark: Int) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(rgb: isDark ? dark : light)
        })
    }
}

private extension NSColor {
    convenience init(rgb: Int) {
        self.init(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}
