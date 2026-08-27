import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Cross-platform semantic color extensions providing uniform styling across iOS and macOS.
///
/// Each property bridges to the closest native system color on the current platform,
/// so the app adapts to light/dark mode automatically without conditional view code.
public extension Color {

    // MARK: - Backgrounds

    /// Primary background color matching the platform's standard canvas.
    static var appBackground: Color {
        #if canImport(UIKit)
        return Color(uiColor: .systemBackground)
        #elseif canImport(AppKit)
        return Color(nsColor: .windowBackgroundColor)
        #else
        return Color.black
        #endif
    }

    /// Secondary background color for grouped cards, rows, and containers.
    static var appSecondaryBackground: Color {
        #if canImport(UIKit)
        return Color(uiColor: .secondarySystemBackground)
        #elseif canImport(AppKit)
        return Color(nsColor: .controlBackgroundColor)
        #else
        return Color.gray.opacity(0.15)
        #endif
    }

    /// Tertiary background color for embedded wells, search bars, and tags.
    static var appTertiaryBackground: Color {
        #if canImport(UIKit)
        return Color(uiColor: .tertiarySystemBackground)
        #elseif canImport(AppKit)
        return Color(nsColor: .underPageBackgroundColor)
        #else
        return Color.gray.opacity(0.25)
        #endif
    }

    // MARK: - Fills & Separators

    /// Standard border and separator color.
    static var appSeparator: Color {
        #if canImport(UIKit)
        return Color(uiColor: .separator)
        #elseif canImport(AppKit)
        return Color(nsColor: .separatorColor)
        #else
        return Color.gray.opacity(0.3)
        #endif
    }

    /// Subtle fill color for badges and inactive button states.
    static var appTertiaryFill: Color {
        #if canImport(UIKit)
        return Color(uiColor: .tertiarySystemFill)
        #elseif canImport(AppKit)
        // quaternaryLabelColor is the closest macOS equivalent to the iOS tertiary fill token
        return Color(nsColor: .quaternaryLabelColor)
        #else
        return Color.gray.opacity(0.2)
        #endif
    }

    /// Secondary fill color for secondary buttons and inputs.
    static var appSecondaryFill: Color {
        #if canImport(UIKit)
        return Color(uiColor: .secondarySystemFill)
        #elseif canImport(AppKit)
        return Color(nsColor: .tertiaryLabelColor)
        #else
        return Color.gray.opacity(0.15)
        #endif
    }

    // MARK: - Special

    /// Inverted background color for high-contrast foreground items.
    static var appInvertedBackground: Color {
        #if canImport(UIKit)
        return Color(uiColor: .systemBackground)
        #elseif canImport(AppKit)
        return Color(nsColor: .windowBackgroundColor)
        #else
        return Color.white
        #endif
    }
}
