import SwiftUI

enum AIConsentPurpose: String, CaseIterable, Identifiable {
    case receiptProcessing = "receipt_processing"
    case itineraryGeneration = "itinerary_generation"

    nonisolated var id: String { rawValue }

    /// Provider changes require fresh consent only for the affected purpose. Keeping these
    /// versions separate prevents a receipt-provider update from disrupting itinerary AI.
    nonisolated var consentVersion: String {
        switch self {
        case .receiptProcessing: "2026-08-05"
        case .itineraryGeneration: "2026-08-06"
        }
    }

    var title: String {
        switch self {
        case .receiptProcessing: "Cloud-assisted receipt scanning"
        case .itineraryGeneration: "AI itinerary planning"
        }
    }

    var disclosure: String {
        switch self {
        case .receiptProcessing:
            "TripSplit will send the receipt photo to Anthropic Claude to identify line items, tax, tip, and totals. If Claude cannot complete the scan, TripSplit will send the photo to Google Gemini as a backup. If you decline, Apple Vision will scan entirely on this device and you can enter anything manually."
        case .itineraryGeneration:
            "TripSplit will send the trip destination, dates, budget, and existing itinerary text to Anthropic Claude, which may search the web to suggest current places and activities. If Claude cannot draft a plan, TripSplit will send the same details to Google Gemini as a backup, which may use Google Search grounding. If you decline, you can continue building the itinerary manually."
        }
    }

    var providerSummary: String {
        switch self {
        case .receiptProcessing: "Anthropic Claude (primary) and Google Gemini (backup)"
        case .itineraryGeneration: "Anthropic Claude with web search (primary) and Google Gemini with Google Search grounding (backup)"
        }
    }
}

enum AIConsentPreferences {
    nonisolated static func hasDecision(_ purpose: AIConsentPurpose, userID: UUID) -> Bool {
        let value = UserDefaults.standard.string(forKey: key(purpose, userID: userID))
        return value == purpose.consentVersion || value == "declined:\(purpose.consentVersion)"
    }

    nonisolated static func isGranted(_ purpose: AIConsentPurpose, userID: UUID) -> Bool {
        UserDefaults.standard.string(forKey: key(purpose, userID: userID)) == purpose.consentVersion
    }

    nonisolated static func setGranted(_ granted: Bool, purpose: AIConsentPurpose, userID: UUID) {
        let storageKey = key(purpose, userID: userID)
        if granted {
            UserDefaults.standard.set(purpose.consentVersion, forKey: storageKey)
        } else {
            UserDefaults.standard.set("declined:\(purpose.consentVersion)", forKey: storageKey)
        }
    }

    nonisolated private static func key(_ purpose: AIConsentPurpose, userID: UUID) -> String {
        "tripsplit.aiConsent.\(userID.uuidString.lowercased()).\(purpose.rawValue)"
    }
}

actor AIConsentService {
    static let shared = AIConsentService()

    nonisolated static func userFacingErrorMessage(
        data: Data,
        statusCode: Int,
        purpose: AIConsentPurpose
    ) -> String {
        let rawResponse = String(data: data, encoding: .utf8) ?? ""
        let normalized = rawResponse.lowercased()

        if statusCode == 404
            || normalized.contains("pgrst202")
            || normalized.contains("schema cache")
            || normalized.contains("could not find the function") {
            let fallback = purpose == .receiptProcessing
                ? "Use On-Device Scan"
                : "Continue Without AI"
            return "Cloud AI is temporarily unavailable. Choose \(fallback) below and try again later."
        }

        if statusCode == 401 || statusCode == 403 {
            return "Your session could not authorize this privacy choice. Sign in again and retry."
        }

        if statusCode >= 500 {
            return "Cloud AI is temporarily unavailable. Your data was not sent. Try again later."
        }

        return ReceiptStorage.messageField(from: rawResponse)
            ?? "Your privacy choice could not be saved. Your data was not sent."
    }

    func setConsent(_ granted: Bool, purpose: AIConsentPurpose, accessToken: String) async throws {
        guard let url = URL(string: "\(SupabaseConfig.url)/rest/v1/rpc/set_ai_consent") else {
            throw AuthError(message: "Supabase isn't configured.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "p_purpose": purpose.rawValue,
            "p_consent_version": purpose.consentVersion,
            "p_granted": granted,
        ])
        let (data, response) = try await BackendSecurity.secureSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw AuthError(
                message: Self.userFacingErrorMessage(data: data, statusCode: status, purpose: purpose),
                statusCode: status
            )
        }
    }
}

/// Contextual, unbundled consent shown before the first transfer for each AI purpose.
struct AIConsentDisclosureView: View {
    let purpose: AIConsentPurpose
    let onDecision: (Bool) -> Void

