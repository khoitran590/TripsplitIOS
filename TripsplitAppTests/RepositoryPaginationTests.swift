import XCTest
import Foundation
@testable import Tripsplit

private final class HTTPFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [Data]
    private var requests: [URLRequest] = []
    init(_ responses: [Data]) { self.responses = responses }
    func next(_ request: URLRequest) -> Data {
        lock.withLock {
            requests.append(request)
            return responses.isEmpty ? Data("[]".utf8) : responses.removeFirst()
        }
    }
    var received: [URLRequest] { lock.withLock { requests } }
}

private final class FixtureRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var fixtures: [String: HTTPFixture] = [:]
    func set(_ fixture: HTTPFixture?, id: String) { lock.withLock { fixtures[id] = fixture } }
    func get(_ id: String) -> HTTPFixture? { lock.withLock { fixtures[id] } }
}

private final class FixtureProtocol: URLProtocol, @unchecked Sendable {
    static let registry = FixtureRegistry()
    override class func canInit(with request: URLRequest) -> Bool { request.value(forHTTPHeaderField: "X-Fixture") != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let id = request.value(forHTTPHeaderField: "X-Fixture")!
        guard let fixture = Self.registry.get(id) else { client?.urlProtocol(self, didFailWithError: URLError(.unknown)); return }
        let data = fixture.next(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
                            httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class RepositoryPaginationTests: XCTestCase {
    private func session(_ fixture: HTTPFixture) -> (URLSession, String) {
        let id = UUID().uuidString
        FixtureProtocol.registry.set(fixture, id: id)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureProtocol.self]
        config.httpAdditionalHeaders = ["X-Fixture": id]
        return (URLSession(configuration: config), id)
    }

    private func token(_ userID: UUID) throws -> String {
        let payload = try JSONSerialization.data(withJSONObject: ["sub": userID.uuidString])
            .base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "header.\(payload).signature"
    }

    private func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }

    func testSummaryRefreshReusesOnlyUnchangedServerDocuments() async throws {
        let person = Person(name: "Test", color: .blue)
        let trip = Trip(name: "Cached", currencyCode: "USD", creatorID: person.id, members: [person], budgets: [:])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let document = try JSONSerialization.jsonObject(with: encoder.encode(trip))
        var changedDocument = document as! [String: Any]
        changedDocument["name"] = "Changed"
        let firstRevision = "2026-09-01T12:00:00.123456+00:00"
        let secondRevision = "2026-09-01T12:00:00.123457+00:00"
        let summary = try json([["id": trip.id.uuidString, "updated_at": firstRevision]])
        let detail = try json([["id": trip.id.uuidString, "updated_at": firstRevision, "data": document]])
        let fixture = try HTTPFixture([
            summary, detail, summary,
            json([["id": trip.id.uuidString, "updated_at": secondRevision]]),
            json([["id": trip.id.uuidString, "updated_at": secondRevision, "data": changedDocument]])
        ])
        let (session, id) = session(fixture)
        defer { session.invalidateAndCancel(); FixtureProtocol.registry.set(nil, id: id) }
        let repository = TripsRepository(session: session)
        let auth = try token(person.id)
        let initial = try await repository.fetch(accessToken: auth, forceRefresh: true)
        let unchanged = try await repository.fetch(accessToken: auth, forceRefresh: true)
        XCTAssertEqual(initial.first?.name, "Cached")
        XCTAssertEqual(unchanged.first?.name, "Cached")
        XCTAssertEqual(fixture.received.count, 3, "Second refresh should transfer only the summary")
        try await repository.upsert(try XCTUnwrap(unchanged.first), accessToken: auth)
        XCTAssertEqual(fixture.received.count, 3, "An unchanged save should not make a network request")
        let changed = try await repository.fetch(accessToken: auth, forceRefresh: true)
        XCTAssertEqual(changed.first?.name, "Changed")
        XCTAssertEqual(fixture.received.count, 5, "Even a microsecond revision change must refetch details")
    }

    func testFeedCursorPreservesMicrosecondsAndUsesStableIDTieBreak() async throws {
        let tripID = UUID()
        let author = UUID()
        let ids = [UUID(), UUID(), UUID()].sorted { $0.uuidString > $1.uuidString }
        let timestamp = "2026-09-01T12:00:00.123456+00:00"
        func row(_ id: UUID) -> [String: Any] {
            ["id": id.uuidString, "trip_id": tripID.uuidString, "author_id": author.uuidString,
             "author_name": "Test", "body": "Place", "photo_paths": [], "created_at": timestamp,
             "location_name": "Museum", "location_latitude": 1, "location_longitude": 2]
        }
        let fixture = try HTTPFixture([json([row(ids[0]), row(ids[1])]), json([row(ids[2])])])
        let (session, id) = session(fixture)
        defer { session.invalidateAndCancel(); FixtureProtocol.registry.set(nil, id: id) }
        let repository = FeedRepository(session: session)
        let first = try await repository.fetchPage(tripID: tripID, accessToken: "fixture", locationsOnly: true, limit: 2)
        XCTAssertEqual(first.next?.createdAt, timestamp)
        XCTAssertEqual(first.next?.id, ids[1])
        XCTAssertTrue(first.posts[0].comments.isEmpty)
        let second = try await repository.fetchPage(tripID: tripID, accessToken: "fixture", before: first.next,
                                                    locationsOnly: true, limit: 2)
        XCTAssertNil(second.next)
        XCTAssertEqual((first.posts + second.posts).map(\.id), ids)
        let query = URLComponents(url: fixture.received.last!.url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(query.first { $0.name == "order" }?.value, "created_at.desc,id.desc")
        let cursor = query.first { $0.name == "or" }!.value!
        XCTAssertTrue(cursor.contains(timestamp))
        XCTAssertTrue(cursor.contains("id.lt.\(ids[1].uuidString)"))
        XCTAssertFalse(query.first { $0.name == "select" }!.value!.contains("comments"))
    }

    func testLargeManifestUsesMultiplePagesAndBoundedDetailBatches() async throws {
        let person = Person(name: "Test", color: .blue)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let trips = (0..<101).map { index in
            Trip(name: "Trip \(index)", currencyCode: "USD", creatorID: person.id, members: [person], budgets: [:])
        }.sorted { $0.id.uuidString < $1.id.uuidString }
        let revision = "2026-09-01T12:00:00+00:00"
        let summaries = trips.map { ["id": $0.id.uuidString, "updated_at": revision] }
        var responses = try [json(Array(summaries.prefix(100))), json(Array(summaries.suffix(1)))]
        for start in stride(from: 0, to: trips.count, by: 25) {
            let rows: [[String: Any]] = try trips[start..<min(start + 25, trips.count)].map { trip in
                ["id": trip.id.uuidString, "updated_at": revision,
                 "data": try JSONSerialization.jsonObject(with: encoder.encode(trip))]
            }
            responses.append(try json(rows))
        }
        let fixture = HTTPFixture(responses)
        let (session, id) = session(fixture)
        defer { session.invalidateAndCancel(); FixtureProtocol.registry.set(nil, id: id) }
        let result = try await TripsRepository(session: session).fetch(accessToken: token(person.id), forceRefresh: true)
        XCTAssertEqual(Set(result.map(\.id)), Set(trips.map(\.id)))
        XCTAssertEqual(fixture.received.filter { $0.url!.path.hasSuffix("fetch_trip_summaries_v1") }.count, 2)
        XCTAssertEqual(fixture.received.filter { $0.url!.path.hasSuffix("fetch_trip_details_v1") }.count, 5)
    }
}
