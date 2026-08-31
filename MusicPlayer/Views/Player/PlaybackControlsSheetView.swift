import SwiftUI

/// Comprehensive playback adjustment sheet featuring Volume Booster (-8 dB to +15 dB with dynamic color gradient),
/// Playback Speed (0.25x to 2.0x), and interactive 10-Band Line Graph Equalizer with Global/Per-Track storage and Presets.
public struct PlaybackControlsSheetView: View {
    @Bindable var playerService: AudioPlayerService
    @Bindable var equalizerManager: EqualizerManager = EqualizerManager.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var appTheme
    @State private var showingPresetsSheet: Bool = false

    public init(playerService: AudioPlayerService) {
        self.playerService = playerService
        EqualizerManager.shared.playerService = playerService
    }

    public var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 24) {
                    // MARK: - 1. Volume Booster
                    volumeBoosterSection
                        .padding(.horizontal, 20)

                    // MARK: - 2. Playback Speed
                    playbackSpeedSection
                        .padding(.horizontal, 20)

                    // MARK: - 3. Sleep Timer
                    sleepTimerSection
                        .padding(.horizontal, 20)

                    // MARK: - 4. Equalizer 10-Band Line Graph (Edge-to-Edge)
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("EQUALIZER")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundStyle(.secondary)

                            Spacer()

                            Button(action: {
                                HapticFeedback.lightImpact()
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    equalizerManager.isEqualizerEnabled.toggle()
                                }
                            }) {
                                Text(equalizerManager.isEqualizerEnabled ? "EQUALIZER IS ENABLED" : "EQUALIZER IS DISABLED")
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundStyle(equalizerManager.isEqualizerEnabled ? Color.green : Color.red)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 20)

                        EqualizerGraphView(equalizerManager: equalizerManager)
                    }

                    // MARK: - 5. Equalizer Action Options & Presets
                    equalizerOptionsSection
                        .padding(.horizontal, 20)
                }
                .padding(.vertical, 16)
            }
            .background(appTheme.backgroundColor.ignoresSafeArea())
            .navigationTitle("PLAYBACK")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("DONE") {
                        dismiss()
                    }
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                }
            }
            .sheet(isPresented: $showingPresetsSheet) {
                EqualizerPresetsSheetView(equalizerManager: equalizerManager)
            }
            .onAppear {
                equalizerManager.playerService = playerService
            }
            .onChange(of: equalizerManager.playbackSpeed) { _, newSpeed in
                playerService.applyPlaybackSpeed(newSpeed)
            }
        }
    }

    // MARK: - Volume Booster Section

    private var volumeBoosterSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("VOLUME BOOSTER")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)

                Spacer()

                Button(action: {
                    if equalizerManager.volumeBoosterDB != 0.0 {
                        HapticFeedback.lightImpact()
                        equalizerManager.volumeBoosterDB = 0.0
                    }
                }) {
                    Text(formatDB(equalizerManager.volumeBoosterDB))
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(volumeBoosterColor)
                }
                .buttonStyle(.plain)
            }

            // Custom Slider with Accurately Positioned Reference Points (-8 dB, 0 dB at 34.8%, +15 dB)
            VStack(spacing: 6) {
                Slider(
                    value: $equalizerManager.volumeBoosterDB,
                    in: -8.0...15.0,
                    step: 0.5
                )
                .tint(volumeBoosterColor)

                // Marked Reference Points with 0 dB in its exact proportional position
                GeometryReader { geo in
                    let width = geo.size.width
                    let thumbRadius: CGFloat = 14.0
                    let trackWidth = max(1, width - 2 * thumbRadius)
                    let zeroX = thumbRadius + (8.0 / 23.0) * trackWidth

                    ZStack {
                        Text("-8 dB")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 2)

                        Button(action: {
                            if equalizerManager.volumeBoosterDB != 0.0 {
                                HapticFeedback.lightImpact()
                                equalizerManager.volumeBoosterDB = 0.0
                            }
                        }) {
                            Text("0 dB")
                                .font(.system(size: 9, weight: equalizerManager.volumeBoosterDB == 0 ? .bold : .medium, design: .monospaced))
                                .foregroundStyle(equalizerManager.volumeBoosterDB == 0 ? Color.green : .secondary)
                        }
                        .buttonStyle(.plain)
                        .position(x: zeroX, y: 7)

                        Text("+15 dB")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .padding(.trailing, 2)
                    }
                }
                .frame(height: 14)
            }
            .padding(.horizontal, 2)
        }
    }

    /// Dynamically interpolates slider color: -8 dB (blue) -> 0 dB (green) -> +15 dB (red)
    private var volumeBoosterColor: Color {
        let db = equalizerManager.volumeBoosterDB
        if db <= 0 {
            // Interpolate from -8 (Blue) to 0 (Green)
            let t = max(0.0, min(1.0, (db + 8.0) / 8.0))
            return Color(
                red: 0.25,
                green: 0.60 + 0.25 * t,
                blue: 1.00 - 0.45 * t
            )
        } else {
            // Interpolate from 0 (Green) to +15 (Red)
            let t = max(0.0, min(1.0, db / 15.0))
            return Color(
                red: 0.25 + 0.70 * t,
                green: 0.85 - 0.55 * t,
                blue: 0.55 - 0.10 * t
            )
        }
    }

    // MARK: - Playback Speed Section

    private var playbackSpeedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("PLAYBACK SPEED")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)

                Spacer()

                Button(action: {
                    if equalizerManager.playbackSpeed != 1.0 {
                        HapticFeedback.lightImpact()
                        equalizerManager.playbackSpeed = 1.0
                        playerService.applyPlaybackSpeed(1.0)
                    }
                }) {
                    Text(formatRate(equalizerManager.playbackSpeed))
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(equalizerManager.playbackSpeed != 1.0 ? appTheme.accentColor : .secondary)
                }
                .buttonStyle(.plain)
            }

            // Custom Slider with Accurately Positioned Reference Points (0.25x, 1.0x at 42.9%, 2.0x)
            VStack(spacing: 6) {
                Slider(
                    value: $equalizerManager.playbackSpeed,
                    in: 0.25...2.0,
                    step: 0.25
                )
                .tint(appTheme.accentColor)

                GeometryReader { geo in
                    let width = geo.size.width
                    let thumbRadius: CGFloat = 14.0
                    let trackWidth = max(1, width - 2 * thumbRadius)
                    let oneX = thumbRadius + (3.0 / 7.0) * trackWidth

                    ZStack {
                        Text("0.25x")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 2)

                        Button(action: {
                            if equalizerManager.playbackSpeed != 1.0 {
                                HapticFeedback.lightImpact()
                                equalizerManager.playbackSpeed = 1.0
                                playerService.applyPlaybackSpeed(1.0)
                            }
                        }) {
                            Text("1.0x")
                                .font(.system(size: 9, weight: equalizerManager.playbackSpeed == 1.0 ? .bold : .medium, design: .monospaced))
                                .foregroundStyle(equalizerManager.playbackSpeed == 1.0 ? Color.blue : .secondary)
                        }
                        .buttonStyle(.plain)
                        .position(x: oneX, y: 7)

                        Text("2.0x")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .padding(.trailing, 2)
                    }
                }
                .frame(height: 14)
            }
            .padding(.horizontal, 2)
        }
    }

    // MARK: - Sleep Timer Section

    private var sleepTimerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("SLEEP TIMER")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)

                Spacer()

                Button(action: {
                    HapticFeedback.lightImpact()
                    withAnimation(.easeInOut(duration: 0.2)) {
                        playerService.toggleSleepTimer(defaultMinutes: 30)
                    }
                }) {
                    Text(playerService.isSleepTimerEnabled ? "\(Int(playerService.sleepTimerMinutes)) MIN" : "OFF")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(playerService.isSleepTimerEnabled ? appTheme.accentColor : .secondary)
                }
                .buttonStyle(.plain)
            }

            if playerService.isSleepTimerEnabled {
                VStack(spacing: 6) {
                    Slider(
                        value: Binding(
                            get: { playerService.sleepTimerMinutes },
                            set: { newMinutes in
                                if newMinutes <= 0 {
                                    playerService.cancelSleepTimer()
                                } else {
                                    playerService.setSleepTimer(minutes: newMinutes)
                                }
                            }
                        ),
                        in: 0...90,
                        step: 5
                    )
                    .tint(appTheme.accentColor)

                    GeometryReader { geo in
                        let width = geo.size.width
                        let thumbRadius: CGFloat = 14.0
                        let trackWidth = max(1, width - 2 * thumbRadius)
                        let midX = thumbRadius + (45.0 / 90.0) * trackWidth

                        ZStack {
                            Text("0 MIN")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.leading, 2)

                            Button(action: {
                                HapticFeedback.lightImpact()
                                playerService.setSleepTimer(minutes: 45)
                            }) {
                                Text("45 MIN")
                                    .font(.system(size: 9, weight: playerService.sleepTimerMinutes == 45 ? .bold : .medium, design: .monospaced))
                                    .foregroundStyle(playerService.sleepTimerMinutes == 45 ? appTheme.accentColor : .secondary)
                            }
                            .buttonStyle(.plain)
                            .position(x: midX, y: 7)

                            Text("90 MIN")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .padding(.trailing, 2)
                        }
                    }
                    .frame(height: 14)
                }
                .padding(.horizontal, 2)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: - Equalizer Options Section

    private var equalizerOptionsSection: some View {
        VStack(spacing: 12) {
            // SET GLOBAL DEFAULT Button
            Button(action: {
                HapticFeedback.lightImpact()
                equalizerManager.setGlobalDefault()
            }) {
                HStack {
                    Text("SET GLOBAL DEFAULT")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(equalizerManager.isGlobalDefaultActive ? Color.blue : Color.secondary)
                    Spacer()
                    if equalizerManager.isGlobalDefaultActive {
                        Text("ACTIVE")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.blue)
                    }
                }
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)

            // SET FOR [track name] Button
            if let currentTrack = playerService.currentTrack {
                let isTrackSaved = equalizerManager.isCustomEQSaved(for: currentTrack.id)

                Button(action: {
                    HapticFeedback.lightImpact()
                    if isTrackSaved {
                        equalizerManager.removeCustomEQForTrack(trackID: currentTrack.id)
                    } else {
                        equalizerManager.setCustomEQForTrack(trackID: currentTrack.id)
                    }
                }) {
                    HStack {
                        Text("SET FOR \(currentTrack.title.uppercased())")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundStyle(isTrackSaved ? Color.blue : Color.secondary)
                            .lineLimit(1)

                        Spacer()

                        if isTrackSaved {
                            Text("SAVED")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(Color.blue)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }

            // PRESETS Button
            Button(action: {
                HapticFeedback.selectionChanged()
                showingPresetsSheet = true
            }) {
                HStack {
                    Text("PRESETS")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.secondary)
                    Spacer()
                    Text("CHOOSE →")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.blue)
                }
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
        }
    }

    private func formatDB(_ db: Double) -> String {
        if abs(db) < 0.01 {
            return "0.0 dB"
        } else if db > 0 {
            return String(format: "+%.1f dB", db)
        } else {
            return String(format: "%.1f dB", db)
        }
    }

    private func formatRate(_ rate: Double) -> String {
        if rate == Double(Int(rate)) {
            return "\(Int(rate))x"
        } else {
            return String(format: "%.2fx", rate)
        }
    }
}
