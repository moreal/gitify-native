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

/// State colors resolved to macOS system semantic colors so icons sit naturally
/// on the popover material and pick up appearance changes, the manual theme
/// override, and the Increase Contrast accessibility setting for free.
/// The role → hue mapping per color-vision mode mirrors @primer/primitives:
/// colorblind swaps open green → orange and closed red → muted gray;
/// tritanopia uses red for open and muted gray for closed. Attention is yellow
/// in the color-vision modes to keep distance from colorblind's orange open,
/// but orange in normal mode where yellow glyphs get lost on light backgrounds.
enum StatePalette {
    static func color(_ role: StateColorRole, mode: ColorMode) -> Color {
        switch (mode, role) {
        case (_, .muted):
            return Color(nsColor: .secondaryLabelColor)

        case (.normal, .open): return Color(nsColor: .systemGreen)
        case (.normal, .closed): return Color(nsColor: .systemRed)
        case (.normal, .done): return Color(nsColor: .systemPurple)
        case (.normal, .attention): return Color(nsColor: .systemOrange)

        case (.colorblind, .open): return Color(nsColor: .systemOrange)
        case (.colorblind, .closed): return Color(nsColor: .secondaryLabelColor)
        case (.colorblind, .done): return Color(nsColor: .systemPurple)
        case (.colorblind, .attention): return Color(nsColor: .systemYellow)

        case (.tritanopia, .open): return Color(nsColor: .systemRed)
        case (.tritanopia, .closed): return Color(nsColor: .secondaryLabelColor)
        case (.tritanopia, .done): return Color(nsColor: .systemPurple)
        case (.tritanopia, .attention): return Color(nsColor: .systemYellow)
        }
    }
}
