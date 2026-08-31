// Services/AudioDSPProcessor.swift
import Foundation
import AVFoundation
import MediaToolbox
import os

/// High-performance real-time audio DSP engine applying 10-Band Biquad IIR Equalizer
/// and Volume Booster gain with musical soft-limiting to AVPlayer playback.
///
/// Designed to strictly follow Apple CoreAudio Real-Time Safety Guidelines:
/// - Zero memory allocations on render callbacks.
/// - Zero Swift Array dynamic heap mutations or bounds-check overhead.
/// - Fast atomic parameter reads with inline fixed-size filter banks.
public final class AudioDSPProcessor: @unchecked Sendable {
    public static let shared = AudioDSPProcessor()

    public struct BiquadCoefficients: Sendable {
        public var b0: Float = 1.0
        public var b1: Float = 0.0
        public var b2: Float = 0.0
        public var a1: Float = 0.0
        public var a2: Float = 0.0

        public static let identity = BiquadCoefficients()

        @inline(__always)
        public var isIdentity: Bool {
            b0 == 1.0 && b1 == 0.0 && b2 == 0.0 && a1 == 0.0 && a2 == 0.0
        }
    }

    public struct BiquadState: Sendable {
        public var s1: Float = 0.0
        public var s2: Float = 0.0

        public init() {}
    }

    /// Fixed 10-band filter bank coefficients stored inline with zero dynamic memory allocation.
    public struct FilterBankCoefficients: Sendable {
        public var c0: BiquadCoefficients = .identity
        public var c1: BiquadCoefficients = .identity
        public var c2: BiquadCoefficients = .identity
        public var c3: BiquadCoefficients = .identity
        public var c4: BiquadCoefficients = .identity
        public var c5: BiquadCoefficients = .identity
        public var c6: BiquadCoefficients = .identity
        public var c7: BiquadCoefficients = .identity
        public var c8: BiquadCoefficients = .identity
        public var c9: BiquadCoefficients = .identity

        public init() {}

        @inline(__always)
        public subscript(index: Int) -> BiquadCoefficients {
            get {
                switch index {
                case 0: return c0
                case 1: return c1
                case 2: return c2
                case 3: return c3
                case 4: return c4
                case 5: return c5
                case 6: return c6
                case 7: return c7
                case 8: return c8
                case 9: return c9
                default: return .identity
                }
            }
            set {
                switch index {
                case 0: c0 = newValue
                case 1: c1 = newValue
                case 2: c2 = newValue
                case 3: c3 = newValue
                case 4: c4 = newValue
                case 5: c5 = newValue
                case 6: c6 = newValue
                case 7: c7 = newValue
                case 8: c8 = newValue
                case 9: c9 = newValue
                default: break
                }
            }
        }
    }

    /// Fixed 10-band per-channel filter states stored inline.
    public struct ChannelFilterState: Sendable {
        public var s0 = BiquadState()
        public var s1 = BiquadState()
        public var s2 = BiquadState()
        public var s3 = BiquadState()
        public var s4 = BiquadState()
        public var s5 = BiquadState()
        public var s6 = BiquadState()
        public var s7 = BiquadState()
        public var s8 = BiquadState()
        public var s9 = BiquadState()

        public init() {}

        @inline(__always)
        public mutating func reset() {
            s0 = BiquadState()
            s1 = BiquadState()
            s2 = BiquadState()
            s3 = BiquadState()
            s4 = BiquadState()
            s5 = BiquadState()
            s6 = BiquadState()
            s7 = BiquadState()
            s8 = BiquadState()
            s9 = BiquadState()
        }
    }

    private final class TapStorage: @unchecked Sendable {
        var sampleRate: Double = 44100.0
        var isEQEnabled: Bool = false
        var volumeBoostLinear: Float = 1.0
        var bandGains: [Double] = [Double](repeating: 0.0, count: 10)
        var coefficients = FilterBankCoefficients()

        var leftState = ChannelFilterState()
        var rightState = ChannelFilterState()

        private var unfairLock = os_unfair_lock()

        func lock() {
            os_unfair_lock_lock(&unfairLock)
        }

