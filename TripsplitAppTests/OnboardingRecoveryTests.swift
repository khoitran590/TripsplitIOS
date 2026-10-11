import XCTest
@testable import Tripsplit

@MainActor
final class OnboardingRecoveryTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private var date = Date(timeIntervalSince1970: 1_000_000)

    override func setUp() {
        super.setUp()
        suite = "OnboardingRecoveryTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        date = Date(timeIntervalSince1970: 1_000_000)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        super.tearDown()
    }

    private func coordinator() -> OnboardingCoordinator {
        OnboardingCoordinator(defaults: defaults, now: { self.date })
    }

    func testInterruptedDraftSurvivesRelaunchWithoutForcedModal() {
        let id = UUID()
        let first = coordinator()
        first.update(userID: nil, displayName: "")
        first.update(userID: id, displayName: "", authIntent: .newRegistration)
        first.saveProgress(step: .quickStart, name: "Jane", page: 2)
        first.saveAvatar(Data([1, 2, 3]))
        first.suspendSetup()
        XCTAssertEqual(first.completion, .interrupted)

        let restored = coordinator()
        restored.update(userID: id, displayName: "Jane", authIntent: .sessionRestored)
        XCTAssertNil(restored.visibleStep)
        XCTAssertTrue(restored.hasUnfinishedSetup)
        XCTAssertEqual(restored.savedStep, .quickStart)
        XCTAssertEqual(restored.savedName, "Jane")
        XCTAssertEqual(restored.savedFeaturePage, 2)
        XCTAssertEqual(restored.savedAvatar, Data([1, 2, 3]))
        restored.resumeSetup()
        XCTAssertEqual(restored.visibleStep, .newUserFlow)
    }

    func testExplicitSkipDoesNotBecomeInterruptionOnSheetDismissal() {
        let id = UUID()
        let subject = coordinator()
        subject.update(userID: nil, displayName: "")
        subject.update(userID: id, displayName: "", authIntent: .newRegistration)
        subject.skipSetup()
        subject.suspendSetup() // SwiftUI onDismiss still runs.
        XCTAssertEqual(subject.completion, .skipped)
        XCTAssertFalse(subject.hasUnfinishedSetup)
        let restored = coordinator()
        restored.update(userID: id, displayName: "Traveler", authIntent: .sessionRestored)
        XCTAssertFalse(restored.hasUnfinishedSetup)
        XCTAssertNil(restored.step)
    }

    func testReturningBlankProfileCanResumeItsIdentityDraft() {
        let id = UUID()
        let first = coordinator()
        first.update(userID: id, displayName: "", authIntent: .sessionRestored)
        first.update(userID: nil, displayName: "")
        first.update(userID: id, displayName: "", authIntent: .existingSignIn)
        XCTAssertEqual(first.step, .profileSetup)
        first.saveProgress(step: .identity, name: "Jane", page: 0)
        first.profileSetupFinished() // Swipe dismissal is an interruption.
        XCTAssertEqual(first.completion, .interrupted)
        let restored = coordinator()
        restored.update(userID: id, displayName: "", authIntent: .sessionRestored)
        XCTAssertNil(restored.visibleStep)
        XCTAssertEqual(restored.savedName, "Jane")
        restored.resumeSetup()
        XCTAssertEqual(restored.visibleStep, .profileSetup)
        restored.skipSetup()
        restored.profileSetupFinished()
        XCTAssertEqual(restored.completion, .skipped)
    }

    func testCompletionClearsAccountScopedDraftWithoutAffectingOtherAccount() {
        let a = UUID(), b = UUID()
        let subject = coordinator()
        subject.update(userID: nil, displayName: "")
        subject.update(userID: a, displayName: "", authIntent: .newRegistration)
        subject.saveProgress(step: .featureTour, name: "A", page: 2)
        subject.suspendSetup()
        subject.update(userID: b, displayName: "", authIntent: .newRegistration)
        XCTAssertEqual(subject.savedStep, .identity)
        XCTAssertEqual(subject.savedName, "")
        subject.newUserOnboardingFinished()
        XCTAssertEqual(subject.completion, .completed)
        subject.update(userID: a, displayName: "A", authIntent: .sessionRestored)
        XCTAssertEqual(subject.savedName, "A")
        XCTAssertEqual(subject.savedFeaturePage, 2)
        XCTAssertTrue(subject.hasUnfinishedSetup)
    }

    func testLongAbsenceOffersOptionalRefresherForSavedSessionAndRespectsDismissal() {
        let id = UUID()
        coordinator().update(userID: id, displayName: "Jane", authIntent: .sessionRestored)
        date += 31 * 24 * 60 * 60
        let returning = coordinator()
        returning.update(userID: id, displayName: "Jane", authIntent: .sessionRestored)
        XCTAssertTrue(returning.offersRefresher)
        XCTAssertNotNil(returning.visibleReturningSummary)
        XCTAssertNil(returning.visibleStep)
        returning.dismissReturningSummary()
        date += 24 * 60 * 60
        let nextDay = coordinator()
        nextDay.update(userID: id, displayName: "Jane", authIntent: .sessionRestored)
        XCTAssertFalse(nextDay.offersRefresher)
        XCTAssertNil(nextDay.visibleReturningSummary)
    }

    func testForegroundDetectsAbsenceWithoutProcessRelaunch() {
        let subject = coordinator()
        subject.update(userID: UUID(), displayName: "Jane", authIntent: .sessionRestored)
        date += 31 * 24 * 60 * 60
        subject.checkForReturn(displayName: "Jane")
        XCTAssertTrue(subject.offersRefresher)
        XCTAssertNil(subject.visibleStep)
        subject.guideOpened()
        XCTAssertNil(subject.returningUserSummary)
    }

    func testInvitationOwnsPresentationAndDefersGenericSetup() {
        let subject = coordinator()
        subject.update(userID: nil, displayName: "")
        subject.invitationOwnsPresentation = true
        subject.update(userID: UUID(), displayName: "", authIntent: .existingSignIn)
        XCTAssertEqual(subject.step, .newUserFlow)
        XCTAssertNil(subject.visibleStep)
        subject.deferSetupForInvitation()
        subject.invitationOwnsPresentation = false
        XCTAssertNil(subject.visibleStep)
        XCTAssertTrue(subject.hasUnfinishedSetup)
        XCTAssertEqual(subject.completion, .interrupted)
    }

    func testTokenRotationDoesNotResetVisibleProgressOrRecordCompletion() {
        let id = UUID()
        let subject = coordinator()
        subject.update(userID: nil, displayName: "")
        subject.update(userID: id, displayName: "", authIntent: .newRegistration)
        subject.saveProgress(step: .featureTour, name: "Jane", page: 1)
        subject.update(userID: id, displayName: "Jane")
        XCTAssertEqual(subject.savedStep, .featureTour)
        XCTAssertEqual(subject.step, .newUserFlow)
        XCTAssertEqual(subject.completion, .inProgress)
    }

    func testZeroNetBalanceDoesNotMeanBothDebtsAreSettled() {
        var totals = TripStore.HomeTotals()
        totals.youOwe = 50
        totals.owedToYou = 50
        let result = ReturningBalances(totals: totals, loadState: .loaded)
        XCTAssertTrue(result.isComplete)
        XCTAssertFalse(result.isSettled)
        XCTAssertEqual(result.youOwe, 50)
        XCTAssertEqual(result.owedToYou, 50)
    }

    func testUnknownOrMissingFXTotalsNeverSaySettled() {
        let zero = TripStore.HomeTotals()
        for state: TripStore.CloudLoadState in [.idle, .loading, .failed("Offline")] {
            XCTAssertFalse(ReturningBalances(totals: zero, loadState: state).isSettled)
        }
        var incomplete = zero
        incomplete.unavailableCurrencies.insert("JPY")
        XCTAssertFalse(ReturningBalances(totals: incomplete, loadState: .loaded).isSettled)
        XCTAssertTrue(ReturningBalances(totals: zero, loadState: .loaded).isSettled)
    }

    func testReturnBalancesUseSelectedCurrency() {
        let store = TripStore()
        let me = store.currentUser, friend = Person(name: "Friend", color: .blue)
        store.trips = [Trip(name: "Trip", currencyCode: "USD", creatorID: me.id, members: [me, friend], budgets: [:], expenses: [
            Expense(title: "Dinner", amount: 60, payerID: me.id, participantIDs: [me.id, friend.id], date: date)
        ])]
        store.usdRates = ["USD": 1, "EUR": 2]
        XCTAssertEqual(ReturningBalances(totals: store.homeTotals(in: "USD"), loadState: .loaded).owedToYou, 30)
        XCTAssertEqual(ReturningBalances(totals: store.homeTotals(in: "EUR"), loadState: .loaded).owedToYou, 60)
    }

    func testPracticeEditsAndRepaymentsLeaveRealAccountUntouched() {
        let real = TripStore()
        real.currentUser.name = "Real person"
        real.accessToken = "real-account-token"
        let user = real.currentUser
        let before = real.trips
        var practice = PracticeTrip()
        practice.useSampleReceipt()
        practice.draft.items[0].soloPayerID = practice.trip.members[1].id
        practice.draft.items[0].splitMethod = .noSplit
        XCTAssertTrue(practice.saveExpense())
        let expense = practice.trip.expenses[0]
        XCTAssertEqual(SplitEngine.roundToTwo(expense.shares.values.reduce(0, +)), expense.amount)
        for settlement in practice.trip.settlements() {
            practice.confirmPracticePayment(settlement)
            XCTAssertEqual(practice.remaining(settlement), 0)
        }
        XCTAssertEqual(real.currentUser.id, user.id)
        XCTAssertEqual(real.currentUser.name, "Real person")
        XCTAssertEqual(real.trips, before)
        XCTAssertEqual(real.accessToken, "real-account-token")
        // Exit/re-entry starts fresh rather than reusing either account or practice data.
        XCTAssertTrue(PracticeTrip().trip.expenses.isEmpty)
    }

    func testScreenshotInstallerCannotBeCalledFromProductionSession() {
        XCTAssertFalse(AppStoreDemoData.isEnabled)
        let real = TripStore()
        real.currentUser.name = "Real person"
        let id = real.currentUser.id
        real.installAppStoreDemoData()
        XCTAssertEqual(real.currentUser.id, id)
        XCTAssertEqual(real.currentUser.name, "Real person")
        XCTAssertTrue(real.trips.isEmpty)
    }

    func testPendingInvitationSurvivesStorageRecreationAndClearsOnCancellation() {
        let service = "OnboardingInvitationTests.\(UUID().uuidString)"
        let first = PendingInvitationStore(service: service)
        defer { first.delete() }
        let url = URL(string: "tripsplit://invite?token=0123456789abcdef0123456789abcdef01234567")!
        XCTAssertTrue(first.save(url))
        let restored = PendingInvitationStore(service: service)
        XCTAssertEqual(restored.load(), url)
        XCTAssertFalse(restored.save(URL(string: "tripsplit://profile?token=hello")!))
        XCTAssertEqual(restored.load(), url)
        XCTAssertTrue(restored.delete())
        XCTAssertNil(first.load())
    }
}
