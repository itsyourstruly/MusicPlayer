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

    // MARK: - Single-row native menu picker ('TITLE [picker]'); long-press the title for the info sheet.
    private func pickerRow<Value: Hashable & Identifiable>(
        _ title: String,
        selection: Binding<Value>,
        options: [Value],
        label: @escaping (Value) -> String,
        detail: SettingOptionDetail
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .font(.system(size: 14.5, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.primary)
                .onLongPressGesture(minimumDuration: 0.45) {
                    HapticFeedback.notificationSuccess()
                    activeDetail = detail
                }

            Spacer(minLength: 8)

            Picker(selection: selection) {
                ForEach(options) { option in
                    Text(label(option)).tag(option)
                }
            } label: {
                Text(title)
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .font(.system(size: 14.5, weight: .bold, design: .monospaced))
            .tint(libraryStore.settings.appTheme.accentColor)
        }
    }

    // MARK: - Theme Section
    private var themeSection: some View {
        pickerRow(
            "THEME",
            selection: Binding(
                get: { libraryStore.settings.appTheme },
                set: { HapticFeedback.selectionChanged(); libraryStore.settings.appTheme = $0; libraryStore.saveSettings() }
            ),
            options: AppTheme.allCases,
            label: { $0.displayName },
            detail: SettingOptionCatalog.themeSection
        )
    }

    // MARK: - Default Library Page Section
    private var defaultLibraryPageSection: some View {
        pickerRow(
            "DEFAULT LIBRARY PAGE",
            selection: Binding(
                get: { libraryStore.settings.defaultLibraryCategory },
                set: { HapticFeedback.selectionChanged(); libraryStore.settings.defaultLibraryCategory = $0; libraryStore.saveSettings() }
            ),
            options: LibraryCategory.allCases,
            label: { $0.title },
            detail: SettingOptionCatalog.defaultLibraryPageSection
        )
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

            pickerRow(
                "BACKGROUND",
                selection: Binding(
                    get: { libraryStore.settings.playerBackgroundStyle },
                    set: { HapticFeedback.selectionChanged(); libraryStore.settings.playerBackgroundStyle = $0; libraryStore.saveSettings() }
                ),
                options: PlayerBackgroundStyle.allCases,
                label: { $0.displayName },
                detail: SettingOptionCatalog.fullscreenPlayerSection
            )

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
