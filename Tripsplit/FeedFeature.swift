import SwiftUI
import PhotosUI
import UIKit
import MapKit

// MARK: - Trip feed models

/// A post on a trip's feed: text and/or photos shared by a member, with comments and
/// emoji reactions from the group. Unlike expenses, feed posts do NOT live in the trip's
/// JSON blob — each post is its own row in `public.trip_feed_posts`, so posting,
/// commenting, and reacting never race with expense edits or with activity on other
/// posts. Photos follow the receipts-bucket convention: the post stores object *paths*
/// resolved to signed URLs at display time.
nonisolated struct FeedPost: Identifiable, Codable {
    var id = UUID()
    var authorID: Person.ID
    var authorName: String
    var text: String
    var photoPaths: [String] = []
    /// Optional place tag the author attached when posting (display name only).
    var locationName: String?
    var date: Date
    var comments: [ExpenseComment] = []
    /// Emoji reactions: emoji → the members who dropped it.
    var reactions: [String: [Person.ID]] = [:]

    init(
        id: UUID = UUID(),
        authorID: Person.ID,
        authorName: String,
        text: String,
        photoPaths: [String] = [],
        locationName: String? = nil,
        date: Date = Date(),
        comments: [ExpenseComment] = [],
        reactions: [String: [Person.ID]] = [:]
    ) {
        self.id = id
        self.authorID = authorID
        self.authorName = authorName
        self.text = text
        self.photoPaths = photoPaths
        self.locationName = locationName
        self.date = date
        self.comments = comments
        self.reactions = reactions
    }
}

// MARK: - Feed repository (Supabase PostgREST)

