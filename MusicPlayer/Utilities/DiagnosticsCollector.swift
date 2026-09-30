import Foundation
import AVFoundation
#if os(iOS)
import UIKit
import AVFAudio
#elseif os(macOS)
import AppKit
import CoreAudio
#endif

/// Comprehensive system, hardware, and audio pipeline diagnostic engine.
/// Collects and structures exhaustive runtime diagnostics for troubleshooting all app components,
/// including Bluetooth car stereos, AVAudioSession route transitions, AVPlayer CoreMedia errors,
/// DSP format negotiation, memory consumption, and security-scoped file access.
public enum DiagnosticsCollector {

    // MARK: - Full Comprehensive Diagnostic Report

    /// Generates a complete, multi-section text breakdown of the entire application state.
    @MainActor
    public static func generateDiagnosticBreakdown(
        playerService: AudioPlayerService? = nil
    ) -> String {
        var report = "================================================================================\n"
        report += "               LAC MUSIC PLAYER - COMPREHENSIVE DIAGNOSTIC REPORT               \n"
        report += "================================================================================\n"
        report += "Generated: \(LogEntry.fullFormatter.string(from: Date()))\n"
        report += "Process ID: \(ProcessInfo.processInfo.processIdentifier)\n"
        report += "Process Name: \(ProcessInfo.processInfo.processName)\n\n"

        // Section 1: Device & Host Environment
        report += "--------------------------------------------------------------------------------\n"
        report += "[1] HOST DEVICE & OS ENVIRONMENT\n"
        report += "--------------------------------------------------------------------------------\n"
        report += deviceEnvironmentDetails()
        report += "\n"

        // Section 2: Audio Session & Hardware Route (iOS)
        report += "--------------------------------------------------------------------------------\n"
        report += "[2] AVAUDIOSESSION HARDWARE & ROUTE STATE\n"
        report += "--------------------------------------------------------------------------------\n"
        report += audioSessionDetails()
        report += "\n"

        // Section 3: Audio Pipeline & Player Diagnostics
        report += "--------------------------------------------------------------------------------\n"
        report += "[3] AUDIO ENGINE & PLAYBACK PIPELINE\n"
        report += "--------------------------------------------------------------------------------\n"
        let activePlayer = playerService ?? AudioPlayerService.shared
        report += audioPlayerPipelineDetails(player: activePlayer)
        report += "\n"

        // Section 4: DSP & Equalizer State
        report += "--------------------------------------------------------------------------------\n"
        report += "[4] REAL-TIME AUDIO DSP & TAP PROCESSOR\n"
        report += "--------------------------------------------------------------------------------\n"
        report += audioDSPDetails()
        report += "\n"

        // Section 5: Audio Session Manager State
        report += "--------------------------------------------------------------------------------\n"
        report += "[5] AUDIO SESSION SERIALIZER & DEDUPLICATION\n"
        report += "--------------------------------------------------------------------------------\n"
        report += "Session Active: \(AudioSessionManager.shared.isActive ? "YES" : "NO")\n\n"

        // Section 6: Storage & Directory Permissions
        report += "--------------------------------------------------------------------------------\n"
        report += "[6] FILE SYSTEM & SECURITY-SCOPED STORAGE\n"
        report += "--------------------------------------------------------------------------------\n"
        report += storageDetails()
        report += "\n"

        report += "================================================================================\n"
        report += "                         END OF DIAGNOSTIC BREAKDOWN                            \n"
        report += "================================================================================\n\n"

        return report
    }

    // MARK: - Section 1: Device & OS Environment

