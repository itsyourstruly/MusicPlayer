import SwiftUI
import AuthenticationServices

/// Sign-in sheet for any media server. The type is auto-detected from the URL (Jellyfin, Subsonic/OpenSubsonic,
/// Plex) with a manual override; Plex signs in through plex.tv.
public struct ServerSignInSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var appTheme
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    public let onConnected: (ServerSourceLink) -> Void

    private enum TypeChoice: String, CaseIterable, Identifiable {
        case auto = "AUTO", jellyfin = "JELLYFIN", subsonic = "SUBSONIC", plex = "PLEX"
        var id: String { rawValue }
        var kind: ServerKind? {
            switch self {
            case .auto: return nil
            case .jellyfin: return .jellyfin
            case .subsonic: return .subsonic
            case .plex: return .plex
            }
        }
    }

    @State private var typeChoice: TypeChoice = .auto
    @State private var serverURLString: String = ""
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var apiKey: String = ""
    @State private var detection: ServerProbe.Detection? = nil
    @State private var detectedInput: String = ""
    @State private var isDetecting: Bool = false
    @State private var isConnecting: Bool = false
    @State private var errorMessage: String? = nil
    @State private var plexChoices: [PlexAccountAuth.Server] = []
    @State private var plexAccount: (token: PlexAccountAuth.AccountToken, user: (id: String, name: String))? = nil

    public init(onConnected: @escaping (ServerSourceLink) -> Void) {
        self.onConnected = onConnected
    }

    /// Kind the form is currently set up for: manual override, else the auto-detected kind.
    private var effectiveKind: ServerKind? {
        typeChoice.kind ?? (detectedInput == trimmedURL ? detection?.kind : nil)
    }

    private var isPlexMode: Bool { effectiveKind == .plex }
    private var trimmedURL: String { serverURLString.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedUser: String { username.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedAPIKey: String { apiKey.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var showsAPIKey: Bool {
        effectiveKind == .subsonic && (typeChoice == .subsonic || detection?.supportsAPIKey == true)
    }

    private var canConnect: Bool {
        if isConnecting { return false }
        if isPlexMode { return true }
        return !trimmedURL.isEmpty && (!trimmedUser.isEmpty || !trimmedAPIKey.isEmpty)
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let error = errorMessage {
                        errorBox(error)
                    }

                    // Server type (auto-detect with manual override)
                    VStack(alignment: .leading, spacing: 6) {
                        fieldLabel("SERVER TYPE")
                        HStack(spacing: 6) {
                            ForEach(TypeChoice.allCases) { choice in
                                Button {
                                    HapticFeedback.selectionChanged()
                                    typeChoice = choice
                                    errorMessage = nil
                                } label: {
                                    Text(choice.rawValue)
                                        .font(.system(size: 11, weight: .black, design: .monospaced))
                                        .foregroundStyle(typeChoice == choice ? Color.black : Color.white)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.7)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 9)
                                        .background(typeChoice == choice ? Color.white : appTheme.secondaryBackgroundColor)
                                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        if typeChoice == .auto {
                            Text(detectionLine)
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }

                    if typeChoice != .plex {
                        VStack(alignment: .leading, spacing: 6) {
                            fieldLabel("SERVER URL")
                            styledField(TextField("HTTP://192.168.1.100", text: $serverURLString), isURL: true)
                        }
                    }

                    if isPlexMode {
                        plexSection
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            fieldLabel("USERNAME")
                            styledField(TextField("USERNAME", text: $username), isURL: false)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            fieldLabel("PASSWORD")
                            styledField(SecureField("PASSWORD", text: $password), isURL: false)
                        }
                        if showsAPIKey {
                            VStack(alignment: .leading, spacing: 6) {
                                fieldLabel("API KEY (OPTIONAL, REPLACES PASSWORD)")
                                styledField(SecureField("API KEY", text: $apiKey), isURL: false)
                            }
                        }
                        primaryButton(isConnecting ? "CONNECTING..." : "CONNECT") { performConnect() }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 20)
            }
            .background(appTheme.backgroundColor.ignoresSafeArea())
            .navigationTitle("CONNECT SERVER")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("CANCEL") { dismiss() }
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(appTheme.accentColor)
                }
            }
            .task(id: trimmedURL) {
                // Debounced background probe while typing (auto mode only).
                guard typeChoice == .auto, !trimmedURL.isEmpty else { return }
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard !Task.isCancelled else { return }
                await runDetection()
            }
        }
    }

    // MARK: - Plex

    @ViewBuilder
    private var plexSection: some View {
        if plexChoices.isEmpty {
            Text("PLEX SIGNS IN THROUGH YOUR PLEX ACCOUNT. ALL SERVERS SHARED WITH YOU ARE AVAILABLE.")
                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
            primaryButton(isConnecting ? "WAITING FOR PLEX..." : "SIGN IN WITH PLEX") { performPlexSignIn() }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                fieldLabel("CHOOSE A PLEX SERVER")
                ForEach(plexChoices) { server in
                    primaryButton(server.name.uppercased() + (server.owned ? "" : " (SHARED)")) { finishPlex(server) }
                }
            }
        }
    }

    private func performPlexSignIn() {
        guard !isConnecting else { return }
        errorMessage = nil
        isConnecting = true
        HapticFeedback.lightImpact()
        Task { @MainActor in
            do {
                let pin = try await PlexAccountAuth.createPin()
                guard let url = PlexAccountAuth.authURL(for: pin) else { throw JellyfinClientError.invalidURL }
                // Returns when plex.tv redirects to the forwardUrl, or when the user closes the page.
                _ = try? await webAuthenticationSession.authenticate(
                    using: url,
                    callbackURLScheme: PlexClient.callbackScheme,
                    preferredBrowserSession: .shared
                )
                var token: PlexAccountAuth.AccountToken?
                for _ in 0..<5 where token == nil {
                    token = try? await PlexAccountAuth.checkPin(pin)
                    if token == nil { try? await Task.sleep(nanoseconds: 1_000_000_000) }
                }
                guard let token else { throw JellyfinClientError.authenticationFailed("PLEX SIGN-IN WAS NOT COMPLETED") }
                let user = try await PlexAccountAuth.user(token: token.token)
                let servers = try await PlexAccountAuth.servers(token: token.token)
                    .sorted { ($0.owned ? 0 : 1, $0.name) < ($1.owned ? 0 : 1, $1.name) }
                guard !servers.isEmpty else { throw JellyfinClientError.networkError("NO PLEX SERVERS ON THIS ACCOUNT") }
                plexAccount = (token, user)
                isConnecting = false
                if servers.count == 1 {
                    finishPlex(servers[0])
                } else {
                    plexChoices = servers
                }
            } catch {
                isConnecting = false
                HapticFeedback.notificationError()
                errorMessage = JellyfinClient.mapNetworkError(error).localizedDescription
            }
        }
    }

    private func finishPlex(_ server: PlexAccountAuth.Server) {
        guard let account = plexAccount else { return }
        let link = PlexAccountAuth.makeLink(server: server, user: account.user)
        let creds = ServerCredentials(token: server.accessToken,
                                      accountToken: account.token.token,
                                      accountTokenIssuedAt: Date(),
                                      accountTokenIsJWT: account.token.isJWT)
        guard ServerCredentialStore.save(creds, for: link.id) else {
            errorMessage = "FAILED TO SAVE AUTHENTICATION TOKEN TO SECURE KEYCHAIN"
            return
        }
        PlexConnectionStore.save(server.connections, for: link.id)
        HapticFeedback.notificationSuccess()
        dismiss()
        onConnected(link)
    }

    // MARK: - URL servers

    private var detectionLine: String {
        if trimmedURL.isEmpty { return "ENTER A URL TO DETECT THE SERVER TYPE" }
        if isDetecting { return "DETECTING..." }
        guard detectedInput == trimmedURL else { return " " }
        guard let d = detection else { return "NO SERVER DETECTED YET" }
        let name = (d.product?.isEmpty == false ? d.product! : d.kind.displayLabel).uppercased()
        return "DETECTED: \(name)"
    }

    @MainActor
    private func runDetection() async {
        let input = trimmedURL
        isDetecting = true
        let result = await ServerProbe.detect(input: input)
        guard input == trimmedURL else { return }
        detection = result
        detectedInput = input
        isDetecting = false
    }

    private func performConnect() {
        guard !isConnecting else { return }
        errorMessage = nil
        isConnecting = true
        HapticFeedback.lightImpact()

        let input = trimmedURL
        let user = trimmedUser
        let pass = password
        let key = trimmedAPIKey
        let manualKind = typeChoice.kind

        Task { @MainActor in
            do {
                var found: ServerProbe.Detection?
                if let manualKind {
                    found = await ServerProbe.detect(input: input, only: manualKind)
                } else if detectedInput == input, let detection {
                    found = detection
                } else {
                    found = await ServerProbe.detect(input: input)
                    detection = found
                    detectedInput = input
                }

                let link: ServerSourceLink
                switch found?.kind ?? manualKind {
                case .jellyfin:
                    guard let base = found?.baseURL ?? JellyfinClient.normalizeServerURL(input) else { throw JellyfinClientError.invalidURL }
                    let auth = try await JellyfinClient.shared.authenticate(serverURL: base, username: user, password: pass)
                    link = ServerSourceLink(kind: .jellyfin, serverId: auth.serverId, serverName: auth.serverName,
                                            userId: auth.userId, userName: user, serverURL: base)
                    guard ServerCredentialStore.saveToken(auth.token, for: link.id) else { throw keychainError }
                case .subsonic:
                    guard let base = found?.baseURL else { throw JellyfinClientError.networkError("NO SUBSONIC SERVER FOUND AT THIS ADDRESS") }
                    let (subLink, creds) = try await SubsonicClient.authenticate(base: base, userName: user, password: pass, apiKey: key.isEmpty ? nil : key)
                    link = subLink
                    guard ServerCredentialStore.save(creds, for: link.id) else { throw keychainError }
                case .plex:
                    isConnecting = false
                    typeChoice = .plex
                    errorMessage = "PLEX SERVER FOUND - SIGN IN WITH PLEX BELOW"
                    return
                case .emby:
                    throw JellyfinClientError.networkError("EMBY IS NOT SUPPORTED YET")
                case nil:
                    throw JellyfinClientError.networkError("NO SUPPORTED SERVER FOUND AT THIS ADDRESS")
                }

                isConnecting = false
                HapticFeedback.notificationSuccess()
                dismiss()
                onConnected(link)
            } catch {
                isConnecting = false
                HapticFeedback.notificationError()
                errorMessage = JellyfinClient.mapNetworkError(error).localizedDescription
            }
        }
    }

    private var keychainError: JellyfinClientError {
        .networkError("FAILED TO SAVE AUTHENTICATION TOKEN TO SECURE KEYCHAIN")
    }

    // MARK: - Styling

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundStyle(.secondary)
    }

    private func styledField<F: View>(_ field: F, isURL: Bool) -> some View {
        field
            .font(.system(size: 14, weight: .medium, design: .monospaced))
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .keyboardType(isURL ? .URL : .default)
            #endif
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(appTheme.secondaryBackgroundColor)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isConnecting {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: Color.black))
                        .scaleEffect(0.9)
                }
                Text(title)
                    .font(.system(size: 14, weight: .black, design: .monospaced))
                    .foregroundStyle(Color.black)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!canConnect)
        .opacity(canConnect ? 1.0 : 0.5)
        .padding(.top, 10)
    }

    private func errorBox(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(error.uppercased().contains("CERTIFICATE") ? "CERTIFICATE ERROR" : "CONNECTION ERROR")
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
                        Image(systemName: "gear").font(.system(size: 11, weight: .bold))
                        Text("OPEN SETTINGS").font(.system(size: 11, weight: .bold, design: .monospaced))
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
}
