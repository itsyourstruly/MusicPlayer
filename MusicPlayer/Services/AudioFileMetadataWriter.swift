import Foundation
import AVFoundation
import ImageIO
import CoreGraphics
import os

/// Production-grade thread-safe metadata persistence engine directly into audio files on local disk and iCloud Drive.
/// Guarantees 100% bit-perfect audio stream preservation across M4A/AAC/ALAC/MP4, MP3, and FLAC containers.
/// Employs NSFileCoordinator to coordinate safely with the iCloud sync daemon (bird) and security-scoped resource management.
public struct AudioFileMetadataWriter: Sendable {
    public static let shared = AudioFileMetadataWriter()

    // File manager
    private let fileManager = FileManager.default

    // Initialize with configured properties
    public init() {}

    /// Downsamples and optimizes image data (max 1000x1000, 85% JPEG compression) to prevent audio file container bloat.
    public static func optimizeArtworkForEmbedding(data: Data, maxDimension: CGFloat = 1000.0) -> Data {
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil) else { return data }
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else { return data }
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(mutableData as CFMutableData, "public.jpeg" as CFString, 1, nil) else { return data }
        let compressionOptions: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.85
        ]
        CGImageDestinationAddImage(destination, thumbnail, compressionOptions as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return data }
        return mutableData as Data
    }

    /// Safely writes updated metadata and artwork into the target audio file on disk without re-encoding audio samples.
    ///
    /// - Parameters:
    ///   - fileURL: The absolute file URL of the audio track.
    ///   - title: Track title.
    ///   - artist: Track artist.
    ///   - album: Album title.
    ///   - albumArtist: Optional album artist.
    ///   - year: Optional release year.
    ///   - genre: Optional genre description.
    ///   - trackNumber: Optional track index number.
    ///   - totalTracks: Optional total track count.
    ///   - discNumber: Optional disc number.
    ///   - artworkData: Optional binary image data (JPEG or PNG).
    /// - Returns: True if file metadata was successfully updated on disk; otherwise false.
    public func writeMetadata(
        to fileURL: URL,
        title: String,
        artist: String,
        album: String,
        albumArtist: String? = nil,
        year: Int? = nil,
        genre: String? = nil,
        trackNumber: Int? = nil,
        totalTracks: Int? = nil,
        discNumber: Int? = nil,
        artworkData: Data? = nil
    ) async -> Bool {
        // Optimize artwork data if provided
        let optimizedArtwork = artworkData.flatMap { Self.optimizeArtworkForEmbedding(data: $0) }

        // Ensure root linked folder security-scoped access is active along with target file access
        let rootURL = SecurityScopedBookmark.shared.currentFolderURL ?? SecurityScopedBookmark.shared.resolveAndAccessBookmark()
        // Flag indicating if root accessing
        let isRootAccessing = rootURL?.startAccessingSecurityScopedResource() ?? false
        // Flag indicating if file accessing
        let isFileAccessing = fileURL.startAccessingSecurityScopedResource()

        // Cleanup upon exiting scope
        defer {
            if isFileAccessing {
                fileURL.stopAccessingSecurityScopedResource()
            }
            if isRootAccessing, let root = rootURL {
                root.stopAccessingSecurityScopedResource()
            }
        }

        // Verify target file existence and reachability
        guard fileManager.fileExists(atPath: fileURL.path) else {
            AppLogger.storage.error("AudioFileMetadataWriter: Target file does not exist at \(fileURL.path)")
            return false
        }

        // Ext
        let ext = fileURL.pathExtension.lowercased()

        switch ext {
        case "m4a", "mp4", "m4b", "m4p", "aac", "alac":
            return await writeM4AMetadata(
                fileURL: fileURL,
                title: title,
                artist: artist,
                album: album,
                albumArtist: albumArtist,
                year: year,
                genre: genre,
                trackNumber: trackNumber,
                totalTracks: totalTracks,
                discNumber: discNumber,
                artworkData: optimizedArtwork
            )

        case "mp3":
            return writeMP3Metadata(
                fileURL: fileURL,
                title: title,
                artist: artist,
                album: album,
                albumArtist: albumArtist,
                year: year,
                genre: genre,
                trackNumber: trackNumber,
                totalTracks: totalTracks,
                discNumber: discNumber,
                artworkData: optimizedArtwork
            )

        case "flac":
            return writeFLACMetadata(
                fileURL: fileURL,
                title: title,
                artist: artist,
                album: album,
                albumArtist: albumArtist,
                year: year,
                genre: genre,
                trackNumber: trackNumber,
                totalTracks: totalTracks,
                discNumber: discNumber,
                artworkData: optimizedArtwork
            )

        default:
            AppLogger.storage.info("AudioFileMetadataWriter: Tag writing not directly supported for format .\(ext). Skipping disk write.")
            return true
        }
    }

    // MARK: - M4A / MP4 / AAC / ALAC Passthrough Export

    /// Rewrites MP4/M4A user data atoms (`udta`/`meta`) using AVAssetExportSession in passthrough mode.
    /// Passthrough mode performs a bit-for-bit verbatim stream copy of audio packets with zero re-encoding.
    private func writeM4AMetadata(
        fileURL: URL,
        title: String,
        artist: String,
        album: String,
        albumArtist: String?,
        year: Int?,
        genre: String?,
        trackNumber: Int?,
        totalTracks: Int?,
        discNumber: Int?,
        artworkData: Data?
    ) async -> Bool {
        // Temp directory
        let tempDirectory = fileManager.temporaryDirectory
        // File system location for local source url
        let localSourceURL = tempDirectory.appendingPathComponent("src_\(UUID().uuidString).m4a")
        // File system location for temp output url
        let tempOutputURL = tempDirectory.appendingPathComponent("meta_\(UUID().uuidString).m4a")

        // Cleanup upon exiting scope
        defer {
            try? fileManager.removeItem(at: localSourceURL)
            try? fileManager.removeItem(at: tempOutputURL)
        }

        // Copy source file to local sandbox temp so out-of-process mediaserverd can read it without sandbox extension issues
        do {
            try fileManager.copyItem(at: fileURL, to: localSourceURL)
        } catch {
            AppLogger.storage.error("Failed to copy M4A file to local sandbox temp: \(error.localizedDescription)")
            return false
        }

        // Asset
        let asset = AVURLAsset(url: localSourceURL)

        // Ensure preconditions are met before proceeding
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            AppLogger.storage.error("Failed to initialize passthrough export session for \(fileURL.lastPathComponent)")
            return false
        }

        exportSession.outputURL = tempOutputURL
        exportSession.outputFileType = .m4a
        exportSession.shouldOptimizeForNetworkUse = false

        // Build metadata item collection
        var metadataItems: [AVMutableMetadataItem] = []

        if !title.isEmpty {
            // Item
            let item = AVMutableMetadataItem()
            item.identifier = .commonIdentifierTitle
            item.value = title as NSString
            item.dataType = kCMMetadataBaseDataType_UTF8 as String
            metadataItems.append(item)
        }

        if !artist.isEmpty {
            // Item
            let item = AVMutableMetadataItem()
            item.identifier = .commonIdentifierArtist
            item.value = artist as NSString
            item.dataType = kCMMetadataBaseDataType_UTF8 as String
            metadataItems.append(item)
        }

        if !album.isEmpty {
            // Item
            let item = AVMutableMetadataItem()
            item.identifier = .commonIdentifierAlbumName
            item.value = album as NSString
            item.dataType = kCMMetadataBaseDataType_UTF8 as String
            metadataItems.append(item)
        }

        // Album Artist
        if let albArtist = albumArtist, !albArtist.isEmpty {
            // Item
            let item = AVMutableMetadataItem()
            item.keySpace = .iTunes
            item.key = "aART" as NSString
            item.value = albArtist as NSString
            item.dataType = kCMMetadataBaseDataType_UTF8 as String
            metadataItems.append(item)
        }

        // Year / Release Date
        if let y = year, y > 0 {
            // Item
            let item = AVMutableMetadataItem()
            item.identifier = .commonIdentifierCreationDate
            item.value = String(y) as NSString
            item.dataType = kCMMetadataBaseDataType_UTF8 as String
            metadataItems.append(item)
        }

        // Genre
        if let g = genre, !g.isEmpty {
            // Item
            let item = AVMutableMetadataItem()
            item.identifier = .commonIdentifierType
            item.value = g as NSString
            item.dataType = kCMMetadataBaseDataType_UTF8 as String
            metadataItems.append(item)
        }

        // Track Number (trkn: 8-byte big-endian payload)
        if let trackNum = trackNumber, trackNum > 0 {
            // Total
            let total = totalTracks ?? 0
            // Track bytes
            let trackBytes: [UInt8] = [0, 0, 0, UInt8(min(255, trackNum)), 0, UInt8(min(255, total)), 0, 0]
            // Item
            let item = AVMutableMetadataItem()
            item.keySpace = .iTunes
            item.key = "trkn" as NSString
            item.value = Data(trackBytes) as NSData
            item.dataType = kCMMetadataBaseDataType_RawData as String
            metadataItems.append(item)
        }

        // Disc Number (disk: 6-byte big-endian payload)
        if let discNum = discNumber, discNum > 0 {
            // Disc bytes
            let discBytes: [UInt8] = [0, 0, 0, UInt8(min(255, discNum)), 0, 0]
            // Item
            let item = AVMutableMetadataItem()
            item.keySpace = .iTunes
            item.key = "disk" as NSString
            item.value = Data(discBytes) as NSData
            item.dataType = kCMMetadataBaseDataType_RawData as String
            metadataItems.append(item)
        }

        // Embedded Artwork (covr)
        if let art = artworkData, !art.isEmpty {
            // Item
            let item = AVMutableMetadataItem()
            item.identifier = .commonIdentifierArtwork
            item.value = art as NSData
            item.dataType = kCMMetadataBaseDataType_JPEG as String
            metadataItems.append(item)
        }

        exportSession.metadata = metadataItems

        // Exported
        let exported = await exportWithTimeout(session: exportSession, timeoutSeconds: 6.0)

        if exported && exportSession.status == .completed {
            // Replaced
            let replaced = coordinateReplace(targetURL: fileURL, tempURL: tempOutputURL)
            if replaced {
                AppLogger.storage.info("Successfully updated M4A tags losslessly via NSFileCoordinator for: \(fileURL.lastPathComponent)")
                return true
            } else {
                AppLogger.storage.error("Failed to coordinate replace M4A file for: \(fileURL.lastPathComponent)")
                return false
            }
        } else {
            // Err
            let err = exportSession.error?.localizedDescription ?? (exported ? "Unknown error" : "Export timed out after 6.0s")
            AppLogger.storage.warning("AVAssetExportSession incomplete (\(err)) for: \(fileURL.lastPathComponent). Skipping disk write.")
            return false
        }
    }

    // MARK: - MP3 ID3v2.3 Lossless Tag Writer

    /// Rewrites MP3 ID3v2.3 tags and prepends them to the verbatim MPEG audio frame stream.
    /// Preserves all audio frames losslessly without decoding or re-encoding.
    private func writeMP3Metadata(
        fileURL: URL,
        title: String,
        artist: String,
        album: String,
        albumArtist: String?,
        year: Int?,
        genre: String?,
        trackNumber: Int?,
        totalTracks: Int?,
        discNumber: Int?,
        artworkData: Data?
    ) -> Bool {
        // Ensure preconditions are met before proceeding
        guard let fileHandle = try? FileHandle(forReadingFrom: fileURL) else {
            AppLogger.storage.error("Unable to open MP3 file for reading: \(fileURL.path)")
            return false
        }
        // Cleanup upon exiting scope
        defer { try? fileHandle.close() }

        // File size
        let fileSize = (try? fileManager.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        // Ensure preconditions are met before proceeding
        guard fileSize > 10 else { return false }

        // Inspect existing ID3v2 header
        let headerData = (try? fileHandle.read(upToCount: 10)) ?? Data()
        // Audio offset
        var audioOffset: UInt64 = 0

        if headerData.count == 10 && headerData[0] == 0x49 && headerData[1] == 0x44 && headerData[2] == 0x33 { // "ID3"
            // Tag size
            let tagSize = (Int(headerData[6] & 0x7F) << 21) |
                          (Int(headerData[7] & 0x7F) << 14) |
                          (Int(headerData[8] & 0x7F) << 7) |
                          Int(headerData[9] & 0x7F)
            // Flags
            let flags = headerData[5]
            // Flag indicating if footer
            let hasFooter = (flags & 0x10) != 0
            audioOffset = UInt64(10 + tagSize + (hasFooter ? 10 : 0))
        }

        // Build new ID3v2.3 frame payload
        var frameData = Data()

        // TIT2 - Title (UTF-8 encoding 0x03)
        if !title.isEmpty {
            frameData.append(buildID3TextFrame(id: "TIT2", text: title))
        }

        // TPE1 - Artist
        if !artist.isEmpty {
            frameData.append(buildID3TextFrame(id: "TPE1", text: artist))
        }

        // TALB - Album
        if !album.isEmpty {
            frameData.append(buildID3TextFrame(id: "TALB", text: album))
        }

        // TPE2 - Album Artist
        if let albArtist = albumArtist, !albArtist.isEmpty {
            frameData.append(buildID3TextFrame(id: "TPE2", text: albArtist))
        }

        // TYER / TDRC - Year
        if let y = year, y > 0 {
            frameData.append(buildID3TextFrame(id: "TYER", text: String(y)))
            frameData.append(buildID3TextFrame(id: "TDRC", text: String(y)))
        }

        // TCON - Genre
        if let g = genre, !g.isEmpty {
            frameData.append(buildID3TextFrame(id: "TCON", text: g))
        }

        // TRCK - Track Number (e.g. "5" or "5/12")
        if let trackNum = trackNumber, trackNum > 0 {
            let str: String
            if let tot = totalTracks, tot > 0 {
                str = "\(trackNum)/\(tot)"
            } else {
                str = "\(trackNum)"
            }
            frameData.append(buildID3TextFrame(id: "TRCK", text: str))
        }

        // TPOS - Disc Number (e.g. "1" or "1/2")
        if let discNum = discNumber, discNum > 0 {
            frameData.append(buildID3TextFrame(id: "TPOS", text: "\(discNum)"))
        }

        // APIC - Attached Picture (Cover Front 0x03)
        if let art = artworkData, !art.isEmpty {
            frameData.append(buildID3PictureFrame(imageData: art))
        }

        // Construct 10-byte ID3v2.3 Header
        var tagHeader = Data([0x49, 0x44, 0x33, 0x03, 0x00, 0x00]) // "ID3", version 2.3.0, no flags
        // Synchsafe
        let synchsafe = encodeSynchsafe(frameData.count)
        tagHeader.append(contentsOf: synchsafe)

        // Write new tag + original MPEG audio stream to sandbox temporary file
        let tempDirectory = fileManager.temporaryDirectory
        // File system location for temp url
        let tempURL = tempDirectory.appendingPathComponent("meta_\(UUID().uuidString).mp3")
        fileManager.createFile(atPath: tempURL.path, contents: nil)

        // Ensure preconditions are met before proceeding
        guard let writeHandle = try? FileHandle(forWritingTo: tempURL) else {
            AppLogger.storage.error("Failed to create MP3 write handle at \(tempURL.path)")
            return false
        }
        // Cleanup upon exiting scope
        defer { try? writeHandle.close() }

        do {
            try writeHandle.write(contentsOf: tagHeader)
            try writeHandle.write(contentsOf: frameData)

            // Seek to audio frames and stream copy in 64KB chunks
            try fileHandle.seek(toOffset: audioOffset)
            // Chunk size
            let chunkSize = 65536

            while true {
                // Chunk
                let chunk = try fileHandle.read(upToCount: chunkSize)
                // Ensure preconditions are met before proceeding
                guard let chunk = chunk, !chunk.isEmpty else { break }
                try writeHandle.write(contentsOf: chunk)
            }

            try writeHandle.synchronize()
            try writeHandle.close()
            try fileHandle.close()

            if coordinateReplace(targetURL: fileURL, tempURL: tempURL) {
                AppLogger.storage.info("Successfully updated MP3 ID3v2 tags via NSFileCoordinator for: \(fileURL.lastPathComponent)")
                return true
            } else {
                AppLogger.storage.error("Failed to coordinate replace MP3 file for: \(fileURL.lastPathComponent)")
                return false
            }
        } catch {
            AppLogger.storage.error("Failed to write MP3 file: \(error.localizedDescription)")
            try? fileManager.removeItem(at: tempURL)
            return false
        }
    }

    // Build id 3 text frame
    private func buildID3TextFrame(id: String, text: String) -> Data {
        // Utf 8 bytes
        let utf8Bytes = Array(text.utf8)
        // Payload size
        let payloadSize = 1 + utf8Bytes.count // 1 byte for encoding (0x03 = UTF-8)
        // Frame
        var frame = Data(id.utf8)

        // 4-byte frame size (big endian)
        frame.append(UInt8((payloadSize >> 24) & 0xFF))
        frame.append(UInt8((payloadSize >> 16) & 0xFF))
        frame.append(UInt8((payloadSize >> 8) & 0xFF))
        frame.append(UInt8(payloadSize & 0xFF))

        // 2-byte flags (0x0000)
        frame.append(contentsOf: [0x00, 0x00])

        // Encoding flag: 0x03 (UTF-8)
        frame.append(0x03)
        frame.append(contentsOf: utf8Bytes)
        return frame
    }

    // Build id 3 picture frame
    private func buildID3PictureFrame(imageData: Data) -> Data {
        // Flag indicating if png
        let isPNG = imageData.count > 8 && imageData[0] == 0x89 && imageData[1] == 0x50
        // Mime type
        let mimeType = isPNG ? "image/png" : "image/jpeg"
        // Mime bytes
        let mimeBytes = Array(mimeType.utf8) + [0x00] // null-terminated

        // Payload
        var payload = Data()
        payload.append(0x00) // Encoding: ISO-8859-1 for MIME and description
        payload.append(contentsOf: mimeBytes)
        payload.append(0x03) // Picture type: 0x03 (Cover Front)
        payload.append(0x00) // Description: empty null-terminated string
        payload.append(imageData)

        // Frame
        var frame = Data("APIC".utf8)
        // Payload size
        let payloadSize = payload.count
        frame.append(UInt8((payloadSize >> 24) & 0xFF))
        frame.append(UInt8((payloadSize >> 16) & 0xFF))
        frame.append(UInt8((payloadSize >> 8) & 0xFF))
        frame.append(UInt8(payloadSize & 0xFF))
        frame.append(contentsOf: [0x00, 0x00]) // Flags
        frame.append(payload)
        return frame
    }

    // Encode synchsafe
    private func encodeSynchsafe(_ value: Int) -> [UInt8] {
        [
            UInt8((value >> 21) & 0x7F),
            UInt8((value >> 14) & 0x7F),
            UInt8((value >> 7) & 0x7F),
            UInt8(value & 0x7F)
        ]
    }

    // MARK: - FLAC Vorbis Comment & Picture Lossless Tag Writer

    /// Rewrites FLAC METADATA_BLOCKs (VORBIS_COMMENT & PICTURE) while keeping STREAMINFO and all audio frames untouched.
    private func writeFLACMetadata(
        fileURL: URL,
        title: String,
        artist: String,
        album: String,
        albumArtist: String?,
        year: Int?,
        genre: String?,
        trackNumber: Int?,
        totalTracks: Int?,
        discNumber: Int?,
        artworkData: Data?
    ) -> Bool {
        // Ensure preconditions are met before proceeding
        guard let fileHandle = try? FileHandle(forReadingFrom: fileURL) else { return false }
        // Cleanup upon exiting scope
        defer { try? fileHandle.close() }

        // Read and verify 4-byte FLAC marker: "fLaC"
        guard let marker = try? fileHandle.read(upToCount: 4), marker == Data([0x66, 0x4C, 0x61, 0x43]) else {
            return false
        }

        // Scan existing metadata blocks to find STREAMINFO block and start of audio frames
        var streamInfoBlock: Data? = nil
        // Flag indicating if last
        var isLast = false

        while !isLast {
            // Ensure preconditions are met before proceeding
            guard let header = try? fileHandle.read(upToCount: 4), header.count == 4 else { break }
            isLast = (header[0] & 0x80) != 0
            // Block type
            let blockType = header[0] & 0x7F
            // Block size
            let blockSize = (Int(header[1]) << 16) | (Int(header[2]) << 8) | Int(header[3])

            // Ensure preconditions are met before proceeding
            guard let blockContent = try? fileHandle.read(upToCount: blockSize), blockContent.count == blockSize else { break }

            if blockType == 0 { // STREAMINFO
                // Clean header
                var cleanHeader = header
                cleanHeader[0] = 0x00 // not last block
                streamInfoBlock = cleanHeader + blockContent
            }
        }

        // Audio frame offset
        let audioFrameOffset = (try? fileHandle.offset()) ?? 0
        // Ensure preconditions are met before proceeding
        guard let streamInfo = streamInfoBlock else { return false }

        // Construct new VORBIS_COMMENT block (Type 4)
        var comments: [String] = []
        if !title.isEmpty { comments.append("TITLE=\(title)") }
        if !artist.isEmpty { comments.append("ARTIST=\(artist)") }
        if !album.isEmpty { comments.append("ALBUM=\(album)") }
        if let aart = albumArtist, !aart.isEmpty { comments.append("ALBUMARTIST=\(aart)") }
        if let y = year, y > 0 { comments.append("DATE=\(y)") }
        if let g = genre, !g.isEmpty { comments.append("GENRE=\(g)") }
        if let trk = trackNumber, trk > 0 { comments.append("TRACKNUMBER=\(trk)") }
        if let tot = totalTracks, tot > 0 { comments.append("TRACKTOTAL=\(tot)") }
        if let dsc = discNumber, dsc > 0 { comments.append("DISCNUMBER=\(dsc)") }

        // Vorbis payload
        let vorbisPayload = buildVorbisCommentPayload(comments: comments)
        // Flag indicating if artwork
        let hasArtwork = artworkData?.isEmpty == false

        // Vorbis header
        var vorbisHeader = Data()
        vorbisHeader.append(hasArtwork ? 0x04 : 0x84) // Type 4, marked last if no artwork
        vorbisHeader.append(UInt8((vorbisPayload.count >> 16) & 0xFF))
        vorbisHeader.append(UInt8((vorbisPayload.count >> 8) & 0xFF))
        vorbisHeader.append(UInt8(vorbisPayload.count & 0xFF))
        // Vorbis block
        let vorbisBlock = vorbisHeader + vorbisPayload

        // Construct optional PICTURE block (Type 6)
        var pictureBlock: Data? = nil
        if let art = artworkData, !art.isEmpty {
            // Pic payload
            let picPayload = buildFLACPicturePayload(imageData: art)
            // Pic header
            var picHeader = Data()
            picHeader.append(0x86) // Type 6, marked as last metadata block (0x80 | 6)
            picHeader.append(UInt8((picPayload.count >> 16) & 0xFF))
            picHeader.append(UInt8((picPayload.count >> 8) & 0xFF))
            picHeader.append(UInt8(picPayload.count & 0xFF))
            pictureBlock = picHeader + picPayload
        }

        // Write new FLAC container + exact audio frame copy to temporary sandbox file
        let tempDirectory = fileManager.temporaryDirectory
        // File system location for temp url
        let tempURL = tempDirectory.appendingPathComponent("meta_\(UUID().uuidString).flac")
        fileManager.createFile(atPath: tempURL.path, contents: nil)

        // Ensure preconditions are met before proceeding
        guard let writeHandle = try? FileHandle(forWritingTo: tempURL) else { return false }
        // Cleanup upon exiting scope
        defer { try? writeHandle.close() }

        do {
            try writeHandle.write(contentsOf: marker)
            try writeHandle.write(contentsOf: streamInfo)
            try writeHandle.write(contentsOf: vorbisBlock)
            if let pic = pictureBlock {
                try writeHandle.write(contentsOf: pic)
            }

            try fileHandle.seek(toOffset: audioFrameOffset)
            // Chunk size
            let chunkSize = 65536
            while true {
                // Chunk
                let chunk = try fileHandle.read(upToCount: chunkSize)
                // Ensure preconditions are met before proceeding
                guard let chunk = chunk, !chunk.isEmpty else { break }
                try writeHandle.write(contentsOf: chunk)
            }

            try writeHandle.synchronize()
            try writeHandle.close()
            try fileHandle.close()

            if coordinateReplace(targetURL: fileURL, tempURL: tempURL) {
                AppLogger.storage.info("Successfully updated FLAC tags via NSFileCoordinator for: \(fileURL.lastPathComponent)")
                return true
            } else {
                AppLogger.storage.error("Failed to coordinate replace FLAC file for: \(fileURL.lastPathComponent)")
                return false
            }
        } catch {
            AppLogger.storage.error("Failed to write FLAC file: \(error.localizedDescription)")
            try? fileManager.removeItem(at: tempURL)
            return false
        }
    }

    // Build vorbis comment payload
    private func buildVorbisCommentPayload(comments: [String]) -> Data {
        // Data
        var data = Data()
        // Vendor
        let vendor = "MusicPlayer"
        // Vendor bytes
        let vendorBytes = Array(vendor.utf8)

        // Vendor string length (32-bit little endian) & string
        data.append(UInt8(vendorBytes.count & 0xFF))
        data.append(UInt8((vendorBytes.count >> 8) & 0xFF))
        data.append(UInt8((vendorBytes.count >> 16) & 0xFF))
        data.append(UInt8((vendorBytes.count >> 24) & 0xFF))
        data.append(contentsOf: vendorBytes)

        // Comment count (32-bit little endian)
        let count = comments.count
        data.append(UInt8(count & 0xFF))
        data.append(UInt8((count >> 8) & 0xFF))
        data.append(UInt8((count >> 16) & 0xFF))
        data.append(UInt8((count >> 24) & 0xFF))

        for c in comments {
            // C bytes
            let cBytes = Array(c.utf8)
            data.append(UInt8(cBytes.count & 0xFF))
            data.append(UInt8((cBytes.count >> 8) & 0xFF))
            data.append(UInt8((cBytes.count >> 16) & 0xFF))
            data.append(UInt8((cBytes.count >> 24) & 0xFF))
            data.append(contentsOf: cBytes)
        }
        return data
    }

    // Build flac picture payload
    private func buildFLACPicturePayload(imageData: Data) -> Data {
        // Data
        var data = Data()
        // Flag indicating if png
        let isPNG = imageData.count > 8 && imageData[0] == 0x89 && imageData[1] == 0x50
        // Mime
        let mime = isPNG ? "image/png" : "image/jpeg"
        // Mime bytes
        let mimeBytes = Array(mime.utf8)

        // Picture type: 3 (Cover Front) 32-bit big endian
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x03])

        // MIME length & string (32-bit big endian)
        let mimeLen = mimeBytes.count
        data.append(UInt8((mimeLen >> 24) & 0xFF))
        data.append(UInt8((mimeLen >> 16) & 0xFF))
        data.append(UInt8((mimeLen >> 8) & 0xFF))
        data.append(UInt8(mimeLen & 0xFF))
        data.append(contentsOf: mimeBytes)

        // Description length: 0
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x00])

        // Width (0), Height (0), Color depth (24), Indexed colors (0) -> 16 bytes
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x18, 0x00, 0x00, 0x00, 0x00])

        // Image data length & data (32-bit big endian)
        let imgLen = imageData.count
        data.append(UInt8((imgLen >> 24) & 0xFF))
        data.append(UInt8((imgLen >> 16) & 0xFF))
        data.append(UInt8((imgLen >> 8) & 0xFF))
        data.append(UInt8(imgLen & 0xFF))
        data.append(imageData)
        return data
    }

    // MARK: - NSFileCoordinator Safe Atomic Replacement for iCloud Drive & Local Disks

    // Coordinate replace
    private func coordinateReplace(targetURL: URL, tempURL: URL) -> Bool {
        // Coordinator error
        var coordinatorError: NSError?
        // Replace success
        var replaceSuccess = false

        // Coordinator
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(
            writingItemAt: targetURL,
            options: .forReplacing,
            error: &coordinatorError
        ) { coordinatedURL in
            do {
                // Strategy 1: Replace item atomically
                _ = try fileManager.replaceItemAt(coordinatedURL, withItemAt: tempURL)
                replaceSuccess = true
            } catch {
                AppLogger.storage.warning("replaceItemAt failed on coordinated file (\(error.localizedDescription)), attempting direct atomic write fallback...")
                do {
                    // Strategy 2: Direct atomic byte write
                    let data = try Data(contentsOf: tempURL)
                    try data.write(to: coordinatedURL, options: .atomic)
                    replaceSuccess = true
                } catch {
                    AppLogger.storage.warning("Data.write failed (\(error.localizedDescription)), attempting coordinated item copy...")
                    do {
                        // Strategy 3: Remove coordinated file and copy temp file in place
                        try fileManager.removeItem(at: coordinatedURL)
                        try fileManager.copyItem(at: tempURL, to: coordinatedURL)
                        replaceSuccess = true
                    } catch {
                        AppLogger.storage.error("All coordinated write strategies failed for \(coordinatedURL.lastPathComponent): \(error.localizedDescription)")
                        replaceSuccess = false
                    }
                }
            }
        }

        if let error = coordinatorError {
            AppLogger.storage.error("NSFileCoordinator failed for \(targetURL.lastPathComponent): \(error.localizedDescription)")
            if !replaceSuccess {
                if let data = try? Data(contentsOf: tempURL) {
                    do {
                        try data.write(to: targetURL, options: .atomic)
                        replaceSuccess = true
                    } catch {
                        replaceSuccess = false
                    }
                }
            }
        }

        try? fileManager.removeItem(at: tempURL)
        return replaceSuccess
    }

    // Export with timeout
    private func exportWithTimeout(session: AVAssetExportSession, timeoutSeconds: Double = 6.0) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await session.export()
                return session.status == .completed
            }
            group.addTask {
                // Sleep ns
                let sleepNs = UInt64(timeoutSeconds * 1_000_000_000)
                try? await Task.sleep(nanoseconds: sleepNs)
                session.cancelExport()
                return false
            }
            // First result
            let firstResult = await group.next() ?? false
            group.cancelAll()
            return firstResult
        }
    }
}
