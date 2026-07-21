import SwiftUI

// MARK: - Models

/// A profile viewed through its share link. Decoded from the `profile_by_token` RPC,
/// which returns identity + a lightweight trip summary regardless of trip membership.
struct PublicProfile: Decodable {
    let userID: UUID
    var isSelf: Bool = false
    /// Relationship of the viewer to this profile: `none`, `requested` (I sent a
    /// pending request), `incoming` (they sent me one), or `accepted`.
    var friendStatus: String = "none"
    var displayName: String = ""
    var avatarPath: String?
    var bio: String = ""
    var dateOfBirth: Date?
    var visitedPlaceNames: [String] = []
    var trips: [PublicTripSummary] = []

    enum CodingKeys: String, CodingKey {
        case userID, isSelf, friendStatus, displayName, avatarPath, bio
        case dateOfBirth, visitedPlaces, trips
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userID = try c.decode(UUID.self, forKey: .userID)
        isSelf = try c.decodeIfPresent(Bool.self, forKey: .isSelf) ?? false
        friendStatus = try c.decodeIfPresent(String.self, forKey: .friendStatus) ?? "none"
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        avatarPath = try c.decodeIfPresent(String.self, forKey: .avatarPath)
        bio = try c.decodeIfPresent(String.self, forKey: .bio) ?? ""
        if let raw = try c.decodeIfPresent(String.self, forKey: .dateOfBirth) {
            dateOfBirth = UserProfile.dobFormatter.date(from: raw)
        }
        visitedPlaceNames = try c.decodeIfPresent([String].self, forKey: .visitedPlaces) ?? []
        trips = try c.decodeIfPresent([PublicTripSummary].self, forKey: .trips) ?? []
    }

    /// A safe, non-empty display name for headers.
    var name: String { displayName.trimmingCharacters(in: .whitespaces).isEmpty ? "TripSplit User" : displayName }

    /// A `Person` shim so the shared avatar/initials views can render this profile.
    var person: Person {
        Person(id: userID, name: name, color: personColor(for: userID), avatarURL: avatarPath)
    }

    /// Stored place names first, then trip locations not already listed — mirrors the
    /// owner's own "Where I've been" merge, with trip dates attached where known.
    var visitedPlaces: [VisitedPlace] {
        var places = visitedPlaceNames.map { VisitedPlace(name: $0, date: nil) }
        for trip in trips {
            guard let location = trip.location?.trimmingCharacters(in: .whitespaces), !location.isEmpty else { continue }
            let date = trip.startDate ?? trip.endDate
            if let index = places.firstIndex(where: { $0.name.caseInsensitiveCompare(location) == .orderedSame }) {
                if places[index].date == nil, let date {
                    places[index] = VisitedPlace(name: places[index].name, date: date)
                }
            } else {
                places.append(VisitedPlace(name: location, date: date))
            }
        }
        return places
    }
}

/// A trip as shown on someone else's profile: just enough to render a cover card.
struct PublicTripSummary: Identifiable, Decodable {
    let id: UUID
    var name: String = "Trip"
    var location: String?
    var startDate: Date?
    var endDate: Date?
    var coverImageURL: String?

    enum CodingKeys: String, CodingKey {
        case id, name, location, startDate, endDate, coverImageURL
    }

    /// Trip dates round-trip through the blob as ISO-8601 strings (`.iso8601` strategy).
    private static let iso: ISO8601DateFormatter = ISO8601DateFormatter()

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Trip"
        location = try c.decodeIfPresent(String.self, forKey: .location)
        if let raw = try c.decodeIfPresent(String.self, forKey: .startDate) { startDate = Self.iso.date(from: raw) }
        if let raw = try c.decodeIfPresent(String.self, forKey: .endDate) { endDate = Self.iso.date(from: raw) }
        coverImageURL = try c.decodeIfPresent(String.self, forKey: .coverImageURL)
    }

    /// Compact "Apr 2025" style label, matching the profile's place cards.
    var dateText: String? {
        (startDate ?? endDate)?.formatted(.dateTime.month(.abbreviated).year())
    }
}

