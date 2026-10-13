import Foundation
import Observation

/// Dedicated, high-efficiency progress model for tracking elapsed playback time.
/// Observed exclusively by progress bars and scrubbers to prevent UI re-renders across the rest of the app.
@Observable
@MainActor
public final class AudioProgressModel {
    public var currentTime: TimeInterval = 0
    public var duration: TimeInterval = 0
    public var isSeeking: Bool = false
    public var seekPosition: TimeInterval = 0

    public init() {}
}
