import SwiftUI

/// Presentation state is independent of the wording or language of a message.
enum ActionFeedback: Equatable {
    case success(String)
    case failure(String)

    var message: String {
        switch self {
        case .success(let message), .failure(let message): message
        }
    }

    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}

struct ActionFeedbackView: View {
    let feedback: ActionFeedback

    var body: some View {
        Label(feedback.message, systemImage: feedback.isSuccess ? "checkmark.circle" : "exclamationmark.circle")
            .font(Theme.Typography.metadata)
            .foregroundStyle(feedback.isSuccess ? Theme.positive : Theme.negative)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor @Observable
final class TripInvitationState {
    var email = ""
    var manualMemberName = ""
    private(set) var link: URL?
    private(set) var feedback: ActionFeedback?
    private(set) var isBusy = false

    var canInvite: Bool {
        !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isBusy
    }

    @discardableResult
    func invite(using send: (String) async throws -> Void) async -> Bool {
        guard canInvite else { return false }
        isBusy = true
        feedback = nil
        let submittedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { isBusy = false }
        do {
            try await send(submittedEmail)
            email = ""
            feedback = .success(String(localized: "Invitation pending. Membership starts only after the recipient accepts."))
            return true
        } catch {
            feedback = .failure((error as? AuthError)?.message ?? error.localizedDescription)
            return false
        }
    }

    @discardableResult
    func generateLink(using generate: () async throws -> URL) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        feedback = nil
        defer { isBusy = false }
        do {
            link = try await generate()
            feedback = .success(String(localized: "Invitation link ready to share."))
            return true
        } catch {
            feedback = .failure((error as? AuthError)?.message ?? error.localizedDescription)
            return false
        }
    }

    func didCopyLink() {
        guard link != nil else { return }
        feedback = .success(String(localized: "Invitation link copied."))
    }
}

/// Used by trip details and itinerary tripmates. The parent retains disclosure state
/// and can refresh its pending-invitations list after a successful request.
struct TripInvitationControls: View {
    @Environment(TripStore.self) private var store
    let tripID: Trip.ID
    @Bindable var state: TripInvitationState
    var onChanged: () async -> Void = {}

    var body: some View {
        VStack(spacing: Theme.Space.content) {
            HStack(spacing: Theme.Space.compact) {
                TextField("Add manual member", text: $state.manualMemberName)
                    .font(Theme.Typography.secondary)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .fieldFill()
                Button {
                    store.addManualMember(name: state.manualMemberName, to: tripID)
                    state.manualMemberName = ""
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Theme.onAccent)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .actionFill(tint: Theme.accent, in: .circle)
                .disabled(state.manualMemberName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Add manual member")
            }

            TextField("Invite by email", text: $state.email)
                .textInputAutocapitalization(.never)
                .keyboardType(.emailAddress)
                .autocorrectionDisabled()
                .font(Theme.Typography.secondary)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .fieldFill()
                .disabled(state.isBusy)

            Button {
                Task {
                    if await state.invite(using: { email in
                        try await store.inviteMember(email: email, displayName: nil, to: tripID)
                    }) { await onChanged() }
                }
            } label: {
                Label("Invite Member", systemImage: "person.badge.plus")
            }
            .buttonStyle(AppActionStyle())
            .disabled(!state.canInvite)

           Divider()

            Button {
                Task {
                    if await state.generateLink(using: {
                        try await store.createInvitationLink(for: tripID)
                    }) { await onChanged() }
                }
            } label: {
                Label("Generate Invitation Link", systemImage: "link")
            }
            .buttonStyle(AppActionStyle())
            .disabled(state.isBusy)

            if state.isBusy { ProgressView().accessibilityLabel("Creating invitation") }

            if let link = state.link {
                HStack(spacing: Theme.Space.compact) {
                    Text(verbatim: link.absoluteString)
                        .font(Theme.Typography.metadata)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1).truncationMode(.middle)
                    Button {
                        UIPasteboard.general.string = link.absoluteString
                        state.didCopyLink()
                    } label: {
                        Image(systemName: "doc.on.doc").frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Copy invitation link")
                    ShareLink(item: link) {
                        Image(systemName: "square.and.arrow.up").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Share invitation link")
                }
                .padding(.horizontal, Theme.Space.content)
                .fieldFill()
            }

            if let feedback = state.feedback { ActionFeedbackView(feedback: feedback) }
        }
    }
}
