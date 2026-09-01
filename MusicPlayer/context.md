# MusicPlayer — Comprehensive Application Context & Architecture Specification

---

## 1. Executive Summary & Product Identity

### 1.1 What It Is
**MusicPlayer** is a high-performance, local-first, audiophile-grade music player and library management suite built natively for **iOS** and **macOS** using pure **Swift** and **SwiftUI**. 

Designed as a modern alternative to native and cloud streaming players, MusicPlayer emphasizes complete user ownership of local audio files (FLAC, ALAC, WAV, AAC, MP3, AIFF, M4A, OGG), uncompromising sound quality, zero-latency library indexing, deep metadata inspection, intelligent duplicate resolution, and a fluid, glassmorphic visual aesthetic.

### 1.2 Core Philosophy
- **Local-First & Privacy-Focused**: Direct access to local filesystem files and security-scoped folders without requiring cloud accounts or remote lock-in.
- **Audiophile Performance**: 10-band / parametric equalizer, real-time FFT spectrum visualizer, gapless playback, sample-accurate crossfade, and high-precision audio rendering.
- **Zero-Friction Search & Indexing**: Inverted posting-list search engine with $O(1)$ prefix lookups, 100ms debounce, 2-phase progressive streaming, and strict hierarchical relevance ranking.
- **Native Platform Fluency**: Tailored experiences for both platforms — a bottom interactive `MiniPlayer` with a gestural `FullScreenPlayerView` on iOS, and a dual-pane `NavigationSplitView` desktop console with dedicated menu bar commands on macOS.

---

## 2. What It Does (Functional Capabilities)

### 2.1 Audio Playback & Queue Management
- **Universal Format Playback**: High-resolution playback powered by `AVAudioEngine` and `AVAudioPlayerNode` supporting lossless and lossy codecs.
- **Gapless & Crossfading Engine**: Configurable crossfade duration (0–12s) with linear/equal-power curves and gapless transition detection.
- **Playback Position Preservation**: Remembers playback timestamps for long-form tracks, audiobooks, DJ sets, and podcasts exceeding a user-configurable duration threshold.
- **Intelligent Queue System**:
  - Play Next (immediate insertion at the top of the queue).
  - Play Later / Add to Queue (tail appending).
  - Smart Shuffle (Fisher-Yates shuffling with history preservation) and repeat modes (`off`, `all`, `one`).
- **System Integrations**: Complete Lock Screen and Control Center synchronization via `MPNowPlayingInfoCenter`, lock screen scrubber support, AirPlay output routing, and `MPRemoteCommandCenter` hardware/headphone media controls.

### 2.2 Library Organization & Multi-Tier Browsing
- **Hierarchical Classification**:
  - **Artists**: Categorized into Lead Studio Albums, Singles & EPs, Remixes/Alternates, and "Featured On" appearances. Supports complex artist parsing (e.g. `feat.`, `ft.`, `&`, `x`, `vs.`, `with`, `prod. by`).
  - **Albums**: Complete discography groupings with multi-disc support, high-resolution artwork rendering, and chronological sorting.
  - **Tracks**: Full track browser with sorting by Title, Artist, Album, Duration, File Size, Bitrate, Sample Rate, and Date Added.
  - **Playlists**: Custom playlist creation, track re-ordering, pinned favorites, and multi-track batch insertion.
- **Specialized Library Views**:
  - **Duplicates Resolver**: Acoustic fingerprint and tag analysis identifying duplicate tracks with 1-tap resolution (keep highest bitrate/lossless, remove lower quality copies).
  - **Unmatched Tracks**: Identifies tracks missing canonical metadata for targeted tagging.
  - **Verified Good Tracks**: High-confidence tagged and acoustic-verified track collections.

### 2.3 Intelligent Inverted Search Engine
- **Hierarchical Relevance Priority**:
  - **Tier 1 (Highest)**: Artist name matches (Exact $\rightarrow$ Prefix $\rightarrow$ Word-Boundary $\rightarrow$ Substring $\rightarrow$ Fuzzy).
  - **Tier 2 (Second)**: Album name matches.
  - **Tier 3 (Third)**: Track name matches.
