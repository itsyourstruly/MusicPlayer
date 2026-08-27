import SwiftUI

/// Modal sheet to initialize a new user playlist with custom name and description.
public struct CreatePlaylistSheet: View {
    @Bindable var libraryStore: LibraryStore
    @Environment(\.dismiss) private var dismiss

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
                Section("PLAYLIST DETAILS") {
                    TextField("PLAYLIST NAME", text: $playlistName)
                        .font(.system(size: 15, weight: .medium))

                    TextField("DESCRIPTION (OPTIONAL)", text: $playlistDescription, axis: .vertical)
                        .font(.system(size: 14))
                        .lineLimit(3...5)
                }
            }
            .navigationTitle("NEW PLAYLIST")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("CANCEL") {
                        dismiss()
                    }
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("ADD") {
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
