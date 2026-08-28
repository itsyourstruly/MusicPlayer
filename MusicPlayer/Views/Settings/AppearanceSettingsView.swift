import SwiftUI

/// Minimal, transparent appearance configuration view for selecting overall app themes,
/// default library landing tab, and player background rendering styles with direct text color highlighting.
public struct AppearanceSettingsView: View {
    @Bindable var libraryStore: LibraryStore
    @State private var activeDetail: SettingOptionDetail? = nil

    // Initialize with configured properties
    public init(libraryStore: LibraryStore) {
        self.libraryStore = libraryStore
    }

    // Main view layout structure
    public var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 28) {
                // Theme Selection
                themeSection

                Divider()
                    .overlay(libraryStore.settings.appTheme.separatorColor.opacity(0.4))

                // Default Library Page
                defaultLibraryPageSection

                Divider()
                    .overlay(libraryStore.settings.appTheme.separatorColor.opacity(0.4))

                // Player Background Style
                playerBackgroundSection
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
            .padding(.bottom, 60)
        }
        .background(libraryStore.settings.appTheme.backgroundColor.ignoresSafeArea())
        .navigationTitle("APPEARANCE")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $activeDetail) { detail in
            SettingOptionDetailSheet(detail: detail)
        }
    }

    // MARK: - Theme Section
    private var themeSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(AppTheme.allCases) { theme in
                let isSelected = libraryStore.settings.appTheme == theme
                Button(action: {
                    HapticFeedback.selectionChanged()
                    libraryStore.settings.appTheme = theme
                    libraryStore.saveSettings()
                }) {
                    HStack {
                        Text(theme.displayName)
                            .font(.system(size: 14.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(isSelected ? Color.blue : Color.primary)

                        Spacer()
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.45).onEnded { _ in
                        HapticFeedback.notificationSuccess()
                        activeDetail = SettingOptionCatalog.appearance
                    }
                )
            }
        }
    }

    // MARK: - Default Library Page Section
    private var defaultLibraryPageSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(LibraryCategory.allCases) { category in
                let isSelected = libraryStore.settings.defaultLibraryCategory == category
                Button(action: {
                    HapticFeedback.selectionChanged()
                    libraryStore.settings.defaultLibraryCategory = category
                    libraryStore.saveSettings()
                }) {
                    HStack {
                        Text(category.title)
                            .font(.system(size: 14.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(isSelected ? Color.blue : Color.primary)

                        Spacer()
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.45).onEnded { _ in
                        HapticFeedback.notificationSuccess()
                        activeDetail = SettingOptionCatalog.appearance
                    }
                )
            }
        }
    }

    // MARK: - Player Background Section
    private var playerBackgroundSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(PlayerBackgroundStyle.allCases) { style in
                let isSelected = libraryStore.settings.playerBackgroundStyle == style
                Button(action: {
                    HapticFeedback.selectionChanged()
                    libraryStore.settings.playerBackgroundStyle = style
                    libraryStore.saveSettings()
                }) {
                    HStack {
                        Text(style.displayName)
                            .font(.system(size: 14.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(isSelected ? Color.blue : Color.primary)

                        Spacer()
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.45).onEnded { _ in
                        HapticFeedback.notificationSuccess()
                        activeDetail = SettingOptionCatalog.appearance
                    }
                )
            }
        }
    }
}