    private static func deviceEnvironmentDetails() -> String {
        var text = ""
        #if os(iOS)
        let device = UIDevice.current
        text += "Device Name: \(device.name)\n"
        text += "Device Model: \(device.model) (\(deviceModelIdentifier()))\n"
        text += "System OS: \(device.systemName) \(device.systemVersion)\n"

        device.isBatteryMonitoringEnabled = true
        let batteryPct = device.batteryLevel >= 0 ? "\(Int(device.batteryLevel * 100))%" : "Unavailable"
        text += "Battery Level: \(batteryPct)\n"
        text += "Battery State: \(batteryStateString(device.batteryState))\n"
        #elseif os(macOS)
        text += "Platform: macOS\n"
        text += "System OS: \(ProcessInfo.processInfo.operatingSystemVersionString)\n"
        #endif

        let proc = ProcessInfo.processInfo
        text += "Active Processor Cores: \(proc.activeProcessorCount)\n"
        text += "Physical RAM: \(ByteFormatting.formatBytes(Int64(proc.physicalMemory)))\n"
        text += "App Resident Memory: \(ByteFormatting.formatBytes(residentMemoryFootprint()))\n"
        text += "Thermal State: \(thermalStateString(proc.thermalState))\n"
        text += "Low Power Mode: \(proc.isLowPowerModeEnabled ? "ACTIVE" : "INACTIVE")\n"

        if let diskFree = availableDiskSpace() {
            text += "Device Free Disk Space: \(ByteFormatting.formatBytes(diskFree))\n"
        }

        return text
    }

    // MARK: - Section 2: Audio Session & Route

    private static func audioSessionDetails() -> String {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        var text = ""
        text += "Category: \(session.category.rawValue)\n"
        text += "Category Options: [\(audioCategoryOptionsString(session.categoryOptions))]\n"
        text += "Mode: \(session.mode.rawValue)\n"
        text += "Route Sharing Policy: \(routeSharingPolicyString(session.routeSharingPolicy))\n"
        text += "Hardware Sample Rate: \(String(format: "%.1f Hz", session.sampleRate))\n"
        text += "Preferred Sample Rate: \(String(format: "%.1f Hz", session.preferredSampleRate))\n"
        text += "IO Buffer Duration: \(String(format: "%.4f s (%.2f ms)", session.ioBufferDuration, session.ioBufferDuration * 1000.0))\n"
        text += "Preferred IO Buffer: \(String(format: "%.4f s (%.2f ms)", session.preferredIOBufferDuration, session.preferredIOBufferDuration * 1000.0))\n"
        text += "Output Latency: \(String(format: "%.4f s (%.2f ms)", session.outputLatency, session.outputLatency * 1000.0))\n"
        text += "Input Latency: \(String(format: "%.4f s (%.2f ms)", session.inputLatency, session.inputLatency * 1000.0))\n"
        text += "Output Channel Count: \(session.outputNumberOfChannels) (Max Hardware: \(session.maximumOutputNumberOfChannels))\n"
        text += "Other Audio Playing: \(session.isOtherAudioPlaying ? "YES" : "NO")\n"
        text += "Secondary Audio Silence Hint: \(session.secondaryAudioShouldBeSilencedHint ? "YES" : "NO")\n\n"

        let route = session.currentRoute
        text += "Current Output Ports (\(route.outputs.count)):\n"
        if route.outputs.isEmpty {
            text += "  [None detected]\n"
        } else {
            for (idx, out) in route.outputs.enumerated() {
                text += "  [\(idx + 1)] Port: \"\(out.portName)\"\n"
                text += "      Type: \(out.portType.rawValue)\n"
                text += "      UID: \(out.uid)\n"
                if let channels = out.channels, !channels.isEmpty {
                    let chDesc = channels.map { "\($0.channelName) (#\($0.channelNumber))" }.joined(separator: ", ")
                    text += "      Channels (\(channels.count)): \(chDesc)\n"
                }
                if let ds = out.selectedDataSource {
                    text += "      Data Source: \(ds.dataSourceName)\n"
                }

                // Bluetooth profile diagnostics
                if out.portType == .bluetoothA2DP {
                    text += "      >> Route Profile: Bluetooth A2DP (Advanced Audio Distribution - High Fidelity Stereo)\n"
                } else if out.portType == .bluetoothHFP {
                    text += "      >> Route Profile: Bluetooth HFP/SCO (Hands-Free Profile - Low Bitrate Voice/Telephony)\n"
                } else if out.portType == .carAudio {
                    text += "      >> Route Profile: Apple CarPlay / Direct Automotive Audio Link\n"
                } else if out.portType == .builtInSpeaker {
                    text += "      >> Route Profile: Integrated Device Speaker\n"
                } else if out.portType == .airPlay {
                    text += "      >> Route Profile: AirPlay Wireless Stream\n"
                }
            }
        }

        text += "Current Input Ports (\(route.inputs.count)):\n"
        if route.inputs.isEmpty {
            text += "  [None detected]\n"
        } else {
            for (idx, inp) in route.inputs.enumerated() {
                text += "  [\(idx + 1)] Port: \"\(inp.portName)\" | Type: \(inp.portType.rawValue) | UID: \(inp.uid)\n"
            }
        }

        return text
        #else
        return "AVAudioSession is not applicable on macOS (CoreAudio HAL active).\n"
        #endif
    }

