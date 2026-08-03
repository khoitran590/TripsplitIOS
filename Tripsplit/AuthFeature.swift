import SwiftUI
import Observation
import Security
import os
import AuthenticationServices
import CryptoKit

// MARK: - Supabase configuration

/// Your Supabase project's connection details.
///
/// Fill these in from the Supabase dashboard → Project Settings → API.
/// The anon (public) key is safe to ship in a client app. Until both values are
/// set, the auth screens show a "not configured" message instead of failing silently.
enum SupabaseConfig {
    /// The project's API URL (derived from the project ref), no trailing slash.
    nonisolated static let url = "https://ttgwzwvlochpvtxrxkoz.supabase.co"
    /// The project's anon/public API key.
    nonisolated static let anonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InR0Z3d6d3Zsb2NocHZ0eHJ4a296Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODIyNTUxMzksImV4cCI6MjA5NzgzMTEzOX0.IfrhBTPNEozGUHJb2J_IH2E5RABFK4PlQihZAOx79f4"

    nonisolated static var isConfigured: Bool {
        !url.contains("YOUR-PROJECT-REF") && !anonKey.contains("YOUR-SUPABASE-ANON-KEY")
    }

    /// Sign in with Apple requires a paid Apple Developer Program team (personal teams
    /// can't sign the `com.apple.developer.applesignin` entitlement). Flip to true after
    /// enrolling AND re-adding `CODE_SIGN_ENTITLEMENTS = Tripsplit/Tripsplit.entitlements`
    /// to both target configurations in project.pbxproj — the code path is otherwise ready.
    nonisolated static let appleSignInEnabled = false
}

// MARK: - Auth models

/// A simple typed auth error whose message is safe to show to the user.
struct AuthError: Error, LocalizedError {
    let message: String
    var statusCode: Int?
    var errorDescription: String? { message }

    init(message: String, statusCode: Int? = nil) {
        self.message = message
        self.statusCode = statusCode
    }
}

// MARK: - Backend security helpers

enum BackendSecurity {
    nonisolated static let logger = Logger(subsystem: "com.tripsplit.app", category: "backend")

