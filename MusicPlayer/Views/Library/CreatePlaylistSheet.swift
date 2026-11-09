import SwiftUI

/// Modal sheet to initialize a new user playlist with custom name and description.
public struct CreatePlaylistSheet: View {
    @Bindable var libraryStore: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isCapitalizationEnabled) private var isCaps: Bool

    @State private var playlistName: String = ""
    @State private var playlistDescription: String = ""

    // Initialize with configured properties
    public init(libraryStore: LibraryStore) {
        self.libraryStore = libraryStore
    }

    // Controls is valid
    private var isValid: Bool {
        !playlistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // Main view layout structure
    public var body: some View {
        NavigationStack {
            Form {
                Section(AppCapitalization.format("PLAYLIST DETAILS", enabled: isCaps)) {
                    TextField(AppCapitalization.format("PLAYLIST NAME", enabled: isCaps), text: $playlistName)
                        .font(.system(size: 15, weight: .medium))

                    TextField(AppCapitalization.format("DESCRIPTION (OPTIONAL)", enabled: isCaps), text: $playlistDescription, axis: .vertical)
                        .font(.system(size: 14))
                        .lineLimit(3...5)
                }
            }
            .navigationTitle(AppCapitalization.format("NEW PLAYLIST", enabled: isCaps))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(AppCapitalization.format("CANCEL", enabled: isCaps)) {
                        dismiss()
                    }
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button(AppCapitalization.format("ADD", enabled: isCaps)) {
                        createAndDismiss()
                    }
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .disabled(!isValid)
                }
            }
        }
        .presentationDetents([.medium])
    }

    // Create and dismiss
    private func createAndDismiss() {
        // Ensure preconditions are met before proceeding
        guard isValid else { return }
        libraryStore.createPlaylist(name: playlistName, description: playlistDescription)
        dismiss()
    }
}
