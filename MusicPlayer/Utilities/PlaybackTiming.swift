import Foundation
import os

/// DEBUG-only "tap to first audio" timing (subsystem = bundle id, category "PlaybackTiming").
/// Stages: tap -> itemCreated -> readyToPlay -> firstAudio, each logged with ms since the tap.
/// The whole span is also a signpost interval ("TapToAudio") shown in Instruments' Points of Interest.
/// In Release builds every call is an empty inline function.
nonisolated enum PlaybackTiming {
#if DEBUG
    private static let subsystem = Bundle.main.bundleIdentifier ?? "MusicPlayer"
    private static let log = Logger(subsystem: subsystem, category: "PlaybackTiming")
    private static let signposter = OSSignposter(subsystem: subsystem, category: "PlaybackTiming")
    private static let poi = OSSignposter(subsystem: subsystem, category: .pointsOfInterest)

    private struct Run {
        var trackID: UUID
        var start: ContinuousClock.Instant
        var stages: Set<String>
        var interval: OSSignpostIntervalState
        var poiInterval: OSSignpostIntervalState
    }
    private static let state = OSAllocatedUnfairLock<Run?>(initialState: nil)

    private static func ms(since start: ContinuousClock.Instant) -> Double {
        let d = ContinuousClock.now - start
        return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    /// Starts timing for a track. A tap on the track already being timed is ignored.
    static func tap(_ trackID: UUID) {
        let begun: Bool = state.withLock { run in
            if let r = run, r.trackID == trackID, !r.stages.contains("firstAudio") { return false }
            if let r = run, !r.stages.contains("firstAudio") {
                signposter.endInterval("TapToAudio", r.interval, "abandoned")
                poi.endInterval("TapToAudio", r.poiInterval, "abandoned")
            }
            run = Run(trackID: trackID, start: .now, stages: ["tap"],
                      interval: signposter.beginInterval("TapToAudio", id: signposter.makeSignpostID()),
                      poiInterval: poi.beginInterval("TapToAudio", id: poi.makeSignpostID()))
            return true
        }
        if begun { log.debug("tap track=\(trackID.uuidString, privacy: .public) 0 ms") }
    }

    /// Records a stage once per run: "itemCreated", "readyToPlay" or "firstAudio" (ends the interval).
    static func mark(_ stage: String, trackID: UUID?) {
        guard let trackID else { return }
        let elapsed: Double? = state.withLock { run in
            guard var r = run, r.trackID == trackID, !r.stages.contains(stage), !r.stages.contains("firstAudio") else { return nil }
            r.stages.insert(stage)
            let e = ms(since: r.start)
            signposter.emitEvent("PlaybackStage", "\(stage, privacy: .public) \(e, format: .fixed(precision: 0)) ms")
            poi.emitEvent("PlaybackStage", "\(stage, privacy: .public) \(e, format: .fixed(precision: 0)) ms")
            if stage == "firstAudio" {
                signposter.endInterval("TapToAudio", r.interval)
                poi.endInterval("TapToAudio", r.poiInterval)
            }
            run = r
            return e
        }
        if let elapsed {
            log.debug("\(stage, privacy: .public) track=\(trackID.uuidString, privacy: .public) \(elapsed, format: .fixed(precision: 1)) ms")
        }
    }
#else
    @inline(__always) static func tap(_ trackID: UUID) {}
    @inline(__always) static func mark(_ stage: String, trackID: UUID?) {}
#endif
}