        func unlock() {
            os_unfair_lock_unlock(&unfairLock)
        }

        func readParameters() -> (isEQ: Bool, boost: Float, coeffs: FilterBankCoefficients) {
            os_unfair_lock_lock(&unfairLock)
            let eq = isEQEnabled
            let b = volumeBoostLinear
            let c = coefficients
            os_unfair_lock_unlock(&unfairLock)
            return (eq, b, c)
        }
    }

    private let storage = TapStorage()
    private let centerFrequencies: [Double] = [32.0, 64.0, 125.0, 250.0, 500.0, 1000.0, 2000.0, 4000.0, 8000.0, 16000.0]

    private init() {
        recalculateCoefficients()
    }

    /// Updates DSP parameters from EqualizerManager
    public func update(isEQEnabled: Bool, volumeBoosterDB: Double, bandGains: [Double]) {
        storage.lock()
        storage.isEQEnabled = isEQEnabled
        // Convert dB to linear amplitude multiplier: 10^(dB / 20)
        let linear = Float(pow(10.0, volumeBoosterDB / 20.0))
        storage.volumeBoostLinear = linear
        if bandGains.count == 10 {
            storage.bandGains = bandGains
        }
        recalculateCoefficients()
        storage.unlock()
    }

    private func recalculateCoefficients() {
        let sr = storage.sampleRate > 0 ? storage.sampleRate : 44100.0
        let q: Double = 1.414 // 1-octave bandwidth Q

        for i in 0..<10 {
            let f0 = centerFrequencies[i]
            let gainDB = storage.bandGains[i]

            if abs(gainDB) < 0.05 || !storage.isEQEnabled {
                storage.coefficients[i] = .identity
                continue
            }

            // Audio EQ Cookbook Peaking EQ formulas
            let a = pow(10.0, gainDB / 40.0) // sqrt(10^(gainDB/20))
            let w0 = 2.0 * Double.pi * (min(f0, sr * 0.45) / sr)
            let alpha = sin(w0) / (2.0 * q)
            let cosw0 = cos(w0)

            let b0 = 1.0 + alpha * a
            let b1 = -2.0 * cosw0
            let b2 = 1.0 - alpha * a
            let a0 = 1.0 + alpha / a
            let a1 = -2.0 * cosw0
            let a2 = 1.0 - alpha / a

            storage.coefficients[i] = BiquadCoefficients(
                b0: Float(b0 / a0),
                b1: Float(b1 / a0),
                b2: Float(b2 / a0),
                a1: Float(a1 / a0),
                a2: Float(a2 / a0)
            )
        }
    }