/// Reads and writes `public.trip_feed_posts` directly over PostgREST. RLS scopes every
/// operation to trip members (see `supabase_schema.sql`): members read, authors insert
/// and edit their own posts, and authors or the trip owner delete. Comments/reactions go
/// through a database RPC which rejects attempts to alter another user's interactions.
actor FeedRepository {
    static let shared = FeedRepository()

    private let session = BackendSecurity.secureSession

    /// One table row. `comments`/`reactions` round-trip through the same Codable shapes
    /// the app uses elsewhere; dates inside them are client-encoded ISO 8601.
    private struct Row: Codable {
        var id: UUID
        var tripID: UUID
        var authorID: UUID
        var authorName: String
        var body: String
        var photoPaths: [String]
        var locationName: String?
        var comments: [ExpenseComment]
        var reactions: [String: [UUID]]
        var createdAt: Date

        enum CodingKeys: String, CodingKey {
            case id
            case tripID = "trip_id"
            case authorID = "author_id"
            case authorName = "author_name"
            case body
            case photoPaths = "photo_paths"
            case locationName = "location_name"
            case comments
            case reactions
            case createdAt = "created_at"
        }

        init(post: FeedPost, tripID: UUID) {
            id = post.id
            self.tripID = tripID
            authorID = post.authorID
            authorName = post.authorName
            body = post.text
            photoPaths = post.photoPaths
            locationName = post.locationName
            comments = post.comments
            reactions = post.reactions
            createdAt = post.date
        }

        var post: FeedPost {
            FeedPost(
                id: id,
                authorID: authorID,
                authorName: authorName,
                text: body,
                photoPaths: photoPaths,
                locationName: locationName,
                date: createdAt,
                comments: comments,
                reactions: reactions
            )
        }
    }

    /// Columns accepted when creating a post. Interaction state and timestamps are
    /// intentionally omitted: Postgres owns their defaults, so a client cannot seed a
    /// new post with forged comments/reactions or manipulate feed ordering.
    private struct InsertRow: Encodable {
        let id: UUID
        let tripID: UUID
        let authorID: UUID
        let authorName: String
        let body: String
        let photoPaths: [String]
        let locationName: String?

        enum CodingKeys: String, CodingKey {
            case id
            case tripID = "trip_id"
            case authorID = "author_id"
            case authorName = "author_name"
            case body
            case photoPaths = "photo_paths"
            case locationName = "location_name"
        }

        init(post: FeedPost, tripID: UUID) {
            id = post.id
            self.tripID = tripID
            authorID = post.authorID
            authorName = post.authorName
            body = post.text
            photoPaths = post.photoPaths
            locationName = post.locationName
        }
    }

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    /// Postgres renders `timestamptz` with fractional seconds, while dates the client
    /// wrote inside jsonb have none — accept both.
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            // Formatters are built per call (they're not Sendable, so they can't be
            // captured into this @Sendable closure); feed payloads are small enough
            // that this stays negligible.
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw) {
                return date
            }
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Unrecognized date: \(raw)"
            ))
        }
        return decoder
    }()

    /// All posts for a trip, newest first.
    func fetch(tripID: UUID, accessToken: String) async throws -> [FeedPost] {
        let data = try await send(
            "GET",
            "/rest/v1/trip_feed_posts?trip_id=eq.\(tripID.uuidString)&select=*&order=created_at.desc",
            accessToken: accessToken
        )
        return try decoder.decode([Row].self, from: data).map(\.post)
    }

    func insert(_ post: FeedPost, tripID: UUID, accessToken: String) async throws {
        let body = try encoder.encode(InsertRow(post: post, tripID: tripID))
        _ = try await send(
            "POST",
            "/rest/v1/trip_feed_posts",
            accessToken: accessToken,
            body: body,
            extraHeaders: ["Prefer": "return=minimal"]
        )
    }

    /// Pushes one post's comments and reactions through the hardened interaction RPC.
    /// The database validates that the caller changed only their own comments/reactions;
    /// a stale snapshot is rejected rather than overwriting another member's new activity.
    func updateInteractions(for post: FeedPost, accessToken: String) async throws {
        struct Parameters: Encodable {
            let postID: UUID
            let comments: [ExpenseComment]
            let reactions: [String: [UUID]]

            enum CodingKeys: String, CodingKey {
                case postID = "p_post_id"
                case comments = "p_comments"
                case reactions = "p_reactions"
            }
        }
        let body = try encoder.encode(Parameters(
            postID: post.id,
            comments: post.comments,
            reactions: post.reactions
        ))
        _ = try await send(
            "POST",
            "/rest/v1/rpc/update_feed_interactions",
            accessToken: accessToken,
            body: body,
            extraHeaders: ["Prefer": "return=minimal"]
        )
    }

    /// Rewrites a post's text and location tag (the author editing their own post).
    func updateBody(postID: UUID, text: String, locationName: String?, accessToken: String) async throws {
        struct Patch: Encodable {
            let body: String
            // Encode nil explicitly so clearing a location tag nulls the column
            // (encodeIfPresent would omit the key and leave the old tag in place).
            let locationName: String?
            enum CodingKeys: String, CodingKey {
                case body
                case locationName = "location_name"
            }
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(body, forKey: .body)
                try c.encode(locationName, forKey: .locationName)
            }
        }
        let body = try encoder.encode(Patch(body: text, locationName: locationName))
        _ = try await send(
            "PATCH",
            "/rest/v1/trip_feed_posts?id=eq.\(postID.uuidString)",
            accessToken: accessToken,
            body: body,
            extraHeaders: ["Prefer": "return=minimal"]
        )
    }

    func delete(postID: UUID, accessToken: String) async throws {
        _ = try await send("DELETE", "/rest/v1/trip_feed_posts?id=eq.\(postID.uuidString)", accessToken: accessToken)
    }

    private func send(
        _ method: String,
        _ path: String,
        accessToken: String,
        body: Data? = nil,
        extraHeaders: [String: String] = [:]
    ) async throws -> Data {
        guard SupabaseConfig.isConfigured, let url = URL(string: SupabaseConfig.url + path) else {
            throw AuthError(message: "Supabase isn't configured.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in extraHeaders { request.setValue(value, forHTTPHeaderField: key) }
        request.httpBody = body

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            BackendSecurity.log("Feed network failure", error: error)
            throw AuthError(message: "Couldn't reach the server. Check your connection.")
        }
        guard let http = response as? HTTPURLResponse else {
            BackendSecurity.log("Feed request returned no HTTP response")
            throw AuthError(message: "No response from the server.")
        }
        guard (200..<300).contains(http.statusCode) else {
            BackendSecurity.log("Feed request rejected", statusCode: http.statusCode)
            let detail = ReceiptStorage.messageField(from: String(data: data, encoding: .utf8) ?? "")
            throw AuthError(
                message: detail.map { "Feed request failed: \($0)" } ?? "Feed request failed (HTTP \(http.statusCode)).",
                statusCode: http.statusCode
            )
        }
        return data
    }
}

