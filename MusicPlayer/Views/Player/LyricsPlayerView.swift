import SwiftUI

/// High-polish, synchronized lyrics rendering component supporting tracked (LRC) glowing sync
/// and solid scrollable lyrics with Transparent Compact and Floating Glass Expanded presentation modes.
public struct LyricsPlayerView: View {
    public let rawLyrics: String?
    public let trackURL: URL?
    public let playerService: AudioPlayerService?
    private let explicitCurrentTime: TimeInterval?
    public let duration: TimeInterval
    public let foregroundColor: Color
    public let secondaryForegroundColor: Color
    public let onSeek: (TimeInterval) -> Void
    public let onNoLyricsAvailable: (() -> Void)?
    public let onLyricsAvailabilityChanged: ((Bool) -> Void)?
    public let onExpansionChanged: ((Bool) -> Void)?

    private var currentTime: TimeInterval {
        playerService?.currentTime ?? explicitCurrentTime ?? 0
    }

    @State private var isExpanded: Bool = false
    @State private var parsed: ParsedLyrics = .empty
    @State private var activeLineIndex: Int = 0
    @State private var lyricsLoadTask: Task<Void, Never>? = nil
    @State private var isLoadingLyrics: Bool = false

    public init(
        playerService: AudioPlayerService,
        rawLyrics: String? = nil,
        trackURL: URL? = nil,
        duration: TimeInterval,
        foregroundColor: Color = .white,
        secondaryForegroundColor: Color = .white.opacity(0.65),
        onSeek: @escaping (TimeInterval) -> Void,
        onNoLyricsAvailable: (() -> Void)? = nil,
        onLyricsAvailabilityChanged: ((Bool) -> Void)? = nil,
        onExpansionChanged: ((Bool) -> Void)? = nil
    ) {
        self.playerService = playerService
        self.explicitCurrentTime = nil
        self.rawLyrics = rawLyrics
        self.trackURL = trackURL
        self.duration = duration
        self.foregroundColor = foregroundColor
        self.secondaryForegroundColor = secondaryForegroundColor
        self.onSeek = onSeek
        self.onNoLyricsAvailable = onNoLyricsAvailable
        self.onLyricsAvailabilityChanged = onLyricsAvailabilityChanged
        self.onExpansionChanged = onExpansionChanged
    }

    public init(
        rawLyrics: String? = nil,
        trackURL: URL? = nil,
        currentTime: TimeInterval,
        duration: TimeInterval,
        foregroundColor: Color = .white,
        secondaryForegroundColor: Color = .white.opacity(0.65),
        onSeek: @escaping (TimeInterval) -> Void,
        onNoLyricsAvailable: (() -> Void)? = nil,
        onLyricsAvailabilityChanged: ((Bool) -> Void)? = nil,
        onExpansionChanged: ((Bool) -> Void)? = nil
    ) {
        self.playerService = nil
        self.explicitCurrentTime = currentTime
        self.rawLyrics = rawLyrics
        self.trackURL = trackURL
        self.duration = duration
        self.foregroundColor = foregroundColor
        self.secondaryForegroundColor = secondaryForegroundColor
        self.onSeek = onSeek
        self.onNoLyricsAvailable = onNoLyricsAvailable
        self.onLyricsAvailabilityChanged = onLyricsAvailabilityChanged
        self.onExpansionChanged = onExpansionChanged
    }

