import Foundation

/// Fast, allocation-conscious time and duration formatting utilities.
public enum TimeFormatting {

    // MARK: - Playback Clock

    /// Formats a time interval in seconds to standard playback strings:
    /// - `m:ss` (e.g. `3:45`)
    /// - `h:mm:ss` (e.g. `1:12:30`)
    public static func format(seconds: TimeInterval) -> String {
        // Guard against NaN/Inf that can appear when a stream hasn't reported its duration yet
        guard !seconds.isNaN && !seconds.isInfinite && seconds >= 0 else {
            return "0:00"
        }

        // Total seconds
        let totalSeconds = Int(seconds.rounded())
        // Hours
        let hours = totalSeconds / 3600
        // Minutes
        let minutes = (totalSeconds % 3600) / 60
        // Remaining seconds
        let remainingSeconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        } else {
            return String(format: "%d:%02d", minutes, remainingSeconds)
        }
    }

    /// Convenience helper for formatting track durations.
    public static func formatTrackDuration(_ duration: TimeInterval) -> String {
        format(seconds: duration)
    }

    /// Convenience alias for format(seconds:).
    public static func formatTime(_ seconds: TimeInterval) -> String {
        format(seconds: seconds)
    }

    /// Formats remaining time as a negative countdown string (e.g., `-2:15`).
    public static func formatRemaining(current: TimeInterval, total: TimeInterval) -> String {
        // Remaining
        let remaining = max(0, total - current)
        // Formatted
        let formatted = format(seconds: remaining)
        return "-\(formatted)"
    }

    // MARK: - Summary Duration

    /// Formats total playback time for an album or playlist (e.g., `45 MIN` or `1 HR 12 MIN`).
    ///
    /// Uses all-caps abbreviated units to match the compact display style used in the library UI.
    public static func formatSummaryDuration(seconds: TimeInterval) -> String {
        // Ensure preconditions are met before proceeding
        guard !seconds.isNaN && !seconds.isInfinite && seconds > 0 else {
            return "0 MIN"
        }

        // Total seconds
        let totalSeconds = Int(seconds.rounded())
        // Hours
        let hours = totalSeconds / 3600
        // Minutes
        let minutes = (totalSeconds % 3600) / 60

        if hours > 0 {
            if minutes > 0 {
                return "\(hours) HR \(minutes) MIN"
            } else {
                return "\(hours) HR"
            }
        } else {
            // Show at least "1 MIN" for very short content rather than "0 MIN"
            return "\(max(1, minutes)) MIN"
        }
    }

    /// Convenience alias for formatSummaryDuration(seconds:).
    public static func formatTotalDuration(_ seconds: TimeInterval) -> String {
        formatSummaryDuration(seconds: seconds)
    }
}
