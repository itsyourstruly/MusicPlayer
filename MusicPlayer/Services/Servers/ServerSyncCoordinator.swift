import Foundation

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
        running[sourceID] = nil
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
