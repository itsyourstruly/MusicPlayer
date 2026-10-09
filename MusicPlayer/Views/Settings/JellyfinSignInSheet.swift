import SwiftUI

/// Sign-in sheet for connecting to a Jellyfin server.
public struct JellyfinSignInSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var appTheme
    public let onConnected: (JellyfinServerLink) -> Void

    @State private var serverURLString: String = ""
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var isConnecting: Bool = false
    @State private var errorMessage: String? = nil

    public init(onConnected: @escaping (JellyfinServerLink) -> Void) {
        self.onConnected = onConnected
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let error = errorMessage {
                        VStack(alignment: .leading, spacing: 8) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("CONNECTION ERROR")
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundStyle(Color.red)

                                Text(error.uppercased())
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundStyle(Color.red.opacity(0.85))
                            }

                            if error.uppercased().contains("LOCAL NETWORK ACCESS IS OFF") {
                                #if os(iOS)
                                Button {
                                    if let url = URL(string: UIApplication.openSettingsURLString),
                                       UIApplication.shared.canOpenURL(url) {
                                        UIApplication.shared.open(url)
                                    }
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: "gear")
                                            .font(.system(size: 11, weight: .bold))
                                        Text("OPEN SETTINGS")
                                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    }
                                    .foregroundStyle(Color.white)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color.red.opacity(0.85))
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                }
                                .buttonStyle(.plain)
                                .padding(.top, 2)
                                #endif
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }

                    // Server URL Input
                    VStack(alignment: .leading, spacing: 6) {
                        Text("SERVER URL")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)

                        TextField("HTTP://192.168.1.100:8096", text: $serverURLString)
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            #endif
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(appTheme.secondaryBackgroundColor)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }

                    // Username Input
                    VStack(alignment: .leading, spacing: 6) {
                        Text("USERNAME")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)

                        TextField("USERNAME", text: $username)
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(appTheme.secondaryBackgroundColor)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }

                    // Password Input
                    VStack(alignment: .leading, spacing: 6) {
                        Text("PASSWORD")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)

                        SecureField("PASSWORD", text: $password)
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(appTheme.secondaryBackgroundColor)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }

                    // Connect Button
                    Button {
                        performConnect()
                    } label: {
                        HStack(spacing: 8) {
                            if isConnecting {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: Color.black))
                                    .scaleEffect(0.9)
                            }
                            Text(isConnecting ? "CONNECTING..." : "CONNECT")
                                .font(.system(size: 14, weight: .black, design: .monospaced))
                                .foregroundStyle(Color.black)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(isConnecting || serverURLString.trimmingCharacters(in: .whitespaces).isEmpty || username.trimmingCharacters(in: .whitespaces).isEmpty)
                    .opacity(isConnecting || serverURLString.trimmingCharacters(in: .whitespaces).isEmpty || username.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1.0)
                    .padding(.top, 10)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 20)
            }
            .background(appTheme.backgroundColor.ignoresSafeArea())
            .navigationTitle("CONNECT JELLYFIN")
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
        }
    }

    private func performConnect() {
        guard !isConnecting else { return }
        errorMessage = nil
        isConnecting = true
        HapticFeedback.lightImpact()

        guard let normalizedURL = JellyfinClient.normalizeServerURL(serverURLString) else {
            errorMessage = "INVALID SERVER ADDRESS"
            isConnecting = false
            return
        }

        let trimmedUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPass = password

        Task {
            do {
                let auth = try await JellyfinClient.shared.authenticate(
                    serverURL: normalizedURL,
                    username: trimmedUser,
                    password: trimmedPass
                )

                guard JellyfinKeychain.saveToken(auth.token, forServerId: auth.serverId, userId: auth.userId) else {
                    await MainActor.run {
                        self.isConnecting = false
                        HapticFeedback.notificationError()
                        self.errorMessage = "FAILED TO SAVE AUTHENTICATION TOKEN TO SECURE KEYCHAIN"
                    }
                    return
                }

                let link = JellyfinServerLink(
                    serverId: auth.serverId,
                    serverName: auth.serverName,
                    userId: auth.userId,
                    userName: trimmedUser,
                    serverURL: normalizedURL
                )

                await MainActor.run {
                    self.isConnecting = false
                    HapticFeedback.notificationSuccess()
                    dismiss()
                    onConnected(link)
                }
            } catch {
                await MainActor.run {
                    self.isConnecting = false
                    HapticFeedback.notificationError()
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }
}