    /// One shared session for every backend call. A `let` (not a computed property) so
    /// TLS connections and HTTP/2 streams are reused across requests — building a fresh
    /// URLSession per call forces a new handshake every time and makes each tap-triggered
    /// save/upload noticeably slower.
    nonisolated static let secureSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        configuration.waitsForConnectivity = true
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // A delegate that re-attaches auth headers across redirects — see the type below.
        return URLSession(configuration: configuration, delegate: RedirectAuthPreserver(), delegateQueue: nil)
    }()

    nonisolated static func normalizedEmail(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    nonisolated static func isValidEmail(_ email: String) -> Bool {
        let trimmed = normalizedEmail(email)
        guard trimmed.count <= 254 else { return false }
        let pattern = #"^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$"#
        return trimmed.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    nonisolated static func isStrongPassword(_ password: String) -> Bool {
        password.count >= 8 && password.count <= 256
    }

    nonisolated static func isSafeStoragePath(_ path: String) -> Bool {
        guard path.count <= 180, !path.hasPrefix("/"), !path.contains("..") else { return false }
        return path.range(of: #"^[a-f0-9-]+/[A-Za-z0-9._-]+\.(jpg|jpeg)$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Authenticated requests and redirects are only allowed to use the configured
    /// Supabase HTTPS origin. Comparing the effective port closes the subtle gap where
    /// `https://host` and `https://host:444` otherwise look like the same backend.
    nonisolated static func isTrustedBackendURL(_ url: URL?) -> Bool {
        guard let url,
              let expected = URL(string: SupabaseConfig.url),
              url.scheme?.lowercased() == "https",
              expected.scheme?.lowercased() == "https",
              url.host?.lowercased() == expected.host?.lowercased() else {
            return false
        }
        return effectivePort(for: url) == effectivePort(for: expected)
    }

    nonisolated private static func effectivePort(for url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }

    nonisolated static func log(_ message: String, statusCode: Int? = nil, error: Error? = nil) {
        if let statusCode {
            logger.error("\(message, privacy: .public) status=\(statusCode, privacy: .public)")
        } else if let error {
            logger.error("\(message, privacy: .public) error=\(String(describing: error), privacy: .private)")
        } else {
            logger.error("\(message, privacy: .public)")
        }
    }
}

/// Preserves credentials only for a tightly bounded same-origin Supabase redirect.
/// Redirect destinations are untrusted input: forwarding a bearer token to a different
/// scheme, host, or port would hand the user's session to that server.
final class RedirectAuthPreserver: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    nonisolated static let maximumRedirectCount = 5

    private let lock = NSLock()
    private var redirectCounts: [Int: Int] = [:]

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard BackendSecurity.isTrustedBackendURL(response.url),
              BackendSecurity.isTrustedBackendURL(request.url),
              claimRedirect(for: task.taskIdentifier) else {
            clearRedirects(for: task.taskIdentifier)
            BackendSecurity.log("Blocked an untrusted or excessive backend redirect", statusCode: response.statusCode)
            completionHandler(nil)
            return
        }

        var updated = request
        if let original = task.currentRequest ?? task.originalRequest {
            for header in ["Authorization", "apikey"] where updated.value(forHTTPHeaderField: header) == nil {
                updated.setValue(original.value(forHTTPHeaderField: header), forHTTPHeaderField: header)
            }
        }
        // Do not log Location: signed URLs and invitation tokens may live in a query.
        BackendSecurity.log("Followed a trusted backend redirect", statusCode: response.statusCode)
        completionHandler(updated)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        clearRedirects(for: task.taskIdentifier)
    }

    private func claimRedirect(for taskIdentifier: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let next = (redirectCounts[taskIdentifier] ?? 0) + 1
        redirectCounts[taskIdentifier] = next
        return next <= Self.maximumRedirectCount
    }

    private func clearRedirects(for taskIdentifier: Int) {
        lock.lock()
        redirectCounts[taskIdentifier] = nil
        lock.unlock()
    }
}

/// The persisted result of a successful sign-in.
struct AuthSession: Codable, Equatable {
    var accessToken: String
    var refreshToken: String
    var email: String?
}

// MARK: - Auth service (Supabase GoTrue REST API)

/// Talks to Supabase Auth (`/auth/v1`) directly over URLSession — no SDK required.
actor AuthService {
    static let shared = AuthService()
    private let session = BackendSecurity.secureSession

    private struct TokenResponse: Decodable {
        let accessToken: String?
        let refreshToken: String?
        let user: AuthUser?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case user
        }
    }

    private struct AuthUser: Decodable {
        let id: String?
        let email: String?
    }

    /// GoTrue error payloads vary by version; this decodes all the common shapes.
    private struct GoTrueError: Decodable {
        let error: String?
        let errorDescription: String?
        let msg: String?
        let message: String?

        enum CodingKeys: String, CodingKey {
            case error
            case errorDescription = "error_description"
            case msg, message
        }

        var text: String {
            errorDescription ?? message ?? msg ?? error ?? "Something went wrong."
        }
    }

    enum SignUpOutcome {
        case signedIn(AuthSession)
        case needsConfirmation
    }

    func signIn(email: String, password: String) async throws -> AuthSession {
        let email = try validateCredentials(email: email, password: password)
        let data = try await post("/auth/v1/token?grant_type=password", body: ["email": email, "password": password])
        let token = try JSONDecoder().decode(TokenResponse.self, from: data)
        guard let access = token.accessToken, let refresh = token.refreshToken else {
            throw AuthError(message: "Unexpected response from the server.")
        }
        return AuthSession(accessToken: access, refreshToken: refresh, email: token.user?.email ?? email)
    }

    func signUp(email: String, password: String) async throws -> SignUpOutcome {
        let email = try validateCredentials(email: email, password: password)
        guard BackendSecurity.isStrongPassword(password) else {
            throw AuthError(message: "Use a password with at least 8 characters.")
        }
        let data = try await post("/auth/v1/signup", body: ["email": email, "password": password])
        let token = try? JSONDecoder().decode(TokenResponse.self, from: data)
        if let access = token?.accessToken, let refresh = token?.refreshToken {
            return .signedIn(AuthSession(accessToken: access, refreshToken: refresh, email: token?.user?.email ?? email))
        }
        // No session returned → the project requires email confirmation.
        return .needsConfirmation
    }

    func resetPassword(email: String) async throws {
        let email = try validateEmail(email)
        _ = try await send("POST", "/auth/v1/recover", body: ["email": email])
    }

    /// Exchanges an Apple identity token for a Supabase session (GoTrue's `id_token`
    /// grant). `nonce` is the raw nonce whose SHA-256 hash was sent in the Apple
    /// request; GoTrue verifies it against the token's `nonce` claim.
    func signInWithApple(identityToken: String, nonce: String) async throws -> AuthSession {
        let data = try await post(
            "/auth/v1/token?grant_type=id_token",
            body: ["provider": "apple", "id_token": identityToken, "nonce": nonce]
        )
        let token = try JSONDecoder().decode(TokenResponse.self, from: data)
        guard let access = token.accessToken, let refresh = token.refreshToken else {
            throw AuthError(message: "Unexpected response from the server.")
        }
        return AuthSession(accessToken: access, refreshToken: refresh, email: token.user?.email)
    }

    /// Whether `accessToken` is currently accepted as a signed-in user by Supabase Auth.
    /// Used to diagnose sync failures: a false result means the session isn't reaching the
    /// backend as an authenticated user (expired, or the `Authorization` header stripped in
    /// transit), which is the real cause behind an RLS "row violates policy" (anon) rejection.
    func isSessionAccepted(accessToken: String) async -> Bool {
        guard SupabaseConfig.isConfigured, let url = URL(string: SupabaseConfig.url + "/auth/v1/user") else {
            return false
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return http.statusCode == 200
    }

    func refreshSession(refreshToken: String, email: String?) async throws -> AuthSession {
        let data = try await post("/auth/v1/token?grant_type=refresh_token", body: ["refresh_token": refreshToken])
        let token = try JSONDecoder().decode(TokenResponse.self, from: data)
        guard let access = token.accessToken, let refresh = token.refreshToken else {
            throw AuthError(message: "Unexpected response from the server.")
        }
        return AuthSession(accessToken: access, refreshToken: refresh, email: token.user?.email ?? email)
    }

    /// Updates the signed-in user's password. Requires the user's own access token
    /// (the anon key is not sufficient for this endpoint).
    func updatePassword(accessToken: String, newPassword: String) async throws {
        guard BackendSecurity.isStrongPassword(newPassword) else {
            throw AuthError(message: "Use a password with at least 8 characters.")
        }
        _ = try await send("PUT", "/auth/v1/user", body: ["password": newPassword], accessToken: accessToken)
    }

    /// Revokes refresh tokens server-side. Local state is cleared by `AuthStore` even
    /// when this best-effort network request fails, so sign-out always completes.
    func signOut(accessToken: String) async throws {
        _ = try await send("POST", "/auth/v1/logout?scope=global", body: [:], accessToken: accessToken)
    }

    /// Starts the privileged deletion workflow. The Edge Function owns the service-role
    /// credential and removes application data before deleting the Auth user.
    func deleteAccount(accessToken: String) async throws {
        _ = try await send("POST", "/functions/v1/delete-account", body: [:], accessToken: accessToken)
    }

    private func validateCredentials(email: String, password: String) throws -> String {
        let email = try validateEmail(email)
        guard !password.isEmpty, password.count <= 256 else {
            throw AuthError(message: "Enter your password.")
        }
        return email
    }

    private func validateEmail(_ email: String) throws -> String {
        let normalized = BackendSecurity.normalizedEmail(email)
        guard BackendSecurity.isValidEmail(normalized) else {
            throw AuthError(message: "Enter a valid email address.")
        }
        return normalized
    }

    // MARK: Networking

    private func post(_ path: String, body: [String: String]) async throws -> Data {
        try await send("POST", path, body: body)
    }

    private func send(_ method: String, _ path: String, body: [String: String], accessToken: String? = nil) async throws -> Data {
        guard SupabaseConfig.isConfigured else {
            throw AuthError(message: "Supabase isn't configured yet. Add your project URL and anon key in SupabaseConfig.")
        }
        guard let url = URL(string: SupabaseConfig.url + path) else {
            throw AuthError(message: "Invalid Supabase URL.")
        }

        let bearer: String
        if let accessToken {
            bearer = accessToken
        } else {
            bearer = SupabaseConfig.anonKey
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            BackendSecurity.log("Auth network request failed", error: error)
            throw AuthError(message: "Couldn't reach the server. Check your connection.")
        }

        guard let http = response as? HTTPURLResponse else {
            throw AuthError(message: "No response from the server.")
        }
        guard (200..<300).contains(http.statusCode) else {
            BackendSecurity.log("Auth request rejected", statusCode: http.statusCode)
            if let decoded = try? JSONDecoder().decode(GoTrueError.self, from: data) {
                throw AuthError(message: decoded.text, statusCode: http.statusCode)
            }
            throw AuthError(message: "Request failed (\(http.statusCode)).", statusCode: http.statusCode)
        }
        return data
    }
}

// MARK: - Secure auth storage

enum AuthSessionStore {
    private static let service = "com.tripsplit.auth"
    private static let account = "session"

    static func load() -> AuthSession? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            if status != errSecItemNotFound {
                BackendSecurity.log("Keychain session read failed", statusCode: Int(status))
            }
            return nil
        }
        guard let session = try? JSONDecoder().decode(AuthSession.self, from: data) else {
            BackendSecurity.log("Discarded an invalid Keychain session")
            delete()
            return nil
        }
        return session
    }

    @discardableResult
    static func save(_ session: AuthSession) -> Bool {
        guard let data = try? JSONEncoder().encode(session) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            attributes.forEach { add[$0.key] = $0.value }
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                BackendSecurity.log("Keychain session write failed", statusCode: Int(addStatus))
                return false
            }
            return true
        }
        guard status == errSecSuccess else {
            BackendSecurity.log("Keychain session update failed", statusCode: Int(status))
            return false
        }
        return true
    }

    @discardableResult
    static func delete() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            BackendSecurity.log("Keychain session deletion failed", statusCode: Int(status))
            return false
        }
        return true
    }
}

