import Foundation

/// Individual lyric line with optional synchronized timestamp.
public struct LyricLine: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let timestamp: TimeInterval?
    public let text: String

    public init(id: UUID = UUID(), timestamp: TimeInterval? = nil, text: String) {
        self.id = id
        self.timestamp = timestamp
        self.text = text
    }
}

/// Parsed lyrics representation categorized as synchronized (tracked) or plain unsynchronized (solid).
public enum ParsedLyrics: Sendable, Equatable {
    case tracked(lines: [LyricLine])
    case solid(lines: [String], rawText: String)
    case empty

    public var isEmpty: Bool {
        switch self {
        case .empty: return true
        case .solid(let lines, _): return lines.isEmpty
        case .tracked(let lines): return lines.isEmpty
        }
    }
}

/// High-speed regex parser for standard LRC timestamped lyrics and plain text formats.
public struct LyricsParser: Sendable {

    /// Validates if a text string contains readable, regular characters (letters, numbers, standard punctuation)
    /// and rejects binary garbage, control characters, or non-text metadata blobs.
    public static func isRegularText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        // Reject control characters or null bytes (except newline / tab)
        let invalidControlChars = CharacterSet.controlCharacters.subtracting(.whitespacesAndNewlines)
        if trimmed.unicodeScalars.contains(where: { invalidControlChars.contains($0) }) {
            return false
        }

        // Count readable letter or number characters
        let letterOrDigitCount = trimmed.unicodeScalars.filter {
            CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
        }.count

        // If the text has no alphanumeric characters at all, or less than 20% readable characters, reject as non-regular
        let totalCount = trimmed.unicodeScalars.count
        guard letterOrDigitCount >= 2, Double(letterOrDigitCount) / Double(totalCount) >= 0.20 else {
            return false
        }

        return true
    }

    /// Parses raw lyric text into tracked or solid representations.
    public static func parse(_ raw: String?) -> ParsedLyrics {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty, isRegularText(raw) else {
            return .empty
        }

        let lines = raw.components(separatedBy: .newlines)
        var trackedLines: [LyricLine] = []
        var plainLines: [String] = []

        // Regex for LRC timestamp: [mm:ss.xx] or [mm:ss.xxx] or [mm:ss]
        let pattern = #"\[(\d{1,2}):(\d{1,2}(?:\.\d{1,3})?)\]"#
        let regex = try? NSRegularExpression(pattern: pattern, options: [])

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            let nsString = trimmed as NSString
            let matches = regex?.matches(in: trimmed, options: [], range: NSRange(location: 0, length: nsString.length)) ?? []

            if !matches.isEmpty {
                // Extract timestamp(s) and lyrics text
                var timestamps: [TimeInterval] = []
                var lastMatchEnd = 0

                for match in matches {
                    let minRange = match.range(at: 1)
                    let secRange = match.range(at: 2)
                    let mins = Double(nsString.substring(with: minRange)) ?? 0
                    let secs = Double(nsString.substring(with: secRange)) ?? 0
                    timestamps.append(mins * 60.0 + secs)
                    lastMatchEnd = max(lastMatchEnd, match.range.location + match.range.length)
                }

                let textContent = nsString.substring(from: lastMatchEnd).trimmingCharacters(in: .whitespaces)
                let cleanedText = textContent.isEmpty ? "..." : textContent

                if isRegularText(cleanedText) || cleanedText == "..." {
                    for t in timestamps {
                        trackedLines.append(LyricLine(timestamp: t, text: cleanedText))
                    }
                }
            } else {
                // Check if it's metadata tag like [ar:...], [ti:...], [al:...]
                if trimmed.hasPrefix("[") && trimmed.contains(":") && trimmed.hasSuffix("]") {
                    continue // Skip LRC header metadata tags
                }
                if isRegularText(trimmed) {
                    plainLines.append(trimmed)
                }
            }
        }

        if trackedLines.count >= 2 {
            // Sort tracked lines chronologically
            let sorted = trackedLines.sorted { ($0.timestamp ?? 0) < ($1.timestamp ?? 0) }
            return .tracked(lines: sorted)
        } else if !plainLines.isEmpty {
            return .solid(lines: plainLines, rawText: raw)
        } else if !trackedLines.isEmpty {
            return .tracked(lines: trackedLines)
        } else {
            return .empty
        }
    }
}
