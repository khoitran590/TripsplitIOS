import XCTest
import SwiftUI
@testable import Tripsplit

@MainActor
final class ExpenseDraftTests: XCTestCase {
    private let alice = Person(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "Alice", color: .red)
    private let bob = Person(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, name: "Bob", color: .blue)
    private let chris = Person(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, name: "Chris", color: .green)

    private var trip: Trip {
        Trip(name: "Weekend", currencyCode: "USD", creatorID: alice.id,
             members: [alice, bob, chris], budgets: [:])
    }

    func testPersonalDefaultAndMapPrefillPrepareOnlyCurrentUsersShare() throws {
        let location = ExpenseLocation(name: "Cafe", latitude: 35, longitude: 139)
        var draft = ExpenseDraft(trip: trip, currentUserID: alice.id,
                                 prefillTitle: "Coffee", prefillAmount: 12.50, prefillLocation: location)
        draft.taxText = "8"
        draft.tipText = "5"
        let expense = try XCTUnwrap(draft.preparedExpense(for: trip, currentUserID: alice.id))
        XCTAssertFalse(draft.payForOthers)
        XCTAssertEqual(expense.title, "Coffee")
        XCTAssertEqual(expense.amount, 12.50)
        XCTAssertEqual(expense.shares, [alice.id: 12.50])
        XCTAssertEqual(expense.participantIDs, [alice.id])
        XCTAssertEqual(expense.location, location)
        XCTAssertEqual(expense.tax, 0)
        XCTAssertEqual(expense.tip, 0)
    }

    func testGroupShortcutReconcilesRoundingAndUsesChosenPayer() throws {
        var draft = ExpenseDraft(trip: trip, currentUserID: alice.id, startWithFullSplit: true)
        draft.amountText = "10"
        draft.title = "   "
        draft.selectedPayerID = bob.id
        XCTAssertTrue(draft.payForOthers)
        XCTAssertEqual(draft.method, .equalAll)
        XCTAssertTrue(draft.canSave(trip, currentUserID: alice.id))
        let expense = try XCTUnwrap(draft.preparedExpense(for: trip, currentUserID: alice.id))
        XCTAssertEqual(expense.id, draft.expenseID)
        XCTAssertEqual(expense.payerID, bob.id)
        XCTAssertEqual(expense.title, "Expense")
        XCTAssertEqual(expense.participantIDs, Set(trip.members.map(\.id)))
        XCTAssertEqual(expense.shares.values.reduce(0, +), 10, accuracy: 0.001)
        XCTAssertEqual(expense.shares.values.sorted(), [3.33, 3.33, 3.34])
    }

    func testIncompleteExpenseSplitsCannotBePrepared() {
        var draft = ExpenseDraft(trip: trip, currentUserID: alice.id)
        for amount in ["", "not a number", "0", "-5"] {
            draft.amountText = amount
            XCTAssertFalse(draft.canSave(trip, currentUserID: alice.id))
            XCTAssertNil(draft.preparedExpense(for: trip, currentUserID: alice.id))
        }
        draft.amountText = "100"
        draft.method = .percentage
        draft.percentages = [alice.id: 40, bob.id: 50]
        XCTAssertFalse(draft.canSave(trip, currentUserID: alice.id))
        XCTAssertNil(draft.preparedExpense(for: trip, currentUserID: alice.id))
        draft.method = .amount
        draft.amounts = [alice.id: 50, bob.id: 40]
        XCTAssertFalse(draft.canSave(trip, currentUserID: alice.id))
        XCTAssertNil(draft.preparedExpense(for: trip, currentUserID: alice.id))
    }

    func testMixedReceiptSplitsAllocateTaxAndTipBySubtotal() throws {
        var draft = ExpenseDraft(trip: trip, currentUserID: alice.id)
        draft.amountText = "999" // Receipt totals must override the manual field.
        draft.items = [
            ReceiptItem(name: "Shared starter", price: 30, splitMethod: .equalAll),
            ReceiptItem(name: "Coffee", price: 10, splitMethod: .noSplit, soloPayerID: bob.id)
        ]
        draft.taxText = "4"
        draft.tipText = "6"
        let expense = try XCTUnwrap(draft.preparedExpense(for: trip, currentUserID: alice.id))
        XCTAssertTrue(draft.canSave(trip, currentUserID: alice.id))
        XCTAssertEqual(expense.amount, 50)
        XCTAssertEqual(expense.shares, [alice.id: 12.5, bob.id: 25, chris.id: 12.5])
        XCTAssertEqual(expense.items, draft.items)
        XCTAssertEqual(expense.tax, 4)
        XCTAssertEqual(expense.tip, 6)
    }

    func testInvalidReceiptItemBlocksSaveEvenWithValidManualAmount() {
        var draft = ExpenseDraft(trip: trip, currentUserID: alice.id, prefillAmount: 10)
        draft.items = [ReceiptItem(name: "Dinner", price: 10, splitMethod: .percentage,
                                   percentages: [alice.id: 50])]
        XCTAssertFalse(draft.canSave(trip, currentUserID: alice.id))
        XCTAssertNil(draft.preparedExpense(for: trip, currentUserID: alice.id))
        draft.items = [ReceiptItem(name: "Empty", price: 0)]
        draft.taxText = "5"
        XCTAssertFalse(draft.canSave(trip, currentUserID: alice.id))
        XCTAssertNil(draft.preparedExpense(for: trip, currentUserID: alice.id))
    }

    func testEditingPreservesIdentityMetadataAndPreviousReceiptOnUploadFailure() throws {
        let original = Expense(title: "Dinner", amount: 30, payerID: bob.id,
                               participantIDs: [alice.id, bob.id], date: Date(timeIntervalSince1970: 100),
                               shares: [alice.id: 10, bob.id: 20], receiptURL: "receipts/original.jpg",
                               deletedAt: Date(timeIntervalSince1970: 200))
        var draft = ExpenseDraft(trip: trip, currentUserID: alice.id, editing: original)
        XCTAssertEqual(draft.method, .amount)
        XCTAssertTrue(draft.payForOthers)
        XCTAssertEqual(draft.amounts, original.shares)
        draft.title = "Updated dinner"
        draft.receiptURL = nil
        let updated = try XCTUnwrap(draft.preparedExpense(for: trip, currentUserID: alice.id, editing: original))
        var expected = original
        expected.title = "Updated dinner"
        XCTAssertEqual(updated, expected)
        draft.receiptURL = "receipts/replacement.jpg"
        XCTAssertEqual(draft.preparedExpense(for: trip, currentUserID: alice.id, editing: original)?.receiptURL,
                       "receipts/replacement.jpg")
    }

    func testItemizedExpenseSurvivesEditRoundTrip() throws {
        var draft = ExpenseDraft(trip: trip, currentUserID: alice.id)
        draft.title = "Receipt"
        draft.items = [ReceiptItem(name: "Dinner", price: 10, splitMethod: .equalAll)]
        draft.taxText = "0.07"
        draft.tipText = "0.08"
        let original = try XCTUnwrap(draft.preparedExpense(for: trip, currentUserID: alice.id))
        XCTAssertEqual(original.shares.values.reduce(0, +), 10.15, accuracy: 0.001)
        let restored = ExpenseDraft(trip: trip, currentUserID: alice.id, editing: original)
        XCTAssertEqual(restored.preparedExpense(for: trip, currentUserID: alice.id, editing: original), original)
    }
}
