import Foundation

/// Fast and clean byte, file size, and bitrate formatting utilities.
public enum ByteFormatting {
    // Shared formatter instance — ByteCountFormatter is thread-safe and expensive to allocate
    private static let byteCountFormatter: ByteCountFormatter = {
        // Formatter
        let formatter = ByteCountFormatter()
        // Restrict to human-readable units; omit TB since music files never get that large
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter
    }()

    // MARK: - File Size

    /// Formats file size in bytes to human-readable strings (e.g., `8.4 MB`, `1.2 GB`).
    public static func formatFileSize(bytes: Int64) -> String {
        // Ensure preconditions are met before proceeding
        guard bytes > 0 else { return "0 KB" }
        return byteCountFormatter.string(fromByteCount: bytes)
    }

    /// Convenience alias for formatFileSize(bytes:).
    public static func formatBytes(_ bytes: Int64) -> String {
        formatFileSize(bytes: bytes)
    }

    // MARK: - Audio Format

    /// Formats audio bitrate in kbps (e.g. `320 kbps`, `1411 kbps`, `Lossless`).
    public static func formatBitrate(bps: Double) -> String {
        // Ensure preconditions are met before proceeding
        guard bps > 0 else { return "N/A" }
        // Round to nearest integer kbps — fractional values are never meaningful in audio UI
        let kbps = Int(round(bps / 1000.0))
        return "\(kbps) kbps"
    }

    /// Formats sample rate in kHz or Hz (e.g. `44.1 kHz`, `96.0 kHz`, `192.0 kHz`).
    public static func formatSampleRate(hz: Double) -> String {
        // Ensure preconditions are met before proceeding
        guard hz > 0 else { return "N/A" }
        if hz >= 1000.0 {
            // Common audio sample rates are all multiples of 1 kHz, so one decimal is sufficient
            let khz = hz / 1000.0
            return String(format: "%.1f kHz", khz)
        } else {
            return "\(Int(hz)) Hz"
        }
    }
}
