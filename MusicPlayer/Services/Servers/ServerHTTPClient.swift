import Foundation

// MARK: - ServerHTTPError

nonisolated public enum ServerHTTPError: Error, Sendable, Equatable {
    /// Server answered with a non-2xx status after all retries.
    case status(Int)
    /// Response was not HTTP.
    case invalidResponse
}

// MARK: - ServerHTTPClient

/// Shared request execution for all media server providers: one retry/backoff policy instead of per-provider loops.
/// Retries transient failures only (timeouts, dropped connections, 5xx, 429 honoring Retry-After).
/// Never retries 4xx auth/client errors, so expired credentials surface immediately.
nonisolated public enum ServerHTTPClient {
    /// Exponential backoff base delays (seconds) between attempts; jittered ±25%.
    private static let backoff: [Double] = [0.5, 1.0, 2.0, 4.0]

    public static func data(
        for request: URLRequest,
        session: URLSession,
        maxAttempts: Int = 3
    ) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        while true {
            attempt += 1
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw ServerHTTPError.invalidResponse }
                if (200...299).contains(http.statusCode) {
                    return (data, http)
                }
                let retryable = http.statusCode == 429 || (500...599).contains(http.statusCode)
                guard retryable, attempt < maxAttempts else { throw ServerHTTPError.status(http.statusCode) }
                let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
                try await sleep(seconds: min(retryAfter ?? delay(for: attempt), 30))
            } catch let error as URLError where isTransient(error) && attempt < maxAttempts {
                try await sleep(seconds: delay(for: attempt))
            }
        }
    }

    private static func isTransient(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost, .dnsLookupFailed, .cannotFindHost:
            return true
        default:
            return false
        }
    }

    private static func delay(for attempt: Int) -> Double {
        let base = backoff[min(attempt - 1, backoff.count - 1)]
        return base * Double.random(in: 0.75...1.25)
    }

    private static func sleep(seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}
