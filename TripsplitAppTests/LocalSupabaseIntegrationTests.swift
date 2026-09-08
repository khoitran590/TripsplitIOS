import XCTest
import UIKit
@testable import Tripsplit

/// Opt-in end-to-end coverage for the Debug app's local Supabase environment.
/// Ordinary unit tests remain Docker-independent. Set the Test action environment
/// variable `TRIPSPLIT_RUN_LOCAL_INTEGRATION=1` while `supabase start` is healthy.
@MainActor
final class LocalSupabaseIntegrationTests: XCTestCase {
    private let password = "TripSplit-Local-Only-2026!"

    func testLocalSupabaseCoreFlow() async throws {
        try XCTSkipUnless(
            Self.runsLocalIntegration,
            "Set TRIPSPLIT_RUN_LOCAL_INTEGRATION=1 in Xcode, or compile with LOCAL_SUPABASE_INTEGRATION from the CLI."
        )

        XCTAssertEqual(SupabaseConfig.url, BackendEnvironment.localDevelopment.url)
        XCTAssertTrue(BackendSecurity.isTrustedBackendURL(URL(string: SupabaseConfig.url)))

        let suffix = UUID().uuidString.lowercased()
        let ownerEmail = "owner-\(suffix)@example.com"
        let memberEmail = "member-\(suffix)@example.com"
        let auth = AuthService.shared

        let ownerOutcome = try await auth.signUp(email: ownerEmail, password: password)
        var ownerSession = try signedInSession(
            from: ownerOutcome,
            email: ownerEmail
        )
        let ownerID = try XCTUnwrap(TripStore.userID(fromJWT: ownerSession.accessToken))
        let ownerSessionAccepted = await auth.isSessionAccepted(accessToken: ownerSession.accessToken)
        XCTAssertTrue(ownerSessionAccepted)

        let memberOutcome = try await auth.signUp(email: memberEmail, password: password)
        let memberSession = try signedInSession(
            from: memberOutcome,
            email: memberEmail
        )
        let memberID = try XCTUnwrap(TripStore.userID(fromJWT: memberSession.accessToken))

        let profiles = ProfilesRepository.shared
        let fetchedOwnerProfile = try await profiles.fetch(
            userID: ownerID,
            accessToken: ownerSession.accessToken
        )
        var ownerProfile = try XCTUnwrap(fetchedOwnerProfile)
        ownerProfile.displayName = "Local Owner"
        ownerProfile.bio = "Local Supabase integration test"
        try await profiles.update(ownerProfile, userID: ownerID, accessToken: ownerSession.accessToken)
        let fetchedUpdatedProfile = try await profiles.fetch(
            userID: ownerID,
            accessToken: ownerSession.accessToken
        )
        let updatedProfile = try XCTUnwrap(fetchedUpdatedProfile)
        XCTAssertEqual(updatedProfile.displayName, "Local Owner")
        XCTAssertEqual(updatedProfile.bio, "Local Supabase integration test")

        let jpeg = try XCTUnwrap(makeJPEG())
        let avatarPath = "\(ownerID.uuidString.lowercased())/profile.jpg"
        let uploadedAvatarPath = try await ReceiptStorage.shared.upload(
            jpeg,
            path: avatarPath,
            assetType: "avatar",
            recordID: ownerID,
            accessToken: ownerSession.accessToken
        )
        XCTAssertEqual(uploadedAvatarPath, avatarPath)
        var profileWithAvatar = updatedProfile
        profileWithAvatar.avatarPath = avatarPath
        try await profiles.update(
            profileWithAvatar,
            userID: ownerID,
            accessToken: ownerSession.accessToken
        )
        let avatarURL = try await ReceiptStorage.shared.signedURL(
            path: avatarPath,
            expiresIn: 60,
            accessToken: ownerSession.accessToken
        )
        let (_, avatarResponse) = try await BackendSecurity.secureSession.data(from: avatarURL)
        XCTAssertEqual((avatarResponse as? HTTPURLResponse)?.statusCode, 200)

        let fetchedMemberProfile = try await profiles.fetch(
            userID: memberID,
            accessToken: memberSession.accessToken
        )
        var memberProfile = try XCTUnwrap(fetchedMemberProfile)
        memberProfile.displayName = "Local Member"
        try await profiles.update(memberProfile, userID: memberID, accessToken: memberSession.accessToken)

        let owner = Person(id: ownerID, name: "Local Owner", color: .blue)
        let expenseID = UUID()
        let expense = Expense(
            id: expenseID,
            title: "Integration dinner",
            amount: 42,
            payerID: ownerID,
            participantIDs: [ownerID],
            date: Date()
        )
        let trip = Trip(
            name: "Local Integration Trip",
            currencyCode: "USD",
            creatorID: ownerID,
            members: [owner],
            budgets: [ownerID: 250],
            expenses: [expense],
            location: "Localhost"
        )

        let trips = TripsRepository.shared
        try await trips.upsert(trip, accessToken: ownerSession.accessToken)
        var ownerTrips = try await trips.fetch(accessToken: ownerSession.accessToken, forceRefresh: true)
        let storedTrip = try XCTUnwrap(ownerTrips.first(where: { $0.id == trip.id }))
        XCTAssertEqual(storedTrip.expenses.first?.id, expenseID)
        XCTAssertEqual(storedTrip.expenses.first?.amount, 42)

        var updatedTrip = storedTrip
        updatedTrip.name = "Updated Local Integration Trip"
        try await trips.upsert(updatedTrip, accessToken: ownerSession.accessToken)
        ownerTrips = try await trips.fetch(accessToken: ownerSession.accessToken, forceRefresh: true)
        XCTAssertEqual(ownerTrips.first(where: { $0.id == trip.id })?.name, updatedTrip.name)

        let invitationToken = try await trips.createInvitationLink(
            tripID: trip.id,
            accessToken: ownerSession.accessToken
        )
        let pending = try await trips.pendingInvitations(
            tripID: trip.id,
            accessToken: ownerSession.accessToken
        )
        XCTAssertEqual(pending.count, 1)
        let preview = try await trips.previewInvitation(
            token: invitationToken,
            accessToken: memberSession.accessToken
        )
        XCTAssertEqual(preview.tripName, updatedTrip.name)
        let acceptedTripID = try await trips.acceptInvitation(
            token: invitationToken,
            accessToken: memberSession.accessToken
        )
        XCTAssertEqual(acceptedTripID, trip.id)
        let memberTrips = try await trips.fetch(accessToken: memberSession.accessToken, forceRefresh: true)
        XCTAssertTrue(memberTrips.contains(where: { $0.id == trip.id }))

        let feed = FeedRepository.shared
        var post = FeedPost(
            authorID: ownerID,
            authorName: owner.name,
            text: "Local feed post",
            locationName: "Supabase Studio"
        )
        try await feed.insert(post, tripID: trip.id, accessToken: ownerSession.accessToken)
        let memberFeed = try await feed.fetch(tripID: trip.id, accessToken: memberSession.accessToken)
        XCTAssertEqual(memberFeed.first?.id, post.id)

        post.comments.append(ExpenseComment(
            authorID: memberID,
            authorName: "Local Member",
            text: "Synced comment"
        ))
        post.reactions["👍"] = [memberID]
        try await feed.updateInteractions(for: post, accessToken: memberSession.accessToken)
        let interactedFeed = try await feed.fetch(
            tripID: trip.id,
            accessToken: ownerSession.accessToken
        )
        let interactedPost = try XCTUnwrap(interactedFeed.first)
        XCTAssertEqual(interactedPost.comments.first?.text, "Synced comment")
        XCTAssertEqual(interactedPost.reactions["👍"], [memberID])
        let newerPost = FeedPost(authorID: ownerID, authorName: owner.name, text: "Newer page")
        try await feed.insert(newerPost, tripID: trip.id, accessToken: ownerSession.accessToken)
        let firstPage = try await feed.fetchPage(tripID: trip.id, accessToken: ownerSession.accessToken, limit: 1)
        XCTAssertEqual(firstPage.posts.first?.id, newerPost.id)
        let secondPage = try await feed.fetchPage(tripID: trip.id, accessToken: ownerSession.accessToken,
                                                   before: firstPage.next, limit: 1)
        XCTAssertEqual(secondPage.posts.first?.id, post.id)
        let endPage = try await feed.fetchPage(tripID: trip.id, accessToken: ownerSession.accessToken,
                                                before: secondPage.next, limit: 1)
        XCTAssertTrue(endPage.posts.isEmpty)
        XCTAssertNil(endPage.next)
        let locations = try await feed.fetch(tripID: trip.id, accessToken: ownerSession.accessToken, locationsOnly: true)
        XCTAssertEqual(locations.map(\.id), [post.id])
        XCTAssertTrue(locations.first?.comments.isEmpty == true)
        try await feed.delete(postID: newerPost.id, accessToken: ownerSession.accessToken)
        try await feed.updateBody(
            postID: post.id,
            text: "Edited local feed post",
            locationName: nil,
            location: nil,
            accessToken: ownerSession.accessToken
        )

        let storagePath = "\(ownerID.uuidString.lowercased())/\(expenseID.uuidString.lowercased()).jpg"
        let uploadedPath = try await ReceiptStorage.shared.upload(
            jpeg,
            path: storagePath,
            assetType: "receipt",
            tripID: trip.id,
            recordID: expenseID,
            accessToken: ownerSession.accessToken
        )
        XCTAssertEqual(uploadedPath, storagePath)
        let signedURL = try await ReceiptStorage.shared.signedURL(
            path: storagePath,
            expiresIn: 60,
            accessToken: ownerSession.accessToken
        )
        let (_, signedResponse) = try await BackendSecurity.secureSession.data(from: signedURL)
        XCTAssertEqual((signedResponse as? HTTPURLResponse)?.statusCode, 200)

        ownerSession = try await auth.refreshSession(
            refreshToken: ownerSession.refreshToken,
            email: ownerEmail
        )
        let refreshedSessionAccepted = await auth.isSessionAccepted(accessToken: ownerSession.accessToken)
        XCTAssertTrue(refreshedSessionAccepted)

        try await auth.signOut(accessToken: ownerSession.accessToken)
        let signedOutSessionAccepted = await auth.isSessionAccepted(accessToken: ownerSession.accessToken)
        XCTAssertFalse(signedOutSessionAccepted)
        ownerSession = try await auth.signIn(email: ownerEmail, password: password)

        try await feed.delete(postID: post.id, accessToken: ownerSession.accessToken)
        let emptyFeed = try await feed.fetch(tripID: trip.id, accessToken: ownerSession.accessToken)
        XCTAssertTrue(emptyFeed.isEmpty)

        try await auth.deleteAccount(accessToken: memberSession.accessToken)
        let deletedMemberSessionAccepted = await auth.isSessionAccepted(accessToken: memberSession.accessToken)
        XCTAssertFalse(deletedMemberSessionAccepted)

        try await trips.delete(id: trip.id, accessToken: ownerSession.accessToken)
        ownerTrips = try await trips.fetch(accessToken: ownerSession.accessToken, forceRefresh: true)
        XCTAssertFalse(ownerTrips.contains(where: { $0.id == trip.id }))

        try await auth.deleteAccount(accessToken: ownerSession.accessToken)
        let deletedOwnerSessionAccepted = await auth.isSessionAccepted(accessToken: ownerSession.accessToken)
        XCTAssertFalse(deletedOwnerSessionAccepted)
    }

