import Foundation
@_exported import os
#if canImport(OSLog)
import OSLog
#endif

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Log Level

/// Severity level for structured log entries.
public enum LogLevel: String, Sendable, CaseIterable, Codable {
    case debug = "DEBUG"
    case info = "INFO"
    case notice = "NOTICE"
    case warning = "WARNING"
    case error = "ERROR"
    case fault = "FAULT"
    case critical = "CRITICAL"
}

// MARK: - Log Entry

/// An immutable, timestamped record of an application event for debugging.
public struct LogEntry: Identifiable, Sendable, Codable {
    public let id: UUID
    public let timestamp: Date
    public let category: String
    public let subsystem: String?
    public let level: LogLevel
    public let message: String
    public let isAppleSystemLog: Bool

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        category: String,
        subsystem: String? = nil,
        level: LogLevel,
        message: String,
        isAppleSystemLog: Bool = false
    ) {
        self.id = id
        self.timestamp = timestamp
        self.category = category
        self.subsystem = subsystem
        self.level = level
        self.message = message
        self.isAppleSystemLog = isAppleSystemLog
    }

    public var formattedTimestamp: String {
        Self.timeFormatter.string(from: timestamp)
    }

    public var fullFormattedTimestamp: String {
        Self.fullFormatter.string(from: timestamp)
    }

    public static let timeFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss.SSS"
        return df
    }()

    public static let fullFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return df
    }()
}

// MARK: - Session Log Store

/// Thread-safe in-memory session log repository retaining recent log entries for debugging.
/// Integrates both high-performance custom application events and Apple framework logs from OSLogStore.
@Observable
public final class SessionLogStore: @unchecked Sendable {
    public static let shared = SessionLogStore()

    private let lock = NSLock()
    private var internalEntries: [LogEntry] = []
    private var internalAppleEntries: [LogEntry] = []
    private let maxEntries: Int = 10_000

    /// Monotonically increasing revision number to drive live SwiftUI observation safely.
    public private(set) var revision: Int = 0

    public init() {}

    /// Appends a new entry to the session log store in a thread-safe manner.
    public func append(_ entry: LogEntry) {
        lock.lock()
        internalEntries.append(entry)
        if internalEntries.count > maxEntries {
            internalEntries.removeFirst(internalEntries.count - maxEntries)
        }
        lock.unlock()

        Task { @MainActor in
            self.revision += 1
        }
    }

    /// Returns a thread-safe snapshot of all in-app log entries for this session.
    public func allEntries() -> [LogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return internalEntries
    }

    /// Returns a thread-safe snapshot of all Apple framework log entries collected via OSLogStore.
    public func appleSystemEntries() -> [LogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return internalAppleEntries
    }

    /// Returns combined in-app and Apple framework logs sorted chronologically.
    public func allCombinedEntries() -> [LogEntry] {
        lock.lock()
        let inApp = internalEntries
        let apple = internalAppleEntries
        lock.unlock()

        var combined = inApp + apple
        combined.sort { $0.timestamp < $1.timestamp }
        return combined
    }