/// An accepted friend, from the `friends_overview` RPC. Carries the friend's own
/// share token so tapping their row opens their full profile.
struct Friend: Identifiable, Decodable {
    let userID: UUID
    var displayName: String = ""
    var avatarPath: String?
    var bio: String = ""
    var shareToken: String = ""
    var id: UUID { userID }

    var name: String { displayName.trimmingCharacters(in: .whitespaces).isEmpty ? "TripSplit User" : displayName }
    var person: Person { Person(id: userID, name: name, color: personColor(for: userID), avatarURL: avatarPath) }
}

/// A pending friend request (incoming or outgoing).
struct FriendRequest: Identifiable, Decodable {
    let friendshipID: UUID
    let userID: UUID
    var displayName: String = ""
    var avatarPath: String?
    var id: UUID { friendshipID }

    var name: String { displayName.trimmingCharacters(in: .whitespaces).isEmpty ? "TripSplit User" : displayName }
    var person: Person { Person(id: userID, name: name, color: personColor(for: userID), avatarURL: avatarPath) }
}

struct FriendsOverview: Decodable {
    var friends: [Friend] = []
    var incoming: [FriendRequest] = []
    var outgoing: [FriendRequest] = []
}

/// Wraps a share token so it can drive an `.sheet(item:)` presentation.
struct SharedProfileLink: Identifiable {
    let id = UUID()
    let token: String
}

/// Deterministic member-palette color for a user id. Uses raw UUID bytes (not
/// `hashValue`, which is per-launch randomized) so a person keeps one color.
func personColor(for id: UUID) -> Color {
    let bytes = id.uuid
    let index = Int(bytes.0 ^ bytes.7 ^ bytes.15) % memberPalette.count
    return Color(hex: memberPalette[index])
}

// MARK: - Repository (Supabase RPC)

/// Direct REST calls to the friends/profile RPCs. Stateless actor mirroring
/// `ProfilesRepository`; all functions are `security definer` and granted to
/// `authenticated`, so a valid user JWT is required.
actor FriendsRepository {
    static let shared = FriendsRepository()
    private let session = BackendSecurity.secureSession

    func profile(token: String, accessToken: String) async throws -> PublicProfile {
        let data = try await rpc("profile_by_token", ["p_token": token], accessToken: accessToken)
        return try JSONDecoder().decode(PublicProfile.self, from: data)
    }

    func overview(accessToken: String) async throws -> FriendsOverview {
        let data = try await rpc("friends_overview", [:], accessToken: accessToken)
        return try JSONDecoder().decode(FriendsOverview.self, from: data)
    }

    /// Returns the resulting edge state: `requested` or `accepted`.
    func sendRequest(token: String, accessToken: String) async throws -> String {
        let data = try await rpc("send_friend_request", ["p_token": token], accessToken: accessToken)
        return (try? JSONDecoder().decode(String.self, from: data)) ?? "requested"
    }

    func respond(friendshipID: UUID, accept: Bool, accessToken: String) async throws {
        _ = try await rpc("respond_friend_request",
                          ["p_friendship_id": friendshipID.uuidString, "p_accept": accept],
                          accessToken: accessToken)
    }

    func removeFriend(userID: UUID, accessToken: String) async throws {
        _ = try await rpc("remove_friend", ["p_other_user_id": userID.uuidString], accessToken: accessToken)
    }

    private func rpc(_ name: String, _ params: [String: Any], accessToken: String) async throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: params)
        return try await send("POST", "/rest/v1/rpc/\(name)", accessToken: accessToken, body: body)
    }

    private func send(_ method: String, _ path: String, accessToken: String, body: Data? = nil) async throws -> Data {
        guard SupabaseConfig.isConfigured, let url = URL(string: SupabaseConfig.url + path) else {
            throw AuthError(message: "Supabase isn't configured.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            BackendSecurity.log("Friends network failure", error: error)
            throw AuthError(message: "Couldn't reach the server. Check your connection.")
        }
        guard let http = response as? HTTPURLResponse else {
            throw AuthError(message: "No response from the server.")
        }
        guard (200..<300).contains(http.statusCode) else {
            // Surface the server's own message (e.g. "This profile link is invalid.") when present.
            let serverMessage = (try? JSONDecoder().decode(PostgRESTError.self, from: data))?.message
            BackendSecurity.log("Friends request rejected", statusCode: http.statusCode)
            throw AuthError(message: serverMessage ?? "Request failed (HTTP \(http.statusCode)).",
                            statusCode: http.statusCode)
        }
        return data
    }

    private struct PostgRESTError: Decodable { let message: String? }
}

