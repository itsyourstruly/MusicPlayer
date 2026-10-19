import Foundation

/// Single source of truth for "can AVPlayer play this server file as-is?".
/// Native formats are always streamed/downloaded as the original file. Everything else is transcoded
/// server-side to AAC 320 kbps in MP4/M4A and fully pre-fetched to disk before playback, so seeking,
/// EQ, pitch and crossfade behave exactly like local files.
nonisolated public enum TranscodePolicy {
    /// Containers AVFoundation decodes natively.
    public static let nativeExtensions: Set<String> = [
        "mp3", "m4a", "m4b", "m4p", "mp4", "mov", "aac", "adts", "alac", "flac",
        "wav", "wave", "aif", "aiff", "aifc", "caf"
    ]
    /// Codecs AVFoundation decodes natively (used when only a demuxer list is known).
    private static let nativeCodecs: Set<String> = ["mp3", "aac", "alac", "flac"]

    public static let transcodeBitRate = 320_000
    public static let transcodedFileExtension = "m4a"

    /// Returns true when the server must transcode this track for AVPlayer.
    public static func requiresTranscode(_ track: Track) -> Bool {
        let rawExt = (track.fileInfo?.fileExtension ?? track.url.pathExtension).lowercased()
        // Legacy Jellyfin entries stored demuxer lists ("mov,mp4,m4a,...") as the extension: decide by codec.
        if rawExt.contains(",") {
            let codec = (track.fileInfo?.formatDescription ?? "").lowercased()
            return !(nativeCodecs.contains(codec) || codec.hasPrefix("pcm"))
        }
        guard !rawExt.isEmpty else { return false }
        return !nativeExtensions.contains(rawExt)
    }
}
