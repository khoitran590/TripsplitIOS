import Foundation

// MARK: - Profiles repository (Supabase REST)

/// Reads/writes the signed-in user's row in `public.profiles`. The row is created
/// server-side by the `auth_users_create_profile` trigger, so the client only ever
/// SELECTs and PATCHes it (RLS restricts both to the user's own row).
actor ProfilesRepository {
    static let shared = ProfilesRepository()
    private let session = BackendSecurity.secureSession

    private static let columns = "display_name,date_of_birth,bio,avatar_path,visited_places,saved_place_keys,saved_map_places,saved_destination_ids,profile_visibility"

    func fetch(userID: UUID, accessToken: String) async throws -> UserProfile? {
        let path = "/rest/v1/profiles?user_id=eq.\(userID.uuidString.lowercased())&select=\(Self.columns)"
        let data = try await send("GET", path, accessToken: accessToken)
        return try JSONDecoder().decode([UserProfile].self, from: data).first
    }

    func update(_ profile: UserProfile, userID: UUID, accessToken: String) async throws {
        let path = "/rest/v1/profiles?user_id=eq.\(userID.uuidString.lowercased())"
        let body = try JSONEncoder().encode(profile)
        _ = try await send("PATCH", path, accessToken: accessToken, body: body,
                           extraHeaders: ["Prefer": "return=minimal"])
    }

    /// The user's own profile share token, used to build their shareable profile link.
    /// `share_token` is intentionally kept out of `UserProfile` so the client never
    /// PATCHes it; it's read on its own here.
    func fetchShareToken(userID: UUID, accessToken: String) async throws -> String? {
        struct Row: Decodable { let share_token: String? }
        let path = "/rest/v1/profiles?user_id=eq.\(userID.uuidString.lowercased())&select=share_token"
        let data = try await send("GET", path, accessToken: accessToken)
        return try JSONDecoder().decode([Row].self, from: data).first?.share_token
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
            BackendSecurity.log("Profile sync network failure", error: error)
            throw AuthError(message: "Couldn't reach the server. Check your connection.")
        }
        guard let http = response as? HTTPURLResponse else {
            throw AuthError(message: "No response from the server.")
        }
        guard (200..<300).contains(http.statusCode) else {
            BackendSecurity.log("Profile request rejected", statusCode: http.statusCode)
            throw AuthError(message: "Profile request failed (HTTP \(http.statusCode)).", statusCode: http.statusCode)
        }
        return data
    }
}