- **Progressive 2-Phase Streaming**:
  - **Phase 1 (Immediate / <15ms)**: Rapid evaluation and emission of topmost direct matches.
  - **Phase 2 (Deep Full Hierarchy)**: Deep discography classification, playlist scanning, and ranked fuzzy matches.
- **Synthetic Tree Synthesis**: Generates virtual artist/album nodes for multi-artist, compilation ("Various Artists"), and soundtrack releases so every matched album is accessible in the "Show All" tree view.
- **Instant Non-Blocking Multi-Album Expansion**: Expanding/collapsing albums operates via `Set<String>` and `LazyVStack`, instantly rendering track lists with zero main-thread frame hitching.

### 2.4 Real-Time DSP, Equalizer & Visualizations
- **10-Band Graphic / Parametric Equalizer**: Low Shelf, High Shelf, and 8 peaking parametric bands with adjustable Center Frequencies, Gain ($\pm 12\text{ dB}$), and Q factors.
- **Built-in & Custom Presets**: Audiophile presets (Flat, Bass Boost, Treble Boost, Vocal Enhancer, Acoustic, Electronic, Rock, R&B, Classical, Jazz) + user custom curves stored in `AppSettings`.
- **Live FFT Audio Visualizer**: Real-time 64-band frequency spectrum analysis, animated waveform oscilloscope, and spectrogram generator.

### 2.5 Synchronized & Plain Lyrics
- **LRC Synchronized Lyrics**: Time-coded line-by-line and word-by-word karaoke tracking with active glow animation and auto-scroll.
- **Interactive Seeking**: Tapping any lyric line instantly seeks audio playback to that exact millisecond timestamp.
- **Unsynchronized Fallback**: Clean typographic plain-text lyrics presentation with user manual editing.

### 2.6 Metadata Enrichment, Shazam Recognition & File Tag Writing
- **Shazam Audio Fingerprinting**: Integrated `SHSession` acoustic matching to identify unrecognized or mislabeled local audio files directly from raw PCM audio buffers.
- **Online Catalog Discovery**: Online search and metadata retrieval via public music metadata APIs.
- **Lossless In-Place File Tag Writer**: `AudioFileMetadataWriter` writes ID3v2.4 / MP4 / Vorbis / FLAC comment tags directly to local audio files without re-encoding audio data.

---

## 3. How It Does It (Architecture & Technology Stack)

### 3.1 Architectural Foundation
- **Language**: Swift 6 with strict concurrency (`@MainActor`, `Sendable`, Swift Concurrency `async`/`await`, `TaskGroup`, `AsyncStream`).
- **Frameworks**: SwiftUI, AVFoundation (`AVAudioEngine`, `AVAudioPlayerNode`, `AVAudioUnitEQ`), Accelerate (vDSP FFT analysis), ShazamKit (`SHSession`), MediaPlayer (`MPNowPlayingInfoCenter`), UniformTypeIdentifiers.
- **State Management**: Modern Swift Observation framework (`@Observable`, `@Bindable`, `@State`).

```
┌────────────────────────────────────────────────────────────────────────┐
│                              VIEW LAYER                                │
│  iOS: TabView (HomeView, LibraryView) + MiniPlayer / FullScreenPlayer  │
│  macOS: MacMainView (Sidebar, NavigationSplitView, BottomConsole)      │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │ Observable Bindings
┌───────────────────────────────────▼────────────────────────────────────┐
│                             STORE & STATE                              │
│  LibraryStore (Tracks, Albums, Artists, Playlists, AppSettings)        │
│  AudioPlayerService (PlaybackState, Queue, Equalizer, AudioEngine)     │
└──────────┬────────────────────────┬─────────────────────────┬──────────┘
           │                        │                         │
┌──────────▼──────────┐  ┌──────────▼──────────┐   ┌──────────▼──────────┐
│    SEARCH ENGINE    │  │     AUDIO ENGINE    │   │  METADATA & FILES   │
│  Inverted N-Gram    │  │  AVAudioEngine      │   │  FastAudioMetadata  │
│  Prefix Index       │  │  AVAudioUnitEQ (DSP)│   │  AudioFileWriter    │
│  2-Phase Streaming  │  │  vDSP FFT Analyzer  │   │  ShazamKit Matcher  │
│  Fuzzy & Postings   │  │  NowPlaying Center  │   │  ArtworkCacheService│
└─────────────────────┘  └─────────────────────┘   └─────────────────────┘
```

