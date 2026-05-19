import SwiftUI

/// Single source of truth for palette, sizes, and shadows used across the new
/// Figma-based redesign. Keep this short — no per-screen rules here.
enum DS {

    // MARK: — Colors
    enum Color {
        // Backgrounds
        static let bg          = SwiftUI.Color(uiColor: .systemBackground)
        static let bgSecondary = SwiftUI.Color(uiColor: .secondarySystemBackground)
        static let card        = SwiftUI.Color(uiColor: .systemBackground)
        static let chip        = SwiftUI.Color(uiColor: .systemBackground)
        static let darkSheet   = SwiftUI.Color(red: 0.05, green: 0.05, blue: 0.06)

        // Text
        static let text        = SwiftUI.Color.primary
        static let textMuted   = SwiftUI.Color.secondary
        static let textOnDark  = SwiftUI.Color.white

        // Accents — pulled from the orb's warm palette
        static let warmStart   = SwiftUI.Color(red: 1.00, green: 0.82, blue: 0.20)  // yellow highlight
        static let warmMid     = SwiftUI.Color(red: 1.00, green: 0.58, blue: 0.12)  // mid orange
        static let warmEnd     = SwiftUI.Color(red: 0.95, green: 0.32, blue: 0.10)  // deep red-orange

        // Semantic
        static let expense     = SwiftUI.Color(red: 0.96, green: 0.32, blue: 0.32)
        static let income      = SwiftUI.Color(red: 0.20, green: 0.78, blue: 0.40)
        static let transfer    = SwiftUI.Color(red: 0.97, green: 0.62, blue: 0.18)
        static let foodTag     = SwiftUI.Color(red: 0.99, green: 0.54, blue: 0.20)
        static let savings     = SwiftUI.Color(red: 0.22, green: 0.78, blue: 0.42)

        // Brand wallet placeholders (used until real PNG logos arrive)
        static let monoPink    = SwiftUI.Color(red: 0.96, green: 0.20, blue: 0.62)
        static let binanceGold = SwiftUI.Color(red: 0.95, green: 0.72, blue: 0.10)
        static let payPalBlue  = SwiftUI.Color(red: 0.00, green: 0.30, blue: 0.65)

        // Dividers / strokes
        static let stroke      = SwiftUI.Color(uiColor: .separator)
        static let strokeSoft  = SwiftUI.Color(uiColor: .separator).opacity(0.4)
    }

    // MARK: — Sizes & radii
    enum Size {
        static let orbDiameter: CGFloat = 168
        static let chipHeight: CGFloat  = 42
        static let composerHeight: CGFloat = 52
        static let cardCorner: CGFloat  = 22
        static let chipCorner: CGFloat  = 22
        static let buttonCorner: CGFloat = 16
        static let modalGrabberWidth: CGFloat = 40
    }

    // MARK: — Spacing
    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat  = 8
        static let m: CGFloat  = 12
        static let l: CGFloat  = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    // MARK: — Shadows
    enum Shadow {
        static let card: (color: SwiftUI.Color, radius: CGFloat, x: CGFloat, y: CGFloat) =
            (.black.opacity(0.06), 14, 0, 6)
        static let composer: (color: SwiftUI.Color, radius: CGFloat, x: CGFloat, y: CGFloat) =
            (.black.opacity(0.05), 12, 0, 4)
        static let orbGlow: (color: SwiftUI.Color, radius: CGFloat, x: CGFloat, y: CGFloat) =
            (Color.warmMid.opacity(0.35), 28, 0, 12)
    }
}

extension View {
    func dsCardShadow() -> some View {
        let s = DS.Shadow.card
        return self.shadow(color: s.color, radius: s.radius, x: s.x, y: s.y)
    }
    func dsComposerShadow() -> some View {
        let s = DS.Shadow.composer
        return self.shadow(color: s.color, radius: s.radius, x: s.x, y: s.y)
    }
}
