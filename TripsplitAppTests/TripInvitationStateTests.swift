import XCTest
@testable import Tripsplit

@MainActor
final class TripInvitationStateTests: XCTestCase {
    func testInvitationSuccessAndFailureDoNotDependOnMessageWords() async {
        let state = TripInvitationState()
        state.email = "  friend@example.com  "
        let sent = await state.invite { email in
            XCTAssertEqual(email, "friend@example.com")
            XCTAssertTrue(state.isBusy)
        }
        XCTAssertTrue(sent)
        XCTAssertEqual(state.feedback, .success(String(localized: "Invitation pending. Membership starts only after the recipient accepts.")))
        XCTAssertTrue(state.email.isEmpty)
        XCTAssertFalse(state.isBusy)

        state.email = "friend@example.com"
        let failed = await state.invite { _ in
            throw AuthError(message: "Previously invited, but access was revoked.")
        }
        XCTAssertFalse(failed)
        XCTAssertEqual(state.feedback, .failure("Previously invited, but access was revoked."))
        XCTAssertEqual(state.email, "friend@example.com")
        XCTAssertFalse(state.isBusy)
    }

    func testInvitationLinkFailurePreservesPreviousLinkAndExplicitFeedback() async throws {
        let state = TripInvitationState()
        let link = try XCTUnwrap(URL(string: "https://example.com/invitation/test"))
        let generated = await state.generateLink { link }
        XCTAssertTrue(generated)
        XCTAssertEqual(state.link, link)
        XCTAssertEqual(state.feedback?.isSuccess, true)
        state.didCopyLink()
        XCTAssertEqual(state.feedback, .success(String(localized: "Invitation link copied.")))

        let failed = await state.generateLink { throw AuthError(message: "Link not ready") }
        XCTAssertFalse(failed)
        XCTAssertEqual(state.link, link)
        XCTAssertEqual(state.feedback, .failure("Link not ready"))
        XCTAssertFalse(state.isBusy)
    }

    func testInvitationRejectsEmptyInputAndOverlappingRequests() async {
        let state = TripInvitationState()
        state.email = "  \n "
        let empty = await state.invite { _ in XCTFail("Empty email must not be sent") }
        XCTAssertFalse(empty)
        state.email = "friend@example.com"
        let sent = await state.invite { _ in
            let duplicate = await state.invite { _ in XCTFail("Duplicate request") }
            let overlapping = await state.generateLink {
                XCTFail("Link request must wait for the invitation")
                throw AuthError(message: "Unexpected request")
            }
            XCTAssertFalse(duplicate)
            XCTAssertFalse(overlapping)
        }
        XCTAssertTrue(sent)
        XCTAssertFalse(state.isBusy)
    }
}