### 3.2 Key Models & State Structures

| Model | File Location | Responsibility |
| :--- | :--- | :--- |
| `Track` | `Models/Track.swift` | Primary track model: ID, title, artist, album, albumArtist, duration, format, bitrate, sampleRate, year, discNumber, trackNumber, bookmark. |
| `Album` | `Models/Album.swift` | Album container: tracks list, normalizedTitle, artworkKey, year, discography classification (Studio, Single, Alternate, Featured). |
| `Artist` | `Models/Artist.swift` | Artist container: all albums, all tracks, normalizedName, collaboration parsing. |
| `Playlist` | `Models/Playlist.swift` | Playlist entity: ID, name, trackIDs, creationDate, custom artwork, isPinned. |
| `AppSettings` | `Models/AppSettings.swift` | User preferences: theme (`AppTheme`), crossfade duration, EQ settings, joined artists rules. |
| `EqualizerPreset` | `Models/EqualizerModels.swift`| EQ preset definition: 10 frequency band gains ($\pm 12\text{ dB}$) and Q factors. |
| `DuplicateGroup` | `Models/DuplicateGroup.swift` | Grouping of identical/similar tracks based on acoustic signature and duration. |
| `OnlineTrackMetadata`| `Models/OnlineTrackMetadata.swift`| Enriched metadata fetched from online catalog endpoints. |

### 3.3 Core Services Pipeline

1. **`LibraryStore` (`Services/LibraryStore.swift`)**:
   - Central observable source of truth for all library entities.
   - Handles security-scoped directory bookmarks (`SecurityScopedBookmark.swift`) to persist filesystem folder access across app restarts.
   - Manages scanning, file persistence, playlist CRUD, and settings sync.

2. **`AudioPlayerService` (`Services/AudioPlayerService.swift`)**:
   - Manages the `AVAudioEngine` graph connecting `AVAudioPlayerNode` $\rightarrow$ `AVAudioUnitEQ` $\rightarrow$ `AVAudioEngine.mainMixerNode` $\rightarrow$ output.
   - Implements gapless playback scheduling and crossfading using dual player node scheduling.
   - Updates `MPNowPlayingInfoCenter` artwork, title, elapsed time, and playback rate.

3. **`SearchEngine` (`Services/SearchEngine.swift`)**:
   - High-throughput isolated `actor` building inverted posting lists:
     - `artistPrefixIndex: [String: Set<Int>]`
     - `albumPrefixIndex: [String: Set<Int>]`
     - `trackPrefixIndex: [String: Set<Int>]`
   - Emits progressive results via `AsyncStream<GlobalSearchResults>`: Phase 1 direct matches $\rightarrow$ Phase 2 complete hierarchical tree.
   - Implements strict priority scoring: Artist ($1\text{M}$) $\rightarrow$ Album ($100\text{k}$) $\rightarrow$ Track ($10\text{k}$).

4. **`FastAudioMetadataReader` & `AudioFileMetadataWriter` (`Utilities/`, `Services/`)**:
   - Reads raw ID3v2.3/v2.4, MP4 (ilst), and Vorbis/FLAC metadata blocks without invoking slow AVAsset decoders.
   - Extracts embedded front cover art and writes lossless tags back to disk.

5. **`ArtworkCacheService` (`Services/ArtworkCacheService.swift`)**:
   - Two-tier LRU memory cache + disk cache for rendered artwork thumbnails.
   - Fast asynchronous image generation with blurhash and downsampling.

---

## 4. How It Looks (UI/UX & Visual Design Language)

