import SwiftUI

/// Clean, high-contrast typographic button style with tactile press animation.
/// Strictly avoids icons/emojis in favor of crisp typography and semantic colors.
public struct TypographicButtonStyle: ButtonStyle {
    // Defines Variant cases
    public enum Variant {
        // Primary option
        case primary
        // Secondary option
        case secondary
        // Subtle option
        case subtle
        // Destructive option
        case destructive
    }

    public var variant: Variant = .primary
    public var size: ControlSize = .regular

    // Initialize with configured properties
    public init(variant: Variant = .primary, size: ControlSize = .regular) {
        self.variant = variant
        self.size = size
    }

    // Make body
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(fontForSize)
            .textCase(.uppercase)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(backgroundColor(isPressed: configuration.isPressed))
            .foregroundStyle(foregroundColor)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(borderColor, lineWidth: 1.0)
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            // Smooth UI transition animation
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }

    private var fontForSize: Font {
        switch size {
        case .mini:
            return .system(size: 10, weight: .bold, design: .monospaced)
        case .small:
            return .system(size: 12, weight: .bold, design: .monospaced)
        case .regular:
            return .system(size: 13, weight: .bold, design: .monospaced)
        case .large:
            return .system(size: 15, weight: .bold, design: .monospaced)
        case .extraLarge:
            return .system(size: 17, weight: .bold, design: .monospaced)
        @unknown default:
            return .system(size: 13, weight: .bold, design: .monospaced)
        }
    }

    private var horizontalPadding: CGFloat {
        switch size {
        case .mini: return 8
        case .small: return 12
        case .regular: return 16
        case .large: return 20
        case .extraLarge: return 24
        @unknown default: return 16
        }
    }

    private var verticalPadding: CGFloat {
        switch size {
        case .mini: return 4
        case .small: return 6
        case .regular: return 10
        case .large: return 14
        case .extraLarge: return 18
        @unknown default: return 10
        }
    }

    private var cornerRadius: CGFloat {
        switch size {
        case .mini, .small: return 6
        case .regular: return 8
        case .large, .extraLarge: return 10
        @unknown default: return 8
        }
    }

    // Background color
    private func backgroundColor(isPressed: Bool) -> Color {
        switch variant {
        case .primary:
            return isPressed ? Color.primary.opacity(0.85) : Color.primary
        case .secondary:
            return isPressed ? Color.appTertiaryFill : Color.appSecondaryFill
        case .subtle:
            return isPressed ? Color.appTertiaryFill : Color.clear
        case .destructive:
            return isPressed ? Color.red.opacity(0.85) : Color.red
        }
    }

    private var foregroundColor: Color {
        switch variant {
        case .primary, .destructive:
            return Color.appInvertedBackground
        case .secondary, .subtle:
            return Color.primary
        }
    }

    private var borderColor: Color {
        switch variant {
        case .primary, .destructive:
            return Color.clear
        case .secondary:
            return Color.appSeparator.opacity(0.4)
        case .subtle:
            return Color.appSeparator.opacity(0.6)
        }
    }
}