// MARK: - TripStore feed methods

/// Feed operations follow the app's concurrency rule: network I/O in the
/// `FeedRepository` actor, state applied back on the main actor. Interactions
/// (comments/reactions) update local state optimistically, then patch the row; on
/// failure the feed reloads from the server so the UI never drifts from the truth.
extension TripStore {
    func feedPosts(for tripID: Trip.ID) -> [FeedPost] {
        feedPostsByTrip[tripID] ?? []
    }

    /// True once `loadFeed` has completed at least once for the trip, so the UI can
    /// distinguish "still loading" from "genuinely empty".
    func hasLoadedFeed(for tripID: Trip.ID) -> Bool {
        feedPostsByTrip[tripID] != nil
    }

    func loadFeed(for tripID: Trip.ID) async throws {
        guard let accessToken = try await authorizedAccessToken() else {
            throw AuthError(message: "Sign in to view the trip feed.")
        }
        let posts = try await withFreshTokenIfNeeded(initialToken: accessToken) { token in
            try await FeedRepository.shared.fetch(tripID: tripID, accessToken: token)
        }
        feedPostsByTrip[tripID] = posts
    }

    /// Uploads one feed photo to the shared private `receipts` bucket and returns its
    /// storage path, namespaced under the uploader's lowercased user id for storage RLS.
    func uploadFeedPhoto(_ jpeg: Data, postID: FeedPost.ID, index: Int) async throws -> String {
        let path = "\(currentUser.id.uuidString.lowercased())/feed-\(postID.uuidString.lowercased())-\(index).jpg"
        return try await uploadReceipt(jpeg, path: path)
    }

    /// Inserts the post on the server first, then shows it — a post that failed to save
    /// should never appear in the feed.
    func addFeedPost(_ post: FeedPost, to tripID: Trip.ID) async throws {
        guard let accessToken = try await authorizedAccessToken() else {
            throw AuthError(message: "Sign in to post to the trip feed.")
        }
        try await withFreshTokenIfNeeded(initialToken: accessToken) { token in
            try await FeedRepository.shared.insert(post, tripID: tripID, accessToken: token)
        }
        feedPostsByTrip[tripID, default: []].insert(post, at: 0)
    }

    /// Rewrites the current user's own post (text + location tag) locally, then patches
    /// the row; a failed patch reloads the feed to resync (same pattern as interactions).
    func editFeedPost(_ postID: FeedPost.ID, in tripID: Trip.ID, text: String, locationName: String?) {
        guard var posts = feedPostsByTrip[tripID],
              let index = posts.firstIndex(where: { $0.id == postID }),
              posts[index].authorID == currentUser.id
        else { return }
        posts[index].text = text
        posts[index].locationName = locationName
        feedPostsByTrip[tripID] = posts
        Task {
            guard let accessToken = try? await authorizedAccessToken() else { return }
            do {
                try await withFreshTokenIfNeeded(initialToken: accessToken) { token in
                    try await FeedRepository.shared.updateBody(
                        postID: postID, text: text, locationName: locationName, accessToken: token
                    )
                }
            } catch {
                try? await loadFeed(for: tripID)
            }
        }
    }