    /// Attaches the audio processing tap to an AVPlayerItem
    public func createAudioProcessingTap() -> MTAudioProcessingTap? {
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passUnretained(self).toOpaque(),
            init: { tap, clientInfo, tapStorageOut in
                tapStorageOut.pointee = clientInfo
            },
            finalize: { tap in },
            prepare: { tap, maxFrames, processingFormat in
                let selfPtr = Unmanaged<AudioDSPProcessor>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                selfPtr.storage.lock()
                selfPtr.storage.sampleRate = processingFormat.pointee.mSampleRate
                selfPtr.recalculateCoefficients()
                selfPtr.storage.leftState.reset()
                selfPtr.storage.rightState.reset()
                selfPtr.storage.unlock()
            },
            unprepare: { tap in },
            process: { tap, numberFrames, flags, bufferListInOut, numberFramesOut, flagsOut in
                let status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut, flagsOut, nil, numberFramesOut)
                guard status == noErr else { return }

                let selfPtr = Unmanaged<AudioDSPProcessor>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                selfPtr.processAudio(bufferList: bufferListInOut, frameCount: Int(numberFrames))
            }
        )

        var tapOut: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault,
            &callbacks,
            kMTAudioProcessingTapCreationFlag_PreEffects,
            &tapOut
        )

        if status == noErr {
            return tapOut
        } else {
            AppLogger.audio.error("Failed to create MTAudioProcessingTap: \(status)")
            return nil
        }
    }

    /// Real-time audio processing loop executing on CoreAudio render thread
    private func processAudio(bufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: Int) {
        let bufferListPtr = UnsafeMutableAudioBufferListPointer(bufferList)
        let numBuffers = bufferListPtr.count
        guard numBuffers > 0, frameCount > 0 else { return }

        let (isEQ, boost, coeffs) = storage.readParameters()
        let isNoop = !isEQ && abs(boost - 1.0) < 0.001
        if isNoop { return }

        for bufferIndex in 0..<numBuffers {
            let audioBuffer = bufferListPtr[bufferIndex]
            guard let data = audioBuffer.mData else { continue }
            let samples = data.assumingMemoryBound(to: Float.self)
            let channelCount = Int(audioBuffer.mNumberChannels)

            if channelCount == 1 {
                // Non-interleaved channel
                if bufferIndex == 1 {
                    for frame in 0..<frameCount {
                        samples[frame] = processSingleSample(
                            samples[frame],
                            state: &storage.rightState,
                            isEQ: isEQ,
                            boost: boost,
                            coeffs: coeffs
                        )
                    }
                } else {
                    for frame in 0..<frameCount {
                        samples[frame] = processSingleSample(
                            samples[frame],
                            state: &storage.leftState,
                            isEQ: isEQ,
                            boost: boost,
                            coeffs: coeffs
                        )
                    }
                }
            } else if channelCount >= 2 {
                // Interleaved stereo channels (L, R, L, R, ...)
                for frame in 0..<frameCount {
                    let leftIdx = frame * channelCount
                    let rightIdx = leftIdx + 1
                    samples[leftIdx] = processSingleSample(
                        samples[leftIdx],
                        state: &storage.leftState,
                        isEQ: isEQ,
                        boost: boost,
                        coeffs: coeffs
                    )
                    samples[rightIdx] = processSingleSample(
                        samples[rightIdx],
                        state: &storage.rightState,
                        isEQ: isEQ,
                        boost: boost,
                        coeffs: coeffs
                    )
                }
            }
        }
    }

    @inline(__always)
    private func processSingleSample(
        _ input: Float,
        state: inout ChannelFilterState,
        isEQ: Bool,
        boost: Float,
        coeffs: FilterBankCoefficients
    ) -> Float {
        var sample = input

        if isEQ {
            // Unrolled 10-band biquad IIR Direct Form II Transposed
            sample = applyBand(sample, coeff: coeffs.c0, state: &state.s0)
            sample = applyBand(sample, coeff: coeffs.c1, state: &state.s1)
            sample = applyBand(sample, coeff: coeffs.c2, state: &state.s2)
            sample = applyBand(sample, coeff: coeffs.c3, state: &state.s3)
            sample = applyBand(sample, coeff: coeffs.c4, state: &state.s4)
            sample = applyBand(sample, coeff: coeffs.c5, state: &state.s5)
            sample = applyBand(sample, coeff: coeffs.c6, state: &state.s6)
            sample = applyBand(sample, coeff: coeffs.c7, state: &state.s7)
            sample = applyBand(sample, coeff: coeffs.c8, state: &state.s8)
            sample = applyBand(sample, coeff: coeffs.c9, state: &state.s9)
        }

        // Apply linear volume boost
        sample *= boost

        // High-Quality Musical Soft-Knee Limiter (Prevents harsh digital clipping above unity)
        if sample > 0.90 {
            let excess = sample - 0.90
            sample = 0.90 + 0.099 * tanhf(excess * 10.0)
        } else if sample < -0.90 {
            let excess = -sample - 0.90
            sample = -(0.90 + 0.099 * tanhf(excess * 10.0))
        }

        return sample
    }

    @inline(__always)
    private func applyBand(_ input: Float, coeff: BiquadCoefficients, state: inout BiquadState) -> Float {
        if coeff.isIdentity { return input }
        let y = coeff.b0 * input + state.s1
        state.s1 = coeff.b1 * input - coeff.a1 * y + state.s2
        state.s2 = coeff.b2 * input - coeff.a2 * y
        return y
    }
}
