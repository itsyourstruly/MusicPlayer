import Foundation
import AVFoundation
import Accelerate
import SwiftUI

/// Processed audio visualization payload containing amplitude waveform envelope and time-frequency spectrogram.
public struct AudioAnalysisResult: Sendable {
    /// Normalized amplitude peaks for waveform rendering (0.0 to 1.0).
    public let waveformPeaks: [Float]
    /// 2D spectrogram matrix: [timeColumnIndex][frequencyBinIndex] with normalized magnitude (0.0 to 1.0).
    public let spectrogramMatrix: [[Float]]
    /// Number of time columns.
    public let timeColumns: Int
    /// Number of frequency bins.
    public let frequencyBins: Int
    /// Duration of audio in seconds.
    public let duration: TimeInterval
}

/// High-performance, concurrency-safe audio analyzer generating waveforms and full-track spectrograms.
public actor AudioWaveformSpectrogramGenerator {
    public static let shared = AudioWaveformSpectrogramGenerator()

    private var cache: [URL: AudioAnalysisResult] = [:]

    private init() {}

    /// Analyzes an audio file at the specified URL and returns waveform and spectrogram data.
    public func analyzeAudio(for url: URL, targetWaveformBuckets: Int = 180, targetSpectrogramColumns: Int = 140, targetFrequencyBins: Int = 48) async -> AudioAnalysisResult? {
        if let cached = cache[url] {
            return cached
        }

        _ = await SecurityScopedBookmark.shared.resolveAndAccessBookmark()
        let effectiveURL = await SecurityScopedBookmark.shared.resolveAccessibleURL(for: url)

        let isAccessing = effectiveURL.startAccessingSecurityScopedResource()
        defer {
            if isAccessing {
                effectiveURL.stopAccessingSecurityScopedResource()
            }
        }

        guard FileManager.default.fileExists(atPath: effectiveURL.path),
              CloudFileAvailability.isLocal(url: effectiveURL) else { return nil }

        let asset = AVURLAsset(url: effectiveURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first else {
            return nil
        }

        guard let reader = try? AVAssetReader(asset: asset) else { return nil }

        // Output settings for 32-bit linear PCM mono float at 22050 Hz for efficient visual analysis
        let targetSampleRate: Double = 22050.0
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: targetSampleRate
        ]

        let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        trackOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(trackOutput) else { return nil }
        reader.add(trackOutput)
        guard reader.startReading() else { return nil }

        // Collect samples
        var allSamples: [Float] = []
        while let sampleBuffer = trackOutput.copyNextSampleBuffer() {
            if Task.isCancelled {
                reader.cancelReading()
                return nil
            }
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            var length = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer) == noErr,
                  let dataPtr = dataPointer else { continue }

            let floatCount = length / MemoryLayout<Float>.size
            let floatPtr = dataPtr.withMemoryRebound(to: Float.self, capacity: floatCount) { $0 }
            let buffer = UnsafeBufferPointer(start: floatPtr, count: floatCount)
            allSamples.append(contentsOf: buffer)

            // Memory guard limit: Max ~10 minutes @ 22kHz
            if allSamples.count > 13_230_000 {
                break
            }
        }

        guard !allSamples.isEmpty else { return nil }

        let totalSamples = allSamples.count
        let duration = Double(totalSamples) / targetSampleRate

        // 1. Dynamic Transient & Crest Envelope Analysis
        var rawBucketEnergies = [Float](repeating: 0.0, count: targetWaveformBuckets)
        let samplesPerBucket = max(1, totalSamples / targetWaveformBuckets)
        let subWindowsPerBucket = 8

        for bucket in 0..<targetWaveformBuckets {
            let start = bucket * samplesPerBucket
            let end = min(totalSamples, start + samplesPerBucket)
            let bucketLength = end - start
            guard bucketLength > 0 else { continue }

            let subLength = max(1, bucketLength / subWindowsPerBucket)
            var maxSubRMS: Double = 0.0
            var sumSubRMS: Double = 0.0
            var bucketPeakSample: Float = 0.0
            var validSubCount: Double = 0.0

            for sub in 0..<subWindowsPerBucket {
                let subStart = start + sub * subLength
                let subEnd = min(end, subStart + subLength)
                guard subStart < subEnd else { continue }

                var sumSq: Double = 0.0
                var subPeak: Float = 0.0
                for i in subStart..<subEnd {
                    let absVal = abs(allSamples[i])
                    if absVal > subPeak { subPeak = absVal }
                    sumSq += Double(absVal * absVal)
                }

                let subCount = Double(subEnd - subStart)
                let subRMS = sqrt(sumSq / max(1.0, subCount))

                if subRMS > maxSubRMS { maxSubRMS = subRMS }
                sumSubRMS += subRMS
                validSubCount += 1.0
                if subPeak > bucketPeakSample { bucketPeakSample = subPeak }
            }

            let avgSubRMS = sumSubRMS / max(1.0, validSubCount)
            // Blend transient punch (65% weight) with sustained bed (20%) and raw sample peak (15%)
            let dynamicEnergy = Float(maxSubRMS * 0.65 + avgSubRMS * 0.20) + bucketPeakSample * 0.15
            rawBucketEnergies[bucket] = dynamicEnergy
        }

        // 2. Full-Range Track Dynamic Normalization (Min = quietest part, Max = loudest part)
        // Normalizes each track so its quietest part is minimum height and loudest part is maximum height
        var minEnergy: Float = Float.greatestFiniteMagnitude
        var maxEnergy: Float = 0.0

        for energy in rawBucketEnergies {
            if energy > maxEnergy { maxEnergy = energy }
            if energy < minEnergy { minEnergy = energy }
        }

        if minEnergy == Float.greatestFiniteMagnitude {
            minEnergy = 0.0
        }

        let energySpan = max(0.001, maxEnergy - minEnergy)

        var waveformPeaks = [Float](repeating: 0, count: targetWaveformBuckets)
        for b in 0..<targetWaveformBuckets {
            let norm = max(0.0, min(1.0, (rawBucketEnergies[b] - minEnergy) / energySpan))
            waveformPeaks[b] = norm
        }

        // Fast-path: if spectrogram is not needed, return waveform peaks immediately
        if targetSpectrogramColumns <= 0 {
            let result = AudioAnalysisResult(
                waveformPeaks: waveformPeaks,
                spectrogramMatrix: [],
                timeColumns: 0,
                frequencyBins: 0,
                duration: duration
            )
            cache[url] = result
            return result
        }

        // 2. Compute STFT Spectrogram
        let fftSize = 512
        let log2n = vDSP_Length(log2(Double(fftSize)))
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            let result = AudioAnalysisResult(
                waveformPeaks: waveformPeaks,
                spectrogramMatrix: [],
                timeColumns: 0,
                frequencyBins: 0,
                duration: duration
            )
            cache[url] = result
            return result
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

        let hopSize = max(fftSize / 2, (totalSamples - fftSize) / targetSpectrogramColumns)
        let actualColumns = min(targetSpectrogramColumns, max(1, (totalSamples - fftSize) / hopSize))
        var spectrogramMatrix: [[Float]] = []

        var realPart = [Float](repeating: 0, count: fftSize / 2)
        var imagPart = [Float](repeating: 0, count: fftSize / 2)

        for col in 0..<actualColumns {
            let startIdx = col * hopSize
            guard startIdx + fftSize <= totalSamples else { break }

            var windowedSegment = [Float](repeating: 0, count: fftSize)
            vDSP_vmul(Array(allSamples[startIdx..<(startIdx + fftSize)]), 1, window, 1, &windowedSegment, 1, vDSP_Length(fftSize))

            // Split complex
            windowedSegment.withUnsafeBufferPointer { winPtr in
                guard let baseAddr = winPtr.baseAddress else { return }
                baseAddr.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { complexPtr in
                    realPart.withUnsafeMutableBufferPointer { realPtr in
                        imagPart.withUnsafeMutableBufferPointer { imagPtr in
                            guard let rBase = realPtr.baseAddress, let iBase = imagPtr.baseAddress else { return }
                            var splitComplex = DSPSplitComplex(realp: rBase, imagp: iBase)
                            vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(fftSize / 2))
                            vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))
                        }
                    }
                }
            }

            // Magnitudes
            var magnitudes = [Float](repeating: 0, count: fftSize / 2)
            realPart.withUnsafeMutableBufferPointer { realPtr in
                imagPart.withUnsafeMutableBufferPointer { imagPtr in
                    guard let rBase = realPtr.baseAddress, let iBase = imagPtr.baseAddress else { return }
                    var splitComplex = DSPSplitComplex(realp: rBase, imagp: iBase)
                    vDSP_zvmags(&splitComplex, 1, &magnitudes, 1, vDSP_Length(fftSize / 2))
                }
            }

            // Convert to logarithmic frequency bins
            var binMagnitudes = [Float](repeating: 0, count: targetFrequencyBins)
            let halfBins = fftSize / 2
            for b in 0..<targetFrequencyBins {
                // Logarithmic frequency scale distribution
                let fracLow = pow(Double(b) / Double(targetFrequencyBins), 2.2)
                let fracHigh = pow(Double(b + 1) / Double(targetFrequencyBins), 2.2)
                let idxLow = max(0, min(halfBins - 1, Int(fracLow * Double(halfBins))))
                let idxHigh = max(idxLow + 1, min(halfBins, Int(fracHigh * Double(halfBins))))

                var avgMag: Float = 0
                for i in idxLow..<idxHigh {
                    avgMag += magnitudes[i]
                }
                avgMag /= Float(max(1, idxHigh - idxLow))

                // Convert power to decibels (0.0 to 1.0 range)
                let db = 10.0 * log10(max(1e-7, avgMag))
                // Map -70 dB..0 dB to 0.0..1.0
                let norm = max(0.0, min(1.0, (db + 70.0) / 70.0))
                binMagnitudes[b] = norm
            }

            spectrogramMatrix.append(binMagnitudes)
        }

        let result = AudioAnalysisResult(
            waveformPeaks: waveformPeaks,
            spectrogramMatrix: spectrogramMatrix,
            timeColumns: spectrogramMatrix.count,
            frequencyBins: targetFrequencyBins,
            duration: duration
        )
        cache[url] = result
        return result
    }

    /// Fetches normalized amplitude peaks sampled at 10-second intervals for the audio track.
    public func fetch10SecondWaveformPeaks(for url: URL, duration: TimeInterval) async -> [Float] {
        let bucketCount = max(1, Int(ceil(duration / 10.0)))
        return await resamplePeaks(for: url, duration: duration, targetBuckets: bucketCount)
    }

    /// Fetches normalized amplitude peaks sampled at sub-second intervals (default: 2 samples per second, 0.5s resolution) for dynamic waveform rendering.
    public func fetchSubSecondWaveformPeaks(for url: URL, duration: TimeInterval, samplesPerSecond: Int = 2) async -> [Float] {
        let bucketCount = max(1, Int(ceil(duration * Double(samplesPerSecond))))
        return await resamplePeaks(for: url, duration: duration, targetBuckets: bucketCount)
    }

    /// Fetches normalized amplitude peaks sampled at high-resolution intervals for the audio track.
    public func fetchSecondBySecondWaveformPeaks(for url: URL, duration: TimeInterval) async -> [Float] {
        return await fetchSubSecondWaveformPeaks(for: url, duration: duration, samplesPerSecond: 2)
    }

    private func resamplePeaks(for url: URL, duration: TimeInterval, targetBuckets: Int) async -> [Float] {
        if let cached = WaveformCache.shared.peaks(for: url) {
            return cached
        }
        if let result = await analyzeAudio(for: url, targetWaveformBuckets: max(targetBuckets, 60), targetSpectrogramColumns: 0) {
            let peaks: [Float]
            if result.waveformPeaks.count == targetBuckets {
                peaks = result.waveformPeaks
            } else {
                var resampled = [Float](repeating: 0.5, count: targetBuckets)
                let sourcePeaks = result.waveformPeaks
                let sourceCount = sourcePeaks.count
                if sourceCount > 0 {
                    for i in 0..<targetBuckets {
                        let startFrac = Double(i) / Double(targetBuckets)
                        let endFrac = Double(i + 1) / Double(targetBuckets)
                        let startIdx = min(sourceCount - 1, Int(startFrac * Double(sourceCount)))
                        let endIdx = min(sourceCount, max(startIdx + 1, Int(ceil(endFrac * Double(sourceCount)))))
                        var maxVal: Float = 0
                        for s in startIdx..<endIdx {
                            if sourcePeaks[s] > maxVal { maxVal = sourcePeaks[s] }
                        }
                        resampled[i] = maxVal
                    }
                }
                peaks = resampled
            }
            WaveformCache.shared.setPeaks(peaks, for: url)
            return peaks
        }
        return []
    }
}

