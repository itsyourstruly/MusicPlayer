import Foundation

// MARK: - ServerHTTPError

nonisolated public enum ServerHTTPError: Error, Sendable, Equatable {
    /// Server answered with a non-2xx status after all retries.
    case status(Int)
    /// Response was not HTTP.
    case invalidResponse
    /// Jellyfin's startup middleware answered 503 with a Message header (server still initializing).
    case serverStarting
}

// MARK: - ServerHTTPClient

/// Shared request execution for all media server providers: one retry/backoff policy instead of per-provider loops.
/// Retries only failures a second attempt can plausibly fix (a timeout or dropped connection, 5xx, 429/503 with
/// Retry-After), at most once by default and never past a total time budget, so an unreachable server fails fast.
/// Never retries 4xx auth/client errors, DNS/refused connections, TLS errors or "no internet".
nonisolated public enum ServerHTTPClient {
    public static func data(
        for request: URLRequest,
        session: URLSession,
        maxAttempts: Int = 2,
        budget: TimeInterval = 90,
        caller: String = #fileID
    ) async throws -> (Data, HTTPURLResponse) {
        ServerRequestLog.log(request, caller: caller)
        let start = Date()
        var attempt = 0
        while true {
            attempt += 1
            try Task.checkCancellation()
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw ServerHTTPError.invalidResponse }
                if (200...299).contains(http.statusCode) {
                    return (data, http)
                }
                let starting = http.statusCode == 503 && http.value(forHTTPHeaderField: "Message") != nil
                let retryable = http.statusCode == 429 || (500...599).contains(http.statusCode)
                let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
                let wait = min(retryAfter ?? delay(for: attempt), 10)
                guard retryable, attempt < maxAttempts, Date().timeIntervalSince(start) + wait < budget else {
                    throw starting ? ServerHTTPError.serverStarting : ServerHTTPError.status(http.statusCode)
                }
                try await sleep(seconds: wait)
            } catch let error as URLError where isTransient(error) && attempt < maxAttempts {
                let wait = delay(for: attempt)
                guard Date().timeIntervalSince(start) + wait < budget else { throw error }
                try await sleep(seconds: wait)
            }
        }
    }

    /// Only failures where an immediate retry can succeed. DNS failures and refused connections are
    /// deterministic (wrong address, server off, VPN down) and are reported at once.
    private static func isTransient(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut, .networkConnectionLost:
            return true
        default:
            return false
        }
    }

    /// 0.5 s, then 1.5 s, jittered ±25%.
    private static func delay(for attempt: Int) -> Double {
        let base = attempt <= 1 ? 0.5 : 1.5
        return base * Double.random(in: 0.75...1.25)
    }

    private static func sleep(seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

// MARK: - ServerDeadline

/// Hard upper bound for a whole multi-request operation (sign-in, pre-sync check). The operation is cancelled
/// when the deadline passes, so URLSession tasks inside it stop immediately.
nonisolated public enum ServerDeadline {
    public struct Exceeded: Error, Sendable {}

    public static func run<T: Sendable>(seconds: TimeInterval, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw Exceeded()
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }
            return result
        }
    }
}
