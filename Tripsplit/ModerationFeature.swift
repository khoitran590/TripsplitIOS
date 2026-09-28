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
        if target.contentType == "community_trip" {
            _ = try await rpc(
                "report_community_trip_guide",
                body: [
                    "p_guide_id": target.contentID.uuidString,
                    "p_reason": reason.rawValue,
                    "p_details": details,
                ],
                accessToken: accessToken
            )
            return
        }
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
                Text("Reports are prioritized by safety risk and retain a moderator audit trail. Content or accounts may be restricted or removed. Safety reports are reviewed within 24 hours; urgent threats receive priority.")
                Link("Contact safety support", destination: URL(string: "mailto:support@tripsplit.app?subject=TripSplit%20Safety")!)
            }
        }
        .navigationTitle("Community Standards")
    }
}

/// A blocked account as Settings lists it. The server returns ids only; blocking happens
/// from a trip feed, so the name and avatar come from trips you share. Someone no longer
/// in any of your trips has no local record and is listed generically.
struct BlockedAccount: Identifiable {
    let id: UUID
    let person: Person?

    static func resolve(_ ids: Set<UUID>, in trips: [Trip]) -> [BlockedAccount] {
        var people: [UUID: Person] = [:]
        for member in trips.flatMap(\.members) where people[member.id] == nil {
            people[member.id] = member
        }
        return ids.map { BlockedAccount(id: $0, person: people[$0]) }.sorted { lhs, rhs in
            switch (lhs.person?.name, rhs.person?.name) {
            case let (l?, r?) where l != r: l.localizedCaseInsensitiveCompare(r) == .orderedAscending
            case (_?, nil): true
            case (nil, _?): false
            default: lhs.id.uuidString < rhs.id.uuidString
            }
        }
    }
}

/// Settings → Blocked accounts: everyone you've blocked, with Unblock.
struct BlockedAccountsView: View {
    @Environment(TripStore.self) private var store
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var pendingUnblock: BlockedAccount?
    @State private var unblockingID: UUID?

    private var accounts: [BlockedAccount] {
        BlockedAccount.resolve(store.blockedUserIDs, in: store.trips)
    }

    var body: some View {
        List {
            if let errorMessage {
                Section { Text(verbatim: errorMessage).foregroundStyle(Theme.negative) }
            }
            if !accounts.isEmpty {
                Section {
                    ForEach(accounts) { account in
                        row(account)
                    }
                } footer: {
                    Text("You won't see their posts or comments, and neither of you can interact with the other in a shared trip feed.")
                }
            }
        }
        .overlay {
            if accounts.isEmpty && errorMessage == nil {
                if isLoading {
                    ProgressView()
                } else {
                    ContentUnavailableView(
                        "No blocked accounts",
                        systemImage: "hand.raised",
                        description: Text("You can block someone from a post in a trip's feed.")
                    )
                }
            }
        }
        .navigationTitle("Blocked accounts")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .confirmationDialog(
            "Unblock \(pendingUnblock.map(name(for:)) ?? "")?",
            isPresented: Binding(
                get: { pendingUnblock != nil },
                set: { if !$0 { pendingUnblock = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Unblock") {
                if let account = pendingUnblock { unblock(account) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Their posts and comments will show in your trip feeds again. Blocking removed any friend connection, so you'd need to add each other again.")
        }
    }

    private func row(_ account: BlockedAccount) -> some View {
        HStack(spacing: 12) {
            Group {
                if let person = account.person {
                    AvatarView(person: person, size: 36)
                } else {
                    Image(systemName: "person.crop.circle.fill")
                        .resizable()
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 36, height: 36)
                }
            }
            .accessibilityHidden(true)

            Text(verbatim: name(for: account))
                .frame(maxWidth: .infinity, alignment: .leading)

            if unblockingID == account.id {
                ProgressView()
            } else {
                Button("Unblock") { pendingUnblock = account }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Unblock \(name(for: account))")
                    .disabled(unblockingID != nil)
            }
        }
    }

    private func name(for account: BlockedAccount) -> String {
        let name = account.person?.name.trimmingCharacters(in: .whitespaces) ?? ""
        return name.isEmpty ? String(localized: "Former trip member") : name
    }

    private func load() async {
        errorMessage = nil
        do {
            try await store.refreshBlockedUsers()
        } catch {
            errorMessage = (error as? AuthError)?.message ?? String(localized: "Blocked accounts couldn't be loaded. Pull to try again.")
        }
        isLoading = false
    }

    private func unblock(_ account: BlockedAccount) {
        pendingUnblock = nil
        unblockingID = account.id
        errorMessage = nil
        Task {
            do {
                try await store.unblockUser(account.id)
            } catch {
                errorMessage = (error as? AuthError)?.message ?? String(localized: "The account couldn't be unblocked. Try again.")
            }
            unblockingID = nil
        }
    }
}