// MARK: - Store

/// Main-actor observable holder for the signed-in user's friends graph and share
/// token. Reuses `TripStore` for token acquisition/refresh and image signing so the
/// same session handling covers friends requests. Injected via `.environment`.
@MainActor
@Observable
final class FriendsStore {
    var friends: [Friend] = []
    var incoming: [FriendRequest] = []
    var outgoing: [FriendRequest] = []
    private(set) var shareToken: String?

    /// Set once from `ContentView`; used only for token/session plumbing.
    @ObservationIgnored weak var store: TripStore?

    /// Pulls the friends overview and (once) the user's own share token.
    func refresh() async {
        guard let store, let token = try? await store.authorizedAccessToken() else { return }
        if let overview = try? await store.withFreshTokenIfNeeded(initialToken: token, operation: { t in
            try await FriendsRepository.shared.overview(accessToken: t)
        }) {
            friends = overview.friends
            incoming = overview.incoming
            outgoing = overview.outgoing
        }
        if shareToken == nil {
            let userID = store.currentUser.id
            shareToken = try? await store.withFreshTokenIfNeeded(initialToken: token) { t in
                try await ProfilesRepository.shared.fetchShareToken(userID: userID, accessToken: t)
            } ?? nil
        }
    }

    /// The shareable deep link, mirroring trip invite links (`tripsplit://profile?token=…`).
    func shareURL() -> URL? {
        guard let shareToken else { return nil }
        var components = URLComponents()
        components.scheme = "tripsplit"
        components.host = "profile"
        components.queryItems = [URLQueryItem(name: "token", value: shareToken)]
        return components.url
    }

    func viewProfile(token: String) async throws -> PublicProfile {
        guard let store, let accessToken = try await store.authorizedAccessToken() else {
            throw AuthError(message: "Sign in to view profiles.")
        }
        return try await store.withFreshTokenIfNeeded(initialToken: accessToken) { t in
            try await FriendsRepository.shared.profile(token: token, accessToken: t)
        }
    }

    /// Sends a friend request via a share token; returns the resulting edge state.
    @discardableResult
    func addFriend(token: String) async throws -> String {
        guard let store, let accessToken = try await store.authorizedAccessToken() else {
            throw AuthError(message: "Sign in to add friends.")
        }
        let status = try await store.withFreshTokenIfNeeded(initialToken: accessToken) { t in
            try await FriendsRepository.shared.sendRequest(token: token, accessToken: t)
        }
        await refresh()
        return status
    }

    func respond(_ request: FriendRequest, accept: Bool) async {
        guard let store, let accessToken = try? await store.authorizedAccessToken() else { return }
        try? await store.withFreshTokenIfNeeded(initialToken: accessToken) { t in
            try await FriendsRepository.shared.respond(friendshipID: request.friendshipID, accept: accept, accessToken: t)
        }
        await refresh()
    }

