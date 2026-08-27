//
//  AudioFileInfo.swift
//  MusicPlayer
//
//  Created by Principal Apple Software Engineer on 8/24/26.
//

import Foundation

/// Detailed audio file specification and container metadata.
public struct AudioFileInfo: Identifiable, Codable, Sendable, Hashable {
    public var id: String { filePath }

    /// Full file URL string representation.
    public let filePath: String

    /// File name including extension (e.g., `track_01.flac`).
    public let fileName: String

    /// File format extension (e.g. `FLAC`, `MP3`, `M4A`, `WAV`, `ALAC`).
    public let fileExtension: String

    /// Exact size of the audio file in bytes.
    public let fileSizeBytes: Int64

    /// Audio sample rate in Hertz (e.g. `44100.0`, `96000.0`).
    public let sampleRate: Double

    /// Audio channel count (e.g. `1` for Mono, `2` for Stereo, `6` for 5.1).
    public let channelCount: Int

    /// Audio bitrate in bits per second (e.g. `320000.0` for 320kbps).
    public let bitRate: Double

    /// Audio codec description or format identifier (e.g. `MPEG-4 AAC`, `FLAC`, `Linear PCM`).
    public let formatDescription: String

    /// Exact duration in seconds with sub-millisecond precision.
    public let durationSeconds: Double

    /// Date file was created or added to device storage.
    public let creationDate: Date?

    /// Date file was last modified on disk.
    public let modificationDate: Date?

    public init(
        filePath: String,
        fileName: String,
        fileExtension: String,
        fileSizeBytes: Int64,
        sampleRate: Double,
        channelCount: Int,
        bitRate: Double,
        formatDescription: String,
        durationSeconds: Double,
        creationDate: Date? = nil,
        modificationDate: Date? = nil
    ) {
        self.filePath = filePath
        self.fileName = fileName
        self.fileExtension = fileExtension.uppercased()
        self.fileSizeBytes = fileSizeBytes
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.bitRate = bitRate
        self.formatDescription = formatDescription
        self.durationSeconds = durationSeconds
        self.creationDate = creationDate
        self.modificationDate = modificationDate
    }

    /// Descriptive channel layout label (e.g., `Stereo (2 Ch)`, `Mono (1 Ch)`).
    public var channelDescription: String {
        switch channelCount {
        case 1:
            return "Mono (1 Ch)"
        case 2:
            return "Stereo (2 Ch)"
        case 6:
            return "5.1 Surround (6 Ch)"
        case 8:
            return "7.1 Surround (8 Ch)"
        default:
            return "\(channelCount) Channels"
        }
    }
}