    /// Fetches direct system logs emitted to OSLogStore by this process (e.g. CoreMedia, AVFoundation, AudioToolbox, MediaRemote).
    public func fetchAppleSystemLogs(limit: Int = 2000) async -> [LogEntry] {
        if #available(iOS 15.0, macOS 12.0, *) {
            return await Task.detached(priority: .userInitiated) {
                do {
                    let store = try OSLogStore(scope: .currentProcessIdentifier)
                    // Fetch logs from last 4 hours or since app launch
                    let startTime = Date().addingTimeInterval(-14400)
                    let position = store.position(date: startTime)
                    let rawEntries = try store.getEntries(at: position)

                    var results: [LogEntry] = []
                    for entry in rawEntries {
                        guard let log = entry as? OSLogEntryLog else { continue }
                        let lvl: LogLevel
                        switch log.level {
                        case .undefined, .debug: lvl = .debug
                        case .info: lvl = .info
                        case .notice: lvl = .notice
                        case .error: lvl = .error
                        case .fault: lvl = .fault
                        @unknown default: lvl = .info
                        }

                        let categoryName = log.subsystem.isEmpty ? log.category : log.category
                        let item = LogEntry(
                            timestamp: log.date,
                            category: categoryName,
                            subsystem: log.subsystem.isEmpty ? nil : log.subsystem,
                            level: lvl,
                            message: log.composedMessage,
                            isAppleSystemLog: true
                        )
                        results.append(item)
                    }

                    if results.count > limit {
                        return Array(results.suffix(limit))
                    }
                    return results
                } catch {
                    return [
                        LogEntry(
                            timestamp: Date(),
                            category: "AppleSystem",
                            subsystem: "com.apple.oslog",
                            level: .warning,
                            message: "Unable to query OSLogStore: \(error.localizedDescription)",
                            isAppleSystemLog: true
                        )
                    ]
                }
            }.value
        } else {
            return []
        }
    }

    /// Asynchronously refreshes internal Apple framework logs and updates the live revision.
    public func refreshAppleSystemLogs(limit: Int = 2000) async {
        let freshLogs = await fetchAppleSystemLogs(limit: limit)
        lock.lock()
        internalAppleEntries = freshLogs
        lock.unlock()

        await MainActor.run {
            self.revision += 1
        }
    }

    /// Clears all stored session logs.
    public func clear() {
        lock.lock()
        internalEntries.removeAll()
        internalAppleEntries.removeAll()
        lock.unlock()

        Task { @MainActor in
            self.revision += 1
        }
    }

    /// Generates exhaustive plain-text representation containing live system diagnostics,
    /// in-app session logs, and direct Apple framework logs from Xcode console.
    @MainActor
    public func formattedComprehensiveReport(playerService: AudioPlayerService? = nil) -> String {
        let formatter = LogEntry.fullFormatter
        let inAppLogs = allEntries()
        let appleLogs = appleSystemEntries()

        var text = "================================================================================\n"
        text += "                    LAC MUSIC PLAYER - SYSTEM & SESSION LOGS                    \n"
        text += "================================================================================\n"
        text += "Exported: \(formatter.string(from: Date()))\n"
        text += "Application Log Entries: \(inAppLogs.count)\n"
        text += "Apple Framework Log Entries (Xcode Console Stream): \(appleLogs.count)\n"
        text += "================================================================================\n\n"

        // Section 1: Detailed Runtime Diagnostics Breakdown
        text += DiagnosticsCollector.generateDiagnosticBreakdown(playerService: playerService)

        // Section 2: In-App Application Logs
        text += "================================================================================\n"
        text += "                       IN-APP APPLICATION SESSION LOGS                          \n"
        text += "================================================================================\n\n"
        if inAppLogs.isEmpty {
            text += "[No in-app application logs recorded in this session]\n\n"
        } else {
            for entry in inAppLogs {
                let timeStr = formatter.string(from: entry.timestamp)
                text += "[\(timeStr)] [\(entry.category)] [\(entry.level.rawValue)] \(entry.message)\n"
            }
            text += "\n"
        }

        // Section 3: Direct Apple Unified Framework Logs
        text += "================================================================================\n"
        text += "          DIRECT APPLE FRAMEWORK LOGS (XCODE CONSOLE / OSLogStore)              \n"
        text += "================================================================================\n\n"
        if appleLogs.isEmpty {
            text += "[No Apple framework logs currently cached from OSLogStore]\n\n"
        } else {
            for entry in appleLogs {
                let timeStr = formatter.string(from: entry.timestamp)
                let sub = entry.subsystem ?? "Apple"
                text += "[\(timeStr)] [\(sub) / \(entry.category)] [\(entry.level.rawValue)] \(entry.message)\n"
            }
            text += "\n"
        }

        text += "================================================================================\n"
        text += "                             END OF SESSION LOGS                                \n"
        text += "================================================================================\n"

        return text
    }

    /// Generates standard plain-text representation (backward compatibility helper).
    public func formattedPlainText() -> String {
        let snapshot = allEntries()
        let formatter = LogEntry.fullFormatter
        var text = "=== LAC APPLICATION LOGS ===\n"
        text += "Exported: \(formatter.string(from: Date()))\n"
        text += "Total Entries: \(snapshot.count)\n"
        text += "============================\n\n"

        for entry in snapshot {
            let timeStr = formatter.string(from: entry.timestamp)
            text += "[\(timeStr)] [\(entry.category)] [\(entry.level.rawValue)] \(entry.message)\n"
        }
        return text
    }

    /// Copies comprehensive diagnostic logs to system clipboard.
    @MainActor
    @discardableResult
    public func copyToClipboard(playerService: AudioPlayerService? = nil) -> Bool {
        let logsText = formattedComprehensiveReport(playerService: playerService)
        #if canImport(UIKit)
        UIPasteboard.general.string = logsText
        return true
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(logsText, forType: .string)
        #else
        return false
        #endif
    }
}