// MARK: - Auth store

/// Holds the current session and persists it across launches. The settings screen
/// gates its content on `isAuthenticated`.
@MainActor
@Observable
final class AuthStore {
    private let storageKey = "tripsplit.authSession"

    var session: AuthSession?

    /// The in-flight token refresh, if any. Concurrent callers (e.g. the several saves a
    /// single trip creation fires) share one refresh instead of each hitting Supabase —
    /// its refresh-token rotation invalidates the old token, so parallel refreshes would
    /// collide and fail, leaving some writes unauthenticated.
    @ObservationIgnored private var refreshTask: Task<AuthSession, Error>?

    var isAuthenticated: Bool { session != nil }
    var email: String? { session?.email }

    init() {
        if AppStoreDemoData.isEnabled {
            session = AuthSession(
                accessToken: AppStoreDemoData.localAccessToken,
                refreshToken: "local-demo-only",
                email: "reviewer@tripsplit.app"
            )
        } else if let saved = AuthSessionStore.load() {
            session = saved
        } else if let data = UserDefaults.standard.data(forKey: storageKey),
                  let saved = try? JSONDecoder().decode(AuthSession.self, from: data) {
            // One-time migration from the previous UserDefaults storage.
            persist(saved)
            UserDefaults.standard.removeObject(forKey: storageKey)
        }
    }