    func removeFriend(_ userID: UUID) async {
        guard let store, let accessToken = try? await store.authorizedAccessToken() else { return }
        try? await store.withFreshTokenIfNeeded(initialToken: accessToken) { t in
            try await FriendsRepository.shared.removeFriend(userID: userID, accessToken: t)
        }
        await refresh()
    }

    func reset() {
        friends = []
        incoming = []
        outgoing = []
        shareToken = nil
    }
}

// MARK: - Friends section (on the user's own profile)

/// Incoming requests + accepted friends, shown as a card on `ProfileDetailView`.
/// Tapping a friend opens their full profile via `onOpenProfile`.
struct FriendsSection: View {
    @Environment(FriendsStore.self) private var friends
    /// Called with a share token to present that person's profile.
    var onOpenProfile: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Friends")
                    .font(.app(.title3, .bold))
                Spacer()
                if !friends.friends.isEmpty {
                    Text(verbatim: "\(friends.friends.count)")
                        .font(.app(.subheadline, .semibold))
                        .foregroundStyle(.secondary)
                }
            }

            if !friends.incoming.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Requests")
                        .font(.app(.subheadline, .semibold))
                        .foregroundStyle(.secondary)
                    ForEach(friends.incoming) { request in
                        RequestRow(request: request)
                    }
                }
                .padding(14)
                .glassEffect(.regular, in: .rect(cornerRadius: 20))
            }

            if friends.friends.isEmpty {
                Text("Share your profile to connect with travel buddies. Friends you add show up here.")
                    .font(.app(.subheadline))
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(friends.friends) { friend in
                            Button { onOpenProfile(friend.shareToken) } label: {
                                VStack(spacing: 8) {
                                    AvatarView(person: friend.person, size: 62)
                                    Text(friend.name)
                                        .font(.app(.caption, .medium))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                        .frame(width: 72)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.horizontal, -16)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One incoming friend request with accept/decline actions.
private struct RequestRow: View {
    @Environment(FriendsStore.self) private var friends
    let request: FriendRequest
    @State private var busy = false

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(person: request.person, size: 40)
            Text(request.name)
                .font(.app(.subheadline, .medium))
                .lineLimit(1)
            Spacer()
            if busy {
                ProgressView()
            } else {
                Button {
                    busy = true
                    Task { await friends.respond(request, accept: false); busy = false }
                } label: {
                    Image(systemName: "xmark")
                        .font(.app(.subheadline, .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 36, height: 36)
                        .background(.secondary.opacity(0.12), in: .circle)
                }
                .buttonStyle(.plain)
                Button {
                    busy = true
                    Task { await friends.respond(request, accept: true); busy = false }
                } label: {
                    Image(systemName: "checkmark")
                        .font(.app(.subheadline, .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Theme.accent, in: .circle)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Shared profile view (someone else's profile)

/// Renders a profile opened via its share link: identity, bio, birthday, places,
/// and trips, plus an Add-friend control reflecting the current relationship.
struct SharedProfileView: View {
    @Environment(FriendsStore.self) private var friends
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss
    let token: String

    @State private var profile: PublicProfile?
    @State private var loadError: String?
    @State private var isLoading = true
    @State private var friendStatus = "none"
    @State private var actionBusy = false

    var body: some View {
        Group {
            if let profile {
                content(profile)
            } else if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                errorState
            }
        }
        .background { AppBackground() }
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
        .task(id: token) { await load() }
    }

    private func content(_ profile: PublicProfile) -> some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 12) {
                    AvatarView(person: profile.person, size: 110)
                    Text(profile.name).font(.app(.title, .bold))
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 8)

                if !profile.isSelf {
                    addFriendButton
                }

                if !profile.bio.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text(profile.bio)
                        .font(.app(.body))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .glassEffect(.regular, in: .rect(cornerRadius: 20))
                }

                if let dob = profile.dateOfBirth {
                    HStack(spacing: 14) {
                        SettingsIconBadge(icon: "birthday.cake.fill", color: Color(hex: 0xEC4899))
                        Text("Birthday").font(.app(.body))
                        Spacer()
                        Text(verbatim: dob.formatted(date: .long, time: .omitted))
                            .font(.app(.body))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .glassEffect(.regular, in: .rect(cornerRadius: 20))
                }

                if !profile.visitedPlaces.isEmpty {
                    section(title: "Where \(profile.name) has been") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 14) {
                                ForEach(profile.visitedPlaces) { VisitedPlaceCard(place: $0) }
                            }
                            .padding(.horizontal, 16)
                        }
                        .padding(.horizontal, -16)
                    }
                }

                if !profile.trips.isEmpty {
                    section(title: "Trips") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 14) {
                                ForEach(profile.trips) { SummaryTripCard(trip: $0) }
                            }
                            .padding(.horizontal, 16)
                        }
                        .padding(.horizontal, -16)
                    }
                }
            }
            .padding()
            .padding(.bottom, 40)
        }
    }

    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(verbatim: title).font(.app(.title3, .bold))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var addFriendButton: some View {
        switch friendStatus {
        case "accepted":
            Label("Friends", systemImage: "checkmark.circle.fill")
                .font(.app(.subheadline, .semibold))
                .foregroundStyle(Theme.positive)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .glassEffect(.regular, in: .capsule)
        case "requested":
            Label("Request sent", systemImage: "clock")
                .font(.app(.subheadline, .semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .glassEffect(.regular, in: .capsule)
        default:
            Button {
                actionBusy = true
                Task {
                    if let status = try? await friends.addFriend(token: token) { friendStatus = status }
                    actionBusy = false
                }
            } label: {
                Group {
                    if actionBusy {
                        ProgressView().tint(.white)
                    } else {
                        Label(friendStatus == "incoming" ? "Accept friend" : "Add friend",
                              systemImage: "person.badge.plus")
                            .font(.app(.subheadline, .semibold))
                            .foregroundStyle(Theme.onAccent)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.tint(Theme.accent).interactive(), in: .capsule)
            .disabled(actionBusy)
        }
    }

    private var errorState: some View {
        VStack(spacing: 14) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.app(size: 40))
                .foregroundStyle(.secondary)
            Text(loadError ?? "Couldn't load this profile.")
                .font(.app(.subheadline))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load() async {
        guard auth.isAuthenticated else {
            isLoading = false
            loadError = "Sign in to view this profile."
            return
        }
        isLoading = true
        do {
            let loaded = try await friends.viewProfile(token: token)
            profile = loaded
            friendStatus = loaded.friendStatus
        } catch {
            loadError = (error as? AuthError)?.message ?? "Couldn't load this profile."
        }
        isLoading = false
    }
}

/// Cover card for a trip on someone else's profile (path + name only, no full Trip).
struct SummaryTripCard: View {
    let trip: PublicTripSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            cover
                .frame(width: 220, height: 148)
                .clipShape(.rect(cornerRadius: 18))

            Text(trip.name)
                .font(.app(.subheadline, .semibold))
                .lineLimit(1)

            if let location = trip.location?.trimmingCharacters(in: .whitespaces), !location.isEmpty {
                Label {
                    Text(verbatim: location)
                } icon: {
                    Image(systemName: "mappin.and.ellipse")
                }
                .font(.app(.caption))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            if let dateText = trip.dateText {
                Text(verbatim: dateText)
                    .font(.app(.caption))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 220, alignment: .leading)
    }

    @ViewBuilder
    private var cover: some View {
        if let path = trip.coverImageURL, !path.isEmpty {
            CachedStorageImage(path: path) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFill()
                } else {
                    coverFallback
                }
            }
        } else {
            coverFallback
        }
    }

    private var coverFallback: some View {
        LinearGradient(colors: [personColor(for: trip.id), personColor(for: trip.id).opacity(0.6)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay {
                Image(systemName: "airplane.departure")
                    .font(.app(size: 34, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.3))
            }
    }
}
