//
//  TimeFormatting.swift
//  MusicPlayer
//
//  Created by Principal Apple Software Engineer on 8/24/26.
//

import Foundation

/// Fast, allocation-conscious time and duration formatting utilities.
public enum TimeFormatting {
    /// Formats a time interval in seconds to standard playback strings:
    /// - `m:ss` (e.g. `3:45`)
    /// - `h:mm:ss` (e.g. `1:12:30`)
    public static func format(seconds: TimeInterval) -> String {
        guard !seconds.isNaN && !seconds.isInfinite && seconds >= 0 else {
            return "0:00"
        }

        let totalSeconds = Int(seconds.rounded())
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
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
        let remaining = max(0, total - current)
        let formatted = format(seconds: remaining)
        return "-\(formatted)"
    }

    /// Formats total playback time for an album or playlist (e.g., `45 MIN` or `1 HR 12 MIN`).
    public static func formatSummaryDuration(seconds: TimeInterval) -> String {
        guard !seconds.isNaN && !seconds.isInfinite && seconds > 0 else {
            return "0 MIN"
        }

        let totalSeconds = Int(seconds.rounded())
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60

        if hours > 0 {
            if minutes > 0 {
                return "\(hours) HR \(minutes) MIN"
            } else {
                return "\(hours) HR"
            }
        } else {
            return "\(max(1, minutes)) MIN"
        }
    }

    /// Convenience alias for formatSummaryDuration(seconds:).
    public static func formatTotalDuration(_ seconds: TimeInterval) -> String {
        formatSummaryDuration(seconds: seconds)
    }
}