    func signIn(email: String, password: String) async throws {
        persist(try await AuthService.shared.signIn(email: email, password: password))
    }

    /// Returns `true` when the user was signed in immediately, `false` when they must
    /// confirm their email first.
    func signUp(email: String, password: String) async throws -> Bool {
        switch try await AuthService.shared.signUp(email: email, password: password) {
        case .signedIn(let session):
            persist(session)
            return true
        case .needsConfirmation:
            return false
        }
    }

    func resetPassword(email: String) async throws {
        try await AuthService.shared.resetPassword(email: email)
    }

    func signInWithApple(identityToken: String, nonce: String) async throws {
        persist(try await AuthService.shared.signInWithApple(identityToken: identityToken, nonce: nonce))
    }

    func refreshSession() async throws -> AuthSession {
        // Coalesce concurrent refreshes onto a single request (see `refreshTask`).
        if let refreshTask {
            return try await refreshTask.value
        }
        guard let session else {
            throw AuthError(message: "You need to be signed in.")
        }
        let task = Task { () throws -> AuthSession in
            defer { self.refreshTask = nil }
            let refreshed = try await AuthService.shared.refreshSession(
                refreshToken: session.refreshToken,
                email: session.email
            )
            self.persist(refreshed)
            return refreshed
        }
        refreshTask = task
        return try await task.value
    }

