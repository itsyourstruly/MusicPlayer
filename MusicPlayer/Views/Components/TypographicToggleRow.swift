import SwiftUI

/// Clean typographic toggle row that displays an uppercase title on the left,
/// and a high-contrast state indicator on the right showing "OFF" in Red by default and "ON" in Blue when active.
/// Supports normal tap to toggle, and long-press to open detailed explanation sheets.
public struct TypographicToggleRow: View {
    public let title: String
    public let subtitle: String?
    @Binding public var isOn: Bool
    public var onToggle: (() -> Void)? = nil
    public var onLongPress: (() -> Void)? = nil

    // Initialize with configured properties
    public init(
        title: String,
        subtitle: String? = nil,
        isOn: Binding<Bool>,
        onToggle: (() -> Void)? = nil,
        onLongPress: (() -> Void)? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self._isOn = isOn
        self.onToggle = onToggle
        self.onLongPress = onLongPress
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.primary)
                    .multilineTextAlignment(.leading)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
            }

            Spacer()

            Text(isOn ? "ON" : "OFF")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(isOn ? Color.blue : Color.red)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            HapticFeedback.selectionChanged()
            withAnimation(.easeInOut(duration: 0.15)) {
                isOn.toggle()
            }
            onToggle?()
        }
        .onLongPressGesture(minimumDuration: 0.45) {
            if let onLongPress {
                HapticFeedback.notificationSuccess()
                onLongPress()
            }
        }
    }
}
