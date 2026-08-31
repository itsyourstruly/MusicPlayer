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

        let isAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if isAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
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

        // 1. Compute Waveform Peaks
        var waveformPeaks = [Float](repeating: 0, count: targetWaveformBuckets)
        let samplesPerBucket = max(1, totalSamples / targetWaveformBuckets)

        for bucket in 0..<targetWaveformBuckets {
            let start = bucket * samplesPerBucket
            let end = min(totalSamples, start + samplesPerBucket)
            guard start < end else { continue }

            var maxAmp: Float = 0
            for i in start..<end {
                let absVal = abs(allSamples[i])
                if absVal > maxAmp { maxAmp = absVal }
            }
            waveformPeaks[bucket] = min(1.0, maxAmp)
        }

        // Normalize waveform
        var maxWaveformVal: Float = 0
        vDSP_maxv(waveformPeaks, 1, &maxWaveformVal, vDSP_Length(waveformPeaks.count))
        if maxWaveformVal > 0 {
            var scale = 1.0 / maxWaveformVal
            vDSP_vsmul(waveformPeaks, 1, &scale, &waveformPeaks, 1, vDSP_Length(waveformPeaks.count))
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
}
