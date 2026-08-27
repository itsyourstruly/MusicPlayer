import SwiftUI

/// Reusable sort selector row featuring generous touch hit targets, forward/reverse sorting toggle,
/// and bold blue highlight state when reverse sorting is active.
public struct SortSelectorBar<Option: Identifiable & Equatable>: View {
    // Display title
    public let title: String
    // Options
    public let options: [Option]
    @Binding public var selectedOption: Option
    @Binding public var isReversed: Bool
    public let labelForOption: (Option) -> String

    // Initialize with configured properties
    public init(
        title: String = "SORT:",
        options: [Option],
        selectedOption: Binding<Option>,
        isReversed: Binding<Bool>,
        labelForOption: @escaping (Option) -> String
    ) {
        self.title = title
        self.options = options
        self._selectedOption = selectedOption
        self._isReversed = isReversed
        self.labelForOption = labelForOption
    }

    // Main view layout structure
    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 4)

                ForEach(options) { option in
                    // Flag indicating if selected
                    let isSelected = selectedOption == option
                    Button(action: {
                        HapticFeedback.selectionChanged()
                        withAnimation(.spring(response: 0.22, dampingFraction: 0.8)) {
                            if isSelected {
                                isReversed.toggle()
                            } else {
                                selectedOption = option
                                isReversed = false
                            }
                        }
                    }) {
                        HStack(spacing: 4) {
                            Text(labelForOption(option))
                                .font(.system(size: 11, weight: isSelected ? .bold : .regular, design: .monospaced))
                                .foregroundStyle(
                                    isSelected
                                        ? (isReversed ? Color.blue : Color.primary)
                                        : Color.secondary
                                )

                            if isSelected && isReversed {
                                Image(systemName: "arrow.up.arrow.down")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(Color.blue)
                            }
                        }
                        // Generous touch target to avoid accidental taps above/below
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
        .frame(height: 38)
    }
}
