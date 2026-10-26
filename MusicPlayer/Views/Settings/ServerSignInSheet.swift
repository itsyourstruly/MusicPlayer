import SwiftUI
import AuthenticationServices

/// Sign-in sheet for any media server. The type is auto-detected from the URL (Jellyfin, Subsonic/OpenSubsonic,
/// Plex) with a manual override; Plex signs in through plex.tv.
public struct ServerSignInSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var appTheme
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @Environment(\.scenePhase) private var scenePhase
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
    @State private var errorHint: String? = nil
    @State private var errorField: JellyfinClientError.Field? = nil
    /// The single in-flight connect / Plex sign-in attempt; replaced attempts are cancelled.
    @State private var attempt: Task<Void, Never>? = nil
    @State private var attemptID = UUID()
    @State private var detectionID = UUID()
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
                        errorBox(error, hint: errorHint)
                    }

                    // Server type (auto-detect with manual override)
                    VStack(alignment: .leading, spacing: 6) {
                        fieldLabel("SERVER TYPE")
                        HStack(spacing: 6) {
                            ForEach(TypeChoice.allCases) { choice in
                                Button {
                                    HapticFeedback.selectionChanged()
                                    typeChoice = choice
                                    clearError()
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
                            styledField(TextField("HTTP://192.168.1.100", text: $serverURLString), isURL: true, highlighted: errorField == .url)
                        }
                    }

                    if isPlexMode {
                        plexSection
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            fieldLabel("USERNAME")
                            styledField(TextField("USERNAME", text: $username), isURL: false, highlighted: errorField == .credentials)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            fieldLabel("PASSWORD")
                            styledField(SecureField("PASSWORD", text: $password), isURL: false, highlighted: errorField == .credentials)
                        }
                        if showsAPIKey {
                            VStack(alignment: .leading, spacing: 6) {
                                fieldLabel("API KEY (OPTIONAL, REPLACES PASSWORD)")
                                styledField(SecureField("API KEY", text: $apiKey), isURL: false, highlighted: errorField == .credentials)
                            }
                        }
                        primaryButton(isConnecting ? "CONNECTING... TAP TO CANCEL" : "CONNECT") { performConnect() }
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
            .onChange(of: serverURLString) { if errorField == .url { clearError() } }
            .onChange(of: username) { if errorField == .credentials { clearError() } }
            .onChange(of: password) { if errorField == .credentials { clearError() } }
            .onChange(of: apiKey) { if errorField == .credentials { clearError() } }
            .onChange(of: scenePhase) { _, phase in
                // Leaving the app abandons the attempt instead of resuming a half-finished sign-in.
                if phase == .background { cancelAttempt() }
            }
            .onDisappear { cancelAttempt() }
        }
    }

    // MARK: - Plex

    @ViewBuilder
    private var plexSection: some View {
        if plexChoices.isEmpty {
            Text("PLEX SIGNS IN THROUGH YOUR PLEX ACCOUNT. ALL SERVERS SHARED WITH YOU ARE AVAILABLE.")
                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
            primaryButton(isConnecting ? "WAITING FOR PLEX... TAP TO CANCEL" : "SIGN IN WITH PLEX") { performPlexSignIn() }
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
        if isConnecting { cancelAttempt(); return }
        startAttempt { id in
            let pin = try await ServerDeadline.run(seconds: 20) { try await PlexAccountAuth.createPin() }
            guard let url = PlexAccountAuth.authURL(for: pin) else { throw JellyfinClientError.invalidURL }
            // Returns when plex.tv redirects to the forwardUrl, or when the user closes the page.
            var userClosedPage = false
            do {
                _ = try await webAuthenticationSession.authenticate(
                    using: url,
                    callbackURLScheme: PlexClient.callbackScheme,
                    preferredBrowserSession: .shared
                )
            } catch let err as ASWebAuthenticationSessionError where err.code == .canceledLogin {
                userClosedPage = true
            }
            // Approval can reach plex.tv slightly after the redirect: poll up to 60 s (once if the page was closed).
            var token: PlexAccountAuth.AccountToken?
            let pollDeadline = Date().addingTimeInterval(userClosedPage ? 0 : 60)
            repeat {
                try Task.checkCancellation()
                token = try? await PlexAccountAuth.checkPin(pin)
                if token == nil && Date() < pollDeadline { try await Task.sleep(nanoseconds: 1_000_000_000) }
            } while token == nil && Date() < pollDeadline
            guard let token else {
                if userClosedPage { throw JellyfinClientError.cancelled }
                throw JellyfinClientError.authenticationFailed("PLEX SIGN-IN TIMED OUT")
            }
            let accountToken = token.token
            let (user, servers) = try await ServerDeadline.run(seconds: 20) {
                (try await PlexAccountAuth.user(token: accountToken), try await PlexAccountAuth.servers(token: accountToken))
            }
            guard id == attemptID else { return }
            let sorted = servers.sorted { ($0.owned ? 0 : 1, $0.name) < ($1.owned ? 0 : 1, $1.name) }
            guard !sorted.isEmpty else { throw JellyfinClientError.networkError("NO PLEX SERVERS ON THIS ACCOUNT") }
            plexAccount = (token, user)
            if sorted.count == 1 {
                finishPlex(sorted[0])
            } else {
                plexChoices = sorted
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
        let id = UUID()
        detectionID = id
        isDetecting = true
        // Always leave DETECTING, even when superseded or cancelled (unless a newer detection owns the flag).
        defer { if detectionID == id { isDetecting = false } }
        do {
            let result = try await ServerProbe.detect(input: input)
            guard !Task.isCancelled, input == trimmedURL else { return }
            detection = result
            detectedInput = input
        } catch {
            guard !Task.isCancelled, input == trimmedURL else { return }
            show(error)
        }
    }

    // MARK: - Attempt lifecycle

    /// Runs one sign-in attempt. A new attempt cancels the previous one; every exit path (success, error,
    /// cancellation) clears the busy state, and results of superseded attempts are ignored.
    private func startAttempt(_ work: @escaping @MainActor (UUID) async throws -> Void) {
        attempt?.cancel()
        clearError()
        let id = UUID()
        attemptID = id
        isConnecting = true
        HapticFeedback.lightImpact()
        attempt = Task { @MainActor in
            defer {
                if attemptID == id {
                    isConnecting = false
                    attempt = nil
                }
            }
            do {
                try await work(id)
            } catch {
                guard attemptID == id, !Task.isCancelled else { return }
                show(error)
            }
        }
    }

    private func cancelAttempt() {
        guard let attempt else { return }
        attempt.cancel()
        self.attempt = nil
        attemptID = UUID()
        isConnecting = false
    }

    private func show(_ error: Error) {
        let mapped = JellyfinClient.mapNetworkError(error)
        guard mapped != .cancelled else { return }
        errorMessage = mapped.localizedDescription.uppercased()
        errorHint = mapped.hint
        errorField = mapped.field
        HapticFeedback.notificationError()
    }

    private func clearError() {
        errorMessage = nil
        errorHint = nil
        errorField = nil
    }

    /// Outcome of the network part of a URL sign-in (runs off the main actor under one deadline).
    private enum ConnectOutcome: Sendable {
        case jellyfin(ServerSourceLink, token: String)
        case subsonic(ServerSourceLink, ServerCredentials)
        case plexFound
    }

    private static let signInDeadline: TimeInterval = 20

    nonisolated private static func connect(
        input: String, user: String, pass: String, key: String,
        manualKind: ServerKind?, cached: ServerProbe.Detection?
    ) async throws -> (ConnectOutcome, ServerProbe.Detection?) {
        let found: ServerProbe.Detection?
        if let manualKind {
            found = try await ServerProbe.detect(input: input, only: manualKind)
        } else if let cached {
            found = cached
        } else {
            found = try await ServerProbe.detect(input: input)
        }
        switch found?.kind ?? manualKind {
        case .jellyfin:
            guard let base = found?.baseURL ?? JellyfinClient.normalizeServerURL(input) else { throw JellyfinClientError.invalidURL }
            let auth = try await JellyfinClient.shared.authenticate(serverURL: base, username: user, password: pass)
            let link = ServerSourceLink(kind: .jellyfin, serverId: auth.serverId, serverName: auth.serverName,
                                        userId: auth.userId, userName: user, serverURL: base)
            return (.jellyfin(link, token: auth.token), found)
        case .subsonic:
            guard let base = found?.baseURL else { throw JellyfinClientError.unreachable("NO SUBSONIC SERVER FOUND AT THIS ADDRESS") }
            let (link, creds) = try await SubsonicClient.authenticate(base: base, userName: user, password: pass, apiKey: key.isEmpty ? nil : key)
            return (.subsonic(link, creds), found)
        case .plex:
            return (.plexFound, found)
        case .emby:
            throw JellyfinClientError.unreachable("EMBY IS NOT SUPPORTED YET")
        case nil:
            throw JellyfinClientError.unreachable("NO SUPPORTED SERVER FOUND AT THIS ADDRESS")
        }
    }

    private func performConnect() {
        if isConnecting { cancelAttempt(); return }
        let input = trimmedURL
        let user = trimmedUser
        let pass = password
        let key = trimmedAPIKey
        let manualKind = typeChoice.kind
        let cached = (manualKind == nil && detectedInput == input) ? detection : nil

        startAttempt { id in
            let (outcome, found) = try await ServerDeadline.run(seconds: Self.signInDeadline) {
                try await Self.connect(input: input, user: user, pass: pass, key: key, manualKind: manualKind, cached: cached)
            }
            guard id == attemptID else { return }
            if manualKind == nil {
                detection = found
                detectedInput = input
            }
            let link: ServerSourceLink
            switch outcome {
            case .jellyfin(let l, let token):
                guard ServerCredentialStore.saveToken(token, for: l.id) else { throw keychainError }
                link = l
            case .subsonic(let l, let creds):
                guard ServerCredentialStore.save(creds, for: l.id) else { throw keychainError }
                link = l
            case .plexFound:
                typeChoice = .plex
                errorMessage = "PLEX SERVER FOUND - SIGN IN WITH PLEX BELOW"
                return
            }
            HapticFeedback.notificationSuccess()
            dismiss()
            onConnected(link)
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

    private func styledField<F: View>(_ field: F, isURL: Bool, highlighted: Bool = false) -> some View {
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
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.red.opacity(highlighted ? 0.85 : 0), lineWidth: 1.5))
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
        .disabled(!(canConnect || isConnecting))
        .opacity(canConnect || isConnecting ? 1.0 : 0.5)
        .padding(.top, 10)
    }

    private func errorBox(_ error: String, hint: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(error.uppercased().contains("CERTIFICATE") ? "CERTIFICATE ERROR" : "CONNECTION ERROR")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.red)
                Text(error.uppercased())
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.red.opacity(0.85))
                if let hint {
                    Text(hint.uppercased())
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            if error.uppercased() == JellyfinClientError.localNetworkDenied.localizedDescription {
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