    /// Changes the signed-in user's password. The current password is verified by
    /// re-authenticating (which also yields a fresh access token to perform the update).
    func changePassword(current: String, new: String) async throws {
        guard let email = session?.email else {
            throw AuthError(message: "You need to be signed in to change your password.")
        }

        let verified: AuthSession
        do {
            verified = try await AuthService.shared.signIn(email: email, password: current)
        } catch let error as AuthError where error.message.lowercased().contains("credential") {
            throw AuthError(message: "Your current password is incorrect.")
        }

        try await AuthService.shared.updatePassword(accessToken: verified.accessToken, newPassword: new)
        persist(verified)
    }

    func signOut() async {
        if let accessToken = session?.accessToken {
            do {
                try await AuthService.shared.signOut(accessToken: accessToken)
            } catch {
                BackendSecurity.log("Remote session revocation failed during sign-out", error: error)
            }
        }
        clearLocalSession()
    }

    /// Requires the current password so deletion is backed by recent authentication.
    /// The backend deletes the Auth user last; only then is the local session removed.
    func deleteAccount(currentPassword: String) async throws {
        guard let email = session?.email else {
            throw AuthError(message: "You need to be signed in.")
        }
        let verified = try await AuthService.shared.signIn(email: email, password: currentPassword)
        try await AuthService.shared.deleteAccount(accessToken: verified.accessToken)
        clearLocalSession()
    }

    private func persist(_ session: AuthSession) {
        self.session = session
        AuthSessionStore.save(session)
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    private func clearLocalSession() {
        refreshTask?.cancel()
        refreshTask = nil
        session = nil
        AuthSessionStore.delete()
        UserDefaults.standard.removeObject(forKey: storageKey)
    }
}

// MARK: - Auth view

/// The sign-in / sign-up / forgot-password screen shown until the user logs in.
struct AuthView: View {
    @Environment(AuthStore.self) private var auth

    enum Mode {
        case signIn, signUp, forgot

        var title: String {
            switch self {
            case .signIn: "Welcome back"
            case .signUp: "Create an account"
            case .forgot: "Reset password"
            }
        }

        var action: String {
            switch self {
            case .signIn: "Sign in"
            case .signUp: "Create account"
            case .forgot: "Send reset link"
            }
        }
    }