### 4.1 Aesthetics & Design Philosophy
- **Glassmorphic Minimalism**: Translucent frosted backgrounds, delicate border strokes (`Color.primary.opacity(0.12)`), and high-contrast typography.
- **Dynamic Artwork Palette Extraction**: Automatically extracts dominant, vibrant, and background accent colors from the active album cover (`ArtworkColorExtractor.swift`) to bathe the `FullScreenPlayerView` and lyrics backdrop in subtle animated gradients.
- **Typography & Hierarchy**:
  - Headers & Track Titles: Clean system sans-serif (`.headline`, `.title3`, `.bold`).
  - Metadata, Timestamps & Bitrates: Monospaced numeric typography (`.system(size: 11, design: .monospaced)`).
  - Category Badges: Uppercase micro-tags (`.font(.system(size: 10, weight: .bold, design: .monospaced))`).

### 4.2 Primary Navigation Structure

#### iOS Layout
- **Root Screen (`ContentView.swift`)**:
  - **Tab 0: Home**: Pinned playlists, frequently played artists, recently added albums, quick shuffle triggers, and settings button.
  - **Tab 1: Library**: Category picker (Artists, Albums, Tracks, Playlists, Duplicates, Unmatched), global search entry bar, and list content.
  - **Floating MiniPlayer (`MiniPlayerView.swift`)**:
    - Docked directly above the TabBar with glassmorphic pill background.
    - Album artwork thumbnail, scrolling track title, artist name, Play/Pause toggle, and Next Track button.
    - Tap or swipe up to expand into `FullScreenPlayerView`.
  - **Full Screen Player (`FullScreenPlayerView.swift`)**:
    - Large rounded album artwork with shadow.
    - Multi-artist interactive pills (tap any collaborator to navigate directly to their artist profile).
    - Interactive waveform scrubber (`PlaybackProgressBar.swift`) with remaining/elapsed monospaced time codes.
    - Playback controls: Shuffle, Previous, Play/Pause (large circular button), Next, Repeat.
    - Action bar: Lyrics toggle, AirPlay output picker, Equalizer preset sheet, Queue inspector sheet.

