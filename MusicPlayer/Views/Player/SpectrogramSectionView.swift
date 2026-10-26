import SwiftUI
import CoreGraphics

/// Tap-to-render full-track spectrogram for the File Info sheet. Results live only in view state.
struct SpectrogramSectionView: View {
    let track: Track

    @Environment(\.appTheme) private var appTheme
    @Environment(\.displayScale) private var displayScale

    private enum Phase {
        case idle
        case downloading
        case rendering(Double)
        case done(SpectrogramResult)
        case unsupported
        case failed(String)
    }

    @State private var phase: Phase = .idle
    @State private var renderToken: Int?
    @State private var plotWidth: CGFloat = 0
    @State private var isTranscodedCopy = false

    private let plotHeight: CGFloat = 200

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("SPECTROGRAM")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(appTheme.accentColor)
                Spacer()
                if let r = result {
                    Text(String(format: "EXTENDS UP TO %.1f KHZ", r.extendsToHz / 1000))
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                if isTranscodedCopy {
                    Text("TRANSCODED COPY")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            plotArea
                .frame(maxWidth: .infinity)
                .frame(height: plotHeight)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { plotWidth = $0 }
        }
        .task(id: renderToken, priority: .utility) {
            guard renderToken != nil else { return }
            await run()
        }
    }

    // MARK: - Plot

    @ViewBuilder
    private var plotArea: some View {
        ZStack {
            Rectangle().fill(appTheme.secondaryBackgroundColor)
            switch phase {
            case .idle:
                Button { start() } label: {
                    placeholder("TAP TO RENDER SPECTROGRAM")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            case .downloading:
                placeholder("DOWNLOADING...")
            case .rendering(let p):
                VStack(spacing: 8) {
                    placeholder("RENDERING... \(Int(p * 100))%")
                    ProgressView(value: p).tint(appTheme.accentColor).frame(width: 140)
                }
            case .done(let result):
                spectrogramImage(result)
            case .unsupported:
                retryable("UNSUPPORTED FORMAT")
            case .failed(let message):
                retryable(message)
            }
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundStyle(appTheme.accentColor.opacity(0.8))
    }

    private func retryable(_ text: String) -> some View {
        Button { start() } label: {
            VStack(spacing: 4) {
                placeholder(text)
                Text("TAP TO RETRY")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Axes

    private var result: SpectrogramResult? {
        if case .done(let r) = phase { return r }
        return nil
    }

    /// Shown 1:1 (image pixels == points x displayScale) so nothing is resampled; only if the layout
    /// changed since rendering (e.g. rotation) is it stretched with high-quality filtering.
    @ViewBuilder
    private func spectrogramImage(_ result: SpectrogramResult) -> some View {
        let w = Int((plotWidth * displayScale).rounded())
        let h = Int((plotHeight * displayScale).rounded())
        if result.image.width == w && result.image.height == h {
            Image(decorative: result.image, scale: displayScale)
                .interpolation(.none)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Image(decorative: result.image, scale: displayScale)
                .resizable()
                .interpolation(.high)
        }
    }

    // MARK: - Rendering

    private func start() {
        renderToken = (renderToken ?? 0) + 1
    }

    private var isServerTrack: Bool {
        track.isJellyfinItem || track.metadataSource == .server
    }

    private func run() async {
        let columns = Int((plotWidth * displayScale).rounded())
        let height = Int((plotHeight * displayScale).rounded())
        guard columns > 0 else { phase = .failed("NO LAYOUT"); return }
        isTranscodedCopy = false

        var tempURL: URL?
        defer { if let tempURL { try? FileManager.default.removeItem(at: tempURL) } }

        let sourceURL: URL
        if let downloaded = JellyfinDownloadManager.shared.localFileURL(for: track.id),
           FileManager.default.fileExists(atPath: downloaded.path) {
            sourceURL = downloaded
            isTranscodedCopy = isServerTrack && TranscodePolicy.requiresTranscode(track)
        } else if track.url.isFileURL {
            sourceURL = SecurityScopedBookmark.shared.ensureAccess(for: track.url, folderID: track.folderID)
        } else if let cached = ServerTranscodeCache.cachedFileURL(for: track) {
            sourceURL = cached
            isTranscodedCopy = true
        } else if isServerTrack {
            let sources = AudioPlayerService.shared?.serverSources ?? []
            guard let link = sources.first(where: { $0.id == track.folderID }) ?? sources.first,
                  let request = try? ServerStreamRequestBuilder.request(for: track, link: link, purpose: .download, caller: "spectrogram")
            else { phase = .failed("NO SERVER"); return }
            isTranscodedCopy = TranscodePolicy.requiresTranscode(track)
            phase = .downloading
            do {
                let (downloaded, response) = try await URLSession.shared.download(for: request)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    try? FileManager.default.removeItem(at: downloaded)
                    phase = .failed("HTTP \(http.statusCode)")
                    return
                }
                let ext = (response.suggestedFilename.map { ($0 as NSString).pathExtension }).flatMap { $0.isEmpty ? nil : $0 }
                    ?? (isTranscodedCopy ? "m4a" : (track.fileInfo?.fileExtension ?? track.url.pathExtension))
                let target = FileManager.default.temporaryDirectory
                    .appendingPathComponent("spectrogram-\(UUID().uuidString)")
                    .appendingPathExtension(ext)
                do { try FileManager.default.moveItem(at: downloaded, to: target) } catch {
                    try? FileManager.default.removeItem(at: downloaded)
                    throw error
                }
                tempURL = target
                sourceURL = target
            } catch {
                if Task.isCancelled { phase = .idle } else { phase = .failed("DOWNLOAD FAILED") }
                return
            }
        } else {
            phase = .unsupported
            return
        }

        phase = .rendering(0)
        let (stream, continuation) = AsyncStream.makeStream(of: Double.self, bufferingPolicy: .bufferingNewest(1))
        async let rendered = SpectrogramRenderer.render(url: sourceURL, columns: columns, height: height,
                                                         progress: continuation)
        for await p in stream { phase = .rendering(p) }
        do {
            phase = .done(try await rendered)
        } catch is SpectrogramError {
            phase = .unsupported
        } catch {
            phase = Task.isCancelled ? .idle : .failed("RENDER FAILED")
        }
    }
}