/// Thread-safe, high-speed in-memory cache for waveform amplitude envelopes.
/// Allows zero-latency synchronous waveform rendering on frame 1 without awaiting asynchronous actors.
public final class WaveformCache: @unchecked Sendable {
    public nonisolated static let shared = WaveformCache()
    private let lock = NSLock()
    private var peaksByURL: [URL: [Float]] = [:]

    private init() {}

    public nonisolated func peaks(for url: URL) -> [Float]? {
        lock.lock()
        defer { lock.unlock() }
        return peaksByURL[url]
    }

    public nonisolated func setPeaks(_ peaks: [Float], for url: URL) {
        lock.lock()
        defer { lock.unlock() }
        peaksByURL[url] = peaks
    }

    /// Generates a deterministic, natural musical waveform envelope instantaneously (in <0.1ms).
    /// Used as an immediate high-quality visual placeholder while exact acoustic analysis decodes in background.
    public static func placeholderPeaks(for trackID: UUID, duration: TimeInterval) -> [Float] {
        let count = max(1, Int(ceil(duration * 2.0)))
        var hash = trackID.hashValue
        var peaks = [Float](repeating: 0, count: count)
        for i in 0..<count {
            hash = hash &* 1664525 &+ 1013904223
            let randNorm = Float(abs(hash % 1000)) / 1000.0
            let beat = sin(Double(i) * 0.35) * 0.18 + cos(Double(i) * 0.12) * 0.10
            let val = max(0.18, min(0.92, 0.45 + (randNorm - 0.5) * 0.35 + Float(beat)))
            peaks[i] = val
        }
        return peaks
    }
}
