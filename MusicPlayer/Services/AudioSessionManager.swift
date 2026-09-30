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
    private let lock = NSLock()
    
    private init() {}
    
    /// Returns whether the audio session is currently activated.
    public var isActive: Bool {
        lock.withLock { isSessionActive }
    }
    
    /// Activates and configures the audio session if not already active.
    /// If activation is already in progress, deduplicates and awaits the active task.
    @discardableResult
    public func activateSessionIfNeeded(force: Bool = false) async -> Bool {
        let (shouldProceed, existingTask) = lock.withLock { () -> (Bool, Task<Bool, Never>?) in
            if !force && isSessionActive {
                return (false, nil)
            }
            if let task = currentActivationTask {
                return (false, task)
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
            return (true, task)
        }
        
        if !shouldProceed {
            if let existingTask = existingTask {
                return await existingTask.value
            }
            return true
        }
        
        guard let task = existingTask else { return false }
        let result = await task.value
        
        lock.withLock {
            currentActivationTask = nil
            if result {
                let wasActive = isSessionActive
                isSessionActive = true
                isSessionConfigured = true
                if !wasActive {
                    AppLogger.audio.info("AVAudioSession successfully configured and activated.")
                }
            }
        }
        
        return result
    }
    
    /// Called when an audio interruption begins (e.g. phone call, Siri, alarm).
    public func notifyInterruptionBegan() {
        lock.withLock {
            isSessionActive = false
        }
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
        lock.withLock {
            isSessionActive = false
            isSessionConfigured = false
            currentActivationTask?.cancel()
            currentActivationTask = nil
        }
        AppLogger.audio.warning("AVAudioSession media services were reset.")
    }
    
    /// Deactivates the audio session when playback has completely stopped.
    public func deactivateSession() {
        #if os(iOS)
        let wasActive = lock.withLock { () -> Bool in
            guard isSessionActive else { return false }
            isSessionActive = false
            return true
        }
        guard wasActive else { return }
        
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
