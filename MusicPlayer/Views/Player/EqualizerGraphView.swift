import SwiftUI

/// High-precision, edge-to-edge interactive 10-band line graph equalizer view with draggable nodes,
/// blue frequency response curve centered precisely through node handles, top live gain readouts,
/// and clean bottom frequency labels.
public struct EqualizerGraphView: View {
    @Bindable var equalizerManager: EqualizerManager
    @Environment(\.appTheme) private var appTheme
    @State private var activeDraggingBand: Int? = nil

    public init(equalizerManager: EqualizerManager) {
        self.equalizerManager = equalizerManager
    }

    private let minDB: Double = -12.0
    private let maxDB: Double = 12.0
    private let marginX: CGFloat = 26.0
    private let insetY: CGFloat = 14.0

    private var isEnabled: Bool {
        equalizerManager.isEqualizerEnabled
    }

    public var body: some View {
        VStack(spacing: 8) {
            // MARK: - 1. Top Live Gain Readouts Row
            GeometryReader { geo in
                let width = geo.size.width
                let count = equalizerManager.bands.count
                let stepX = count > 1 ? (width - 2 * marginX) / CGFloat(count - 1) : 0

                ForEach(0..<count, id: \.self) { i in
                    let x = marginX + CGFloat(i) * stepX
                    let gain = equalizerManager.bands[i].gainDB
                    let isDragging = activeDraggingBand == i

                    Text(formatGain(gain))
                        .font(.system(size: 9, weight: isDragging ? .heavy : .bold, design: .monospaced))
                        .foregroundStyle(
                            isEnabled
                                ? (gain > 0 ? Color.blue : (gain < 0 ? Color.blue.opacity(0.75) : Color.secondary))
                                : Color.secondary.opacity(0.6)
                        )
                        .scaleEffect(isDragging ? 1.15 : 1.0)
                        .animation(.easeInOut(duration: 0.12), value: isDragging)
                        .position(x: x, y: 10)
                }
            }
            .frame(height: 18)

            // MARK: - 2. Edge-to-Edge Interactive Graph Area
            GeometryReader { geo in
                let width = geo.size.width
                let height = geo.size.height
                let count = equalizerManager.bands.count
                let stepX = count > 1 ? (width - 2 * marginX) / CGFloat(count - 1) : 0
                let usableHeight = height - 2 * insetY

                ZStack {
                    // Background Surface
                    appTheme.secondaryBackgroundColor.opacity(isEnabled ? 0.35 : 0.18)
                        .ignoresSafeArea()

                    // dB Scale Grid & Reference Lines
                    Path { path in
                        // +12 dB (top guide)
                        path.move(to: CGPoint(x: 0, y: insetY))
                        path.addLine(to: CGPoint(x: width, y: insetY))

                        // +6 dB
                        let plus6Y = insetY + usableHeight * 0.25
                        path.move(to: CGPoint(x: 0, y: plus6Y))
                        path.addLine(to: CGPoint(x: width, y: plus6Y))

                        // 0 dB (center line)
                        let zeroY = insetY + usableHeight * 0.50
                        path.move(to: CGPoint(x: 0, y: zeroY))
                        path.addLine(to: CGPoint(x: width, y: zeroY))

                        // -6 dB
                        let minus6Y = insetY + usableHeight * 0.75
                        path.move(to: CGPoint(x: 0, y: minus6Y))
                        path.addLine(to: CGPoint(x: width, y: minus6Y))

                        // -12 dB (bottom guide)
                        let minus12Y = insetY + usableHeight
                        path.move(to: CGPoint(x: 0, y: minus12Y))
                        path.addLine(to: CGPoint(x: width, y: minus12Y))
                    }
                    .stroke(Color.white.opacity(isEnabled ? 0.07 : 0.03), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))

                    // Subtle 0 dB Solid Reference Line
                    Path { path in
                        let zeroY = insetY + usableHeight * 0.50
                        path.move(to: CGPoint(x: 0, y: zeroY))
                        path.addLine(to: CGPoint(x: width, y: zeroY))
                    }
                    .stroke(Color.white.opacity(isEnabled ? 0.16 : 0.08), lineWidth: 1)

                    // Vertical Band Column Guides
                    Path { path in
                        for i in 0..<count {
                            let x = marginX + CGFloat(i) * stepX
                            path.move(to: CGPoint(x: x, y: 0))
                            path.addLine(to: CGPoint(x: x, y: height))
                        }
                    }
                    .stroke(Color.white.opacity(isEnabled ? 0.04 : 0.02), style: StrokeStyle(lineWidth: 1, dash: [2, 4]))

                    // Left & Right Axis dB Scale Labels
                    VStack(alignment: .leading, spacing: 0) {
                        Text("+12")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Text("+6")
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Text(" 0")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundStyle(isEnabled ? .secondary : .tertiary)
                        Spacer()
                        Text("-6")
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Text("-12")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.leading, 6)
                    .padding(.vertical, insetY - 5)

                    // Compute Node Coordinates
                    let nodePoints = (0..<count).map { i -> CGPoint in
                        let x = marginX + CGFloat(i) * stepX
                        let gain = equalizerManager.bands[i].gainDB
                        let norm = (gain - minDB) / (maxDB - minDB) // 0.0 at -12, 1.0 at +12
                        let y = (height - insetY) - (CGFloat(norm) * usableHeight)
                        return CGPoint(x: x, y: y)
                    }

                    // Translucent Gradient Fill Area under the Curve
                    Path { path in
                        guard !nodePoints.isEmpty else { return }
                        path.move(to: CGPoint(x: 0, y: height))
                        path.addLine(to: CGPoint(x: 0, y: nodePoints[0].y))
                        path.addLine(to: nodePoints[0])

                        for i in 1..<nodePoints.count {
                            let p0 = nodePoints[i - 1]
                            let p1 = nodePoints[i]
                            let control1 = CGPoint(x: p0.x + (p1.x - p0.x) * 0.45, y: p0.y)
                            let control2 = CGPoint(x: p0.x + (p1.x - p0.x) * 0.55, y: p1.y)
                            path.addCurve(to: p1, control1: control1, control2: control2)
                        }

                        if let last = nodePoints.last {
                            path.addLine(to: CGPoint(x: width, y: last.y))
                            path.addLine(to: CGPoint(x: width, y: height))
                        }
                        path.closeSubpath()
                    }
                    .fill(
                        LinearGradient(
                            colors: isEnabled
                                ? [
                                    Color.blue.opacity(0.20),
                                    Color.blue.opacity(0.04),
                                    Color.clear
                                ]
                                : [
                                    Color.gray.opacity(0.12),
                                    Color.gray.opacity(0.02),
                                    Color.clear
                                ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                    // Continuous Bezier Frequency Response Curve
                    Path { path in
                        guard !nodePoints.isEmpty else { return }
                        path.move(to: CGPoint(x: 0, y: nodePoints[0].y))
                        path.addLine(to: nodePoints[0])

                        for i in 1..<nodePoints.count {
                            let p0 = nodePoints[i - 1]
                            let p1 = nodePoints[i]
                            let control1 = CGPoint(x: p0.x + (p1.x - p0.x) * 0.45, y: p0.y)
                            let control2 = CGPoint(x: p0.x + (p1.x - p0.x) * 0.55, y: p1.y)
                            path.addCurve(to: p1, control1: control1, control2: control2)
                        }

                        if let last = nodePoints.last {
                            path.addLine(to: CGPoint(x: width, y: last.y))
                        }
                    }
                    .stroke(
                        isEnabled ? Color.blue : Color(white: 0.45),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
                    )

                    // 10 Interactive Draggable Node Handles (Centered Exactly on the Line)
                    ForEach(0..<count, id: \.self) { i in
                        let pt = nodePoints[i]
                        let isDragging = activeDraggingBand == i

                        Circle()
                            .fill(isEnabled ? Color.white : Color(white: 0.65))
                            .frame(width: isDragging ? 16 : 13, height: isDragging ? 16 : 13)
                            .overlay(
                                Circle()
                                    .stroke(isEnabled ? Color.blue : Color(white: 0.4), lineWidth: isDragging ? 3 : 2.5)
                            )
                            .shadow(color: isEnabled ? Color.blue.opacity(0.4) : Color.clear, radius: isDragging ? 6 : 3, x: 0, y: 1)
                            .position(x: pt.x, y: pt.y)
                            .animation(.easeInOut(duration: 0.12), value: isDragging)
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    isEnabled
                        ? DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let touchX = value.location.x
                                let touchY = value.location.y

                                // Find nearest frequency band
                                let normalizedX = (touchX - marginX) / max(1, width - 2 * marginX)
                                let rawIndex = Int(round(normalizedX * CGFloat(count - 1)))
                                let nearestIndex = max(0, min(count - 1, rawIndex))
                                activeDraggingBand = nearestIndex

                                // Calculate gain from touchY clamped within usable height
                                let clampedY = max(insetY, min(height - insetY, touchY))
                                let normGain = Double(1.0 - ((clampedY - insetY) / usableHeight))
                                let rawDB = minDB + normGain * (maxDB - minDB)

                                equalizerManager.setGain(bandIndex: nearestIndex, gainDB: rawDB)
                            }
                            .onEnded { _ in
                                activeDraggingBand = nil
                            }
                        : nil
                )
                .overlay(
                    VStack {
                        Divider().background(Color.white.opacity(0.08))
                        Spacer()
                        Divider().background(Color.white.opacity(0.08))
                    }
                )
            }
            .frame(height: 185)

            // MARK: - 3. Bottom Frequency Values Row (No "Hz", just values)
            GeometryReader { geo in
                let width = geo.size.width
                let count = equalizerManager.bands.count
                let stepX = count > 1 ? (width - 2 * marginX) / CGFloat(count - 1) : 0

                ForEach(0..<count, id: \.self) { i in
                    let x = marginX + CGFloat(i) * stepX
                    let isDragging = activeDraggingBand == i

                    Text(equalizerManager.bands[i].displayLabel)
                        .font(.system(size: 10, weight: isDragging ? .heavy : .medium, design: .monospaced))
                        .foregroundStyle(isDragging ? Color.primary : (isEnabled ? Color.secondary : Color.secondary.opacity(0.5)))
                        .position(x: x, y: 8)
                }
            }
            .frame(height: 18)
        }
        .grayscale(isEnabled ? 0.0 : 1.0)
        .opacity(isEnabled ? 1.0 : 0.45)
        .animation(.easeInOut(duration: 0.25), value: isEnabled)
    }

    private func formatGain(_ gain: Double) -> String {
        if abs(gain) < 0.01 {
            return "0.0"
        } else if gain > 0 {
            return String(format: "+%.1f", gain)
        } else {
            return String(format: "%.1f", gain)
        }
    }
}

