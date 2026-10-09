import Foundation

/// Concurrency-safe actor that writes data atomically per file URL
/// and drops any write whose generation number is older than the last one written for that URL.
public actor PersistenceWriter {
    public static let shared = PersistenceWriter()

    private var lastWrittenGenerations: [URL: Int] = [:]

    private init() {}

    /// Writes data to a specific file URL atomically if the generation is newer than or equal to the last write.
    @discardableResult
    public func write(data: Data, to url: URL, generation: Int) -> Bool {
        let lastGen = lastWrittenGenerations[url] ?? -1
        guard generation >= lastGen else {
            return false // Drop older snapshot
        }
        do {
            try data.write(to: url, options: .atomic)
            lastWrittenGenerations[url] = generation
            return true
        } catch {
            return false
        }
    }

    /// Writes multiple data items atomically in one job, tracking per-URL generations.
    public func writeBatch(_ items: [(data: Data, url: URL, generation: Int)]) {
        for item in items {
            write(data: item.data, to: item.url, generation: item.generation)
        }
    }
}
