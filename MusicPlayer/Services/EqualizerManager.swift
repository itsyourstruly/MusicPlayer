import Foundation
import SwiftUI
import Observation
import os

/// Global equalizer state coordinator managing 10-band line graph settings, volume boost, playback speed,
/// global defaults, per-track equalizer presets, and built-in acoustic sound curves.
@Observable
@MainActor
public final class EqualizerManager {
    public static let shared = EqualizerManager()

    // MARK: - State Properties

    /// Whether the 10-band equalizer processing is enabled.
    public var isEqualizerEnabled: Bool = false {
        didSet {
            notifyAudioEngine()
        }
    }

    /// Volume Booster in decibels (-8.0 dB to +15.0 dB, step 0.5 dB).
    public var volumeBoosterDB: Double = 0.0 {
        didSet {
            let clamped = min(15.0, max(-8.0, volumeBoosterDB))
            let rounded = (clamped * 2.0).rounded() / 2.0
            if volumeBoosterDB != rounded {
                volumeBoosterDB = rounded
            }
            notifyAudioEngine()
        }
    }

    /// Playback rate (0.25x to 2.0x, step 0.25x). Resets to 1.0x on app relaunch.
    public var playbackSpeed: Double = 1.0 {
        didSet {
            let clamped = min(2.0, max(0.25, playbackSpeed))
            let rounded = (clamped * 4.0).rounded() / 4.0
            if playbackSpeed != rounded {
                playbackSpeed = rounded
            }
            notifyAudioEngine()
        }
    }

    /// 10 interactive frequency bands.
    public var bands: [EqualizerBand] = EqualizerBand.standard10Bands {
        didSet {
            isGlobalDefaultActive = checkIfMatchesGlobalDefault()
            notifyAudioEngine()
        }
    }

    /// Whether the current equalizer configuration matches the stored Global Default.
    public var isGlobalDefaultActive: Bool = false

    /// Per-track custom equalizer mappings: [TrackID : [10 gain values]].
    public private(set) var perTrackEQMap: [String: [Double]] = [:]

    // Keys for persistent storage
    private let globalDefaultKey = "audio_eq_global_default_v1"
    private let perTrackEQKey = "audio_eq_per_track_map_v1"
    private let isEQEnabledKey = "audio_eq_is_enabled_v1"
    private let volumeBoostKey = "audio_eq_volume_boost_v1"

    /// Weak reference to AudioPlayerService for dynamic rate changes
    public weak var playerService: AudioPlayerService?

    private init() {
        loadPersistedState()
        notifyAudioEngine()
    }

    // MARK: - Gain & Band Mutation

    /// Sets gain for a specific frequency band index.
    public func setGain(bandIndex: Int, gainDB: Double) {
        guard bands.indices.contains(bandIndex) else { return }
        let clamped = min(12.0, max(-12.0, gainDB))
        let rounded = (clamped * 2.0).rounded() / 2.0
        bands[bandIndex].gainDB = rounded
    }

    /// Applies a built-in equalizer preset.
    public func applyPreset(_ preset: EqualizerPreset) {
        guard preset.gains.count == bands.count else { return }
        for i in 0..<bands.count {
            bands[i].gainDB = preset.gains[i]
        }
        isEqualizerEnabled = true
    }

    // MARK: - Global Default Management

    /// Saves the currently configured equalizer as the global default for all future sessions.
    public func setGlobalDefault() {
        let currentGains = bands.map { $0.gainDB }
        UserDefaults.standard.set(currentGains, forKey: globalDefaultKey)
        isGlobalDefaultActive = true
        AppLogger.audio.info("Saved equalizer as global default: \(currentGains)")
    }

    /// Checks if current bands match stored global default.
    private func checkIfMatchesGlobalDefault() -> Bool {
        guard let saved = UserDefaults.standard.array(forKey: globalDefaultKey) as? [Double],
              saved.count == bands.count else { return false }
        for i in 0..<bands.count {
            if abs(bands[i].gainDB - saved[i]) > 0.01 {
                return false
            }
        }
        return true
    }

    // MARK: - Per-Track Custom Equalizer

    /// Checks if a custom equalizer is saved for a specific track.
    public func isCustomEQSaved(for trackID: UUID) -> Bool {
        perTrackEQMap[trackID.uuidString] != nil
    }

    /// Sets or toggles custom equalizer for a specific track.
    public func setCustomEQForTrack(trackID: UUID) {
        let currentGains = bands.map { $0.gainDB }
        perTrackEQMap[trackID.uuidString] = currentGains
        savePerTrackEQ()
        AppLogger.audio.info("Saved custom equalizer for track \(trackID.uuidString)")
    }

    /// Removes custom equalizer for a specific track.
    public func removeCustomEQForTrack(trackID: UUID) {
        perTrackEQMap.removeValue(forKey: trackID.uuidString)
        savePerTrackEQ()
    }

    /// Automatically invoked when a new track begins playing.
    public func trackWillPlay(track: Track) {
        if let customGains = perTrackEQMap[track.id.uuidString], customGains.count == bands.count {
            for i in 0..<bands.count {
                bands[i].gainDB = customGains[i]
            }
            isEqualizerEnabled = true
            AppLogger.audio.info("Loaded custom equalizer curve for track: \(track.title)")
        } else if let globalGains = UserDefaults.standard.array(forKey: globalDefaultKey) as? [Double], globalGains.count == bands.count {
            for i in 0..<bands.count {
                bands[i].gainDB = globalGains[i]
            }
            isGlobalDefaultActive = true
        }
        notifyAudioEngine()
    }

    // MARK: - Persistence Helpers

    private func loadPersistedState() {
        if let savedMap = UserDefaults.standard.dictionary(forKey: perTrackEQKey) as? [String: [Double]] {
            self.perTrackEQMap = savedMap
        }
        if UserDefaults.standard.object(forKey: isEQEnabledKey) != nil {
            self.isEqualizerEnabled = UserDefaults.standard.bool(forKey: isEQEnabledKey)
        }
        if UserDefaults.standard.object(forKey: volumeBoostKey) != nil {
            self.volumeBoosterDB = UserDefaults.standard.double(forKey: volumeBoostKey)
        }
        if let globalGains = UserDefaults.standard.array(forKey: globalDefaultKey) as? [Double], globalGains.count == bands.count {
            for i in 0..<bands.count {
                bands[i].gainDB = globalGains[i]
            }
            self.isGlobalDefaultActive = true
        }
    }

    private func savePerTrackEQ() {
        UserDefaults.standard.set(perTrackEQMap, forKey: perTrackEQKey)
    }

    private func notifyAudioEngine() {
        // Save persistable flags
        UserDefaults.standard.set(isEqualizerEnabled, forKey: isEQEnabledKey)
        UserDefaults.standard.set(volumeBoosterDB, forKey: volumeBoostKey)

        // Real-time DSP update for 10-band EQ and volume booster
        AudioDSPProcessor.shared.update(
            isEQEnabled: isEqualizerEnabled,
            volumeBoosterDB: volumeBoosterDB,
            bandGains: bands.map { $0.gainDB }
        )

        // Dynamically attach or detach audio processing tap on active track
        playerService?.updateAudioMixForCurrentItem()

        // Playback speed dynamic update
        playerService?.applyPlaybackSpeed(playbackSpeed)
    }
}
