import SwiftUI
import UniformTypeIdentifiers

#if canImport(UIKit)
import UIKit
#endif

// MARK: - Plain Text Document for File Exporter

/// Uniform Type plain text document wrapper for system file export.
public struct PlainTextLogDocument: FileDocument {
    public static var readableContentTypes: [UTType] { [.plainText] }

    public var text: String

    public init(text: String) {
        self.text = text
    }

    public init(configuration: ReadConfiguration) throws {
        if let data = configuration.file.regularFileContents {
            text = String(decoding: data, as: UTF8.self)
        } else {
            text = ""
        }
    }

    public func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let data = Data(text.utf8)
        return FileWrapper(regularFileWithContents: data)
    }
}

// MARK: - Session Logs Sheet View

/// Dedicated debugging inspection sheet displaying application logs and direct Apple framework logs.
/// Formatted to match the minimal monospaced design language of the app.
public struct SessionLogsSheetView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var appTheme

    @State private var logStore = SessionLogStore.shared
    @State private var searchText: String = ""
    @State private var selectedCategory: String = "ALL"
    @State private var showingCopiedFeedback: Bool = false
    @State private var isExportingLogs: Bool = false
    @State private var exportDocument: PlainTextLogDocument? = nil
    @State private var diagnosticReport: String = ""

    public init() {}

    private var categories: [String] {
        ["ALL", "APPLE (XCODE)", "AUDIO", "STORAGE", "LIBRARY", "SCANNER", "NETWORK", "UI", "DIAGNOSTICS"]
    }

    private var filteredEntries: [LogEntry] {
        let all = logStore.allCombinedEntries()
        return all.filter { entry in
            if selectedCategory == "APPLE (XCODE)" {
                if !entry.isAppleSystemLog { return false }
            } else if selectedCategory == "AUDIO" {
                let isAudioCat = entry.category.lowercased() == "audio"
                let sub = entry.subsystem?.lowercased() ?? ""
                let isAppleAudio = sub.contains("audio") || sub.contains("coremedia") || sub.contains("avfoundation")
                if !isAudioCat && !isAppleAudio { return false }
            } else if selectedCategory != "ALL" && selectedCategory != "DIAGNOSTICS" {
                if entry.category.lowercased() != selectedCategory.lowercased() {
                    return false
                }
            }
            if !searchText.isEmpty {
                let query = searchText.lowercased()
                let matchesMsg = entry.message.lowercased().contains(query)
                let matchesCat = entry.category.lowercased().contains(query)
                let matchesSub = entry.subsystem?.lowercased().contains(query) ?? false
                let matchesLvl = entry.level.rawValue.lowercased().contains(query)
                return matchesMsg || matchesCat || matchesSub || matchesLvl
            }
            return true
        }
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Category Filter Bar (Minimal monospaced text tabs matching app styling)
                categoryFilterBar

                // Main Log Console Content
                ZStack {
                    appTheme.backgroundColor
                        .ignoresSafeArea()

                    if selectedCategory == "DIAGNOSTICS" {
                        diagnosticsView
                    } else if filteredEntries.isEmpty {
                        emptyLogsState
                    } else {
                        logsList
                    }

                    // Transient "Copied to clipboard" feedback
                    if showingCopiedFeedback {
                        VStack {
                            Spacer()
                            Text("COPIED TO CLIPBOARD")
                                .font(.system(size: 11, weight: .heavy, design: .monospaced))
                                .foregroundStyle(appTheme.backgroundColor)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(Color.primary)
                                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                                .padding(.bottom, 68)
                                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                        }
                        .zIndex(20)
                    }
                }

                // Bottom Action Deck (Pure prominent text in ALL CAPS with no background)
                bottomActionDeck
            }
            .background(appTheme.backgroundColor.ignoresSafeArea())
            .toolbarBackground(appTheme.backgroundColor, for: .navigationBar)
            .navigationTitle("SESSION LOGS")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search logs (message, subsystem, level)...")
            .task {
                refreshDiagnostics()
                await logStore.refreshAppleSystemLogs()
            }
            .fileExporter(
                isPresented: $isExportingLogs,
                document: exportDocument,
                contentType: .plainText,
                defaultFilename: "LAC_SYSTEM_DIAGNOSTICS"
            ) { result in
                switch result {
                case .success(let url):
                    AppLogger.ui.info("Saved logs file to: \(url.lastPathComponent)")
                    HapticFeedback.notificationSuccess()
                case .failure(let error):
                    AppLogger.ui.error("Failed to save logs file: \(error.localizedDescription)")
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Category Filter Bar

    private var categoryFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(categories, id: \.self) { cat in
                    let isSelected = selectedCategory == cat
                    Button(action: {
                        HapticFeedback.selectionChanged()
                        selectedCategory = cat
                        if cat == "DIAGNOSTICS" {
                            refreshDiagnostics()
                        }
                    }) {
                        Text(cat)
                            .font(.system(size: 11, weight: isSelected ? .heavy : .medium, design: .monospaced))
                            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
        }
        .frame(height: 38)
        .background(appTheme.backgroundColor)
        .overlay(
            Divider().overlay(Color.appSeparator.opacity(0.18)),
            alignment: .bottom
        )
    }

    // MARK: - Logs List

    private var logsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // Header meta summary
                    HStack {
                        let totalCombined = logStore.allCombinedEntries().count
                        Text("\(filteredEntries.count) OF \(totalCombined) ENTRIES")
                            .font(.system(size: 10, weight: .heavy, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("JUMP TO BOTTOM")
                            .font(.system(size: 10, weight: .heavy, design: .monospaced))
                            .foregroundStyle(.secondary.opacity(0.85))
                            .onTapGesture {
                                if let last = filteredEntries.last {
                                    withAnimation {
                                        proxy.scrollTo(last.id, anchor: .bottom)
                                    }
                                }
                            }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
                    .padding(.bottom, 6)

                    ForEach(filteredEntries) { entry in
                        logRow(entry)
                            .id(entry.id)
                    }
                }
                .padding(.bottom, 20)
            }
        }
    }

    // MARK: - Log Row

    private func logRow(_ entry: LogEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                // Timestamp
                Text(entry.formattedTimestamp)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)

                // Subsystem / Category
                if let sub = entry.subsystem, !sub.isEmpty {
                    Text(sub)
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(categoryColor(sub))
                        .lineLimit(1)
                } else {
                    Text(entry.category.uppercased())
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(categoryColor(entry.category))
                }

                // Level Badge
                Text(entry.level.rawValue)
                    .font(.system(size: 9.5, weight: .heavy, design: .monospaced))
                    .foregroundStyle(levelColor(entry.level))

                if entry.isAppleSystemLog {
                    Text("APPLE")
                        .font(.system(size: 8.5, weight: .heavy, design: .monospaced))
                        .foregroundStyle(.secondary.opacity(0.55))
                }

                Spacer()
            }

            // Log Message Body
            Text(entry.message)
                .font(.system(size: 11.5, weight: .regular, design: .monospaced))
                .foregroundStyle(Color.primary)
                .textSelection(.enabled)
                .lineSpacing(2)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            Divider().overlay(Color.appSeparator.opacity(0.12)),
            alignment: .bottom
        )
    }

    // MARK: - Diagnostics View

    private var diagnosticsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("SYSTEM & RUNTIME DIAGNOSTICS")
                        .font(.system(size: 10, weight: .heavy, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("REFRESH") {
                        HapticFeedback.lightImpact()
                        refreshDiagnostics()
                    }
                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                    .foregroundStyle(Color.primary)
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 2)

                Text(diagnosticReport)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(Color.primary)
                    .textSelection(.enabled)
                    .lineSpacing(2)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.bottom, 20)
        }
    }

    // MARK: - Empty State

    private var emptyLogsState: some View {
        VStack(spacing: 12) {
            Image(systemName: "text.alignleft")
                .font(.system(size: 36))
                .foregroundStyle(.secondary.opacity(0.5))

            Text("NO LOGS RECORDED")
                .font(.system(size: 13, weight: .heavy, design: .monospaced))
                .foregroundStyle(.primary)

            Text(searchText.isEmpty ? "No logs matching this category have been collected." : "No logs match the current search filters.")
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Bottom Action Deck (Pure text in ALL CAPS, NO background)

    private var bottomActionDeck: some View {
        VStack(spacing: 0) {
            Divider()
                .overlay(Color.appSeparator.opacity(0.2))

            HStack(spacing: 40) {
                // Button 1: COPY LOGS
                Button(action: {
                    copyLogsAction()
                }) {
                    Text("COPY LOGS")
                        .font(.system(size: 13, weight: .heavy, design: .monospaced))
                        .foregroundStyle(Color.primary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // Button 2: SAVE LOGS
                Button(action: {
                    saveLogsAction()
                }) {
                    Text("SAVE LOGS")
                        .font(.system(size: 13, weight: .heavy, design: .monospaced))
                        .foregroundStyle(Color.primary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .background(appTheme.backgroundColor)
        }
    }

    // MARK: - Actions

    private func refreshDiagnostics() {
        diagnosticReport = DiagnosticsCollector.generateDiagnosticBreakdown(playerService: AudioPlayerService.shared)
    }

    private func copyLogsAction() {
        let fullReport = logStore.formattedComprehensiveReport(playerService: AudioPlayerService.shared)
        #if canImport(UIKit)
        UIPasteboard.general.string = fullReport
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(fullReport, forType: .string)
        #endif

        HapticFeedback.notificationSuccess()
        withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
            showingCopiedFeedback = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation(.easeOut(duration: 0.25)) {
                showingCopiedFeedback = false
            }
        }
    }

    private func saveLogsAction() {
        HapticFeedback.lightImpact()
        let fullReport = logStore.formattedComprehensiveReport(playerService: AudioPlayerService.shared)
        exportDocument = PlainTextLogDocument(text: fullReport)
        isExportingLogs = true
    }

    // MARK: - Styling Helpers

    private func categoryColor(_ cat: String) -> Color {
        let lower = cat.lowercased()
        if lower.contains("audio") || lower.contains("coremedia") || lower.contains("avfoundation") {
            return Color.cyan
        } else if lower.contains("library") {
            return Color.purple
        } else if lower.contains("scanner") {
            return Color.teal
        } else if lower.contains("storage") {
            return Color.indigo
        } else if lower.contains("network") {
            return Color.blue
        } else if lower.contains("metadata") {
            return Color.orange
        } else if lower.contains("ui") {
            return Color.green
        } else {
            return Color.secondary
        }
    }

    private func levelColor(_ lvl: LogLevel) -> Color {
        switch lvl {
        case .error, .fault, .critical: return Color.red
        case .warning: return Color.yellow
        case .notice, .info: return Color.blue
        case .debug: return Color.gray
        }
    }
}
