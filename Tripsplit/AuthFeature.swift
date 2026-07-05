import SwiftUI
import Observation
import Security
import os

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

/// Re-attaches `Authorization`/`apikey` when `URLSession` follows an HTTP redirect.
/// iOS strips these sensitive headers on redirects (always cross-origin, sometimes even
/// same-origin), which would make a redirected Supabase write arrive unauthenticated —
/// Postgres then runs it as the anon role and RLS rejects it with "new row violates
/// row-level security policy" (the observed 403 on trip saves where `auth_user` is null
/// even though reads authenticate fine). The redirect is also logged so we can confirm
/// whether one is actually happening.
final class RedirectAuthPreserver: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        var updated = request
        if let original = task.originalRequest {
            for header in ["Authorization", "apikey"] where updated.value(forHTTPHeaderField: header) == nil {
                updated.setValue(original.value(forHTTPHeaderField: header), forHTTPHeaderField: header)
            }
        }
        BackendSecurity.log("Followed HTTP redirect (\(response.statusCode)) to \(response.value(forHTTPHeaderField: "Location") ?? "?"); re-attached auth headers")
        completionHandler(updated)
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
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(AuthSession.self, from: data)
    }

    static func save(_ session: AuthSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            attributes.forEach { add[$0.key] = $0.value }
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
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
        if let saved = AuthSessionStore.load() {
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

    func signOut() {
        session = nil
        AuthSessionStore.delete()
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    private func persist(_ session: AuthSession) {
        self.session = session
        AuthSessionStore.save(session)
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
            case .signIn: "Login"
            case .signUp: "Sign up"
            case .forgot: "Send reset link"
            }
        }
    }

    @State private var mode: Mode = .signIn
    @State private var email = ""
    @State private var password = ""
    @State private var errorMessage: String?
    @State private var infoMessage: String?
    @State private var isWorking = false

    private var canSubmit: Bool {
        guard !email.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return mode == .forgot || !password.isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                brandHeader

                card
            }
            .padding()
            .padding(.top, 24)
            .padding(.bottom, 80) // Clearance for the floating dock.
            .animation(.snappy, value: mode)
        }
    }

    /// The app mark above the card, mirroring the reference's "Product Inc." lockup.
    private var brandHeader: some View {
        VStack(spacing: 12) {
            Image(systemName: "airplane.departure")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 58, height: 58)
                .background(
                    LinearGradient(colors: [Color(hex: 0x818CF8), Color(hex: 0x4F46E5)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: .rect(cornerRadius: 16)
                )
            Text("TripSplit")
                .font(.headline)
        }
        .padding(.top, 12)
    }

    /// The single centered card: title, subtitle, fields, primary action, and the
    /// sign-in/sign-up switch link at the bottom.
    private var card: some View {
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                Text(LocalizedStringKey(mode.title))
                    .font(.title.bold())
                Text(LocalizedStringKey(subtitle))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.bottom, 8)

            field(placeholder: "name@company.com", text: $email, isSecure: false)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            if mode != .forgot {
                field(placeholder: mode == .signUp ? "Create a password" : "Enter your password",
                      text: $password, isSecure: true)
                    .textContentType(mode == .signUp ? .newPassword : .password)
            }

            if let infoMessage {
                banner(infoMessage, icon: "checkmark.circle.fill", color: Color(hex: 0x10B981))
            }
            if let errorMessage {
                banner(errorMessage, icon: "exclamationmark.triangle.fill", color: Color(hex: 0xEF4444))
            }

            primaryButton

            if mode == .signIn {
                Button("Forgot password?") { switchMode(.forgot) }
                    .font(.subheadline)
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
        .font(.body)
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
                if isWorking { ProgressView().tint(.white) }
                Text(LocalizedStringKey(isWorking ? "Please wait…" : mode.action))
                    .font(.headline)
                    .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(Color(hex: 0x4F46E5)).interactive(), in: .rect(cornerRadius: 14))
        .disabled(!canSubmit || isWorking)
        .opacity(canSubmit && !isWorking ? 1 : 0.5)
    }

    /// "Don't have an account? Sign up" / "Already have an account? Login".
    @ViewBuilder
    private var switchModeFooter: some View {
        switch mode {
        case .signIn:
            HStack(spacing: 5) {
                Text("Don't have an account?")
                    .foregroundStyle(.secondary)
                Button("Sign up") { switchMode(.signUp) }
                    .fontWeight(.semibold)
            }
            .font(.subheadline)
        case .signUp:
            HStack(spacing: 5) {
                Text("Already have an account?")
                    .foregroundStyle(.secondary)
                Button("Login") { switchMode(.signIn) }
                    .fontWeight(.semibold)
            }
            .font(.subheadline)
        case .forgot:
            Button("Back to login") { switchMode(.signIn) }
                .font(.subheadline)
        }
    }

    private func banner(_ text: String, icon: String, color: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.footnote.weight(.medium))
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
                        .font(.footnote)
                        .foregroundStyle(Color(hex: 0xEF4444))
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
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
