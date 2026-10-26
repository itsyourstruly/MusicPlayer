import Foundation
import AVFoundation
import Accelerate
import CoreGraphics

/// Rendered spectrogram image plus the axis facts needed to label it.
nonisolated struct SpectrogramResult: @unchecked Sendable {
    let image: CGImage
    let sampleRate: Double
    let durationSeconds: Double
    /// Highest frequency with sustained content above the noise floor (lossy cutoff detector).
    let extendsToHz: Double
}

nonisolated enum SpectrogramError: Error {
    case unsupportedFormat
}

/// Streams a file through a Hann-windowed 4096-point FFT and renders a full-track spectrogram in memory.
/// Nothing is written to disk; decoding is chunked so the whole PCM is never resident.
nonisolated enum SpectrogramRenderer {
    static let fftSize = 4096
    static let minDB: Float = -120

    @concurrent
    static func render(url: URL, columns requestedColumns: Int, height requestedHeight: Int,
                       progress: AsyncStream<Double>.Continuation) async throws -> SpectrogramResult {
        defer { progress.finish() }
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch { throw SpectrogramError.unsupportedFormat }

        let format = file.processingFormat
        let channelCount = Int(format.channelCount)
        let totalFrames = max(Int(file.length), 1)
        guard channelCount > 0, format.sampleRate > 0, format.commonFormat == .pcmFormatFloat32 else {
            throw SpectrogramError.unsupportedFormat
        }

        let n = fftSize
        let half = n / 2
        let log2n = vDSP_Length(12)
        let columns = max(1, min(requestedColumns, 8192))
        let framesPerColumn = Double(totalFrames) / Double(columns)
        let hop = max(1, min(n / 4, Int(framesPerColumn)))   // >= 75% overlap, at least one frame per column

        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { throw SpectrogramError.unsupportedFormat }
        defer { vDSP_destroy_fftsetup(setup) }

        let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: n, isHalfWindow: false)
        var colMax = [Float](repeating: 0, count: columns * half)   // linear power, max-aggregated per column
        var colFilled = [Bool](repeating: false, count: columns)
        var windowed = [Float](repeating: 0, count: n)
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var mags = [Float](repeating: 0, count: half)
        var frameDB = [Float](repeating: 0, count: half)
        // Per-bin level histogram (1 dB buckets, 0..-160 dBFS) over non-silent frames: lets the
        // "extends up to" detector use peaks/percentiles and a self-measured noise floor in one pass.
        var hist = [UInt32](repeating: 0, count: half * histBuckets)
        var activeFrames = 0
        var realEnd = Int.max          // frames reaching into the zero-pad tail are excluded from detection
        var invRef = 1 / (Float(half) * Float(half))
        var floorPower: Float = 1e-16
        var halfCount32 = Int32(half)
        var ten: Float = 10

        // Samples carry across 65,536-frame read chunks: `pending` keeps everything not yet consumed by a
        // frame, addressed in absolute sample positions, so frames straddling chunk boundaries are exact.
        // Lead-in of half a window of zeros centres the first frame on sample 0 (no gap at the start).
        var pending = [Float](repeating: 0, count: half)
        pending.reserveCapacity(65536 + n)
        var pendingStart = -half      // absolute sample index of pending[0]
        var frameStart = -half        // absolute sample index of next FFT frame

        func processFrames() {
            while frameStart + n <= pendingStart + pending.count {
                let offset = frameStart - pendingStart
                pending.withUnsafeBufferPointer { src in
                    vDSP.multiply(UnsafeBufferPointer(rebasing: src[offset..<(offset + n)]), window, result: &windowed)
                }
                real.withUnsafeMutableBufferPointer { rp in
                    imag.withUnsafeMutableBufferPointer { ip in
                        var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                        windowed.withUnsafeBytes { raw in
                            vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(half))
                        }
                        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                        ip[0] = 0   // packed Nyquist term; drop so bin 0 is pure DC
                        vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(half))
                    }
                }
                let col = min(columns - 1, max(0, Int((Double(frameStart) + Double(half)) / framesPerColumn)))
                colFilled[col] = true
                colMax.withUnsafeMutableBufferPointer { cp in
                    let base = cp.baseAddress! + col * half
                    vDSP_vmax(base, 1, mags, 1, base, 1, vDSP_Length(half))
                }
                // Per-bin mean dB over non-silent frames, for the "extends up to" estimate.
                vDSP_vsmul(mags, 1, &invRef, &frameDB, 1, vDSP_Length(half))
                vDSP_vthr(frameDB, 1, &floorPower, &frameDB, 1, vDSP_Length(half))
                vvlog10f(&frameDB, frameDB, &halfCount32)
                vDSP_vsmul(frameDB, 1, &ten, &frameDB, 1, vDSP_Length(half))
                var frameMax: Float = 0
                vDSP_maxv(frameDB, 1, &frameMax, vDSP_Length(half))
                if frameMax > -70 && ((frameStart >= 0 && frameStart + n <= realEnd) || realEnd < n) {
                    hist.withUnsafeMutableBufferPointer { hp in
                        for k in 0..<half {
                            let bucket = min(histBuckets - 1, max(0, Int(-frameDB[k])))
                            hp[k * histBuckets + bucket] &+= 1
                        }
                    }
                    activeFrames += 1
                }
                frameStart += hop
            }
            let consumed = frameStart - pendingStart
            if consumed > 0 {
                pending.removeFirst(min(consumed, pending.count))
                pendingStart += consumed
            }
        }

        let chunk: AVAudioFrameCount = 65536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { throw SpectrogramError.unsupportedFormat }
        let gain = 1 / Float(channelCount)
        var mono = [Float](repeating: 0, count: Int(chunk))
        var framesRead = 0
        var lastReported = -1.0

        while file.framePosition < file.length {
            try Task.checkCancellation()
            do { try file.read(into: buffer, frameCount: chunk) } catch {
                if framesRead == 0 { throw SpectrogramError.unsupportedFormat }
                break
            }
            let count = Int(buffer.frameLength)
            if count == 0 { break }
            guard let channels = buffer.floatChannelData else { throw SpectrogramError.unsupportedFormat }
            vDSP_vclr(&mono, 1, vDSP_Length(count))
            for c in 0..<channelCount {
                vDSP_vsma(channels[c], 1, [gain], mono, 1, &mono, 1, vDSP_Length(count))
            }
            pending.append(contentsOf: mono[0..<count])
            processFrames()
            framesRead += count
            let p = Double(framesRead) / Double(totalFrames)
            if p - lastReported >= 0.01 { lastReported = p; progress.yield(min(p, 1)) }
        }
        // Zero-pad the tail so the last samples (and very short files) still get a frame.
        realEnd = pendingStart + pending.count
        // Lead-out of half a window: last frame is centred on the final sample; nothing past it is analysed.
        pending.append(contentsOf: [Float](repeating: 0, count: half))
        processFrames()
        try Task.checkCancellation()

        fillEmptyColumns(&colMax, filled: colFilled, columns: columns, bins: half)
        let image = try makeImage(colMax: colMax, columns: columns, bins: half,
                                  height: max(1, requestedHeight))
        return SpectrogramResult(image: image, sampleRate: format.sampleRate,
                                 durationSeconds: Double(file.length) / format.sampleRate,
                                 extendsToHz: upperFrequency(hist: hist, bins: half, frames: activeFrames, hop: hop,
                                                             sampleRate: format.sampleRate,
                                                             bitDepth: sourceBitDepth(file)))
    }

    static let histBuckets = 160

    /// Source bit depth for PCM/lossless files (nil for lossy), used for the dither/quantization floor.
    private static func sourceBitDepth(_ file: AVAudioFile) -> Int? {
        let asbd = file.fileFormat.streamDescription.pointee
        switch asbd.mFormatID {
        case kAudioFormatLinearPCM:
            return asbd.mBitsPerChannel > 0 ? Int(asbd.mBitsPerChannel) : nil
        case kAudioFormatFLAC, kAudioFormatAppleLossless:
            switch asbd.mFormatFlags { case 1: return 16; case 2: return 20; case 3: return 24; case 4: return 32; default: return nil }
        default:
            return nil
        }
    }

    /// Highest frequency with real content. Noise floor = median level of the band just below Nyquist,
    /// measured from the file (if that band itself holds sustained content well above dither, report Nyquist).
    /// A bin counts when frames spanning more than one window (~0.1 s) exceed floor + 15 dB, and 3 adjacent bins must qualify, so brief or
    /// quiet HF sounds count while dither/noise (statistically never 15 dB over its median) and lone glitches don't.
    static func upperFrequency(hist: [UInt32], bins: Int, frames: Int, hop: Int, sampleRate: Double, bitDepth: Int?) -> Double {
        guard frames > 0, bins > 8 else { return 0 }
        let nb = histBuckets
        func medianDB(_ k: Int) -> Float {
            var acc = 0
            let target = (frames + 1) / 2
            for b in 0..<nb {
                acc += Int(hist[k * nb + b])
                if acc >= target { return -Float(b) - 0.5 }
            }
            return -Float(nb)
        }
        let binHz = sampleRate / Double(fftSize)
        let topBand = max(8, max(Int(300 / binHz), bins / 50))
        var medians = (bins - topBand..<bins).map(medianDB)
        medians.sort()
        var floorDB = medians[medians.count / 2]
        // Sustained level just below Nyquist far above any dither/quantization floor means content reaches Nyquist.
        let ditherFloor = Float(-6.02 * Double(bitDepth ?? 16) - 33.1)
        if floorDB > max(ditherFloor + 25, -105) { return sampleRate / 2 }
        // Never trust anything below -135 dBFS/bin (codec residue above a lossy low-pass); keeps threshold >= -120, the plot floor.
        floorDB = max(floorDB, -135)
        let threshold = floorDB + 15
        let lastBucket = Int(-threshold)          // buckets 0...lastBucket are >= threshold
        guard lastBucket >= 0 else { return 0 }
        // Must persist longer than one analysis window (~93 ms), so single clicks/edits don't count.
        let minFrames = min(fftSize / hop + 2, frames)
        var streak = 0
        for k in stride(from: bins - 1, through: 1, by: -1) {
            var count = 0
            for b in 0...min(lastBucket, nb - 1) { count += Int(hist[k * nb + b]) }
            if count >= minFrames {
                streak += 1
                if streak >= 3 {
                    let top = k + 2
                    if top >= bins - 3 { return sampleRate / 2 }
                    return (Double(top) + 0.5) * binHz
                }
            } else {
                streak = 0
            }
        }
        return 0
    }

    /// Very short tracks can have fewer frames than columns: linearly interpolate empty columns from the
    /// nearest analysed neighbours (or copy the edge column) so there are no gaps or duplicated seams.
    private static func fillEmptyColumns(_ colMax: inout [Float], filled: [Bool], columns: Int, bins: Int) {
        let idx = filled.indices.filter { filled[$0] }
        guard !idx.isEmpty, idx.count < columns else { return }
        colMax.withUnsafeMutableBufferPointer { cp in
            for col in 0..<columns where !filled[col] {
                let next = idx.first { $0 > col }
                let prev = idx.last { $0 < col }
                let dst = cp.baseAddress! + col * bins
                switch (prev, next) {
                case let (p?, q?):
                    let t = Float(col - p) / Float(q - p)
                    for b in 0..<bins { dst[b] = cp[p * bins + b] * (1 - t) + cp[q * bins + b] * t }
                case let (p?, nil):
                    dst.update(from: cp.baseAddress! + p * bins, count: bins)
                case let (nil, q?):
                    dst.update(from: cp.baseAddress! + q * bins, count: bins)
                default: break
                }
            }
        }
    }

    /// Converts max-power columns to dBFS and maps them through an inferno colormap (top row = Nyquist).
    private static func makeImage(colMax: [Float], columns: Int, bins: Int, height: Int) throws -> CGImage {
        // Full-scale sine through a Hann window yields |X| = N/2 with vDSP's 2x-scaled real FFT.
        let ref = Float(fftSize / 2) * Float(fftSize / 2)
        var db = [Float](repeating: 0, count: colMax.count)
        var scale = 1 / ref
        vDSP_vsmul(colMax, 1, &scale, &db, 1, vDSP_Length(colMax.count))
        var floorPower: Float = 1e-14
        vDSP_vthr(db, 1, &floorPower, &db, 1, vDSP_Length(db.count))
        var count32 = Int32(db.count)
        vvlog10f(&db, db, &count32)

        // Per-row bin span (row 0 = top = Nyquist). Max over covering bins when bins >= rows,
        // linear interpolation between neighbouring bins when rows outnumber bins.
        let binsPerRow = Double(bins) / Double(height)
        struct RowMap { let lo: Int; let hi: Int; let frac: Float }
        let rowMaps: [RowMap] = (0..<height).map { row in
            let f0 = Double(height - 1 - row) * binsPerRow
            let f1 = f0 + binsPerRow
            if binsPerRow >= 1 {
                let lo = min(bins - 1, Int(f0))
                return RowMap(lo: lo, hi: max(lo + 1, min(bins, Int(f1.rounded(.up)))), frac: -1)
            }
            let c = max(0, min(Double(bins - 1), (f0 + f1) / 2 - 0.5))
            let lo = Int(c)
            return RowMap(lo: lo, hi: min(bins - 1, lo + 1), frac: Float(c - Double(lo)))
        }
        let lut = colormap
        var pixels = [UInt8](repeating: 0, count: columns * height * 4)
        let range = -minDB
        for row in 0..<height {
            try Task.checkCancellation()
            let m = rowMaps[row]
            for col in 0..<columns {
                let base = col * bins
                var level: Float
                if m.frac < 0 {
                    level = -.infinity
                    for b in m.lo..<m.hi { level = max(level, db[base + b]) }
                } else {
                    level = db[base + m.lo] + (db[base + m.hi] - db[base + m.lo]) * m.frac
                }
                let t = min(max((level * 10 - minDB) / range, 0), 1)
                let c = lut[Int((t * 255).rounded())]
                let i = (row * columns + col) * 4
                pixels[i] = c.0; pixels[i + 1] = c.1; pixels[i + 2] = c.2; pixels[i + 3] = 255
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: columns, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: columns * 4, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw SpectrogramError.unsupportedFormat }
        return image
    }

    /// 256-entry inferno approximation (polynomial fit of the matplotlib map).
    private static let colormap: [(UInt8, UInt8, UInt8)] = (0..<256).map { i in
        let t = Double(i) / 255
        let c: [[Double]] = [
            [0.0002189403691192265, 0.001651004631001012, -0.01948089843709184],
            [0.1065134194856116, 0.5639564367884091, 3.932712388889277],
            [11.60249308247187, -3.972853965665698, -15.9423941062914],
            [-41.70399613139459, 17.43639888205313, 44.35414519872813],
            [77.162935699427, -33.40235894210092, -81.80730925738993],
            [-71.31942824499214, 32.62606426397723, 73.20951985803202],
            [25.13112622477341, -12.24266895238567, -23.07032500287172],
        ]
        func channel(_ k: Int) -> UInt8 {
            var v = c[6][k]
            for j in stride(from: 5, through: 0, by: -1) { v = c[j][k] + t * v }
            return UInt8(max(0, min(255, v * 255)))
        }
        return (channel(0), channel(1), channel(2))
    }
}
