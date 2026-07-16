import Foundation

// MARK: - Trips repository (Supabase PostgREST)

/// Persists shared trips to a single `trips` table in Supabase, storing each trip as a
/// JSON blob in a `jsonb` column. Access is enforced by RLS through `trip_members`, so
/// the client only ever sends the access token.
///
/// Run `supabase_schema.sql` (at the repo root) once in the Supabase SQL editor to
/// create the table and its row-level-security policy.
actor TripsRepository {
    static let shared = TripsRepository()

    private let session = BackendSecurity.secureSession
    private var tripCache: (userID: UUID, timestamp: Date, trips: [Trip])?
    private let cacheLifetime: TimeInterval = 60

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

    /// Fetches every trip visible to the token through `trip_members`. Decodes rows individually so a
    /// single malformed trip can't drop the entire list. Throws only on network/HTTP
    /// failure, letting callers distinguish "couldn't reach the server" from "no trips".
    func fetch(accessToken: String) async throws -> [Trip] {
        if let userID = TripStore.userID(fromJWT: accessToken),
           let cached = tripCache,
           cached.userID == userID,
           Date().timeIntervalSince(cached.timestamp) < cacheLifetime {
            return cached.trips
        }
        let data = try await send("GET", "/rest/v1/trips?select=data&order=updated_at.desc", accessToken: accessToken)
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        let trips: [Trip] = rows.compactMap { row in
            guard let dataValue = row["data"],
                  let dataData = try? JSONSerialization.data(withJSONObject: dataValue) else { return nil }
            return try? decoder.decode(Trip.self, from: dataData)
        }
        if let userID = TripStore.userID(fromJWT: accessToken) {
            tripCache = (userID, Date(), trips)
        }
        return trips
    }

    /// Inserts or updates a trip (keyed on its id) for any account that can access it.
    func upsert(_ trip: Trip, accessToken: String) async throws {
        let tripJSON = try JSONSerialization.jsonObject(with: encoder.encode(trip))
        let body = try JSONSerialization.data(withJSONObject: [
            "p_id": trip.id.uuidString,
            "p_user_id": trip.creatorID.uuidString,
            "p_data": tripJSON,
        ])
        _ = try await send(
            "POST",
            "/rest/v1/rpc/upsert_trip",
            accessToken: accessToken,
            body: body,
            extraHeaders: ["Prefer": "return=minimal"]
        )
        invalidateCache(accessToken: accessToken)
    }

    /// Deletes a trip the token's account owns.
    func delete(id: Trip.ID, accessToken: String) async throws {
        _ = try await send("DELETE", "/rest/v1/trips?id=eq.\(id.uuidString)", accessToken: accessToken)
        invalidateCache(accessToken: accessToken)
    }

    func inviteMember(tripID: Trip.ID, email: String, accessToken: String) async throws -> InviteResult {
        let body = try JSONSerialization.data(withJSONObject: [
            "p_trip_id": tripID.uuidString,
            "p_email": email,
        ])
        let data = try await send(
            "POST",
            "/rest/v1/rpc/invite_trip_member",
            accessToken: accessToken,
            body: body,
            extraHeaders: ["Prefer": "return=representation"]
        )
        if let rows = try? decoder.decode([InviteResult].self, from: data), let first = rows.first {
            invalidateCache(accessToken: accessToken)
            return first
        }
        let result = try decoder.decode(InviteResult.self, from: data)
        invalidateCache(accessToken: accessToken)
        return result
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

    private func invalidateCache(accessToken: String) {
        guard let userID = TripStore.userID(fromJWT: accessToken) else {
            tripCache = nil
            return
        }
        if tripCache?.userID == userID { tripCache = nil }
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