    public var body: some View {
        GeometryReader { geo in
            let totalHeight = geo.size.height
            let availableWidth = max(50, geo.size.width - 40)
            // In compact mode: lyrics sit clearly above the duration progress bar (~240pt bottom clearance)
            // In expanded mode: lyrics float over the entire fullscreen player (~8pt bottom margin)
            let cardHeight: CGFloat = isExpanded ? max(220, totalHeight - 8) : max(100, totalHeight - 240)

            ZStack(alignment: .top) {
                // Background Tap Target when Expanded to collapse back to compact mode
                if isExpanded {
                    Color.black.opacity(0.001)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            HapticFeedback.lightImpact()
                            collapse()
                        }
                }

                // Floating Lyrics Container (Transparent Compact vs Expanded Glass Card)
                lyricsCard(height: cardHeight, availableWidth: availableWidth)
                    .frame(maxWidth: .infinity)
                    .frame(height: cardHeight)
                    .zIndex(isExpanded ? 10 : 1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .onAppear {
            fetchLyricsIfNeeded()
        }
        .onChange(of: rawLyrics) { _, _ in
            fetchLyricsIfNeeded()
        }
        .onChange(of: trackURL) { _, _ in
            fetchLyricsIfNeeded()
        }
        .onChange(of: currentTime) { _, newTime in
            updateActiveIndex(for: newTime)
        }
        .onDisappear {
            lyricsLoadTask?.cancel()
        }
    }

    private func fetchLyricsIfNeeded() {
        lyricsLoadTask?.cancel()
        if let raw = rawLyrics, !raw.isEmpty {
            let parsedResult = LyricsParser.parse(raw)
            if case .empty = parsedResult {
                self.parsed = .empty
                self.isLoadingLyrics = false
                onLyricsAvailabilityChanged?(false)
                onNoLyricsAvailable?()
            } else {
                self.parsed = parsedResult
                self.isLoadingLyrics = false
                onLyricsAvailabilityChanged?(true)
                updateActiveIndex(for: currentTime)
            }
            return
        }

        guard let url = trackURL else {
            self.parsed = .empty
            self.isLoadingLyrics = false
            onLyricsAvailabilityChanged?(false)
            onNoLyricsAvailable?()
            return
        }

        isLoadingLyrics = true
        lyricsLoadTask = Task { @MainActor in
            let extracted = await AudioScannerService.extractLyrics(from: url)
            if !Task.isCancelled {
                let parsedResult = LyricsParser.parse(extracted)
                if case .empty = parsedResult {
                    self.parsed = .empty
                    self.isLoadingLyrics = false
                    onLyricsAvailabilityChanged?(false)
                    onNoLyricsAvailable?()
                } else {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        self.parsed = parsedResult
                        self.isLoadingLyrics = false
                        onLyricsAvailabilityChanged?(true)
                        updateActiveIndex(for: currentTime)
                    }
                }
            }
        }
    }

    // MARK: - Direct Clean Transitions

    private func expand() {
        guard !isExpanded else { return }
        onExpansionChanged?(true)
        withAnimation(.spring(response: 0.46, dampingFraction: 0.88, blendDuration: 0.08)) {
            isExpanded = true
        }
    }

    private func collapse() {
        guard isExpanded else { return }
        onExpansionChanged?(false)
        withAnimation(.spring(response: 0.44, dampingFraction: 0.88, blendDuration: 0.08)) {
            isExpanded = false
        }
    }

    // MARK: - Lyrics Card View

    private func lyricsCard(height: CGFloat, availableWidth: CGFloat) -> some View {
        VStack(spacing: 0) {
            // Main scrollable lyrics content
            Group {
                switch parsed {
                case .tracked(let lines):
                    trackedLyricsScrollView(lines: lines, availableWidth: availableWidth)

                case .solid(let lines, _):
                    solidLyricsScrollView(lines: lines, availableWidth: availableWidth)

                case .empty:
                    emptyLyricsView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Bottom Pull Bar / Grab Handle
            bottomPullBar
        }
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .background {
            // iOS 26 Floating Glass Background — smoothly fades in/out with GPU compositingGroup
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                stops: [
                                    .init(color: Color.white.opacity(0.38), location: 0.0),
                                    .init(color: Color.white.opacity(0.10), location: 0.25),
                                    .init(color: Color.white.opacity(0.04), location: 0.70),
                                    .init(color: Color.white.opacity(0.20), location: 1.0)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.75
                        )
                }
                .shadow(color: Color.black.opacity(0.18), radius: 22, x: 0, y: 11)
                .shadow(color: Color.black.opacity(0.06), radius: 6, x: 0, y: 2)
                .compositingGroup()
                .opacity(isExpanded ? 1.0 : 0.0)
                .scaleEffect(isExpanded ? 1.0 : 0.98)
        }
        .contentShape(Rectangle())
    }

    // MARK: - Bottom Pull Bar

    private var bottomPullBar: some View {
        Button(action: {
            HapticFeedback.lightImpact()
            if isExpanded {
                collapse()
            } else {
                expand()
            }
        }) {
            VStack(spacing: 4) {
                Capsule()
                    .fill(Color.white.opacity(isExpanded ? 0.40 : 0.22))
                    .frame(width: 36, height: 4.0)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { value in
                    if isExpanded {
                        if value.translation.height > 20 {
                            HapticFeedback.lightImpact()
                            collapse()
                        }
                    } else {
                        if value.translation.height < -15 {
                            HapticFeedback.lightImpact()
                            expand()
                        }
                    }
                }
        )
    }

    // MARK: - Tracked (Synchronized LRC) Lyrics

    private func trackedLyricsScrollView(lines: [LyricLine], availableWidth: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    // Top breathing spacer
                    Spacer().frame(height: isExpanded ? 24 : 16)

                    ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                        let isActive = index == activeLineIndex
                        let isNext = (index == activeLineIndex + 1)
                        let isAnticipating = isNext && (line.timestamp.map { currentTime >= ($0 - 0.70) } ?? false)
                        let distance = abs(index - activeLineIndex)
                        let activeFontSize: CGFloat = 20.5
                        let fontSize: CGFloat = isActive ? 20.5 : 17.0

                        LyricLineRow(
                            text: line.text,
                            isActive: isActive,
                            isAnticipating: isAnticipating,
                            distance: distance,
                            fontSize: fontSize,
                            activeFontSize: activeFontSize,
                            availableWidth: availableWidth,
                            foregroundColor: foregroundColor,
                            secondaryForegroundColor: secondaryForegroundColor,
                            onTap: {
                                HapticFeedback.lightImpact()
                                if let ts = line.timestamp {
                                    onSeek(ts)
                                }
                            }
                        )
                        .padding(.vertical, 2)
                        .id(line.id)
                    }

                    // Bottom breathing spacer
                    Spacer().frame(height: isExpanded ? 44 : 24)
                }
                .padding(.leading, 8)
                .padding(.trailing, 8)
            }
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.0),
                        .init(color: .black, location: 0.08),
                        .init(color: .black, location: 0.88),
                        .init(color: .clear, location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .onAppear {
                if lines.indices.contains(activeLineIndex) {
                    Task { @MainActor in
                        proxy.scrollTo(lines[activeLineIndex].id, anchor: UnitPoint(x: 0.5, y: isExpanded ? 0.32 : 0.35))
                    }
                }
            }
            .onChange(of: activeLineIndex) { _, newIndex in
                if lines.indices.contains(newIndex) {
                    withAnimation(.spring(response: 0.72, dampingFraction: 0.86, blendDuration: 0.15)) {
                        proxy.scrollTo(lines[newIndex].id, anchor: UnitPoint(x: 0.5, y: isExpanded ? 0.32 : 0.35))
                    }
                }
            }
        }
    }

    // MARK: - Solid (Plain Text) Lyrics

    private func solidLyricsScrollView(lines: [String], availableWidth: CGFloat) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                Spacer().frame(height: isExpanded ? 18 : 12)

                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    let activeFontSize: CGFloat = 17.0

                    LyricLineRow(
                        text: line,
                        isActive: true,
                        isAnticipating: false,
                        distance: 0,
                        fontSize: activeFontSize,
                        activeFontSize: activeFontSize,
                        availableWidth: availableWidth,
                        foregroundColor: foregroundColor,
                        secondaryForegroundColor: foregroundColor.opacity(0.88),
                        onTap: {}
                    )
                    .padding(.vertical, 2)
                }

                Spacer().frame(height: isExpanded ? 26 : 14)
            }
            .padding(.leading, 8)
            .padding(.trailing, 8)
        }
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: .black, location: 0.08),
                    .init(color: .black, location: 0.88),
                    .init(color: .clear, location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var emptyLyricsView: some View {
        VStack(spacing: 8) {
            if isLoadingLyrics {
                Text("SCANNING FOR LYRICS...")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundStyle(secondaryForegroundColor)

                Text("Inspecting audio stream tags and sidecar files...")
                    .font(.system(size: 12))
                    .foregroundStyle(secondaryForegroundColor.opacity(0.7))
                    .multilineTextAlignment(.center)
            } else {
                Text("NO LYRICS AVAILABLE")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundStyle(secondaryForegroundColor)

                Text("This audio file does not contain embedded or sidecar lyrics.")
                    .font(.system(size: 12))
                    .foregroundStyle(secondaryForegroundColor.opacity(0.7))
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 32)
    }

    // MARK: - Synchronized Time Calculations

    private func updateActiveIndex(for time: TimeInterval) {
        guard case .tracked(let lines) = parsed, !lines.isEmpty else { return }

        var targetIndex = 0
        for (idx, line) in lines.enumerated() {
            if let ts = line.timestamp, time >= (ts - 0.08) {
                targetIndex = idx
            }
        }

        if activeLineIndex != targetIndex {
            activeLineIndex = targetIndex
        }
    }
}

// MARK: - Glass Background Modifier Extension

public extension View {
    /// Applies native iOS 26 floating glass container styling with precision specular rim, crystal depth, and soft atmospheric shadows.
    func glass(cornerRadius: CGFloat = 24) -> some View {
        self.background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                stops: [
                                    .init(color: Color.white.opacity(0.38), location: 0.0),
                                    .init(color: Color.white.opacity(0.10), location: 0.25),
                                    .init(color: Color.white.opacity(0.04), location: 0.70),
                                    .init(color: Color.white.opacity(0.20), location: 1.0)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.75
                        )
                }
                .shadow(color: Color.black.opacity(0.18), radius: 22, x: 0, y: 11)
                .shadow(color: Color.black.opacity(0.06), radius: 6, x: 0, y: 2)
                .compositingGroup()
        }
    }
}