    /// A member may delete their own posts; the trip creator may delete any post.
    /// (Mirrors the table's delete RLS policy.)
    func canDeleteFeedPost(_ post: FeedPost, in trip: Trip) -> Bool {
        post.authorID == currentUser.id || isCreator(of: trip)
    }

    func deleteFeedPost(_ postID: FeedPost.ID, in tripID: Trip.ID) {
        feedPostsByTrip[tripID]?.removeAll { $0.id == postID }
        Task {
            guard let accessToken = try? await authorizedAccessToken() else { return }
            do {
                try await withFreshTokenIfNeeded(initialToken: accessToken) { token in
                    try await FeedRepository.shared.delete(postID: postID, accessToken: token)
                }
            } catch {
                try? await loadFeed(for: tripID)
            }
        }
    }

    func addFeedComment(_ text: String, to postID: FeedPost.ID, in tripID: Trip.ID) {
        mutateFeedPost(postID, in: tripID) { post in
            post.comments.append(ExpenseComment(
                authorID: currentUser.id,
                authorName: currentUser.name,
                text: text
            ))
        }
    }

    /// Rewrites the current user's own comment in place and stamps it as edited.
    func editFeedComment(_ commentID: ExpenseComment.ID, text: String, in postID: FeedPost.ID, tripID: Trip.ID) {
        mutateFeedPost(postID, in: tripID) { post in
            guard let index = post.comments.firstIndex(where: { $0.id == commentID }),
                  post.comments[index].authorID == currentUser.id
            else { return }
            post.comments[index].text = text
            post.comments[index].editedAt = Date()
        }
    }

    func deleteFeedComment(_ commentID: ExpenseComment.ID, from postID: FeedPost.ID, in tripID: Trip.ID) {
        mutateFeedPost(postID, in: tripID) { post in
            guard post.comments.contains(where: {
                $0.id == commentID && $0.authorID == currentUser.id
            }) else { return }
            post.comments.removeAll { $0.id == commentID && $0.authorID == currentUser.id }
        }
    }

    /// Adds the current user's reaction with `emoji`, or removes it if already present.
    func toggleFeedReaction(_ emoji: String, on postID: FeedPost.ID, in tripID: Trip.ID) {
        mutateFeedPost(postID, in: tripID) { post in
            var reactors = post.reactions[emoji] ?? []
            if let existing = reactors.firstIndex(of: currentUser.id) {
                reactors.remove(at: existing)
            } else {
                reactors.append(currentUser.id)
            }
            post.reactions[emoji] = reactors.isEmpty ? nil : reactors
        }
    }

    /// Applies `change` to the post locally (instant UI), then patches the row's
    /// comments/reactions on the server; a failed patch reloads the feed to resync.
    private func mutateFeedPost(_ postID: FeedPost.ID, in tripID: Trip.ID, change: (inout FeedPost) -> Void) {
        guard var posts = feedPostsByTrip[tripID],
              let index = posts.firstIndex(where: { $0.id == postID })
        else { return }
        change(&posts[index])
        let updated = posts[index]
        feedPostsByTrip[tripID] = posts
        Task {
            guard let accessToken = try? await authorizedAccessToken() else { return }
            do {
                try await withFreshTokenIfNeeded(initialToken: accessToken) { token in
                    try await FeedRepository.shared.updateInteractions(for: updated, accessToken: token)
                }
            } catch {
                try? await loadFeed(for: tripID)
            }
        }
    }
}

// MARK: - Feed views

/// The Feed tab of a trip: a composer for new posts (text + up to 4 photos) followed by
/// the group's posts, newest first. Loaded on demand from `trip_feed_posts` the first
/// time the tab opens, with pull-style refresh via the reload button.
struct TripFeedView: View {
    @Environment(TripStore.self) private var store
    let tripID: Trip.ID

    @State private var loadError: String?
    @State private var isReloading = false

    private var posts: [FeedPost] { store.feedPosts(for: tripID) }