// MARK: - Log Category Wrapper

/// High-performance logging category wrapping Apple's `os.Logger` while capturing entries in `SessionLogStore`.
public struct LogCategory: Sendable {
    public let name: String
    private let osLogger: os.Logger

    public init(subsystem: String, category: String) {
        self.name = category
        self.osLogger = os.Logger(subsystem: subsystem, category: category)
    }

    private func record(level: LogLevel, message: String) {
        SessionLogStore.shared.append(
            LogEntry(category: name, level: level, message: message)
        )
    }

    public func debug(_ message: String) {
        record(level: .debug, message: message)
        osLogger.debug("\(message, privacy: .public)")
    }

    public func info(_ message: String) {
        record(level: .info, message: message)
        osLogger.info("\(message, privacy: .public)")
    }

    public func notice(_ message: String) {
        record(level: .notice, message: message)
        osLogger.notice("\(message, privacy: .public)")
    }

    public func warning(_ message: String) {
        record(level: .warning, message: message)
        osLogger.warning("\(message, privacy: .public)")
    }

    public func error(_ message: String) {
        record(level: .error, message: message)
        osLogger.error("\(message, privacy: .public)")
    }

    public func fault(_ message: String) {
        record(level: .fault, message: message)
        osLogger.fault("\(message, privacy: .public)")
    }

    public func critical(_ message: String) {
        record(level: .critical, message: message)
        osLogger.critical("\(message, privacy: .public)")
    }

    public func log(_ message: String) {
        record(level: .info, message: message)
        osLogger.log("\(message, privacy: .public)")
    }

    public func log(level: OSLogType, _ message: String) {
        let mappedLevel: LogLevel
        switch level {
        case .debug: mappedLevel = .debug
        case .info: mappedLevel = .info
        case .error: mappedLevel = .error
        case .fault: mappedLevel = .fault
        default: mappedLevel = .info
        }
        record(level: mappedLevel, message: message)
        osLogger.log(level: level, "\(message, privacy: .public)")
    }
}

// MARK: - AppLogger Facade

/// Structured, high-performance system logger utilizing Apple's unified logging system (`os.Logger`)
/// and retaining in-memory session logs for in-app debug inspection and export.
public enum AppLogger {
    private static let subsystem: String = Bundle.main.bundleIdentifier ?? "com.musicplayer.app"

    // MARK: - Categories

    /// Logs related to audio engine, playback states, queue transitions, and hardware interruptions.
    public static let audio = LogCategory(subsystem: subsystem, category: "Audio")

    /// Logs related to library management, playlist mutations, and sorting algorithms.
    public static let library = LogCategory(subsystem: subsystem, category: "Library")

    /// Logs related to directory scanning, file system traversal, and AVFoundation metadata extraction.
    public static let scanner = LogCategory(subsystem: subsystem, category: "Scanner")

    /// Logs related to disk persistence, JSON serialization, and cache storage.
    public static let storage = LogCategory(subsystem: subsystem, category: "Storage")

    /// Logs related to online metadata fetching, network requests, and API rate limits.
    public static let network = LogCategory(subsystem: subsystem, category: "Network")

    /// Logs related to metadata comparison, enrichment diffs, and tag parsing.
    public static let metadata = LogCategory(subsystem: subsystem, category: "Metadata")

    /// Logs related to UI lifecycle events, sheet transitions, and navigation.
    public static let ui = LogCategory(subsystem: subsystem, category: "UI")

    // MARK: - Helpers

    /// Returns plain text representation of all session logs.
    public static func allLogsText() -> String {
        SessionLogStore.shared.formattedPlainText()
    }

    /// Copies all session logs to system clipboard.
    @discardableResult
    public static func copyLogsToClipboard() -> Bool {
        SessionLogStore.shared.copyToClipboard()
    }
}