// MARK: - Lyric Line Row View

/// High-performance, lightweight lyric line renderer prioritizing slow, smooth, fluid motion and clean typography.
private struct LyricLineRow: View {
    let text: String
    let isActive: Bool
    let isAnticipating: Bool
    let distance: Int
    let fontSize: CGFloat
    let activeFontSize: CGFloat
    let availableWidth: CGFloat
    let foregroundColor: Color
    let secondaryForegroundColor: Color
    let onTap: () -> Void

    @State private var isPressed: Bool = false

    private var isBright: Bool {
        isActive || isAnticipating
    }

    private var targetOpacity: Double {
        if isActive {
            return 1.0
        }
        if isAnticipating {
            return 0.92
        }
        if distance == 1 {
            return 0.46
        }
        return 0.24
    }

    private var targetRowWidth: CGFloat {
        guard availableWidth > 0 else { return .infinity }
        let ratio = max(0.5, min(1.0, fontSize / activeFontSize))
        return isActive ? availableWidth : (availableWidth * ratio)
    }

    var body: some View {
        Button(action: onTap) {
            Text(text)
                .font(.system(size: fontSize, weight: isActive ? .heavy : .bold, design: .default))
                .lineSpacing(4.0)
                .foregroundStyle(isBright ? foregroundColor : secondaryForegroundColor)
                .opacity(targetOpacity)
                .shadow(color: Color.white.opacity(isActive ? 0.30 : 0.0), radius: 0.8, x: 0, y: -0.8)
                .shadow(color: Color.black.opacity(isActive ? 0.40 : 0.15), radius: 2.0, x: 0, y: 1.5)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: targetRowWidth, alignment: .leading)
                .scaleEffect(isPressed ? 0.98 : (isActive ? 1.015 : 0.985), anchor: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.spring(response: 0.58, dampingFraction: 0.82, blendDuration: 0.12), value: isActive)
                .animation(.spring(response: 0.20, dampingFraction: 0.80), value: isPressed)
                .animation(.easeInOut(duration: 0.70), value: isAnticipating)
                .animation(.easeInOut(duration: 0.75), value: distance)
        }
        .buttonStyle(.plain)
    }
}