    @State private var mode: Mode = .signIn
    @State private var email = ""
    @State private var password = ""
    @State private var showsPassword = false
    @State private var errorMessage: String?
    @State private var infoMessage: String?
    @State private var isWorking = false
    @State private var showPrivacyPolicy = false
    /// Raw nonce for the in-flight Apple request; its SHA-256 goes to Apple, the raw
    /// value to Supabase so GoTrue can verify the identity token's `nonce` claim.
    @State private var appleNonce = ""
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var focusedField: AuthField?

    private enum AuthField: Hashable { case email, password }

    private var canSubmit: Bool {
        guard !email.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return mode == .forgot || !password.isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                brandHeader

                card
                    .animation(.snappy, value: mode)

                Button("Privacy Policy") { showPrivacyPolicy = true }
                    .font(.app(.footnote, .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding()
            .padding(.top, 24)
            .padding(.bottom, 80) // Clearance for the floating dock.
        }
        .sheet(isPresented: $showPrivacyPolicy) { PrivacyPolicyView() }
    }

    /// The app mark above the card, mirroring the reference's "Product Inc." lockup.
    private var brandHeader: some View {
        VStack(spacing: 12) {
            Image("SplashLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 58, height: 58)
                .clipShape(.rect(cornerRadius: 16, style: .continuous))
            Text("TripSplit")
                .font(.app(.headline))
        }
        .padding(.top, 12)
    }

    /// The single centered card: title, subtitle, fields, primary action, and the
    /// sign-in/sign-up switch link at the bottom.
    private var card: some View {
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                Text(LocalizedStringKey(mode.title))
                    .font(.app(.title, .bold))
                Text(LocalizedStringKey(subtitle))
                    .font(.app(.subheadline))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.bottom, 8)

            VStack(alignment: .leading, spacing: 6) {
                Text("Email")
                    .font(.app(.caption, .semibold))
                    .foregroundStyle(Theme.textSecondary)
                field(placeholder: "name@example.com", text: $email, isSecure: false)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(mode == .forgot ? .go : .next)
                    .focused($focusedField, equals: .email)
                    .onSubmit { mode == .forgot ? submit() : (focusedField = .password) }
            }

            if mode != .forgot {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Password")
                        .font(.app(.caption, .semibold))
                        .foregroundStyle(Theme.textSecondary)
                    field(placeholder: mode == .signUp ? "At least 8 characters" : "Enter your password",
                          text: $password, isSecure: !showsPassword)
                        .textContentType(mode == .signUp ? .newPassword : .password)
                        .submitLabel(.go)
                        .focused($focusedField, equals: .password)
                        .onSubmit { if canSubmit { submit() } }
                    Button { showsPassword.toggle() } label: {
                        Label(showsPassword ? "Hide password" : "Show password",
                              systemImage: showsPassword ? "eye.slash" : "eye")
                            .font(.app(.caption, .semibold))
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    if mode == .signUp {
                        Label("Use 8+ characters with uppercase, lowercase, and a number.",
                              systemImage: BackendSecurity.isStrongPassword(password) ? "checkmark.circle.fill" : "info.circle")
                            .font(.app(.caption))
                            .foregroundStyle(BackendSecurity.isStrongPassword(password) ? Theme.positive : Theme.textSecondary)
                    }
                }
            }

            if let infoMessage {
                banner(infoMessage, icon: "checkmark.circle.fill", color: Theme.positive)
            }
            if let errorMessage {
                banner(errorMessage, icon: "exclamationmark.triangle.fill", color: Theme.negative)
            }

            primaryButton

            if mode != .forgot && SupabaseConfig.appleSignInEnabled {
                orDivider
                appleButton
            }

            if mode == .signIn {
                Button("Forgot password?") { switchMode(.forgot) }
                    .font(.app(.subheadline))
                    .foregroundStyle(.secondary)
            }

            switchModeFooter
                .padding(.top, 8)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
    }

    private var subtitle: String {
        switch mode {
        case .signIn: "Sign in to your account"
        case .signUp: "Start splitting trip expenses with friends"
        case .forgot: "Enter your email and we'll send a reset link."
        }
    }

    private func field(placeholder: LocalizedStringKey, text: Binding<String>, isSecure: Bool) -> some View {
        Group {
            if isSecure {
                SecureField(placeholder, text: text)
            } else {
                TextField(placeholder, text: text)
            }
        }
        .font(.app(.body))
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(.secondary.opacity(0.1), in: .rect(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.secondary.opacity(0.25), lineWidth: 1)
        )
    }

    private var primaryButton: some View {
        Button(action: submit) {
            HStack(spacing: 8) {
                if isWorking { ProgressView().tint(Theme.onAccent) }
                Text(LocalizedStringKey(isWorking ? "Please wait…" : mode.action))
                    .font(.app(.headline))
                    .foregroundStyle(Theme.onAccent)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(Theme.accent).interactive(), in: .rect(cornerRadius: 14))
        .disabled(!canSubmit || isWorking)
        .opacity(canSubmit && !isWorking ? 1 : 0.5)
    }

    private var orDivider: some View {
        HStack(spacing: 12) {
            Rectangle().fill(.secondary.opacity(0.25)).frame(height: 1)
            Text("or")
                .font(.app(.footnote))
                .foregroundStyle(.secondary)
            Rectangle().fill(.secondary.opacity(0.25)).frame(height: 1)
        }
    }

    private var appleButton: some View {
        SignInWithAppleButton(mode == .signUp ? .signUp : .signIn) { request in
            appleNonce = Self.randomNonce()
            request.requestedScopes = [.fullName, .email]
            request.nonce = SHA256.hash(data: Data(appleNonce.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
        } onCompletion: { result in
            handleAppleResult(result)
        }
        .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
        // Recreate the button when the label should change — UIKit-backed, so SwiftUI
        // won't re-render "Sign in" ↔ "Sign up" on its own.
        .id(mode == .signUp)
        .frame(height: 48)
        .clipShape(.rect(cornerRadius: 14))
        .disabled(isWorking)
    }

    private static func randomNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).map { String(format: "%02x", $0) }.joined()
    }

    private func handleAppleResult(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let identityToken = String(data: tokenData, encoding: .utf8) else {
                errorMessage = "Apple didn't return a usable credential. Try again."
                return
            }
            // Apple provides the name only on the very first authorization for this
            // account — stash it so the profile-setup step can prefill it.
            if let name = credential.fullName {
                let display = [name.givenName, name.familyName].compactMap(\.self).joined(separator: " ")
                if !display.isEmpty {
                    UserDefaults.standard.set(display, forKey: "pendingAppleDisplayName")
                }
            }
            errorMessage = nil
            infoMessage = nil
            isWorking = true
            let nonce = appleNonce
            Task {
                do {
                    try await auth.signInWithApple(identityToken: identityToken, nonce: nonce)
                } catch {
                    errorMessage = (error as? AuthError)?.message ?? error.localizedDescription
                }
                isWorking = false
            }
        case .failure(let error):
            // A user-cancelled sheet is not an error worth surfacing.
            if let authError = error as? ASAuthorizationError, authError.code == .canceled { return }
            errorMessage = error.localizedDescription
        }
    }

    /// Consistent account vocabulary across every authentication mode.
    @ViewBuilder
    private var switchModeFooter: some View {
        switch mode {
        case .signIn:
            HStack(spacing: 5) {
                Text("Don't have an account?")
                    .foregroundStyle(.secondary)
                Button("Create account") { switchMode(.signUp) }
                    .fontWeight(.semibold)
            }
            .font(.app(.subheadline))
        case .signUp:
            HStack(spacing: 5) {
                Text("Already have an account?")
                    .foregroundStyle(.secondary)
                Button("Sign in") { switchMode(.signIn) }
                    .fontWeight(.semibold)
            }
            .font(.app(.subheadline))
        case .forgot:
            Button("Back to sign in") { switchMode(.signIn) }
                .font(.app(.subheadline))
        }
    }

    private func banner(_ text: String, icon: String, color: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.app(.footnote, .medium))
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(color.opacity(0.12), in: .rect(cornerRadius: 12))
    }