    // MARK: - Section 3: Audio Player Pipeline Details

    @MainActor
    private static func audioPlayerPipelineDetails(player: AudioPlayerService?) -> String {
        guard let player else {
            return "AudioPlayerService instance is currently inactive or uninitialized.\n"
        }

        var text = ""
        text += "Playback State: \(player.playbackStatus.label)\n"
        text += "Playback Position: \(String(format: "%.2f s / %.2f s", player.currentTime, player.duration))\n"
        text += "Volume: \(String(format: "%.2f", player.volume)) (Muted: \(player.isMuted ? "YES" : "NO"))\n"
        text += "Active Route: \"\(player.currentAudioRouteName)\" (External: \(player.isExternalAudioRouteActive ? "YES" : "NO"))\n"
        text += "Queue Items: \(player.queue.count) (Active Index: \(player.currentIndex.map(String.init) ?? "nil"))\n"
        text += "Play Next Items: \(player.playNextQueue.count)\n"
        text += "Shuffle: \(player.shuffleMode.rawValue.uppercased()) | Repeat: \(player.repeatMode.rawValue.uppercased())\n"
        text += "Crossfade: \(player.isCrossfadeEnabled ? "ENABLED (\(player.crossfadeDuration)s)" : "DISABLED")\n"
        text += "Smooth Skipping: \(player.smoothSkippingEnabled ? "ENABLED" : "DISABLED")\n\n"

        // Track Information
        if let track = player.currentTrack {
            text += "Active Track Metadata:\n"
            text += "  Title: \"\(track.title)\"\n"
            text += "  Artist: \"\(track.artist)\"\n"
            text += "  Album: \"\(track.album)\"\n"
            text += "  Duration: \(String(format: "%.2f s", track.duration))\n"
            let fileSize = track.fileInfo?.fileSizeBytes ?? (try? FileManager.default.attributesOfItem(atPath: track.url.path)[.size] as? Int64)
            if let fileSize {
                text += "  File Size: \(ByteFormatting.formatBytes(fileSize))\n"
            }
            let url = track.url
            text += "  File Path: \(url.path)\n"
            text += "  File Extension: .\(url.pathExtension.uppercased())\n"
            text += "  Disk Reachable: \(FileManager.default.fileExists(atPath: url.path) ? "YES" : "NO")\n"
        } else {
            text += "Active Track: [None loaded in playback pipeline]\n"
        }
        text += "\n"

        // Detailed AVPlayer Diagnostics
        let diags = player.playerDiagnostics()
        text += "AVFoundation Engine Diagnostics:\n"
        for key in diags.keys.sorted() {
            text += "  \(key): \(diags[key] ?? "")\n"
        }

        return text
    }

    // MARK: - Section 4: Audio DSP & Tap

