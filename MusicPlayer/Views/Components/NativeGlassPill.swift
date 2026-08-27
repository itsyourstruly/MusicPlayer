import SwiftUI

#if canImport(UIKit)
import UIKit

/// High-fidelity native UIKit visual effect blur representation.
public struct VisualEffectBlurView: UIViewRepresentable {
    // Style
    public let style: UIBlurEffect.Style

    // Initialize with configured properties
    public init(style: UIBlurEffect.Style = .systemMaterial) {
        self.style = style
    }

    // Make ui view
    public func makeUIView(context: Context) -> UIVisualEffectView {
        let view = UIVisualEffectView(effect: UIBlurEffect(style: style))
        view.backgroundColor = .clear
        return view
    }

    // Update ui view
    public func updateUIView(_ uiView: UIVisualEffectView, context: Context) {
        uiView.effect = UIBlurEffect(style: style)
    }
}
#endif

/// Pure native Apple iOS 26 Glass Pill container with hardware-accelerated optical blur,
/// crystal specular highlights, and Fresnel edge refraction.
public struct NativeGlassPillModifier: ViewModifier {
    // Initialize with configured properties
    public init() {}

    // Body
    public func body(content: Content) -> some View {
        #if os(visionOS)
        content
            .glassBackgroundEffect(in: Capsule(), displayMode: .always)
            .clipShape(Capsule())
            .shadow(color: Color.black.opacity(0.14), radius: 16, x: 0, y: 8)
        #else
        content
            .background {
                #if canImport(UIKit)
                VisualEffectBlurView(style: .systemMaterial)
                    .clipShape(Capsule())
                #else
                Capsule()
                    .fill(.regularMaterial)
                #endif
            }
            .background {
                // Crystal luminosity & specular light reflection on the upper curvature
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.24),
                        Color.white.opacity(0.06),
                        Color.clear
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .clipShape(Capsule())
            }
            .overlay {
                // Precision Fresnel glass rim bevel
                Capsule()
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.65),
                                Color.white.opacity(0.20),
                                Color.white.opacity(0.04),
                                Color.white.opacity(0.35)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.75
                    )
            }
            .shadow(color: Color.black.opacity(0.14), radius: 18, x: 0, y: 8)
            .shadow(color: Color.black.opacity(0.04), radius: 4, x: 0, y: 2)
            .clipShape(Capsule())
        #endif
    }
}

public extension View {
    /// Applies native Apple iOS 26 glass capsule styling.
    func nativeGlassPill() -> some View {
        self.modifier(NativeGlassPillModifier())
    }
}
