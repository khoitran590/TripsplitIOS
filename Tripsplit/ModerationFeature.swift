import SwiftUI

struct ModerationTarget: Identifiable {
    let contentType: String
    let contentID: UUID
    let authorID: UUID
    let label: String

    var id: String { "\(contentType):\(contentID.uuidString)" }
}

enum ReportReason: String, CaseIterable, Identifiable {
    case spam, harassment, hate, sexual, violence, privacy, other
    var id: String { rawValue }
    var label: String {
        switch self {
        case .spam: "Spam or scam"
        case .harassment: "Harassment or bullying"
        case .hate: "Hate speech"
        case .sexual: "Sexual content"
        case .violence: "Violence or threats"
        case .privacy: "Privacy violation"
        case .other: "Something else"
        }
    }
}

actor ModerationService {
    static let shared = ModerationService()

    func blockedUserIDs(accessToken: String) async throws -> Set<UUID> {
        let data = try await rpc("blocked_user_ids", body: [:], accessToken: accessToken)
        return Set(try JSONDecoder().decode([UUID].self, from: data))
    }

    func setBlocked(_ blocked: Bool, userID: UUID, accessToken: String) async throws {
        _ = try await rpc(
            "set_user_block",
            body: ["p_blocked_user_id": userID.uuidString, "p_blocked": blocked],
            accessToken: accessToken
        )
    }

    func report(_ target: ModerationTarget, reason: ReportReason, details: String, accessToken: String) async throws {
        _ = try await rpc(
            "report_content",
            body: [
                "p_content_type": target.contentType,
                "p_content_id": target.contentID.uuidString,
                "p_reason": reason.rawValue,
                "p_details": details,
            ],
            accessToken: accessToken
        )
    }

    private func rpc(_ name: String, body: [String: Any], accessToken: String) async throws -> Data {
        guard let url = URL(string: "\(SupabaseConfig.url)/rest/v1/rpc/\(name)") else {
            throw AuthError(message: "Supabase isn't configured.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await BackendSecurity.secureSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let detail = ReceiptStorage.messageField(from: String(data: data, encoding: .utf8) ?? "")
            throw AuthError(message: detail ?? "The moderation request failed.", statusCode: status)
        }
        return data
    }
}

struct ReportContentView: View {
    let target: ModerationTarget

    @Environment(TripStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var reason: ReportReason = .spam
    @State private var details = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Report \(target.label)") {
                    Picker("Reason", selection: $reason) {
                        ForEach(ReportReason.allCases) { Text($0.label).tag($0) }
                    }
                    TextField("Additional details (optional)", text: $details, axis: .vertical)
                        .lineLimit(2...6)
                }
                if let errorMessage {
                    Section { Text(verbatim: errorMessage).foregroundStyle(Theme.negative) }
                }
                Section {
                    Button("Submit Report") { submit() }
                        .disabled(isSubmitting || details.count > 2000)
                } footer: {
                    Text("Reports are private and reviewed by the TripSplit moderation team. For immediate danger, contact local emergency services.")
                }
            }
            .navigationTitle("Report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isSubmitting)
                }
            }
            .interactiveDismissDisabled(isSubmitting)
        }
    }

    private func submit() {
        isSubmitting = true
        errorMessage = nil
        Task {
            do {
                try await store.reportContent(target, reason: reason, details: details)
                dismiss()
            } catch {
                errorMessage = (error as? AuthError)?.message ?? "The report could not be submitted."
            }
            isSubmitting = false
        }
    }
}

struct CommunityStandardsView: View {
    var body: some View {
        List {
            Section("Be respectful") {
                Text("Do not post harassment, hate speech, threats, sexual exploitation, graphic violence, scams, or another person's private information.")
            }
            Section("Use the safety tools") {
                Text("Use Report on a post or comment to send it for private review. Blocking immediately hides that person's feed content and prevents direct feed interaction in either direction.")
            }
            Section("Review process") {
                Text("Reports are prioritized by safety risk and retain a moderator audit trail. Content or accounts may be restricted or removed. Before public launch, TripSplit must publish a staffed support address and response-time commitment here.")
            }
        }
        .navigationTitle("Community Standards")
    }
}