    var body: some View {
        FeedComposerCard(tripID: tripID)

        if let loadError {
            TripCard(title: "Trip Feed", icon: "photo.on.rectangle.angled") {
                VStack(spacing: 10) {
                    Text(verbatim: loadError)
                        .font(.app(.subheadline)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Retry") { Task { await reload() } }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                }
                .frame(maxWidth: .infinity)
            }
        } else if !store.hasLoadedFeed(for: tripID) {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
        } else if posts.isEmpty {
            TripCard(title: "Trip Feed", icon: "photo.on.rectangle.angled") {
                ContentUnavailableView(
                    "No posts yet",
                    systemImage: "photo.on.rectangle.angled",
                    description: Text("Share a photo or a moment from the trip — everyone on the trip will see it.")
                )
                .frame(maxWidth: .infinity)
            }
        } else {
            HStack {
                Spacer()
                Button {
                    Task { await reload() }
                } label: {
                    if isReloading {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                            .font(.app(.caption, .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            // Lazy so long feeds build post cards (and kick off their photo loads)
            // only as they scroll into view. Spacing matches the enclosing detail VStack.
            LazyVStack(spacing: 18) {
                ForEach(posts) { post in
                    FeedPostCard(tripID: tripID, post: post)
                }
            }
        }

        // `task` (not onAppear+Task) so leaving the tab cancels an in-flight load.
        Color.clear.frame(height: 0)
            .task { if !store.hasLoadedFeed(for: tripID) { await reload() } }
    }

    private func reload() async {
        isReloading = true
        defer { isReloading = false }
        do {
            try await store.loadFeed(for: tripID)
            loadError = nil
        } catch {
            loadError = (error as? AuthError)?.message ?? "Couldn't load the trip feed."
        }
    }
}

/// Inline composer: a text field plus a multi-photo picker. Photos are uploaded to the
/// private `receipts` bucket first (paths namespaced under the poster's lowercased user
/// id), then the post row is inserted and shown.
private struct FeedComposerCard: View {
    @Environment(TripStore.self) private var store
    let tripID: Trip.ID

    @State private var text = ""
    @State private var picks: [PhotosPickerItem] = []
    @State private var previews: [UIImage] = []
    @State private var locationName: String?
    @State private var showLocationPicker = false
    @State private var isPosting = false
    @State private var postError: String?

    private var canPost: Bool {
        !isPosting && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !previews.isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                AvatarView(person: store.currentUser, imageData: store.profileImageData, size: 34)
                TextField("Share a moment from the trip…", text: $text, axis: .vertical)
                    .lineLimit(1...4)
            }

            if !previews.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(previews.enumerated()), id: \.offset) { index, image in
                            Image(uiImage: image)
                                .resizable().scaledToFill()
                                .frame(width: 72, height: 72)
                                .clipShape(.rect(cornerRadius: 10))
                                .overlay(alignment: .topTrailing) {
                                    Button {
                                        previews.remove(at: index)
                                        if index < picks.count { picks.remove(at: index) }
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.app(.body))
                                            .foregroundStyle(.white, .black.opacity(0.55))
                                    }
                                    .buttonStyle(.plain)
                                    .padding(3)
                                }
                        }
                    }
                }
            }

            if let locationName {
                HStack(spacing: 4) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.app(.caption, .semibold))
                    Text(verbatim: locationName)
                        .font(.app(.caption, .semibold))
                        .lineLimit(1)
                    Button {
                        self.locationName = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.app(.caption))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Theme.accent.opacity(0.12), in: .capsule)
            }

            if let postError {
                Text(verbatim: postError).font(.app(.caption)).foregroundStyle(Theme.negative)
            }

