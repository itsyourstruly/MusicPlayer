import SwiftUI
import AVFoundation

/// Lightweight manager handling 30-second online audio previews.
@MainActor
@Observable
public final class OnlineAudioPreviewManager {
    public static let shared = OnlineAudioPreviewManager()

    // Controls is playing
    public var isPlaying: Bool = false
    // Unique identifier
    public var currentTrackID: String? = nil
    public var progress: Double = 0.0

    private var player: AVPlayer? = nil
    private var timeObserver: Any? = nil

    // Initialize with configured properties
    private init() {}

    // Toggle preview
    public func togglePreview(track: OnlineTrackItem) {
        if currentTrackID == track.id && isPlaying {
            pause()
            return
        }

        // Ensure preconditions are met before proceeding
        guard let previewURL = track.previewURL else { return }
        play(url: previewURL, trackID: track.id)
    }

    // Play
    public func play(url: URL, trackID: String) {
        stop()

        currentTrackID = trackID
        isPlaying = true
        progress = 0.0

        // Player item
        let playerItem = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: playerItem)

        // Track playback progress
        timeObserver = player?.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            // Ensure preconditions are met before proceeding
            guard let self = self, let duration = self.player?.currentItem?.duration.seconds, duration > 0 else { return }
            self.progress = min(1.0, time.seconds / duration)
        }

        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            self?.stop()
        }

        player?.play()
    }

    // Pause
    public func pause() {
        player?.pause()
        isPlaying = false
    }

    // Stop
    public func stop() {
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        player?.pause()
        player = nil
        isPlaying = false
        currentTrackID = nil
        progress = 0.0
    }
}

// MARK: - Artist Detail View (Matches Library ArtistDetailView Layout)

// OnlineArtistDetailView representation
public struct OnlineArtistDetailView: View {
    // Primary artist name
    let artist: OnlineArtistItem
    @State private var detailedArtist: OnlineArtistItem? = nil
    @State private var isLoading: Bool = true
    @State private var previewManager = OnlineAudioPreviewManager.shared
    @Environment(\.appTheme) private var appTheme

    // Initialize with configured properties
    public init(artist: OnlineArtistItem) {
        self.artist = artist
    }

    private var ownAlbums: [OnlineAlbumItem] {
        // Ensure preconditions are met before proceeding
        guard let list = detailedArtist?.albums else { return artist.albums }
        // Albums
        let albums = list.filter { ($0.trackCount ?? 1) > 2 }
        return albums.sorted { a, b in
            // Y a
            let yA = a.releaseYear ?? 0
            // Y b
            let yB = b.releaseYear ?? 0
            if yA != yB { return yA > yB }
            return a.title < b.title
        }
    }

    private var ownSingles: [OnlineAlbumItem] {
        // Ensure preconditions are met before proceeding
        guard let list = detailedArtist?.albums else { return [] }
        // Singles
        let singles = list.filter { ($0.trackCount ?? 1) <= 2 }
        return singles.sorted { a, b in
            // Y a
            let yA = a.releaseYear ?? 0
            // Y b
            let yB = b.releaseYear ?? 0
            if yA != yB { return yA > yB }
            return a.title < b.title
        }
    }

    private var featuredAlbums: [OnlineAlbumItem] {
        detailedArtist?.featuredAlbums ?? artist.featuredAlbums
    }

    // Main view layout structure
    public var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                // Header (Matching Library ArtistDetailView)
                headerView