    private static func audioDSPDetails() -> String {
        var text = ""
        let isEQ = EqualizerManager.shared.isEqualizerEnabled
        text += "Equalizer Active: \(isEQ ? "YES" : "NO")\n"
        text += "Volume Booster Gain: \(String(format: "%.1f dB", EqualizerManager.shared.volumeBoosterDB))\n"
        text += "Limiter / Dynamic Floor: Real-time linked true-peak lookahead limiter active\n"

        text += "10-Band Gains (dB):\n"
        let bands = EqualizerManager.shared.bands
        var bandStrings: [String] = []
        for band in bands {
            bandStrings.append("\(band.displayLabel)Hz: \(String(format: "%+.1f", band.gainDB))dB")
        }
        text += "  " + bandStrings.joined(separator: " | ") + "\n"

        return text
    }

    // MARK: - Section 5: Storage Details

    private static func storageDetails() -> String {
        var text = ""
        if let folderURL = SecurityScopedBookmark.shared.currentFolderURL {
            text += "Linked Music Folder: \(folderURL.path)\n"
            let exists = FileManager.default.fileExists(atPath: folderURL.path)
            let readable = FileManager.default.isReadableFile(atPath: folderURL.path)
            text += "Directory Exists: \(exists ? "YES" : "NO")\n"
            text += "Directory Readable: \(readable ? "YES" : "NO")\n"
        } else {
            text += "Linked Music Folder: [No folder currently linked]\n"
        }

        return text
    }

    // MARK: - Private Helpers

    #if os(iOS)
    private static func batteryStateString(_ state: UIDevice.BatteryState) -> String {
        switch state {
        case .unknown: return "UNKNOWN"
        case .unplugged: return "UNPLUGGED (ON BATTERY)"
        case .charging: return "CHARGING"
        case .full: return "CHARGED (FULL)"
        @unknown default: return "UNKNOWN"
        }
    }

    private static func audioCategoryOptionsString(_ options: AVAudioSession.CategoryOptions) -> String {
        var parts: [String] = []
        if options.contains(.mixWithOthers) { parts.append("mixWithOthers") }
        if options.contains(.duckOthers) { parts.append("duckOthers") }
        if options.contains(.allowBluetoothHFP) { parts.append("allowBluetoothHFP") }
        if options.contains(.defaultToSpeaker) { parts.append("defaultToSpeaker") }
        if options.contains(.interruptSpokenAudioAndMixWithOthers) { parts.append("interruptSpokenAudio") }
        if options.contains(.allowBluetoothA2DP) { parts.append("allowBluetoothA2DP") }
        if options.contains(.allowAirPlay) { parts.append("allowAirPlay") }
        return parts.isEmpty ? "default" : parts.joined(separator: ", ")
    }

    private static func routeSharingPolicyString(_ policy: AVAudioSession.RouteSharingPolicy) -> String {
        switch policy {
        case .default: return "default"
        case .longFormAudio: return "longFormAudio"
        case .longFormVideo: return "longFormVideo"
        case .independent: return "independent"
        @unknown default: return "unknown"
        }
    }

    private static func deviceModelIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machineMirror = Mirror(reflecting: systemInfo.machine)
        let identifier = machineMirror.children.reduce("") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else { return identifier }
            return identifier + String(UnicodeScalar(UInt8(value)))
        }
        return identifier.isEmpty ? "Unknown" : identifier
    }
    #endif

    private static func thermalStateString(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "NOMINAL (NORMAL)"
        case .fair: return "FAIR (ELEVATED)"
        case .serious: return "SERIOUS (HIGH LOAD)"
        case .critical: return "CRITICAL (THERMAL THROTTLING)"
        @unknown default: return "UNKNOWN"
        }
    }

    private static func residentMemoryFootprint() -> Int64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / 4)
        let kerr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        if kerr == KERN_SUCCESS {
            return Int64(info.resident_size)
        }
        return 0
    }

    private static func availableDiskSpace() -> Int64? {
        do {
            let values = try URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
            if let important = values.volumeAvailableCapacityForImportantUsage {
                return important
            }
            if let regular = values.volumeAvailableCapacity {
                return Int64(regular)
            }
        } catch {
            // Ignore error
        }
        return nil
    }
}