            HStack {
                PhotosPicker(selection: $picks, maxSelectionCount: 4, matching: .images) {
                    Label("Photos", systemImage: "photo.badge.plus")
                        .font(.app(.subheadline, .semibold))
                }
                Button {
                    showLocationPicker = true
                } label: {
                    Label("Location", systemImage: "mappin.and.ellipse")
                        .font(.app(.subheadline, .semibold))
                }
                .padding(.leading, 12)
                Spacer()
                Button {
                    Task { await submit() }
                } label: {
                    if isPosting {
                        ProgressView().frame(minWidth: 44)
                    } else {
                        Text("Post").font(.app(.subheadline, .bold)).frame(minWidth: 44)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(!canPost)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .onChange(of: picks) { _, newPicks in
            Task { await loadPreviews(newPicks) }
        }
        .sheet(isPresented: $showLocationPicker) {
            FeedLocationPicker(locationName: $locationName)
        }
    }

    private func loadPreviews(_ items: [PhotosPickerItem]) async {
        var images: [UIImage] = []
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self),
               let prepared = await UploadImagePreparation.preparedImage(
                from: data,
                maxPixelSize: 2_200,
                compressionQuality: 0.82
               ) {
                images.append(prepared.image)
            }
        }
        previews = images
    }

    private func submit() async {
        isPosting = true
        postError = nil
        defer { isPosting = false }

        let postID = UUID()
        var paths: [String] = []
        for (index, image) in previews.enumerated() {
            let jpeg = await UploadImagePreparation.jpegData(
                from: image,
                maxPixelSize: 2_200,
                compressionQuality: 0.72
            )
            guard let jpeg else {
                postError = "Couldn't read one of the photos."
                return
            }
            do {
                paths.append(try await store.uploadFeedPhoto(jpeg, postID: postID, index: index))
            } catch {
                postError = (error as? AuthError)?.message ?? "Couldn't upload the photos. Check your connection and try again."
                return
            }
        }

        let post = FeedPost(
            id: postID,
            authorID: store.currentUser.id,
            authorName: store.currentUser.name,
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            photoPaths: paths,
            locationName: locationName
        )
        do {
            try await store.addFeedPost(post, to: tripID)
        } catch {
            postError = (error as? AuthError)?.message ?? "Couldn't publish the post. Check your connection and try again."
            return
        }
        text = ""
        picks = []
        previews = []
        locationName = nil
    }
}

/// Sheet for tagging a post with a place: MapKit autocomplete over the typed query, with
/// the raw text usable as-is (so places MapKit doesn't know can still be tagged).
private struct FeedLocationPicker: View {
    @Binding var locationName: String?
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var completer = LocationCompleter()

    var body: some View {
        NavigationStack {
            List {
                if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    Button {
                        choose(query.trimmingCharacters(in: .whitespaces))
                    } label: {
                        Label {
                            Text("Use \u{201C}\(query.trimmingCharacters(in: .whitespaces))\u{201D}")
                        } icon: {
                            Image(systemName: "mappin.and.ellipse")
                        }
                    }
                }
                ForEach(completer.results, id: \.self) { completion in
                    Button {
                        choose(
                            completion.subtitle.isEmpty
                                ? completion.title
                                : "\(completion.title), \(completion.subtitle)"
                        )
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: completion.title).font(.app(.subheadline, .semibold))
                            if !completion.subtitle.isEmpty {
                                Text(verbatim: completion.subtitle)
                                    .font(.app(.caption)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .searchable(text: $query, prompt: "Search for a place")
            .onChange(of: query) { _, newValue in
                completer.search(newValue)
            }
            .navigationTitle("Tag Location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func choose(_ name: String) {
        locationName = name
        dismiss()
    }
}

/// Thin `@Observable` wrapper around `MKLocalSearchCompleter` (delegate-based, main-thread).
@Observable @MainActor
private final class LocationCompleter: NSObject, @preconcurrency MKLocalSearchCompleterDelegate {
    private(set) var results: [MKLocalSearchCompletion] = []
    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.pointOfInterest, .address]
    }

    func search(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            results = []
            completer.cancel()
        } else {
            completer.queryFragment = trimmed
        }
    }

    // MKLocalSearchCompleter delivers delegate callbacks on the main queue.
    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        results = completer.results
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        results = []
    }
}

/// One post in the trip feed: author header, text, photos, emoji reaction bar, and
/// comments with an inline reply field.
private struct FeedPostCard: View {
    @Environment(TripStore.self) private var store
    let tripID: Trip.ID
    let post: FeedPost

