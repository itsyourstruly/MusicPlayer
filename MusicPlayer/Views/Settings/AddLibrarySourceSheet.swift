import SwiftUI

/// Sheet presenting choice of music sources: local folder / iCloud Drive or a media server.
public struct AddLibrarySourceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var appTheme
    public let onSelectLocalFolder: () -> Void
    public let onServerConnected: (ServerSourceLink) -> Void

    @State private var showingServerSignIn: Bool = false

    public init(
        onSelectLocalFolder: @escaping () -> Void,
        onServerConnected: @escaping (ServerSourceLink) -> Void
    ) {
        self.onSelectLocalFolder = onSelectLocalFolder
        self.onServerConnected = onServerConnected
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Sheet header (same style as EDIT PLAYLIST / ADD TO PLAYLIST)
            Text("ADD SOURCE")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.primary)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.top, 22)
                .padding(.bottom, 12)

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

                // Option 2: Media server (Jellyfin / Subsonic / Plex, auto-detected)
                Button {
                    HapticFeedback.selectionChanged()
                    showingServerSignIn = true
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("SERVER")
                                .font(.system(size: 14, weight: .black, design: .monospaced))
                                .foregroundStyle(Color.black)

                            Text("JELLYFIN, SUBSONIC (NAVIDROME) OR PLEX")
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
            .padding(.bottom, 20)
            .sheet(isPresented: $showingServerSignIn) {
                ServerSignInSheet { serverLink in
                    dismiss()
                    onServerConnected(serverLink)
                }
                .environment(\.appTheme, appTheme)
            }
        }
        .background(appTheme.backgroundColor.ignoresSafeArea())
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(appTheme.backgroundColor)
    }
}
