import SwiftUI
import UniformTypeIdentifiers

/// Minimal, transparent appearance configuration view for selecting overall app themes,
/// default library landing tab, and player background rendering styles with direct text color highlighting.
public struct AppearanceSettingsView: View {
    @Bindable var libraryStore: LibraryStore
    @State private var activeDetail: SettingOptionDetail? = nil
    #if os(iOS)
    @State private var isHomePageExpanded: Bool = false
    @State private var draggedHomeSection: HomeSectionID? = nil
    #endif

    // Initialize with configured properties
    public init(libraryStore: LibraryStore) {
        self.libraryStore = libraryStore
    }

    // Main view layout structure
    public var body: some View {
        let isCaps = libraryStore.settings.isCapitalizationEnabled
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 28) {
                // Theme Selection
                themeSection

                Divider()
                    .overlay(libraryStore.settings.appTheme.separatorColor.opacity(0.4))

                // CAPITALIZATION (immediately below THEME)
                capitalizationSection

                #if os(iOS)
                Divider()
                    .overlay(libraryStore.settings.appTheme.separatorColor.opacity(0.4))

                homePageSection
                #endif

                Divider()
                    .overlay(libraryStore.settings.appTheme.separatorColor.opacity(0.4))

                // Default Library Page
                defaultLibraryPageSection

                #if os(iOS)
                Divider()
                    .overlay(libraryStore.settings.appTheme.separatorColor.opacity(0.4))

                // Album Page Section (iPhone)
                albumPageSection
                #endif

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
        .navigationTitle(AppCapitalization.format("APPEARANCE", enabled: isCaps))
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.isCapitalizationEnabled, isCaps)
        .sheet(item: $activeDetail) { detail in
            SettingOptionDetailSheet(detail: detail)
                .environment(\.appTheme, libraryStore.settings.appTheme)
                .environment(\.isCapitalizationEnabled, isCaps)
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
        let isCaps = libraryStore.settings.isCapitalizationEnabled
        let displayTitle = AppCapitalization.format(title, enabled: isCaps)
        return HStack(alignment: .center, spacing: 12) {
            Text(displayTitle)
                .font(.system(size: 14.5, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.primary)
                .onLongPressGesture(minimumDuration: 0.45) {
                    HapticFeedback.notificationSuccess()
                    activeDetail = detail
                }

            Spacer(minLength: 8)

            Picker(selection: selection) {
                ForEach(options) { option in
                    Text(AppCapitalization.format(label(option), enabled: isCaps)).tag(option)
                }
            } label: {
                Text(displayTitle)
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .font(.system(size: 14.5, weight: .bold, design: .monospaced))
            .tint(libraryStore.settings.appTheme.accentColor)
        }
    }

    #if os(iOS)
    // MARK: - Home Page Section (collapsed by default)
    private var homePageSection: some View {
        let isCaps = libraryStore.settings.isCapitalizationEnabled
        return VStack(alignment: .leading, spacing: 14) {
            Button {
                HapticFeedback.selectionChanged()
                withAnimation(.easeInOut(duration: 0.2)) {
                    isHomePageExpanded.toggle()
                }
            } label: {
                HStack {
                    Text(AppCapitalization.format("HOME PAGE", enabled: isCaps))
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isHomePageExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onLongPressGesture(minimumDuration: 0.45) {
                HapticFeedback.notificationSuccess()
                activeDetail = SettingOptionCatalog.homePageSection
            }

            if isHomePageExpanded {
                VStack(spacing: 0) {
                    ForEach(Array(libraryStore.settings.homeSections.enumerated()), id: \.element.id) { index, section in
                        HStack(spacing: 12) {
                            Image(systemName: "line.3.horizontal")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.tertiary)

                            Text(AppCapitalization.format(section.id.displayName, enabled: isCaps))
                                .font(.system(size: 13, weight: .bold, design: .monospaced))
                                .foregroundStyle(Color.primary)
                                .lineLimit(2)
                                .minimumScaleFactor(0.85)

                            Spacer(minLength: 8)

                            Text(AppCapitalization.format(section.isEnabled ? "ON" : "OFF", enabled: isCaps))
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundStyle(section.isEnabled ? Color.blue : Color.red)
                                .frame(minWidth: 36, alignment: .trailing)
                        }
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            HapticFeedback.selectionChanged()
                            var sections = libraryStore.settings.homeSections
                            sections[index].isEnabled.toggle()
                            libraryStore.settings.homeSections = sections
                            libraryStore.saveSettings()
                        }
                        .onDrag {
                            draggedHomeSection = section.id
                            return NSItemProvider(object: section.id.rawValue as NSString)
                        }
                        .onDrop(
                            of: [UTType.text],
                            delegate: HomeSectionDropDelegate(
                                targetID: section.id,
                                draggedID: $draggedHomeSection,
                                libraryStore: libraryStore
                            )
                        )
                    }
                }
            }
        }
    }
    #endif

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

    // MARK: - Capitalization Section
    private var capitalizationSection: some View {
        let isCaps = libraryStore.settings.isCapitalizationEnabled
        return TypographicToggleRow(
            title: AppCapitalization.format("CAPITALIZATION", enabled: isCaps),
            isOn: $libraryStore.settings.isCapitalizationEnabled,
            onToggle: { libraryStore.saveSettings() },
            onLongPress: { activeDetail = SettingOptionCatalog.capitalization }
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

    #if os(iOS)
    // MARK: - Album Page Section
    private var albumPageSection: some View {
        let isCaps = libraryStore.settings.isCapitalizationEnabled
        return VStack(alignment: .leading, spacing: 20) {
            Text(AppCapitalization.format("ALBUM PAGE", enabled: isCaps))
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
                .onLongPressGesture(minimumDuration: 0.45) {
                    HapticFeedback.notificationSuccess()
                    activeDetail = SettingOptionCatalog.albumPageSection
                }

            pickerRow(
                "BACKGROUND",
                selection: Binding(
                    get: { libraryStore.settings.albumPageBackgroundStyle },
                    set: { HapticFeedback.selectionChanged(); libraryStore.settings.albumPageBackgroundStyle = $0; libraryStore.saveSettings() }
                ),
                options: PlayerBackgroundStyle.allCases,
                label: { $0.displayName },
                detail: SettingOptionCatalog.albumPageSection
            )
        }
    }
    #endif

    // MARK: - Fullscreen Player Section
    private var fullscreenPlayerSection: some View {
        let isCaps = libraryStore.settings.isCapitalizationEnabled
        return VStack(alignment: .leading, spacing: 20) {
            Text(AppCapitalization.format("FULLSCREEN PLAYER", enabled: isCaps))
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

            TypographicToggleRow(
                title: AppCapitalization.format("SHOW AUDIO SPECS", enabled: isCaps),
                isOn: $libraryStore.settings.showAudioSpecsInPlayer,
                onToggle: { libraryStore.saveSettings() },
                onLongPress: { activeDetail = SettingOptionCatalog.showAudioSpecs }
            )

            TypographicToggleRow(
                title: AppCapitalization.format("USE PROGRESS BAR", enabled: isCaps),
                isOn: $libraryStore.settings.useProgressBar,
                onToggle: { libraryStore.saveSettings() },
                onLongPress: { activeDetail = SettingOptionCatalog.useProgressBar }
            )

            TypographicToggleRow(
                title: AppCapitalization.format("ROUNDED ARTWORK", enabled: isCaps),
                isOn: $libraryStore.settings.isArtworkRounded,
                onToggle: { libraryStore.saveSettings() },
                onLongPress: { activeDetail = SettingOptionCatalog.roundedArtwork }
            )

            TypographicToggleRow(
                title: AppCapitalization.format("ICONS", enabled: isCaps),
                isOn: $libraryStore.settings.usePlayerIcons,
                onToggle: { libraryStore.saveSettings() },
                onLongPress: { activeDetail = SettingOptionCatalog.playerIcons }
            )
        }
    }
}

#if os(iOS)
/// Long-press drag reordering for Appearance → HOME PAGE rows (same idea as Home Pins).
private struct HomeSectionDropDelegate: DropDelegate {
    let targetID: HomeSectionID
    @Binding var draggedID: HomeSectionID?
    let libraryStore: LibraryStore

    func dropEntered(info: DropInfo) {
        guard let draggedID, draggedID != targetID else { return }
        var sections = libraryStore.settings.homeSections
        guard let from = sections.firstIndex(where: { $0.id == draggedID }),
              let to = sections.firstIndex(where: { $0.id == targetID }) else { return }
        HapticFeedback.lightImpact()
        withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
            sections.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
            libraryStore.settings.homeSections = sections
            libraryStore.saveSettings()
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedID = nil
        return true
    }
}
#endif