#### macOS Layout (`MacMainView.swift`)
- **Desktop NavigationSplitView**:
  - **Sidebar (`MacSidebarView.swift`)**: Library categories (Home, Tracks, Artists, Albums, Playlists, Duplicates), pinned items, import folder button.
  - **Detail View**: Multi-column tabular layout (Track #, Title, Artist, Album, Duration, Bitrate) with sticky headers and column sorting.
  - **Bottom Playback Console (`MacPlaybackBarView.swift`)**: Persistent desktop player bar with full scrubber, volume slider, DSP toggle, AirPlay picker, and right-side queue inspector drawer.

---

## 5. Directory & File Structure Reference

```
MusicPlayer/
├── MusicPlayerApp.swift                  # Application entry point (@main)
├── ContentView.swift                     # Multiplatform coordinator (iOS TabView / macOS SplitView)
├── Info.plist / Entitlements             # Permissions & security-scoped entitlements
│
├── Models/                               # Data entities & transfer objects
│   ├── Track.swift                       # Audio track model & metadata
│   ├── Album.swift                       # Album model & discography categorization
│   ├── Artist.swift                      # Artist model & collaboration parsing
│   ├── Playlist.swift                    # Playlist container & track associations
│   ├── AppSettings.swift                 # User preferences, themes, crossfade settings
│   ├── EqualizerModels.swift             # 10-band EQ presets & parametric frequencies
│   ├── LyricsModels.swift                # Synchronized LRC and plain lyrics models
│   ├── DuplicateGroup.swift              # Duplicate track grouping models
│   ├── OnlineDiscoveryModels.swift       # Online catalog search models
│   └── PlaybackState.swift               # Playback status, repeat, shuffle modes
│
├── Services/                             # Core actors, engines, and background services
│   ├── LibraryStore.swift                # Main state store & persistence manager
│   ├── AudioPlayerService.swift          # Playback coordinator & AVAudioEngine controller
│   ├── AudioDSPProcessor.swift           # Real-time audio DSP, EQ, and vDSP FFT analysis
│   ├── SearchEngine.swift                # Inverted index search actor with 2-phase streaming
│   ├── EqualizerManager.swift            # EQ preset management & filter curves
│   ├── ArtworkCacheService.swift         # Multi-tier memory/disk image cache
│   ├── FastAudioMetadataReader.swift     # Low-level ID3/MP4/FLAC tag parser
│   ├── AudioFileMetadataWriter.swift     # In-place lossless audio file tag writer
│   ├── DuplicateDetectionService.swift   # Acoustic & tag duplicate detection engine
│   ├── MusicMetadataService.swift        # Metadata enrichment & fetching service
│   ├── ShazamRecognitionService.swift    # ShazamKit acoustic recognition
│   ├── OnlineDiscoveryService.swift      # Public music metadata API integration
│   └── BackgroundMetadataScanner.swift   # Asynchronous directory scanner
│
├── Views/                                # SwiftUI User Interface
│   ├── Home/                             # Home dashboard, pinned items, shuffle triggers
│   ├── Library/                          # Artists, Albums, Tracks, Playlists, GlobalSearchView
│   ├── Player/                           # MiniPlayer, FullScreenPlayer, Equalizer, Lyrics, Queue
│   ├── Components/                       # Reusable glassmorphic UI widgets, buttons, artwork
│   ├── Duplicates/                       # Duplicate resolution view & batch actions
│   ├── Settings/                         # App appearance, themes, playback settings
│   ├── OnlineDiscovery/                  # Online search & metadata match sheets
│   └── MacOS/                            # Dedicated macOS sidebar, playback bar, split views
│
└── Utilities/                            # Formatting, math, color, and parsing utilities
    ├── ArtistParser.swift                # Multi-artist & collaboration regex parser
    ├── ArtworkColorExtractor.swift       # CoreImage / Accelerate color palette extraction
    ├── FuzzySearch.swift                 # Fuzzy string matching & Levenshtein metrics
    ├── TimeFormatting.swift              # Monospaced minute/second timestamp formatters
    ├── ByteFormatting.swift              # File size, bitrate, and sample rate formatters
    ├── SecurityScopedBookmark.swift      # Sandbox directory persistence wrapper
    ├── Color+Semantic.swift              # Theme color definitions & glassmorphic styles
    └── AppLogger.swift                   # Unified OSLog diagnostics logger
```

---

## 6. Summary of Key Workflows

### 6.1 Audio Importing & Indexing Workflow
1. User selects a local directory via document picker.
2. `LibraryStore` creates a `SecurityScopedBookmark` to preserve sandbox permissions.
3. `BackgroundMetadataScanner` iterates through files using `FastAudioMetadataReader`.
4. Extracted tracks are grouped into `Album` and `Artist` entities and committed to `LibraryStore`.
5. `SearchEngine.updateIndex()` compiles inverted prefix posting lists asynchronously.

### 6.2 Search Query Execution Workflow
1. User types in search bar $\rightarrow$ 100ms debounce timer starts.
2. Keystroke immediately aborts previous queries via cooperative cancellation (`Task.isCancelled`).
3. `SearchEngine.searchStream()` begins:
   - **Phase 1**: Emits top-tier direct matches (Artists $\rightarrow$ Albums $\rightarrow$ Tracks) in $<15\text{ms}$.
   - **Phase 2**: Evaluates deep discography, fuzzy matches, and synthesizes multi-artist album nodes.
4. UI renders collapsed artist rows first, and cleanly auto-expands the topmost match after a 180ms settling window.

### 6.3 Playback & DSP Pipeline Workflow
1. User taps track $\rightarrow$ `AudioPlayerService.play(track:inQueue:)` sets up playback state.
2. Audio buffers flow through `AVAudioEngine` $\rightarrow$ `AVAudioUnitEQ` applying 10-band gain curves.
3. Tap on `mainMixerNode` feeds raw PCM into `AudioDSPProcessor` for live 64-band vDSP FFT visualization.
4. `MPNowPlayingInfoCenter` is populated with artwork, track title, artist, and duration for lock-screen controls.