    func testLocalSupabaseOutageIsAnErrorNotEmptyData() async throws {
        try XCTSkipUnless(
            Self.runsLocalOutageTest,
            "Set TRIPSPLIT_RUN_LOCAL_OUTAGE_TEST=1 in Xcode, or compile with LOCAL_SUPABASE_OUTAGE from the CLI."
        )

        XCTAssertEqual(SupabaseConfig.url, BackendEnvironment.localDevelopment.url)
        let signInStartedAt = Date()
        do {
            _ = try await AuthService.shared.signIn(
                email: "offline-signin@example.com",
                password: password
            )
            XCTFail("Sign-in must not succeed while local Auth is unavailable.")
        } catch let error as AuthError {
            XCTAssertEqual(error.message, "Couldn't reach the server. Check your connection.")
        }
        XCTAssertLessThan(
            Date().timeIntervalSince(signInStartedAt),
            8,
            "Sign-in should fail within the five-second Debug budget."
        )

        let tripFetchStartedAt = Date()
        do {
            _ = try await TripsRepository.shared.fetch(
                accessToken: "intentionally-unusable-while-offline",
                forceRefresh: true
            )
            XCTFail("An unavailable backend must throw rather than look like an empty account.")
        } catch let error as AuthError {
            XCTAssertEqual(error.message, "Couldn't reach the server. Check your connection.")
        }
        XCTAssertLessThan(
            Date().timeIntervalSince(tripFetchStartedAt),
            8,
            "Initial data refresh should fail within the five-second Debug budget."
        )
    }

    private func signedInSession(
        from outcome: AuthService.SignUpOutcome,
        email: String
    ) throws -> AuthSession {
        switch outcome {
        case .signedIn(let session):
            return session
        case .needsConfirmation:
            throw XCTSkip("Local email confirmation is enabled unexpectedly for \(email).")
        }
    }

    private static var runsLocalIntegration: Bool {
        #if LOCAL_SUPABASE_INTEGRATION
        true
        #else
        ProcessInfo.processInfo.environment["TRIPSPLIT_RUN_LOCAL_INTEGRATION"] == "1"
        #endif
    }

    private static var runsLocalOutageTest: Bool {
        #if LOCAL_SUPABASE_OUTAGE
        true
        #else
        ProcessInfo.processInfo.environment["TRIPSPLIT_RUN_LOCAL_OUTAGE_TEST"] == "1"
        #endif
    }

    private func makeJPEG() -> Data? {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2))
        let image = renderer.image { context in
            UIColor.systemBlue.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        return image.jpegData(compressionQuality: 0.8)
    }
}