    @Environment(TripStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showPrivacyPolicy = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Image(systemName: "sparkles.rectangle.stack.fill")
                        .font(.system(size: 42))
                        .foregroundStyle(Theme.accent)

                    Text(purpose.title)
                        .font(.app(.title2, .bold))
                    Text(purpose.disclosure)
                        .font(.app(.body))
                    Label("Providers: \(purpose.providerSummary)", systemImage: "network")
                        .font(.app(.subheadline))
                    Text("TripSplit does not use this content for advertising and does not log receipt images, receipt text, or itinerary prompts. Provider handling is described in the Privacy Policy.")
                        .font(.app(.footnote))
                        .foregroundStyle(.secondary)

                    Button("Read Privacy Policy") { showPrivacyPolicy = true }
                        .font(.app(.subheadline, .semibold))

                    if let errorMessage {
                        Text(verbatim: errorMessage)
                            .font(.app(.footnote))
                            .foregroundStyle(Theme.negative)
                    }

                    Button { save(granted: true) } label: {
                        Label("Allow Cloud AI", systemImage: "checkmark.shield.fill")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaving)

                    Button { save(granted: false) } label: {
                        Text(purpose == .receiptProcessing ? "Use On-Device Scan" : "Continue Without AI")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isSaving)
                }
                .padding(24)
            }
            .navigationTitle("AI Privacy")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(isSaving)
            .sheet(isPresented: $showPrivacyPolicy) { PrivacyPolicyView() }
        }
    }

    private func save(granted: Bool) {
        guard !isSaving else { return }
        isSaving = true
        errorMessage = nil
        Task {
            do {
                if let token = try await store.authorizedAccessToken() {
                    if granted {
                        try await AIConsentService.shared.setConsent(true, purpose: purpose, accessToken: token)
                    } else {
                        // A declined transfer is safe immediately. Persist revocation
                        // best-effort so another client cannot use an older grant.
                        try? await AIConsentService.shared.setConsent(false, purpose: purpose, accessToken: token)
                    }
                } else if granted {
                    throw AuthError(message: "Sign in before enabling cloud AI.")
                }
                AIConsentPreferences.setGranted(granted, purpose: purpose, userID: store.currentUser.id)
                onDecision(granted)
                dismiss()
            } catch {
                errorMessage = (error as? AuthError)?.message ?? "Your privacy choice could not be saved."
            }
            isSaving = false
        }
    }
}

struct PrivacyPolicyView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("TripSplit Privacy Policy")
                        .font(.app(.title2, .bold))
                    Text("Last updated August 5, 2026")
                        .font(.app(.caption))
                        .foregroundStyle(.secondary)
                    policySection("Data we use", "Account and profile details, trip membership, itineraries, expenses, settlements, receipts, photos, posts, comments, friendships, place information, and privacy choices are used to provide the features you request.")
                    policySection("Cloud providers", "TripSplit stores account and app data with Supabase. After receipt-processing consent, TripSplit sends the receipt image to Anthropic Claude first and to Google Gemini only if Claude cannot complete the scan. AI itinerary planning sends the destination, dates, budget, and existing plan text to Anthropic Claude first and to Google Gemini only if Claude cannot draft a plan; either provider may search the web for current places. Both happen only after separate consent.")
                    policySection("Retention", "TripSplit retains cloud data while your account or shared records need it. The app's AI proxy does not intentionally persist prompts, receipt images, or provider responses in logs. Provider-side retention is governed by the production cloud agreements. Device caches are protected and removed at sign-out or account deletion.")
                    policySection("Your choices", "You can decline or revoke cloud AI, use manual and on-device alternatives, edit profile information, sign out, and permanently delete your account in Settings. Deletion removes owned trips and user-generated content; shared financial history may retain a pseudonymous participant record so other members' balances remain accurate.")
                    policySection("Security and contact", "TripSplit uses HTTPS, private object storage, row-level authorization, Keychain session storage, and server-side provider credentials. Privacy questions can be sent to support@tripsplit.app.")
                    Link("Email privacy support", destination: URL(string: "mailto:support@tripsplit.app?subject=TripSplit%20Privacy")!)
                        .font(.app(.body, .semibold))
                }
                .padding(24)
            }
            .navigationTitle("Privacy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func policySection(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.app(.headline))
            Text(text).font(.app(.body)).foregroundStyle(.secondary)
        }
    }
}

struct AIPrivacyChoicesView: View {
    @Environment(TripStore.self) private var store
    @State private var workingPurpose: AIConsentPurpose?
    @State private var message: String?

    var body: some View {
        List {
            Section {
                ForEach(AIConsentPurpose.allCases) { purpose in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(purpose.title)
                            Text(AIConsentPreferences.isGranted(purpose, userID: store.currentUser.id) ? "Allowed" : "Not allowed")
                                .font(.app(.caption)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if workingPurpose == purpose {
                            ProgressView()
                        } else if AIConsentPreferences.isGranted(purpose, userID: store.currentUser.id) {
                            Button("Revoke", role: .destructive) { revoke(purpose) }
                        }
                    }
                }
            } footer: {
                Text("Revocation blocks future cloud transfers. On-device and manual features remain available.")
            }
            if let message { Section { Text(verbatim: message).foregroundStyle(Theme.negative) } }
        }
        .navigationTitle("Privacy & AI")
    }

    private func revoke(_ purpose: AIConsentPurpose) {
        workingPurpose = purpose
        message = nil
        Task {
            do {
                guard let token = try await store.authorizedAccessToken() else {
                    throw AuthError(message: "Sign in to update this choice.")
                }
                try await AIConsentService.shared.setConsent(false, purpose: purpose, accessToken: token)
                AIConsentPreferences.setGranted(false, purpose: purpose, userID: store.currentUser.id)
            } catch {
                message = (error as? AuthError)?.message ?? "Your privacy choice could not be saved."
            }
            workingPurpose = nil
        }
    }
}
