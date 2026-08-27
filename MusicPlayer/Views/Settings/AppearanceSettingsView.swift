import SwiftUI

/// Detailed appearance configuration view for selecting overall app themes,
/// default library landing tab, and player background rendering styles.
public struct AppearanceSettingsView: View {
    @Bindable var libraryStore: LibraryStore

    // Initialize with configured properties
    public init(libraryStore: LibraryStore) {
        self.libraryStore = libraryStore
    }

    // Main view layout structure
    public var body: some View {
        List {
            // MARK: - Overall App Themes (8 Distinct Themes)
            Section {
                ForEach(AppTheme.allCases) { theme in
                    Button(action: {
                        HapticFeedback.selectionChanged()
                        libraryStore.settings.appTheme = theme
                        libraryStore.saveSettings()
                    }) {
                        HStack(spacing: 14) {
                            // Dual-Color Theme Preview Swatch
                            ZStack {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(theme.backgroundColor)
                                    .frame(width: 28, height: 28)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .stroke(theme.separatorColor, lineWidth: 1.0)
                                    )

                                Circle()
                                    .fill(theme.accentColor)
                                    .frame(width: 12, height: 12)
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text(theme.displayName)
                                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                                    .foregroundStyle(Color.primary)
                            }

                            Spacer()

                            if libraryStore.settings.appTheme == theme {
                                Text("ACTIVE")
                                    .typographicBadge(isHighlighted: true)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("APP THEME")
            } footer: {
                Text("Select from 8 themes that customize backgrounds, surface cards, and text colors.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            // MARK: - Default Library Page
            Section {
                ForEach(LibraryCategory.allCases) { category in
                    Button(action: {
                        HapticFeedback.selectionChanged()
                        libraryStore.settings.defaultLibraryCategory = category
                        libraryStore.saveSettings()
                    }) {
                        HStack {
                            Text(category.title)
                                .font(.system(size: 13, weight: .bold, design: .monospaced))
                                .foregroundStyle(Color.primary)

                            Spacer()

                            if libraryStore.settings.defaultLibraryCategory == category {
                                Text("DEFAULT")
                                    .typographicBadge(isHighlighted: true)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("DEFAULT LIBRARY PAGE")
            } footer: {
                Text("Sets which category is opened when first visiting your library.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            // MARK: - Player Background Style
            Section {
                ForEach(PlayerBackgroundStyle.allCases) { style in
                    Button(action: {
                        HapticFeedback.selectionChanged()
                        libraryStore.settings.playerBackgroundStyle = style
                        libraryStore.saveSettings()
                    }) {
                        HStack(alignment: .center, spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(style.displayName)
                                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                                    .foregroundStyle(Color.primary)

                                Text(style.descriptionText)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            if libraryStore.settings.playerBackgroundStyle == style {
                                Text("ACTIVE")
                                    .typographicBadge(isHighlighted: true)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("PLAYER BACKGROUND")
            } footer: {
                Text("Applies to both the floating miniplayer and fullscreen player card.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("APPEARANCE")
        .navigationBarTitleDisplayMode(.inline)
    }
}