    private func switchMode(_ newMode: Mode) {
        mode = newMode
        errorMessage = nil
        infoMessage = nil
    }

    private func submit() {
        errorMessage = nil
        infoMessage = nil
        isWorking = true
        let currentMode = mode
        Task {
            do {
                switch currentMode {
                case .signIn:
                    try await auth.signIn(email: email, password: password)
                case .signUp:
                    let signedIn = try await auth.signUp(email: email, password: password)
                    if !signedIn {
                        infoMessage = "Account created. Check your email to confirm, then log in."
                        switchMode(.signIn)
                    }
                case .forgot:
                    try await auth.resetPassword(email: email)
                    infoMessage = "If an account exists for that email, a reset link is on its way."
                    switchMode(.signIn)
                }
            } catch {
                errorMessage = (error as? AuthError)?.message ?? error.localizedDescription
            }
            isWorking = false
        }
    }
}

/// One reusable, contextual account surface for every gated action. Presenters can
/// supply the reason the sheet appeared; successful authentication dismisses it and
/// lets the presenting screen replay its pending intent.
struct AuthenticationSheet: View {
    var reason: LocalizedStringKey = "Sign in to continue."

    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                VStack(spacing: 0) {
                    Label(reason, systemImage: "lock.open.fill")
                        .font(.app(.subheadline, .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                        .padding(.top, 8)
                    AuthView()
                }
            }
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not now") { dismiss() }
                }
            }
        }
        .onChange(of: auth.isAuthenticated) { _, signedIn in
            if signedIn { dismiss() }
        }
    }
}
// MARK: - Change password view

