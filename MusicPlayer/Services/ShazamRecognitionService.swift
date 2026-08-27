//
//  ShazamRecognitionService.swift
//  MusicPlayer
//
//  Created by Principal Apple Software Engineer on 8/25/26.
//

import Foundation
import AVFoundation
import os
#if canImport(ShazamKit)
import ShazamKit
#endif

/// Native Apple acoustic recognition actor utilizing ShazamKit (`SHSignatureGenerator` & `SHSession`).
/// Directly generates an acoustic audio fingerprint from a local audio file and matches against Apple's global Shazam catalog.
/// Bypasses text search APIs entirely, requires zero API keys, and has zero HTTP rate limits.
public actor ShazamRecognitionService: NSObject {
    public static let shared = ShazamRecognitionService()

    #if canImport(ShazamKit)
    private var activeContinuation: CheckedContinuation<OnlineTrackMetadata?, Never>?
    private var session: SHSession?
    #endif

    private override init() {
        super.init()
    }

    /// Asynchronously recognizes a song by analyzing its raw acoustic waveform.
    ///
    /// - Parameter fileURL: The audio file URL on disk.
    /// - Returns: Official Apple Music metadata verified by Shazam, or nil if acoustic match was not found.
    public func recognizeTrack(at fileURL: URL) async -> OnlineTrackMetadata? {
        #if canImport(ShazamKit)
        let isAccessing = fileURL.startAccessingSecurityScopedResource()
        defer {
            if isAccessing {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }

        guard let audioFile = try? AVAudioFile(forReading: fileURL) else {
            return nil
        }

        let format = audioFile.processingFormat
        guard format.sampleRate > 0 && format.channelCount > 0 else { return nil }

        // Read 10-12 seconds of PCM audio (optimal duration for Shazam signature generation)
        let sampleRate = format.sampleRate
        let maxFrames = AVAudioFrameCount(min(Double(audioFile.length), sampleRate * 12.0))
        guard maxFrames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: maxFrames) else {
            return nil
        }

        do {
            try audioFile.read(into: buffer, frameCount: maxFrames)
        } catch {
            return nil
        }

        let generator = SHSignatureGenerator()
        do {
            try generator.append(buffer, at: nil)
            let signature = generator.signature()

            return await withCheckedContinuation { continuation in
                let shSession = SHSession()
                self.session = shSession
                self.activeContinuation = continuation
                shSession.delegate = self
                shSession.match(signature)
            }
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    #if canImport(ShazamKit)
    private func handleMatchResult(_ item: SHMatchedMediaItem?) {
        guard let item = item, let title = item.title, let artist = item.artist else {
            activeContinuation?.resume(returning: nil)
            activeContinuation = nil
            return
        }

        let artworkURL = item.artworkURL
        let genre = item.genres.first
        let releaseDate = item.creationDate
        let releaseYear = releaseDate.map { Calendar.current.component(.year, from: $0) }

        let onlineMeta = OnlineTrackMetadata(
            id: "shazam_\(item.appleMusicID ?? UUID().uuidString)",
            title: title,
            artist: artist,
            album: title,
            albumArtist: artist,
            releaseDate: releaseDate,
            releaseYear: releaseYear,
            genre: genre,
            trackNumber: nil,
            totalTracks: nil,
            discNumber: nil,
            duration: nil,
            artworkURL: artworkURL,
            previewURL: item.appleMusicURL,
            sourceAPI: "Apple ShazamKit",
            isCompilation: false,
            isShazamMatch: true
        )

        activeContinuation?.resume(returning: onlineMeta)
        activeContinuation = nil
    }
    #endif
}

#if canImport(ShazamKit)
extension ShazamRecognitionService: @preconcurrency SHSessionDelegate {
    nonisolated public func session(_ session: SHSession, didFind match: SHMatch) {
        Task {
            await self.handleMatchResult(match.mediaItems.first)
        }
    }

    nonisolated public func session(_ session: SHSession, didNotFindMatchFor signature: SHSignature, error: (any Error)?) {
        Task {
            await self.handleMatchResult(nil)
        }
    }
}
#endif
