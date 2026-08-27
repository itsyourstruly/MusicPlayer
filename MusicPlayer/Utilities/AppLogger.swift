//
//  AppLogger.swift
//  MusicPlayer
//
//  Created by Principal Apple Software Engineer on 8/24/26.
//

import Foundation
@_exported import os

/// Structured, high-performance system logger utilizing Apple's unified logging system (`os.Logger`).
/// Adheres strictly to subsystem and category separation for clean console filtering and zero performance overhead.
public enum AppLogger {
    private static let subsystem: String = Bundle.main.bundleIdentifier ?? "com.musicplayer.app"

    /// Logs related to audio engine, playback states, queue transitions, and hardware interruptions.
    public static let audio: Logger = Logger(subsystem: subsystem, category: "Audio")

    /// Logs related to library management, playlist mutations, and sorting algorithms.
    public static let library: Logger = Logger(subsystem: subsystem, category: "Library")

    /// Logs related to directory scanning, file system traversal, and AVFoundation metadata extraction.
    public static let scanner: Logger = Logger(subsystem: subsystem, category: "Scanner")

    /// Logs related to disk persistence, JSON serialization, and cache storage.
    public static let storage: Logger = Logger(subsystem: subsystem, category: "Storage")

    /// Logs related to online metadata fetching, network requests, and API rate limits.
    public static let network: Logger = Logger(subsystem: subsystem, category: "Network")

    /// Logs related to metadata comparison, enrichment diffs, and tag parsing.
    public static let metadata: Logger = Logger(subsystem: subsystem, category: "Metadata")

    /// Logs related to UI lifecycle events, sheet transitions, and navigation.
    public static let ui: Logger = Logger(subsystem: subsystem, category: "UI")
}
