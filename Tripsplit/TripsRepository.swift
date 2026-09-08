import Foundation

// MARK: - Trips repository (Supabase PostgREST)

/// Persists trip metadata and independently edited child records in normalized Supabase
/// tables. During the B10 compatibility window the database also rebuilds `trips.data`,
/// allowing older clients to keep reading without making it the source of truth.
///
/// Apply the ordered `supabase/migrations` history to create and secure the backend.
actor TripsRepository {
    static let shared = TripsRepository()

    private let session: URLSession
    init(session: URLSession = BackendSecurity.secureSession) { self.session = session }
    private var tripCache: (userID: UUID, timestamp: Date, trips: [Trip])?
    /// The exact snapshot last read or successfully submitted by this process. It lets
    /// the client derive a field-level delta, so a save only touches child rows this
    /// client actually changed and preserves concurrent edits to other rows.
    private var syncedSnapshots: [Trip.ID: Trip] = [:]
    private var snapshotUserID: UUID?
    private var readSnapshots: [Trip.ID: (revision: String, trip: Trip)] = [:]
    private var cacheGeneration = 0
    private var accountEpoch = UUID()
    private let cacheLifetime: TimeInterval = 60

    /// Clears user-scoped snapshots when an account leaves the device. The actor is a
    /// singleton, so in-memory data would otherwise survive even after UI state resets.
    func clearCachedState() {
        accountEpoch = UUID()
        cacheGeneration += 1
        readSnapshots = [:]
        tripCache = nil
        syncedSnapshots = [:]
        snapshotUserID = nil
    }

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    struct InviteResult: Decodable {
        let memberUserID: UUID?
        let invitationID: UUID
        let accepted: Bool

        enum CodingKeys: String, CodingKey {
            case memberUserID = "member_user_id"
            case invitationID = "invitation_id"
            case accepted
        }
    }

    struct InvitationPreview: Decodable {
        let tripName: String
        let inviterName: String
        let expiresAt: Date

        enum CodingKeys: String, CodingKey {
            case tripName = "trip_name"
            case inviterName = "inviter_name"
            case expiresAt = "expires_at"
        }
    }

    struct PendingInvitation: Decodable, Identifiable {
        let id: UUID
        let email: String?
        let expiresAt: Date

        enum CodingKeys: String, CodingKey {
            case id, email
            case expiresAt = "expires_at"
        }
    }

    private struct LinkInviteResult: Decodable {
        let invitationID: UUID
        let token: String

        enum CodingKeys: String, CodingKey {
            case invitationID = "invitation_id"
            case token
        }
    }

    private struct AcceptedInviteResult: Decodable {
        let tripID: UUID

        enum CodingKeys: String, CodingKey {
            case tripID = "trip_id"
        }
    }

    /// Decode each nested document directly, preserving the existing tolerance for
    /// malformed rows without materializing and re-serializing a Foundation JSON tree.
    private struct TripRow: Decodable {
        let trip: Trip?
        private enum CodingKeys: String, CodingKey { case data }

        init(from decoder: Decoder) throws {
            let container = try? decoder.container(keyedBy: CodingKeys.self)
            trip = try? container?.decode(Trip.self, forKey: .data)
        }
    }

    func decodeTrips(from data: Data) throws -> [Trip] {
        try decoder.decode([TripRow].self, from: data).compactMap(\.trip)
    }

    private struct SyncParameters: Encodable {
        let p_id: UUID
        let p_user_id: UUID
        let p_data: Trip
        let p_previous_data: Trip?
    }

    private struct LegacySyncParameters: Encodable {
        let p_id: UUID
        let p_user_id: UUID
        let p_data: Trip
    }

    private struct Summary: Decodable {
        let id: UUID
        let updated_at: String
    }

    private struct Detail: Decodable {
        let id: UUID
        let updated_at: String
        let trip: Trip?
        private enum CodingKeys: String, CodingKey { case id, data, updated_at }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(UUID.self, forKey: .id)
            updated_at = try c.decode(String.self, forKey: .updated_at)
            trip = try? c.decode(Trip.self, forKey: .data)
        }
    }

    /// Read small summary pages, then retrieve only changed/missing complete trips.
    /// Never put a partial Trip into the financial store or use it as a delta base.
    func fetch(accessToken: String, forceRefresh: Bool = false) async throws -> [Trip] {
        alignSnapshots(with: accessToken)
        if !forceRefresh,
           let userID = TripStore.userID(fromJWT: accessToken),
           let cached = tripCache, cached.userID == userID,
           Date().timeIntervalSince(cached.timestamp) < cacheLifetime { return cached.trips }
        let generation = cacheGeneration
        let trips: [Trip]
        do {
            trips = try await fetchChangedTrips(accessToken: accessToken, generation: generation)
        } catch let error as AuthError where error.statusCode == 404 {
            // Compatibility with deployments that do not yet expose manifest pages.
            let data: Data
            do {
                data = try await send("POST", "/rest/v1/rpc/fetch_normalized_trips",
                                      accessToken: accessToken, body: Data("{}".utf8))
            } catch let error as AuthError where error.statusCode == 404 {
                data = try await send("GET", "/rest/v1/trips?select=data&order=updated_at.desc", accessToken: accessToken)
            }
            trips = try decodeTrips(from: data)
        }
        try Task.checkCancellation()
        guard cacheGeneration == generation else { throw CancellationError() }
        if let userID = TripStore.userID(fromJWT: accessToken) { tripCache = (userID, Date(), trips) }
        syncedSnapshots = Dictionary(trips.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return trips
    }

    private func fetchChangedTrips(accessToken: String, generation: Int) async throws -> [Trip] {
        struct SummaryParameters: Encodable { let p_after_id: UUID?; let p_limit: Int }
        struct DetailParameters: Encodable { let p_ids: [UUID] }
        var summaries: [Summary] = []
        var cursor: UUID?
        repeat {
            try Task.checkCancellation()
            let body = try encoder.encode(SummaryParameters(p_after_id: cursor, p_limit: 100))
            let data = try await send("POST", "/rest/v1/rpc/fetch_trip_summaries_v1", accessToken: accessToken, body: body)
            let page = try decoder.decode([Summary].self, from: data)
            summaries.append(contentsOf: page)
            cursor = page.count == 100 ? page.last?.id : nil
        } while cursor != nil
        var snapshots: [Trip.ID: (revision: String, trip: Trip)] = [:]
        var changed: [UUID] = []
        for summary in summaries {
            if let cached = readSnapshots[summary.id], cached.revision == summary.updated_at {
                snapshots[summary.id] = cached
            } else { changed.append(summary.id) }
        }
        for start in stride(from: 0, to: changed.count, by: 25) {
            try Task.checkCancellation()
            guard generation == cacheGeneration else { throw CancellationError() }
            let ids = Array(changed[start..<min(start + 25, changed.count)])
            let data = try await send("POST", "/rest/v1/rpc/fetch_trip_details_v1", accessToken: accessToken,
                                      body: encoder.encode(DetailParameters(p_ids: ids)))
            for detail in try decoder.decode([Detail].self, from: data) {
                if let trip = detail.trip { snapshots[detail.id] = (detail.updated_at, trip) }
            }
        }
        guard generation == cacheGeneration else { throw CancellationError() }
        readSnapshots = snapshots
        var ordered: [(date: Date, trip: Trip)] = snapshots.values.map {
            (date: BackendDate.parse($0.revision) ?? Date.distantPast, trip: $0.trip)
        }
        ordered.sort { left, right in
            if left.date != right.date { return left.date > right.date }
            return left.trip.id.uuidString < right.trip.id.uuidString
        }
        return ordered.map { $0.trip }
    }

    /// Inserts or updates only this client's changed records. Older deployments retain
    /// the normalized/legacy fallback until the delta migration has been applied.
    func upsert(_ trip: Trip, accessToken: String) async throws {
        alignSnapshots(with: accessToken)
        struct Parameters: Encodable {
            let p_id: UUID
            let p_user_id: UUID
            let p_delta: TripDelta
        }
        let epoch = accountEpoch
        let previous = syncedSnapshots[trip.id]
        let delta = TripDelta(current: trip, previous: previous)
        guard !delta.isEmpty else { return }
        cacheGeneration += 1
        readSnapshots[trip.id] = nil
        let body = try encoder.encode(Parameters(p_id: trip.id, p_user_id: trip.creatorID, p_delta: delta))
        do {
            _ = try await send("POST", "/rest/v1/rpc/sync_trip_delta_v1", accessToken: accessToken, body: body)
        } catch let error as AuthError where error.statusCode == 404 {
            let fullBody = try encoder.encode(SyncParameters(
                p_id: trip.id, p_user_id: trip.creatorID, p_data: trip, p_previous_data: previous
            ))
            do {
                _ = try await send("POST", "/rest/v1/rpc/sync_trip_normalized", accessToken: accessToken, body: fullBody)
            } catch let error as AuthError where error.statusCode == 404 {
                let legacyBody = try encoder.encode(LegacySyncParameters(p_id: trip.id, p_user_id: trip.creatorID, p_data: trip))
                _ = try await send("POST", "/rest/v1/rpc/upsert_trip", accessToken: accessToken,
                                   body: legacyBody, extraHeaders: ["Prefer": "return=minimal"])
            }
        }
        // Submitted snapshots are delta bases, never authoritative read-cache entries:
        // unseen concurrent rows must arrive from the server before they can be deleted.
        guard accountEpoch == epoch else { throw CancellationError() }
        syncedSnapshots[trip.id] = trip
        invalidateCache(accessToken: accessToken)
    }

    /// Deletes a trip the token's account owns.
    func delete(id: Trip.ID, accessToken: String) async throws {
        alignSnapshots(with: accessToken)
        _ = try await send("DELETE", "/rest/v1/trips?id=eq.\(id.uuidString)", accessToken: accessToken)
        syncedSnapshots[id] = nil
        invalidateCache(accessToken: accessToken)
    }

    func inviteMember(tripID: Trip.ID, email: String, accessToken: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "tripID": tripID.uuidString,
            "email": email,
        ])
        _ = try await send(
            "POST",
            "/functions/v1/send-invitation",
            accessToken: accessToken,
            body: body
        )
        invalidateCache(accessToken: accessToken)
    }

    func createInvitationLink(tripID: Trip.ID, accessToken: String) async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: ["p_trip_id": tripID.uuidString])
        let data = try await send(
            "POST",
            "/rest/v1/rpc/create_trip_invitation_link",
            accessToken: accessToken,
            body: body,
            extraHeaders: ["Prefer": "return=representation"]
        )
        if let rows = try? decoder.decode([LinkInviteResult].self, from: data), let first = rows.first {
            return first.token
        }
        return try decoder.decode(LinkInviteResult.self, from: data).token
    }

    func acceptInvitation(token: String, accessToken: String) async throws -> Trip.ID {
        let body = try JSONSerialization.data(withJSONObject: ["p_token": token])
        let data = try await send(
            "POST",
            "/rest/v1/rpc/accept_trip_invitation",
            accessToken: accessToken,
            body: body,
            extraHeaders: ["Prefer": "return=representation"]
        )
        if let rows = try? decoder.decode([AcceptedInviteResult].self, from: data), let first = rows.first {
            invalidateCache(accessToken: accessToken)
            return first.tripID
        }
        let tripID = try decoder.decode(AcceptedInviteResult.self, from: data).tripID
        invalidateCache(accessToken: accessToken)
        return tripID
    }

    func declineInvitation(token: String, accessToken: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["p_token": token])
        _ = try await send(
            "POST",
            "/rest/v1/rpc/decline_trip_invitation",
            accessToken: accessToken,
            body: body
        )
    }

    func pendingInvitations(tripID: Trip.ID, accessToken: String) async throws -> [PendingInvitation] {
        let data = try await send(
            "GET",
            "/rest/v1/trip_invitations?trip_id=eq.\(tripID.uuidString)&status=eq.pending&select=id,email,expires_at&order=created_at.desc",
            accessToken: accessToken
        )
        return try decoder.decode([PendingInvitation].self, from: data)
    }

    func revokeInvitation(id: UUID, accessToken: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["p_invitation_id": id.uuidString])
        _ = try await send(
            "POST",
            "/rest/v1/rpc/revoke_trip_invitation",
            accessToken: accessToken,
            body: body
        )
        invalidateCache(accessToken: accessToken)
    }

    func previewInvitation(token: String, accessToken: String) async throws -> InvitationPreview {
        let body = try JSONSerialization.data(withJSONObject: ["p_token": token])
        let data = try await send(
            "POST",
            "/rest/v1/rpc/preview_trip_invitation",
            accessToken: accessToken,
            body: body,
            extraHeaders: ["Prefer": "return=representation"]
        )
        if let rows = try? decoder.decode([InvitationPreview].self, from: data), let first = rows.first {
            return first
        }
        return try decoder.decode(InvitationPreview.self, from: data)
    }

    func removeMember(tripID: Trip.ID, userID: UUID, accessToken: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "p_trip_id": tripID.uuidString,
            "p_user_id": userID.uuidString,
        ])
        _ = try await send(
            "POST",
            "/rest/v1/rpc/remove_trip_member",
            accessToken: accessToken,
            body: body
        )
        invalidateCache(accessToken: accessToken)
    }

    func leaveTrip(tripID: Trip.ID, accessToken: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["p_trip_id": tripID.uuidString])
        _ = try await send(
            "POST",
            "/rest/v1/rpc/leave_trip",
            accessToken: accessToken,
            body: body
        )
        syncedSnapshots[tripID] = nil
        invalidateCache(accessToken: accessToken)
    }

    private func invalidateCache(accessToken: String) {
        cacheGeneration += 1
        guard let userID = TripStore.userID(fromJWT: accessToken) else {
            tripCache = nil
            return
        }
        if tripCache?.userID == userID { tripCache = nil }
    }

    /// The repository actor outlives sign-out. Never reuse one account's delta base for
    /// another account, even when both happen to be members of the same trip.
    private func alignSnapshots(with accessToken: String) {
        let userID = TripStore.userID(fromJWT: accessToken)
        guard snapshotUserID != userID else { return }
        cacheGeneration += 1
        accountEpoch = UUID()
        readSnapshots = [:]
        tripCache = nil
        snapshotUserID = userID
        syncedSnapshots = [:]
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
            BackendSecurity.log("Trip sync network failure", error: error)
            throw AuthError(message: "Couldn't reach the server. Check your connection.")
        }
        guard let http = response as? HTTPURLResponse else {
            BackendSecurity.log("Trip sync returned no HTTP response")
            throw AuthError(message: "No response from the server.")
        }
        guard (200..<300).contains(http.statusCode) else {
            BackendSecurity.log("Trip sync request rejected", statusCode: http.statusCode)
            let body = String(data: data, encoding: .utf8) ?? ""
            let detail = ReceiptStorage.messageField(from: body)
            throw AuthError(
                message: detail.map { "Sync request failed: \($0)" } ?? "Sync request failed (HTTP \(http.statusCode)).",
                statusCode: http.statusCode
            )
        }
        return data
    }
}