                // Biography & Overview Card
                if let bio = detailedArtist?.biography, !bio.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("BIOGRAPHY & OVERVIEW")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)

                        Text(bio)
                            .font(.system(size: 13))
                            .lineSpacing(4)
                            .foregroundStyle(Color.primary)
                    }
                    .padding(14)
                    .background(appTheme.secondaryBackgroundColor)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                // 1. Studio Albums Horizontal Row
                if !ownAlbums.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("ALBUMS (\(ownAlbums.count))")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(ownAlbums) { album in
                                    NavigationLink(destination: OnlineAlbumDetailView(album: album)) {
                                        albumCard(album: album)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }

                // 2. Singles & EPs Horizontal Row
                if !ownSingles.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("SINGLES (\(ownSingles.count))")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(ownSingles) { single in
                                    NavigationLink(destination: OnlineAlbumDetailView(album: single)) {
                                        albumCard(album: single)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }

                // 3. Featured On Horizontal Row (Below Singles)
                if !featuredAlbums.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("FEATURED ON (\(featuredAlbums.count))")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(featuredAlbums) { featAlbum in
                                    NavigationLink(destination: OnlineAlbumDetailView(album: featAlbum)) {
                                        VStack(alignment: .leading, spacing: 6) {
                                            AsyncImage(url: featAlbum.artworkURL) { phase in
                                                switch phase {
                                                case .success(let image):
                                                    image
                                                        .resizable()
                                                        .aspectRatio(1.0, contentMode: .fill)
                                                default:
                                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                        .fill(appTheme.secondaryBackgroundColor)
                                                }
                                            }
                                            .frame(width: 110, height: 110)
                                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(featAlbum.title)
                                                    .font(.system(size: 12, weight: .bold))
                                                    .foregroundStyle(Color.primary)
                                                    .lineLimit(1)

                                                Text(featAlbum.artistName)
                                                    .font(.system(size: 10))
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(1)

                                                Text(featAlbum.formattedReleaseDate)
                                                    .font(.system(size: 10, design: .monospaced))
                                                    .foregroundStyle(.tertiary)
                                                    .lineLimit(1)
                                            }
                                            .frame(width: 110, alignment: .leading)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }

                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                }
            }
            .padding(16)
            .padding(.bottom, 120)
        }
        .background(appTheme.backgroundColor.ignoresSafeArea())
        .navigationTitle(artist.name)
        .navigationBarTitleDisplayMode(.inline)
        // Async lifecycle task
        .task {
            self.detailedArtist = await OnlineDiscoveryService.shared.fetchArtistDetails(artist: artist)
            self.isLoading = false
        }
        // Triggered when view disappears
        .onDisappear {
            previewManager.stop()
        }
    }

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("ARTIST")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)

            Text(artist.name)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(Color.primary)

            // Album count
            let albumCount = ownAlbums.count
            // Single count
            let singleCount = ownSingles.count
            // Feat count
            let featCount = featuredAlbums.count
            Text("\(albumCount) ALBUMS · \(singleCount) SINGLES · \(featCount) FEATURED")
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    // Album card
    private func albumCard(album: OnlineAlbumItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            AsyncImage(url: album.artworkURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(1.0, contentMode: .fill)
                default:
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(appTheme.secondaryBackgroundColor)
                }
            }
            .frame(width: 110, height: 110)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(album.title)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)

                Text(album.formattedReleaseDate)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 110, alignment: .leading)
        }
    }
}

// MARK: - Album Detail View (Matches Library AlbumDetailView Layout)

// OnlineAlbumDetailView representation
public struct OnlineAlbumDetailView: View {
    // Album title
    let album: OnlineAlbumItem
    @State private var detailedAlbum: OnlineAlbumItem? = nil
    @State private var isLoading: Bool = true
    @State private var previewManager = OnlineAudioPreviewManager.shared
    @Environment(\.appTheme) private var appTheme
    @Environment(LibraryStore.self) private var libraryStore: LibraryStore?

    @State private var showingEnrichmentSheet: Bool = false
    @State private var albumDiffs: [MetadataDiff] = []
    @State private var isPreparingEnrichment: Bool = false
    @State private var showNoLocalTracksAlert: Bool = false

    // Initialize with configured properties
    public init(album: OnlineAlbumItem) {
        self.album = album
    }

    private var currentAlbum: OnlineAlbumItem {
        detailedAlbum ?? album
    }

    private var totalDuration: TimeInterval {
        currentAlbum.tracklist.reduce(0) { $0 + $1.duration }
    }