/// A sheet that lets a signed-in user change their password by confirming their
/// current one and entering (and re-entering) a new one.
struct ChangePasswordView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss

    @State private var current = ""
    @State private var newPassword = ""
    @State private var confirm = ""
    @State private var errorMessage: String?
    @State private var isWorking = false

    private var passwordsMatch: Bool { newPassword == confirm }

    private var canSubmit: Bool {
        !current.isEmpty && newPassword.count >= 6 && passwordsMatch
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Current password") {
                    SecureField("Current password", text: $current)
                        .textContentType(.password)
                }

                Section {
                    SecureField("New password", text: $newPassword)
                        .textContentType(.newPassword)
                    SecureField("Confirm new password", text: $confirm)
                        .textContentType(.newPassword)
                } header: {
                    Text("New password")
                } footer: {
                    Text("Must be at least 6 characters.")
                }

                if !confirm.isEmpty && !passwordsMatch {
                    Text("New passwords don't match.")
                        .font(.app(.footnote))
                        .foregroundStyle(Color(hex: 0xEF4444))
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.app(.footnote))
                        .foregroundStyle(Color(hex: 0xEF4444))
                }
            }
            .navigationTitle("Change Password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isWorking {
                        ProgressView()
                    } else {
                        Button("Save") { submit() }
                            .disabled(!canSubmit)
                    }
                }
            }
        }
    }

    private func submit() {
        errorMessage = nil
        isWorking = true
        Task {
            do {
                try await auth.changePassword(current: current, new: newPassword)
                dismiss()
            } catch {
                errorMessage = (error as? AuthError)?.message ?? error.localizedDescription
            }
            isWorking = false
        }
    }
}

// MARK: - Sign-in gating

/// Standard alert shown when a signed-out user taps a feature that needs an
/// account (creating trips, adding expenses, editing trips). Sign-in itself
/// lives on the Settings tab, so the alert points there.
extension View {
    func signInRequiredAlert(isPresented: Binding<Bool>) -> some View {
        alert("Sign In Required", isPresented: isPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Sign in from the Profile tab to create trips, add expenses, and edit trips.")
        }
    }
}