    @State private var newComment = ""
    @State private var editingCommentID: ExpenseComment.ID?
    @State private var editedCommentText = ""
    @State private var isEditingPost = false
    @State private var editedPostText = ""
    @State private var editedLocation: String?
    @State private var showEditLocationPicker = false

    private static let quickEmojis = ["👍", "❤️", "😂", "😮", "🎉", "🔥"]

    private var author: Person {
        store.trip(tripID)?.members.first { $0.id == post.authorID }
            ?? Person(id: post.authorID, name: post.authorName.isEmpty ? "Member" : post.authorName, color: .gray)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if isEditingPost {
                postEditor
            } else if !post.text.isEmpty {
                Text(verbatim: post.text).font(.app(.subheadline))
            }
            if !post.photoPaths.isEmpty {
                photosRow
            }
            reactionBar
            if !post.comments.isEmpty {
                Divider()
                ForEach(post.comments) { comment in
                    commentRow(comment)
                }
            }
            commentField
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }

    private var header: some View {
        HStack(spacing: 10) {
            AvatarView(person: author, size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: author.name).font(.app(.subheadline, .semibold))
                Text(post.date.formatted(.relative(presentation: .named)))
                    .font(.app(.caption)).foregroundStyle(.secondary)
                if let location = post.locationName, !location.isEmpty {
                    HStack(spacing: 3) {
                        Image(systemName: "mappin.and.ellipse").font(.app(.caption2))
                        Text(verbatim: location).font(.app(.caption)).lineLimit(1)
                    }
                    .foregroundStyle(Theme.accent)
                }
            }
            Spacer()
            if let trip = store.trip(tripID), store.canDeleteFeedPost(post, in: trip) {
                Menu {
                    if post.authorID == store.currentUser.id {
                        Button {
                            editedPostText = post.text
                            editedLocation = post.locationName
                            isEditingPost = true
                        } label: {
                            Label("Edit Post", systemImage: "pencil")
                        }
                    }
                    Button(role: .destructive) {
                        store.deleteFeedPost(post.id, in: tripID)
                    } label: {
                        Label("Delete Post", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.app(.subheadline, .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .contentShape(.rect)
                }
            }
        }
    }

    /// Inline editor for the author's own post: text plus a re-taggable location.
    private var postEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Edit post", text: $editedPostText, axis: .vertical)
                .font(.app(.subheadline))
                .lineLimit(1...6)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Theme.fieldBackground, in: .rect(cornerRadius: 12))

            HStack(spacing: 8) {
                Button {
                    showEditLocationPicker = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "mappin.and.ellipse").font(.app(.caption, .semibold))
                        Text(verbatim: editedLocation ?? String(localized: "Add location"))
                            .font(.app(.caption, .semibold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Theme.accent.opacity(0.12), in: .capsule)
                }
                .buttonStyle(.plain)
                if editedLocation != nil {
                    Button {
                        editedLocation = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.app(.caption))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Button("Cancel") { isEditingPost = false }
                    .font(.app(.caption, .semibold))
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
                Button {
                    savePostEdit()
                } label: {
                    Text("Save").font(.app(.caption, .bold)).frame(minWidth: 40)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .controlSize(.small)
                .disabled(
                    editedPostText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        && post.photoPaths.isEmpty
                )
            }
        }
        .sheet(isPresented: $showEditLocationPicker) {
            FeedLocationPicker(locationName: $editedLocation)
        }
    }

    private func savePostEdit() {
        let trimmed = editedPostText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !post.photoPaths.isEmpty else { return }
        if trimmed != post.text || editedLocation != post.locationName {
            store.editFeedPost(post.id, in: tripID, text: trimmed, locationName: editedLocation)
        }
        isEditingPost = false
    }

    private var photosRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(post.photoPaths, id: \.self) { path in
                    FeedPhotoView(path: path)
                        .frame(
                            width: post.photoPaths.count == 1 ? 260 : 180,
                            height: post.photoPaths.count == 1 ? 260 : 180
                        )
                        .clipShape(.rect(cornerRadius: 14))
                }
            }
        }
    }

    private var reactionBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Self.quickEmojis, id: \.self) { emoji in
                    reactionChip(emoji)
                }
            }
        }
    }

    private func reactionChip(_ emoji: String) -> some View {
        let reactors = post.reactions[emoji] ?? []
        let mine = reactors.contains(store.currentUser.id)
        return Button {
            store.toggleFeedReaction(emoji, on: post.id, in: tripID)
        } label: {
            HStack(spacing: 4) {
                Text(verbatim: emoji).font(.app(.subheadline))
                if !reactors.isEmpty {
                    Text(verbatim: "\(reactors.count)")
                        .font(.app(.caption, .bold))
                        .foregroundStyle(mine ? Theme.accent : .secondary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(
                mine ? Theme.accent.opacity(0.18) : Theme.fieldBackground,
                in: .capsule
            )
            .overlay(
                Capsule().strokeBorder(mine ? Theme.accent : .clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func commentRow(_ comment: ExpenseComment) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: comment.authorName.isEmpty ? "Member" : comment.authorName)
                        .font(.app(.caption, .semibold))
                    Text(comment.date.formatted(.relative(presentation: .named)))
                        .font(.app(.caption2)).foregroundStyle(.secondary)
                    if comment.editedAt != nil {
                        Text("(edited)")
                            .font(.app(.caption2)).foregroundStyle(.secondary)
                    }
                }
                if editingCommentID == comment.id {
                    HStack(spacing: 8) {
                        TextField("Edit comment", text: $editedCommentText, axis: .vertical)
                            .font(.app(.subheadline))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Theme.fieldBackground, in: .rect(cornerRadius: 10))
                        Button {
                            saveCommentEdit(comment)
                        } label: {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.app(.title3))
                                .foregroundStyle(Theme.accent)
                        }
                        .buttonStyle(.plain)
                        .disabled(editedCommentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button {
                            editingCommentID = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.app(.title3))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    Text(verbatim: comment.text).font(.app(.subheadline))
                }
            }
            Spacer(minLength: 0)
            if comment.authorID == store.currentUser.id && editingCommentID != comment.id {
                Menu {
                    Button {
                        editedCommentText = comment.text
                        editingCommentID = comment.id
                    } label: {
                        Label("Edit Comment", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        store.deleteFeedComment(comment.id, from: post.id, in: tripID)
                    } label: {
                        Label("Delete Comment", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.app(.caption, .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .contentShape(.rect)
                }
            }
        }
    }

    private func saveCommentEdit(_ comment: ExpenseComment) {
        let trimmed = editedCommentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if trimmed != comment.text {
            store.editFeedComment(comment.id, text: trimmed, in: post.id, tripID: tripID)
        }
        editingCommentID = nil
        editedCommentText = ""
    }

    private var commentField: some View {
        HStack(spacing: 8) {
            TextField("Add a comment…", text: $newComment)
                .font(.app(.subheadline))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Theme.fieldBackground, in: .capsule)
                .onSubmit(sendComment)
            Button(action: sendComment) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.app(.title2))
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            .disabled(newComment.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func sendComment() {
        let trimmed = newComment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        store.addFeedComment(trimmed, to: post.id, in: tripID)
        newComment = ""
    }
}

/// A feed photo loaded from its private-bucket storage path via a signed URL,
/// mirroring `TripCoverView` / `AvatarView`.
private struct FeedPhotoView: View {
    let path: String

    var body: some View {
        Theme.fieldBackground
            .overlay {
                CachedStorageImage(path: path) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .loading:
                        ProgressView()
                    case .failure:
                        Image(systemName: "photo")
                            .font(.app(.title2))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .clipped()
    }
}
