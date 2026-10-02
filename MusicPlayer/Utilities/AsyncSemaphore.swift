import Foundation

/// Thread-safe actor-based semaphore and rate limiter.
/// Supports strict minimum-interval pacing (e.g. 1 request per second for MusicBrainz)
/// and asynchronous task queuing.
public actor AsyncSemaphore {
    private let minInterval: TimeInterval
    private var lastExecutionTime: Date = .distantPast

    public init(minInterval: TimeInterval = 1.0) {
        self.minInterval = minInterval
    }

    /// Suspends execution until the required minimum interval has elapsed since the last execution.
    public func wait() async {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastExecutionTime)
        if elapsed < minInterval {
            let delay = minInterval - elapsed
            let nanos = UInt64(delay * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
        }
        lastExecutionTime = Date()
    }
}