    // Main view layout structure
    public var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                // Header (Matching Library AlbumDetailView 124x124 layout)
                headerView

                // Description / Overview Card
                if let desc = currentAlbum.description, !desc.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("ALBUM OVERVIEW")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)

                        Text(desc)
                            .font(.system(size: 13))
                            .lineSpacing(4)
                            .foregroundStyle(Color.primary)
                    }
                    .padding(14)
                    .background(appTheme.secondaryBackgroundColor)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                // Detailed Specifications & Credits Card
                VStack(alignment: .leading, spacing: 8) {
                    Text("PRODUCTION & SPECIFICATIONS")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)

                    VStack(spacing: 6) {
                        specRow(label: "RELEASE DATE", value: currentAlbum.formattedReleaseDate)
                        if let label = currentAlbum.recordLabel, !label.isEmpty {
                            specRow(label: "RECORD LABEL", value: label)
                        }
                        // Musical genre classification
                        if let genre = currentAlbum.genre, !genre.isEmpty {
                            specRow(label: "GENRE", value: genre)
                        }
                        if let count = currentAlbum.trackCount ?? (currentAlbum.tracklist.isEmpty ? nil : currentAlbum.tracklist.count) {
                            specRow(label: "TRACK COUNT", value: "\(count) TRACKS")
                        }
                        if let copyright = currentAlbum.copyright, !copyright.isEmpty {
                            specRow(label: "COPYRIGHT", value: copyright)
                        }
                    }
                }
                .padding(14)
                .background(appTheme.secondaryBackgroundColor.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                // Tracklist Section (Matching Library AlbumDetailView Tracklist)
                if !currentAlbum.tracklist.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("TRACKLIST (\(currentAlbum.tracklist.count))")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 2)

                        LazyVStack(spacing: 4) {
                            ForEach(currentAlbum.tracklist) { track in
                                NavigationLink(destination: OnlineTrackDetailView(track: track)) {
                                    trackRow(track: track)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                }
            }
            .padding(16)
            .padding(.bottom, 120)
        }
        .background(appTheme.backgroundColor.ignoresSafeArea())
        .navigationTitle(album.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(action: {
                        prepareEnrichment()
                    }) {
                        Label("DOWNLOAD METADATA TO LOCAL FILES", systemImage: "arrow.down.doc.fill")
                    }
                } label: {
                    if isPreparingEnrichment {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "square.and.arrow.down.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(appTheme.accentColor)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        // Modal presentation sheet
        .sheet(isPresented: $showingEnrichmentSheet) {
            if let store = libraryStore {
                MetadataComparisonListView(libraryStore: store, customDiffs: albumDiffs)
            }
        }
        .alert("NO LOCAL TRACKS FOUND", isPresented: $showNoLocalTracksAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("No local audio files for \"\(currentAlbum.title)\" by \"\(currentAlbum.artistName)\" were found in your library.")
        }
        // Async lifecycle task
        .task {
            self.detailedAlbum = await OnlineDiscoveryService.shared.fetchAlbumDetails(album: album)
            self.isLoading = false
        }
        // Triggered when view disappears
        .onDisappear {
            previewManager.stop()
        }
    }

    // Prepare enrichment
    private func prepareEnrichment() {
        // Ensure preconditions are met before proceeding
        guard let store = libraryStore else { return }
        isPreparingEnrichment = true
        Task {
            // Diffs
            let diffs = await store.checkMetadataForOnlineAlbum(title: currentAlbum.title, artist: currentAlbum.artistName)
            await MainActor.run {
                self.isPreparingEnrichment = false
                if diffs.isEmpty {
                    self.showNoLocalTracksAlert = true
                } else {
                    self.albumDiffs = diffs
                    self.showingEnrichmentSheet = true
                }
            }
        }
    }

    private var headerView: some View {
        HStack(alignment: .top, spacing: 16) {
            AsyncImage(url: currentAlbum.artworkURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(1.0, contentMode: .fill)
                default:
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(appTheme.secondaryBackgroundColor)
                }
            }
            .frame(width: 124, height: 124)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: Color.black.opacity(0.12), radius: 8, x: 0, y: 4)

            VStack(alignment: .leading, spacing: 6) {
                Text("ALBUM")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)

                Text(currentAlbum.title)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Color.primary)
                    .lineLimit(2)

                NavigationLink(destination: OnlineArtistDetailView(artist: OnlineArtistItem(id: currentAlbum.artistId ?? currentAlbum.artistName, name: currentAlbum.artistName))) {
                    Text(currentAlbum.artistName)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(appTheme.accentColor)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 2) {
                    // Count
                    let count = currentAlbum.trackCount ?? (currentAlbum.tracklist.isEmpty ? nil : currentAlbum.tracklist.count)
                    if let count = count {
                        Text("\(count) TRACKS")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }

                    if totalDuration > 0 {
                        Text(TimeFormatting.formatSummaryDuration(seconds: totalDuration))
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color.primary)
                    }
                }
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // Track row
    private func trackRow(track: OnlineTrackItem) -> some View {
        HStack(spacing: 12) {
            // Track artwork thumbnail
            AsyncImage(url: track.artworkURL ?? currentAlbum.artworkURL) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().aspectRatio(contentMode: .fill)
                default:
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(appTheme.secondaryBackgroundColor)
                }
            }
            .frame(width: 42, height: 42)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)

                // Show all artists and features on track
                Text(track.artistName)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            // 30s Preview Button
            if track.previewURL != nil {
                Button(action: {
                    previewManager.togglePreview(track: track)
                }) {
                    Text(previewManager.currentTrackID == track.id && previewManager.isPlaying ? "PAUSE" : "PREVIEW")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3.5)
                        .background(appTheme.accentColor.opacity(0.18))
                        .foregroundStyle(appTheme.accentColor)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            // Track duration
            Text(TimeFormatting.formatTrackDuration(track.duration))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(appTheme.backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // Spec row
    private func specRow(label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.primary)
                .multilineTextAlignment(.trailing)
        }
    }
}

