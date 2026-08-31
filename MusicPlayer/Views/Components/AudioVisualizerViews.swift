import SwiftUI

/// Clean, high-definition audio amplitude waveform visualizer.
public struct AudioWaveformView: View {
    public let peaks: [Float]
    public let duration: TimeInterval
    public let accentColor: Color

    public init(peaks: [Float], duration: TimeInterval, accentColor: Color = Color.blue) {
        self.peaks = peaks
        self.duration = duration
        self.accentColor = accentColor
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                let width = geo.size.width
                let height = geo.size.height
                let count = peaks.count
                let barWidth = max(1.5, (width / CGFloat(max(1, count))) - 1.0)

                HStack(alignment: .center, spacing: 1.0) {
                    ForEach(0..<peaks.count, id: \.self) { idx in
                        let peak = CGFloat(peaks[idx])
                        let barHeight = max(2.0, peak * height)

                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        accentColor.opacity(0.95),
                                        accentColor.opacity(0.45)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(width: barWidth, height: barHeight)
                    }
                }
                .frame(width: width, height: height, alignment: .center)
            }
            .frame(height: 74)
            .padding(.vertical, 4)
            .background(Color.black.opacity(0.25))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )

            // Timeline markers
            HStack {
                Text("00:00")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer()
                Text("PEAK AMPLITUDE ENVELOPE")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary.opacity(0.7))
                Spacer()
                Text(TimeFormatting.format(seconds: duration))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// Full-track time-frequency 2D spectrogram visualizer with frequency axis and dB intensity heatmap.
public struct AudioSpectrogramView: View {
    public let matrix: [[Float]]
    public let timeColumns: Int
    public let frequencyBins: Int
    public let duration: TimeInterval

    public init(matrix: [[Float]], timeColumns: Int, frequencyBins: Int, duration: TimeInterval) {
        self.matrix = matrix
        self.timeColumns = timeColumns
        self.frequencyBins = frequencyBins
        self.duration = duration
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                // Frequency Y-Axis Labels
                VStack(alignment: .trailing, spacing: 0) {
                    Text("20k")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Text("5k")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Text("1k")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Text("100")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Text("20Hz")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                .frame(width: 30, height: 110)

                // 2D Spectrogram Canvas Heatmap
                Canvas { context, size in
                    guard timeColumns > 0, frequencyBins > 0, !matrix.isEmpty else { return }

                    let colWidth = size.width / CGFloat(timeColumns)
                    let rowHeight = size.height / CGFloat(frequencyBins)

                    for col in 0..<min(timeColumns, matrix.count) {
                        let bins = matrix[col]
                        let x = CGFloat(col) * colWidth

                        for bin in 0..<min(frequencyBins, bins.count) {
                            let intensity = Double(bins[bin])
                            // Flip y so high frequencies are at the top
                            let y = size.height - CGFloat(bin + 1) * rowHeight
                            let rect = CGRect(x: x, y: y, width: colWidth + 0.5, height: rowHeight + 0.5)

                            let color = spectrogramColor(for: intensity)
                            context.fill(Path(rect), with: .color(color))
                        }
                    }
                }
                .frame(height: 110)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
            }

            // Timeline X-Axis Markers
            HStack {
                Text("00:00")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 38)
                Spacer()
                Text("STFT SPECTROGRAM (20Hz - 22kHz)")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary.opacity(0.7))
                Spacer()
                Text(TimeFormatting.format(seconds: duration))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// Maps normalized magnitude (0.0 to 1.0) to professional audio spectrogram heatmap palette.
    private func spectrogramColor(for intensity: Double) -> Color {
        // Range 0.0 -> deep navy/purple, 0.35 -> cyan, 0.65 -> yellow/orange, 1.0 -> bright white
        if intensity < 0.08 {
            return Color(red: 0.04, green: 0.04, blue: 0.12)
        } else if intensity < 0.30 {
            let t = (intensity - 0.08) / 0.22
            return Color(
                red: 0.08 + 0.10 * t,
                green: 0.10 + 0.50 * t,
                blue: 0.40 + 0.45 * t
            )
        } else if intensity < 0.65 {
            let t = (intensity - 0.30) / 0.35
            return Color(
                red: 0.18 + 0.70 * t,
                green: 0.60 + 0.30 * t,
                blue: 0.85 - 0.65 * t
            )
        } else {
            let t = (intensity - 0.65) / 0.35
            return Color(
                red: 0.88 + 0.12 * t,
                green: 0.90 + 0.10 * t,
                blue: 0.20 + 0.80 * t
            )
        }
    }
}
