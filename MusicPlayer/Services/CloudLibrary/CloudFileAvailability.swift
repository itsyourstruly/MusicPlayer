import Foundation
import Darwin

/// Classification of audio file availability for local versus iCloud storage.
public enum CloudAvailabilityStatus: String, Sendable, Codable {
    case local
    case cloudOnly
    case downloading
}

/// Helper classifying files as local, cloud-only, or downloading without reading or downloading the file.
public enum CloudFileAvailability: Sendable {

    /// Classifies an audio file URL into its cloud availability status.
    public static func status(for url: URL) -> CloudAvailabilityStatus {
        let filename = url.lastPathComponent
        // Legacy iCloud stubs: .Name.ext.icloud or files ending in .icloud
        if filename.hasSuffix(".icloud") || (filename.hasPrefix(".") && url.pathExtension.lowercased() == "icloud") {
            return .cloudOnly
        }

        // Check URL resource values
        if let values = try? url.resourceValues(forKeys: [
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
            .ubiquitousItemIsDownloadingKey
        ]) {
            if values.isUbiquitousItem == true {
                if values.ubiquitousItemIsDownloading == true {
                    return .downloading
                }
                if let status = values.ubiquitousItemDownloadingStatus {
                    if status == .current || status == .downloaded {
                        return .local
                    } else if status == .notDownloaded {
                        return .cloudOnly
                    }
                }
            }
        }

        // Non-ubiquitous files: test filesystem dataless flag (SF_DATALESS) for third-party cloud providers
        var st = stat()
        if lstat(url.path, &st) == 0 {
            let flags = UInt32(st.st_flags)
            let datalessFlag: UInt32 = 0x40000000 // SF_DATALESS
            if (flags & datalessFlag) != 0 {
                return .cloudOnly
            }
        }

        return .local
    }

    /// Returns true if the file is confirmed local and can be read immediately without blocking on a cloud download.
    public static func isLocal(url: URL) -> Bool {
        guard url.isFileURL else { return false }
        if url.scheme == "jellyfin" || url.scheme == "http" || url.scheme == "https" {
            return false
        }
        // Build a fresh URL and remove cached values to ensure we don't read stale cached resource keys
        var freshURL = URL(fileURLWithPath: url.path)
        freshURL.removeAllCachedResourceValues()
        return status(for: freshURL) == .local
    }

    /// Retrieves current download progress (0.0 to 1.0) if downloading.
    public static func downloadProgress(for url: URL) -> Double? {
        #if os(macOS)
        guard url.isFileURL else { return nil }
        var freshURL = URL(fileURLWithPath: url.path)
        freshURL.removeAllCachedResourceValues()
        if let values = try? freshURL.resourceValues(forKeys: [.ubiquitousItemPercentDownloadedKey]),
           let pct = values.ubiquitousItemPercentDownloaded {
            return pct / 100.0
        }
        #endif
        return nil
    }

    /// Returns true if the file is located in iCloud Drive or recognized as a ubiquitous cloud file.
    public static func isCloudItem(url: URL) -> Bool {
        guard url.isFileURL else { return false }
        if url.scheme == "jellyfin" || url.scheme == "http" || url.scheme == "https" { return false }
        let filename = url.lastPathComponent
        if filename.hasSuffix(".icloud") || (filename.hasPrefix(".") && url.pathExtension.lowercased() == "icloud") {
            return true
        }
        if let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey]), values.isUbiquitousItem == true {
            return true
        }
        let path = url.path
        if path.contains("com~apple~CloudDocs") || path.contains("Mobile Documents") {
            return true
        }
        return false
    }

    /// Returns true if the file is an iCloud file that is currently fully downloaded on disk.
    public static func isCloudDownloaded(url: URL) -> Bool {
        guard isCloudItem(url: url) else { return false }
        return isLocal(url: url)
    }
}
