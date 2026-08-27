//
//  LibraryView.swift
//  MusicPlayer
//
//  Created by Principal Apple Software Engineer on 8/24/26.
//

import SwiftUI

/// Main Library screen with categorized navigation (Artists, Albums, Playlists, Tracks),
/// real-time search, and top-right Settings navigation trigger.
public struct LibraryView: View {
    @Bindable var libraryStore: LibraryStore
    @Bindable var playerService: AudioPlayerService
    public let onOpenSettings: () -> Void

    public init(
        libraryStore: LibraryStore,
        playerService: AudioPlayerService,
        onOpenSettings: @escaping () -> Void
    ) {
        self.libraryStore = libraryStore
        self.playerService = playerService
        self.onOpenSettings = onOpenSettings
    }

    public var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 16) {
                // Category Switcher
                categorySegmentPicker

                // Active Category Content
                switch libraryStore.selectedCategory {
                case .artists:
                    ArtistsListView(libraryStore: libraryStore, playerService: playerService)
                case .albums:
                    AlbumsListView(libraryStore: libraryStore, playerService: playerService)
                case .playlists:
                    PlaylistsListView(libraryStore: libraryStore, playerService: playerService)
                case .tracks:
                    AllTracksListView(libraryStore: libraryStore, playerService: playerService)
                }
            }
            .padding(.vertical, 12)
            .padding(.bottom, 140) // Padding for floating mini player and tab bar
        }
        .dismissKeyboardOnDrag()
        .background(libraryStore.settings.appTheme.backgroundColor.ignoresSafeArea())
        .navigationTitle("LIBRARY")
        .navigationBarTitleDisplayMode(.large)
        .searchable(
            text: $libraryStore.searchQuery,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: searchPrompt
        )
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.primary)
                }
            }
        }
    }

    private var searchPrompt: String {
        switch libraryStore.selectedCategory {
        case .artists:
            let count = libraryStore.artists.count
            return "FIND \(count) \(count == 1 ? "ARTIST" : "ARTISTS")"
        case .albums:
            let count = libraryStore.albums.count
            return "FIND \(count) \(count == 1 ? "ALBUM" : "ALBUMS")"
        case .playlists:
            let count = libraryStore.playlists.count
            return "FIND \(count) \(count == 1 ? "PLAYLIST" : "PLAYLISTS")"
        case .tracks:
            let count = libraryStore.tracks.count
            return "FIND \(count) \(count == 1 ? "TRACK" : "TRACKS")"
        }
    }

    private var headerSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 20, coordinateSpace: .local)
            .onEnded { value in
                let horizontalAmount = value.translation.width
                let verticalAmount = value.translation.height
                if abs(horizontalAmount) > abs(verticalAmount) {
                    if horizontalAmount < -30 {
                        // Swiped Left -> Next tab in carousel
                        HapticFeedback.selectionChanged()
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                            libraryStore.selectedCategory = libraryStore.selectedCategory.next
                        }
                    } else if horizontalAmount > 30 {
                        // Swiped Right -> Previous tab in carousel
                        HapticFeedback.selectionChanged()
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                            libraryStore.selectedCategory = libraryStore.selectedCategory.previous
                        }
                    }
                }
            }
    }

    private var categorySegmentPicker: some View {
        HStack(spacing: 8) {
            ForEach(LibraryCategory.allCases) { category in
                let isSelected = libraryStore.selectedCategory == category
                Button(action: {
                    HapticFeedback.selectionChanged()
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.8)) {
                        libraryStore.selectedCategory = category
                    }
                }) {
                    Text(category.title)
                        .font(.system(size: 13, weight: isSelected ? .bold : .regular, design: .monospaced))
                        .foregroundStyle(isSelected ? Color.primary : .secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .contentShape(Rectangle())
        .highPriorityGesture(headerSwipeGesture)
    }
}
