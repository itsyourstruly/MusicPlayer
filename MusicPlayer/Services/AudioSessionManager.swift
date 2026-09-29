// Services/AudioSessionManager.swift
import Foundation
import AVFoundation
import os

/// Thread-safe, single-point manager for AVAudioSession lifecycle.
/// Prevents concurrent or redundant session activation storms, especially during
/// Bluetooth A2DP / car stereo AVRCP handshakes.
public final class AudioSessionManager: @unchecked Sendable {
    public static let shared = AudioSessionManager()
    
    private var isSessionActive = false
    private var isSessionConfigured = false
    private var currentActivationTask: Task<Bool, Never>?
    private var unfairLock = os_unfair_lock()
    
    private init() {}
    
    /// Returns whether the audio session is currently activated.
    public var isActive: Bool {
        os_unfair_lock_lock(&unfairLock)
        defer { os_unfair_lock_unlock(&unfairLock) }
        return isSessionActive
    }
    
    /// Activates and configures the audio session if not already active.
    /// If activation is already in progress, deduplicates and awaits the active task.
    @discardableResult
    public func activateSessionIfNeeded(force: Bool = false) async -> Bool {
        os_unfair_lock_lock(&unfairLock)
        if !force && isSessionActive {
            os_unfair_lock_unlock(&unfairLock)
            return true
        }
        if let existingTask = currentActivationTask {
            os_unfair_lock_unlock(&unfairLock)
            return await existingTask.value
        }
        
        let task = Task.detached(priority: .userInitiated) { () -> Bool in
            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            var succeeded = false
            do {
                try session.setCategory(.playback, mode: .default, policy: .longFormAudio, options: [])
                try session.setActive(true)
                succeeded = true
            } catch {
                AppLogger.audio.info("longFormAudio policy not accepted, falling back to standard playback category: \(error.localizedDescription)")
                do {
                    try session.setCategory(.playback, mode: .default, options: [])
                    try session.setActive(true)
                    succeeded = true
                } catch {
                    AppLogger.audio.warning("Could not activate AVAudioSession: \(error.localizedDescription)")
                    succeeded = false
                }
            }
            return succeeded
            #else
            return true
            #endif
        }
        
        currentActivationTask = task
        os_unfair_lock_unlock(&unfairLock)
        
        let result = await task.value
        
        os_unfair_lock_lock(&unfairLock)
        currentActivationTask = nil
        if result {
            let wasActive = isSessionActive
            isSessionActive = true
            isSessionConfigured = true
            if !wasActive {
                AppLogger.audio.info("AVAudioSession successfully configured and activated.")
            }
        }
        os_unfair_lock_unlock(&unfairLock)
        
        return result
    }
    
    /// Called when an audio interruption begins (e.g. phone call, Siri, alarm).
    public func notifyInterruptionBegan() {
        os_unfair_lock_lock(&unfairLock)
        isSessionActive = false
        os_unfair_lock_unlock(&unfairLock)
        AppLogger.audio.info("AVAudioSession interruption began.")
    }
    
    /// Called when an audio interruption ends.
    @discardableResult
    public func notifyInterruptionEnded(shouldResume: Bool) async -> Bool {
        AppLogger.audio.info("AVAudioSession interruption ended (shouldResume: \(shouldResume)).")
        if shouldResume {
            return await activateSessionIfNeeded(force: true)
        }
        return false
    }
    
    /// Called when OS media services are reset.
    public func notifyMediaServicesWereReset() {
        os_unfair_lock_lock(&unfairLock)
        isSessionActive = false
        isSessionConfigured = false
        currentActivationTask?.cancel()
        currentActivationTask = nil
        os_unfair_lock_unlock(&unfairLock)
        AppLogger.audio.warning("AVAudioSession media services were reset.")
    }
    
    /// Deactivates the audio session when playback has completely stopped.
    public func deactivateSession() {
        #if os(iOS)
        os_unfair_lock_lock(&unfairLock)
        guard isSessionActive else {
            os_unfair_lock_unlock(&unfairLock)
            return
        }
        isSessionActive = false
        os_unfair_lock_unlock(&unfairLock)
        
        Task.detached(priority: .utility) {
            do {
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                AppLogger.audio.info("AVAudioSession deactivated cleanly.")
            } catch {
                AppLogger.audio.warning("AVAudioSession deactivation: \(error.localizedDescription)")
            }
        }
        #endif
    }
}
