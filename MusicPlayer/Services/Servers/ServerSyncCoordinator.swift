import Foundation
import os

/// Serializes server syncs: one queue per source (duplicate requests coalesce onto the running sync),
/// plus a global concurrency limit so server syncs never contend with each other or the local scanner
/// for the shared library write path and scan-progress UI.
actor ServerSyncCoordinator {
    static let shared = ServerSyncCoordinator()

    /// LibraryStore exposes a single scan-progress slot, so syncs run one at a time.
    private let maxConcurrentSyncs = 1
    private var running: [UUID: Task<Void, Never>] = [:]
    private var activeCount = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Runs `operation` for a source unless a sync for that source is already queued/running,
    /// in which case the caller awaits the in-flight sync instead of starting another.
    func sync(sourceID: UUID, operation: @escaping @Sendable () async -> Void) async {
        if let existing = running[sourceID] {
            await existing.value
            return
        }
        let task = Task {
            await self.acquire()
            if !Task.isCancelled {
                await operation()
            }
            self.release()
        }
        running[sourceID] = task
        await task.value
        // Only clear our own entry: after cancel(sourceID:) a newer sync may already be registered.
        if running[sourceID] == task { running[sourceID] = nil }
    }

    /// Cancels a queued or running sync (e.g. when the source is removed).
    func cancel(sourceID: UUID) {
        running[sourceID]?.cancel()
        running[sourceID] = nil
    }

    private func acquire() async {
        if activeCount < maxConcurrentSyncs {
            activeCount += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            activeCount -= 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

// MARK: - Stall watchdog

/// Cancels a long operation (a server sync) when it stops reporting progress, so a server that accepts the
/// connection but never finishes can't hold the sync slot forever. Progress is any status/progress callback.
nonisolated final class ServerStallWatchdog: Sendable {
    struct Stalled: Error, Sendable {}

    private let lastProgress = OSAllocatedUnfairLock<Date>(initialState: Date())

    func touch() { lastProgress.withLock { $0 = Date() } }

    func run<T: Sendable>(limit: TimeInterval, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        touch()
        return try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await operation() }
            group.addTask { [self] in
                while true {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    if Date().timeIntervalSince(lastProgress.withLock { $0 }) > limit { throw Stalled() }
                }
            }
            defer { group.cancelAll() }
            while let result = try await group.next() {
                if let result { return result }
            }
            throw CancellationError()
        }
    }
}