// MARK: - Track Detail View

// OnlineTrackDetailView representation
public struct OnlineTrackDetailView: View {
    // Track
    let track: OnlineTrackItem
    @State private var detailedTrack: OnlineTrackItem? = nil
    @State private var previewManager = OnlineAudioPreviewManager.shared
    @Environment(\.appTheme) private var appTheme

    // Initialize with configured properties
    public init(track: OnlineTrackItem) {
        self.track = track
    }

    // Main view layout structure
    public var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                // Header Artwork
                VStack(spacing: 14) {
                    AsyncImage(url: (detailedTrack?.artworkURL ?? track.artworkURL)) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().aspectRatio(1.0, contentMode: .fill)
                        default:
                            RoundedRectangle(cornerRadius: 10).fill(appTheme.secondaryBackgroundColor)
                        }
                    }
                    .frame(width: 180, height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .shadow(color: Color.black.opacity(0.15), radius: 8, x: 0, y: 4)

                    VStack(spacing: 4) {
                        Text(track.title)
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(Color.primary)
                            .multilineTextAlignment(.center)

                        // Interactive Artist Navigation Link
                        NavigationLink(destination: OnlineArtistDetailView(artist: OnlineArtistItem(id: track.artistName, name: track.artistName))) {
                            Text(track.artistName)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(appTheme.accentColor)
                        }
                        .buttonStyle(.plain)

                        // Interactive Album Navigation Link
                        NavigationLink(destination: OnlineAlbumDetailView(album: OnlineAlbumItem(id: track.albumId ?? track.albumTitle, title: track.albumTitle, artistName: track.artistName, artworkURL: track.artworkURL))) {
                            Text(track.albumTitle)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 10)

                // 30-Second Audio Preview Player
                if (detailedTrack?.previewURL ?? track.previewURL) != nil {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("30-SECOND AUDIO PREVIEW")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(.secondary)

                            Spacer()

                            Text(previewManager.currentTrackID == track.id && previewManager.isPlaying ? "STREAMING" : "READY")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundStyle(appTheme.accentColor)
                        }

                        ProgressView(value: previewManager.currentTrackID == track.id ? previewManager.progress : 0.0)
                            .tint(appTheme.accentColor)

                        Button(action: {
                            previewManager.togglePreview(track: detailedTrack ?? track)
                        }) {
                            HStack {
                                Spacer()
                                Text(previewManager.currentTrackID == track.id && previewManager.isPlaying ? "PAUSE PREVIEW" : "PLAY PREVIEW")
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                Spacer()
                            }
                        }
                        .buttonStyle(TypographicButtonStyle(variant: .primary, size: .small))
                    }
                    .padding(14)
                    .background(appTheme.secondaryBackgroundColor)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                // Deep Song Credits & Production Section
                VStack(alignment: .leading, spacing: 10) {
                    Text("SONG CREDITS & PRODUCTION")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)

                    VStack(spacing: 8) {
                        if let producers = detailedTrack?.producers, !producers.isEmpty {
                            specRow(label: "PRODUCERS", value: producers)
                        }
                        if let composers = (detailedTrack?.composer ?? track.composer), !composers.isEmpty {
                            specRow(label: "COMPOSERS & WRITERS", value: composers)
                        }
                        if let performers = detailedTrack?.performers, !performers.isEmpty {
                            specRow(label: "PERFORMERS", value: performers)
                        }
                        if let label = (detailedTrack?.recordLabel ?? track.recordLabel), !label.isEmpty {
                            specRow(label: "RECORD LABEL", value: label)
                        }
                        specRow(label: "RELEASE DATE", value: (detailedTrack ?? track).formattedReleaseDate)
                        if let bpm = detailedTrack?.bpm, bpm > 0 {
                            specRow(label: "TEMPO", value: "\(bpm) BPM")
                        }
                    }
                    .padding(14)
                    .background(appTheme.secondaryBackgroundColor)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                // Track Specifications Grid
                VStack(alignment: .leading, spacing: 10) {
                    Text("AUDIO SPECIFICATIONS")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)

                    VStack(spacing: 8) {
                        specRow(label: "DURATION", value: TimeFormatting.formatTrackDuration(track.duration))
                        if let g = (detailedTrack?.genre ?? track.genre) {
                            specRow(label: "GENRE", value: g)
                        }
                        if let t = (detailedTrack?.trackNumber ?? track.trackNumber), t > 0 {
                            // Total
                            let total = (detailedTrack?.totalTracks ?? track.totalTracks).map { " of \($0)" } ?? ""
                            specRow(label: "TRACK NUMBER", value: "\(t)\(total)")
                        }
                        if let d = (detailedTrack?.discNumber ?? track.discNumber), d > 0 {
                            specRow(label: "DISC NUMBER", value: "\(d)")
                        }
                        specRow(label: "EXPLICIT RATING", value: (detailedTrack?.isExplicit ?? track.isExplicit) ? "EXPLICIT (PARENTAL ADVISORY)" : "CLEAN")
                        specRow(label: "AUDIO STREAM", value: "AAC 256 kbps (Apple Digital Master)")
                    }
                    .padding(14)
                    .background(appTheme.secondaryBackgroundColor)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
            .padding(16)
            .padding(.bottom, 120)
        }
        .background(appTheme.backgroundColor.ignoresSafeArea())
        .navigationTitle(track.title)
        .navigationBarTitleDisplayMode(.inline)
        // Async lifecycle task
        .task {
            self.detailedTrack = await OnlineDiscoveryService.shared.fetchTrackDetails(track: track)
        }
        // Triggered when view disappears
        .onDisappear {
            previewManager.stop()
        }
    }

    // Spec row
    private func specRow(label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.primary)
                .multilineTextAlignment(.trailing)
        }
    }
}
