import SwiftUI

/// Sheet presenting choice of music sources: local folder / iCloud Drive or Jellyfin server.
public struct AddLibrarySourceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var appTheme
    public let onSelectLocalFolder: () -> Void
    public let onJellyfinConnected: (JellyfinServerLink) -> Void

    @State private var showingJellyfinSignIn: Bool = false

    public init(
        onSelectLocalFolder: @escaping () -> Void,
        onJellyfinConnected: @escaping (JellyfinServerLink) -> Void
    ) {
        self.onSelectLocalFolder = onSelectLocalFolder
        self.onJellyfinConnected = onJellyfinConnected
    }

    public var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Text("CHOOSE A SOURCE TYPE TO ADD TO YOUR MUSIC LIBRARY.")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)

                // Option 1: Local / iCloud Folder
                Button {
                    HapticFeedback.selectionChanged()
                    onSelectLocalFolder()
                    dismiss()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("LOCAL / ICLOUD FOLDER")
                                .font(.system(size: 14, weight: .black, design: .monospaced))
                                .foregroundStyle(Color.black)

                            Text("PLAY AUDIO FILES STORED ON DEVICE OR IN ICLOUD DRIVE")
                                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                                .foregroundStyle(Color.black.opacity(0.65))
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color.black.opacity(0.5))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // Option 2: Jellyfin Server
                Button {
                    HapticFeedback.selectionChanged()
                    showingJellyfinSignIn = true
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("JELLYFIN SERVER")
                                .font(.system(size: 14, weight: .black, design: .monospaced))
                                .foregroundStyle(Color.black)

                            Text("STREAM DIRECTLY FROM YOUR HOME MEDIA SERVER")
                                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                                .foregroundStyle(Color.black.opacity(0.65))
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color.black.opacity(0.5))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
            .background(appTheme.backgroundColor.ignoresSafeArea())
            .navigationTitle("ADD SOURCE")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("CANCEL") {
                        dismiss()
                    }
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(appTheme.accentColor)
                }
            }
            .sheet(isPresented: $showingJellyfinSignIn) {
                JellyfinSignInSheet { serverLink in
                    dismiss()
                    onJellyfinConnected(serverLink)
                }
                .environment(\.appTheme, appTheme)
            }
        }
    }
}
