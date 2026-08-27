//
//  ByteFormatting.swift
//  MusicPlayer
//
//  Created by Principal Apple Software Engineer on 8/24/26.
//

import Foundation

/// Fast and clean byte, file size, and bitrate formatting utilities.
public enum ByteFormatting {
    private static let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter
    }()

    /// Formats file size in bytes to human-readable strings (e.g., `8.4 MB`, `1.2 GB`).
    public static func formatFileSize(bytes: Int64) -> String {
        guard bytes > 0 else { return "0 KB" }
        return byteCountFormatter.string(fromByteCount: bytes)
    }

    /// Convenience alias for formatFileSize(bytes:).
    public static func formatBytes(_ bytes: Int64) -> String {
        formatFileSize(bytes: bytes)
    }

    /// Formats audio bitrate in kbps (e.g. `320 kbps`, `1411 kbps`, `Lossless`).
    public static func formatBitrate(bps: Double) -> String {
        guard bps > 0 else { return "N/A" }
        let kbps = Int(round(bps / 1000.0))
        return "\(kbps) kbps"
    }

    /// Formats sample rate in kHz or Hz (e.g. `44.1 kHz`, `96.0 kHz`, `192.0 kHz`).
    public static func formatSampleRate(hz: Double) -> String {
        guard hz > 0 else { return "N/A" }
        if hz >= 1000.0 {
            let khz = hz / 1000.0
            return String(format: "%.1f kHz", khz)
        } else {
            return "\(Int(hz)) Hz"
        }
    }
}
