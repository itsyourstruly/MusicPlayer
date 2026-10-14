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

                // Fullscreen Player Section
                fullscreenPlayerSection
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
                .environment(\.appTheme, libraryStore.settings.appTheme)
        }
    }

    // MARK: - Theme Section
    private var themeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("THEME")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
                .onLongPressGesture(minimumDuration: 0.45) {
                    HapticFeedback.notificationSuccess()
                    activeDetail = SettingOptionCatalog.themeSection
                }

            VStack(alignment: .leading, spacing: 16) {
                ForEach(AppTheme.allCases) { theme in
                    let isSelected = libraryStore.settings.appTheme == theme
                    HStack {
                        Text(theme.displayName)
                            .font(.system(size: 14.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(isSelected ? libraryStore.settings.appTheme.accentColor : Color.primary)

                        Spacer()
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                    .gesture(
                        LongPressGesture(minimumDuration: 0.45)
                            .onEnded { _ in
                                HapticFeedback.notificationSuccess()
                                activeDetail = SettingOptionCatalog.themeSection
                            }
                            .exclusively(before: TapGesture().onEnded {
                                HapticFeedback.selectionChanged()
                                libraryStore.settings.appTheme = theme
                                libraryStore.saveSettings()
                            })
                    )
                }
            }
        }
    }

    // MARK: - Default Library Page Section
    private var defaultLibraryPageSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("DEFAULT LIBRARY PAGE")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
                .onLongPressGesture(minimumDuration: 0.45) {
                    HapticFeedback.notificationSuccess()
                    activeDetail = SettingOptionCatalog.defaultLibraryPageSection
                }

            VStack(alignment: .leading, spacing: 16) {
                ForEach(LibraryCategory.allCases) { category in
                    let isSelected = libraryStore.settings.defaultLibraryCategory == category
                    HStack {
                        Text(category.title)
                            .font(.system(size: 14.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(isSelected ? libraryStore.settings.appTheme.accentColor : Color.primary)

                        Spacer()
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                    .gesture(
                        LongPressGesture(minimumDuration: 0.45)
                            .onEnded { _ in
                                HapticFeedback.notificationSuccess()
                                activeDetail = SettingOptionCatalog.defaultLibraryPageSection
                            }
                            .exclusively(before: TapGesture().onEnded {
                                HapticFeedback.selectionChanged()
                                libraryStore.settings.defaultLibraryCategory = category
                                libraryStore.saveSettings()
                            })
                    )
                }
            }
        }
    }

    // MARK: - Fullscreen Player Section
    private var fullscreenPlayerSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("FULLSCREEN PLAYER")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
                .onLongPressGesture(minimumDuration: 0.45) {
                    HapticFeedback.notificationSuccess()
                    activeDetail = SettingOptionCatalog.fullscreenPlayerSection
                }

            VStack(alignment: .leading, spacing: 12) {
                Text("BACKGROUND")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .onLongPressGesture(minimumDuration: 0.45) {
                        HapticFeedback.notificationSuccess()
                        activeDetail = SettingOptionCatalog.fullscreenPlayerSection
                    }

                VStack(alignment: .leading, spacing: 16) {
                    ForEach(PlayerBackgroundStyle.allCases) { style in
                        let isSelected = libraryStore.settings.playerBackgroundStyle == style
                        HStack {
                            Text(style.displayName)
                                .font(.system(size: 14.5, weight: .bold, design: .monospaced))
                                .foregroundStyle(isSelected ? libraryStore.settings.appTheme.accentColor : Color.primary)

                            Spacer()
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                        .gesture(
                            LongPressGesture(minimumDuration: 0.45)
                                .onEnded { _ in
                                    HapticFeedback.notificationSuccess()
                                    activeDetail = SettingOptionCatalog.fullscreenPlayerSection
                                }
                                .exclusively(before: TapGesture().onEnded {
                                    HapticFeedback.selectionChanged()
                                    libraryStore.settings.playerBackgroundStyle = style
                                    libraryStore.saveSettings()
                                })
                        )
                    }
                }
            }

            Divider()
                .overlay(libraryStore.settings.appTheme.separatorColor.opacity(0.4))

            TypographicToggleRow(
                title: "SHOW AUDIO SPECS",
                isOn: $libraryStore.settings.showAudioSpecsInPlayer,
                onToggle: { libraryStore.saveSettings() },
                onLongPress: { activeDetail = SettingOptionCatalog.showAudioSpecs }
            )

            TypographicToggleRow(
                title: "USE PROGRESS BAR",
                isOn: $libraryStore.settings.useProgressBar,
                onToggle: { libraryStore.saveSettings() },
                onLongPress: { activeDetail = SettingOptionCatalog.useProgressBar }
            )

            TypographicToggleRow(
                title: "ROUNDED ARTWORK",
                isOn: $libraryStore.settings.isArtworkRounded,
                onToggle: { libraryStore.saveSettings() },
                onLongPress: { activeDetail = SettingOptionCatalog.roundedArtwork }
            )
        }
    }
}
