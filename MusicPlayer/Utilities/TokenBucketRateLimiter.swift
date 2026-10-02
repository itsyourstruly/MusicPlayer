import Foundation

/// Thread-safe actor implementing a token bucket rate limiter.
/// Specifically configured for Deezer API guidelines:
/// Maximum 10 requests per second sustained, with a burst allowance of 50 requests per 5 seconds.
public actor TokenBucketRateLimiter {
    private let maxTokens: Double
    private let refillRatePerSecond: Double
    private var availableTokens: Double
    private var lastRefillTime: Date

    /// Initializes with capacity and sustained rate.
    /// Default: 50 token capacity (burst max), refilling at 10 tokens per second.
    public init(capacity: Double = 50.0, refillRatePerSecond: Double = 10.0) {
        self.maxTokens = capacity
        self.refillRatePerSecond = refillRatePerSecond
        self.availableTokens = capacity
        self.lastRefillTime = Date()
    }

    /// Acquires a single execution token, sleeping if the bucket is exhausted.
    public func acquire() async {
        while true {
            refill()
            if availableTokens >= 1.0 {
                availableTokens -= 1.0
                return
            }

            // Calculate wait time until at least 1 token is available
            let needed = 1.0 - availableTokens
            let waitSeconds = max(0.05, needed / refillRatePerSecond)
            let nanos = UInt64(waitSeconds * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
        }
    }

    private func refill() {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastRefillTime)
        guard elapsed > 0 else { return }

        let addedTokens = elapsed * refillRatePerSecond
        availableTokens = min(maxTokens, availableTokens + addedTokens)
        lastRefillTime = now
    }
}
