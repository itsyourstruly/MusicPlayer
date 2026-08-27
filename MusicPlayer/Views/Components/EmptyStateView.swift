import SwiftUI

/// Minimal, high-contrast typographic empty state component.
/// Strictly avoids SF Symbols or illustrative graphics.
public struct EmptyStateView: View {
    public let title: String
    public let message: String
    public let actionTitle: String?
    public let action: (() -> Void)?

    public init(
        title: String,
        message: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        VStack(spacing: 16) {
            Text(title)
                .font(.system(size: 17, weight: .bold, design: .monospaced))
                .textCase(.uppercase)
                .foregroundStyle(Color.primary)

            Text(message)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .padding(.horizontal, 32)

            if let actTitle = actionTitle, let act = action {
                Button(action: act) {
                    Text(actTitle)
                }
                .buttonStyle(TypographicButtonStyle(variant: .primary, size: .regular))
                .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }
}
