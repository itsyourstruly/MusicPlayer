import SwiftUI

/// Sheet listing user-saved equalizer presets: SAVE stores the current EQ; long-press a preset to RENAME or DELETE.
public struct EqualizerPresetsSheetView: View {
    @Bindable var equalizerManager: EqualizerManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var appTheme
    @State private var renameTarget: EqualizerPreset? = nil
    @State private var renameText: String = ""

    public init(equalizerManager: EqualizerManager) {
        self.equalizerManager = equalizerManager
    }

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        HapticFeedback.notificationSuccess()
                        equalizerManager.saveCurrentAsPreset()
                    } label: {
                        Text("SAVE")
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundStyle(appTheme.accentColor)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                Section {
                    if equalizerManager.userPresets.isEmpty {
                        Text("NO SAVED PRESETS")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(equalizerManager.userPresets) { preset in
                            presetRow(preset)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("PRESETS")
            .navigationBarTitleDisplayMode(.inline)
            .alert("RENAME", isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
            )) {
                TextField("NAME", text: $renameText)
                Button("CANCEL", role: .cancel) { renameTarget = nil }
                Button("SAVE") {
                    if let target = renameTarget {
                        equalizerManager.renamePreset(id: target.id, to: renameText)
                    }
                    renameTarget = nil
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Preset Row

    private func presetRow(_ preset: EqualizerPreset) -> some View {
        let isApplied = matchesCurrentEQ(preset)

        return Button(action: {
            HapticFeedback.selectionChanged()
            equalizerManager.applyPreset(preset)
            dismiss()
        }) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center) {
                    Text(preset.name)
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundStyle(isApplied ? appTheme.accentColor : Color.primary)
                        .lineLimit(2)

                    Spacer()

                    if isApplied {
                        Text("ACTIVE")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(appTheme.accentColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(appTheme.accentColor.opacity(0.12))
                            .clipShape(Capsule())
                    } else {
                        Text("APPLY")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.secondary)
                    }
                }

                miniLineGraphView(gains: preset.gains, isApplied: isApplied)
                    .padding(.top, 4)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("RENAME") {
                renameText = preset.name
                renameTarget = preset
            }
            Button("DELETE", role: .destructive) {
                HapticFeedback.selectionChanged()
                equalizerManager.deletePreset(id: preset.id)
            }
        }
    }

    /// Miniature 10-band interactive line graph preview illustrating exact frequency response curve
    private func miniLineGraphView(gains: [Double], isApplied: Bool) -> some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            let count = gains.count
            let marginX: CGFloat = 8.0
            let insetY: CGFloat = 5.0
            let usableWidth = max(1, width - 2 * marginX)
            let usableHeight = max(1, height - 2 * insetY)
            let stepX = count > 1 ? usableWidth / CGFloat(count - 1) : 0

            let nodePoints = (0..<count).map { i -> CGPoint in
                let x = marginX + CGFloat(i) * stepX
                let gain = gains[i]
                let norm = (gain - (-12.0)) / 24.0 // 0.0 at -12 dB, 0.5 at 0 dB, 1.0 at +12 dB
                let y = (height - insetY) - (CGFloat(max(0.0, min(1.0, norm))) * usableHeight)
                return CGPoint(x: x, y: y)
            }

            ZStack {
                // Background Card
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(appTheme.secondaryBackgroundColor.opacity(0.35))

                // Faint 0 dB Center Reference Line
                Path { path in
                    let zeroY = insetY + usableHeight * 0.50
                    path.move(to: CGPoint(x: 4, y: zeroY))
                    path.addLine(to: CGPoint(x: width - 4, y: zeroY))
                }
                .stroke(Color.white.opacity(0.10), style: StrokeStyle(lineWidth: 0.8, dash: [3, 3]))

                // Translucent Gradient Fill Area under the curve
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
                        colors: isApplied
                            ? [
                                appTheme.accentColor.opacity(0.22),
                                appTheme.accentColor.opacity(0.05),
                                Color.clear
                            ]
                            : [
                                appTheme.accentColor.opacity(0.15),
                                appTheme.accentColor.opacity(0.03),
                                Color.clear
                            ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                // Smooth Continuous Bezier Curve
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
                    appTheme.accentColor,
                    style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round)
                )

                // Discrete 10-Band Node Points
                ForEach(0..<count, id: \.self) { i in
                    let pt = nodePoints[i]
                    Circle()
                        .fill(Color.white)
                        .frame(width: 4, height: 4)
                        .overlay(
                            Circle()
                                .stroke(appTheme.accentColor, lineWidth: 1.2)
                        )
                        .position(x: pt.x, y: pt.y)
                }

                // Frequency Range Markers (32 Hz on left, 16k on right)
                HStack {
                    Text("32")
                        .font(.system(size: 7, weight: .bold, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Text("0 dB")
                        .font(.system(size: 7, weight: .regular, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Text("16k")
                        .font(.system(size: 7, weight: .bold, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 6)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 1)
            }
        }
        .frame(height: 38)
    }

    /// Checks whether preset gains exactly match current equalizer gains
    private func matchesCurrentEQ(_ preset: EqualizerPreset) -> Bool {
        guard equalizerManager.isEqualizerEnabled, preset.gains.count == equalizerManager.bands.count else {
            return false
        }
        for i in 0..<preset.gains.count {
            if abs(preset.gains[i] - equalizerManager.bands[i].gainDB) > 0.01 {
                return false
            }
        }
        return true
    }
}
