import Foundation

/// Claude supplies better search text for ambiguous itinerary labels. MapKit remains
/// the authority for coordinates and Apple place identifiers.
nonisolated struct AIItineraryLocationHint: Codable, Equatable, Sendable {
    let stopID: UUID
    let canonicalName: String
    let area: String?
    let address: String?
    let aliases: [String]
    let confidence: Double
}

enum ItineraryPinAI {
    private struct StopInput: Encodable {
        let stopID: UUID
        let name: String
        let kind: String
        let area: String?
        let address: String?
    }

    private struct RequestBody: Encodable {
        let destination: String
        let stops: [StopInput]
    }

    private struct ResponseBody: Decodable {
        let hints: [AIItineraryLocationHint]
    }

    nonisolated static let session = BackendSecurity.makeSecureSession(
        requestTimeout: 55,
        resourceTimeout: 55
    )

    static func clarify(
        destination: String,
        stops: [ItineraryStop],
        accessToken: String
    ) async throws -> [AIItineraryLocationHint] {
        guard let url = URL(string: "\(SupabaseConfig.url)/functions/v1/clarify-itinerary-locations") else {
            throw AuthError(message: "AI location help is not configured.")
        }
        let inputs = stops.prefix(10).map { stop in
            StopInput(
                stopID: stop.id,
                name: String(stop.name.prefix(180)),
                kind: stop.kind.rawValue,
                area: stop.area.map { String($0.prefix(180)) },
                // An address from an earlier automatic match may itself be wrong.
                address: stop.locationSource == .automatic ? nil : stop.address.map { String($0.prefix(240)) }
            )
        }
        guard !inputs.isEmpty else { return [] }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(RequestBody(
            destination: String(destination.prefix(200)),
            stops: inputs
        ))

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AuthError(message: "Claude did not respond.")
        }
        switch http.statusCode {
        case 200:
            let allowedIDs = Set(inputs.map(\.stopID))
            return try JSONDecoder().decode(ResponseBody.self, from: data).hints.filter {
                allowedIDs.contains($0.stopID)
                    && !$0.canonicalName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && $0.confidence >= 0.65
            }
        case 401, 403:
            throw AuthError(message: "Sign in and allow AI itinerary planning to improve pins.", statusCode: http.statusCode)
        case 429:
            throw ItineraryAIError.rateLimited(
                retryAfterSeconds: AIRateLimitResponse.retryDelay(data: data, response: http)
            )
        default:
            let detail = ReceiptStorage.messageField(from: String(data: data, encoding: .utf8) ?? "")
            throw AuthError(message: detail ?? "Claude location service error (HTTP \(http.statusCode)).", statusCode: http.statusCode)
        }
    }
}
