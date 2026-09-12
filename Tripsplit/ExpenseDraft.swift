import Foundation

/// Editable expense data and deterministic split/save preparation. Receipt I/O and
/// presentation state stay in AddExpenseView; all money allocation uses SplitEngine.
struct ExpenseDraft {
    var title = ""
    var amountText = ""
    var date = Date()
    var expenseLocation: ExpenseLocation?
    var method: SplitMethod = .equalAll
    var selected: Set<Person.ID> = []
    var noSplitAssignee: Person.ID?
    var percentages: [Person.ID: Double] = [:]
    var amounts: [Person.ID: Double] = [:]
    var expenseID = UUID()
    var items: [ReceiptItem] = []
    var receiptURL: String?
    var taxText = ""
    var tipText = ""
    var payForOthers = false
    var selectedPayerID: Person.ID?
    var removedItems: [(item: ReceiptItem, index: Int)] = []

    init() {}

    var total: Double { Double(amountText) ?? 0 }

    func payer(fallback currentUserID: Person.ID) -> Person.ID {
        selectedPayerID ?? currentUserID
    }

    var itemsTotal: Double {
        SplitEngine.roundToTwo(items.reduce(0) { $0 + $1.price })
    }

    var taxAmount: Double { max(0, Double(taxText) ?? 0) }
    var tipAmount: Double { max(0, Double(tipText) ?? 0) }
    var extras: Double { SplitEngine.roundToTwo(taxAmount + tipAmount) }
    /// Items subtotal plus tax and tip — the amount actually charged.
    var grandTotal: Double { SplitEngine.roundToTwo(itemsTotal + extras) }

    /// Live split computation, reused for validation, the per-person preview, and save.
    func result(for trip: Trip, currentUserID: Person.ID) -> SplitResult {
        SplitEngine.calculate(
            total: total,
            method: method,
            people: trip.members,
            payer: payer(fallback: currentUserID),
            selected: selected,
            noSplitAssignee: noSplitAssignee ?? payer(fallback: currentUserID),
            percentages: percentages,
            amounts: amounts
        )
    }

    func canSave(_ trip: Trip, currentUserID: Person.ID) -> Bool {
        if !items.isEmpty {
            return itemsTotal > 0 && allocatedShares(trip, currentUserID: currentUserID).valid
        }
        return total > 0 && result(for: trip, currentUserID: currentUserID).isValid
    }

    /// Each scanned item carries its own split; the expense total per member is the sum
    /// of that member's share across every item. Mirrors the capstone's per-item model.
    func perItemShares(_ trip: Trip, currentUserID: Person.ID) -> (shares: [Person.ID: Double], valid: Bool) {
        var totals: [Person.ID: Double] = [:]
        var valid = true
        for item in items {
            let outcome = SplitEngine.calculate(
                total: item.price,
                method: item.splitMethod,
                people: trip.members,
                payer: payer(fallback: currentUserID),
                selected: item.participantIDs,
                noSplitAssignee: item.soloPayerID ?? payer(fallback: currentUserID),
                percentages: item.percentages,
                amounts: item.amounts
            )
            if !outcome.isValid { valid = false }
            for (member, owed) in outcome.owed where owed > 0.005 {
                totals[member, default: 0] += owed
            }
        }
        return (totals.mapValues { SplitEngine.roundToTwo($0) }, valid)
    }

    /// Per-item shares with tax and tip allocated on top, proportional to each person's
    /// subtotal. The combined shares sum exactly to `grandTotal`.
    func allocatedShares(_ trip: Trip, currentUserID: Person.ID) -> (shares: [Person.ID: Double], valid: Bool) {
        let base = perItemShares(trip, currentUserID: currentUserID)
        guard extras > 0.005 else { return base }

        let allocation = SplitEngine.allocateProportionally(extras, weights: base.shares)
        var combined = base.shares
        for (id, add) in allocation {
            combined[id] = SplitEngine.roundToTwo((combined[id] ?? 0) + add)
        }
        return (combined, base.valid)
    }

    /// Sets sensible defaults when switching split methods.
    mutating func configureForMethod(_ trip: Trip, currentUserID: Person.ID) {
        switch method {
        case .equalSelected:
            if selected.isEmpty { selected = Set(trip.members.map(\.id)) }
        case .noSplit:
            if noSplitAssignee == nil { noSplitAssignee = payer(fallback: currentUserID) }
        default:
            break
        }
    }

    init(
        trip: Trip,
        currentUserID: Person.ID,
        editing: Expense? = nil,
        startWithFullSplit: Bool = false,
        prefillTitle: String? = nil,
        prefillAmount: Double? = nil,
        prefillLocation: ExpenseLocation? = nil
    ) {
        if let editing {
            expenseID = editing.id
            selectedPayerID = editing.payerID
            title = editing.title
            amountText = Self.formatted(editing.amount)
            date = editing.date
            items = editing.items
            receiptURL = editing.receiptURL
            if let location = editing.location {
                expenseLocation = location
            }
            selected = editing.participantIDs
            if editing.tax > 0 { taxText = Self.formatted(editing.tax) }
            if editing.tip > 0 { tipText = Self.formatted(editing.tip) }
            // Reconstruct an editable split from the stored per-member shares.
            if !editing.shares.isEmpty {
                method = .amount
                amounts = editing.shares
            }
            // Restore "pay for others" if anyone besides the current user was included.
            let me = currentUserID
            payForOthers = editing.participantIDs.contains(where: { $0 != me })
                || editing.shares.keys.contains(where: { $0 != me })
            return
        }
        // Default: the user only covers their own share, paid by themselves. The
        // explicit Split Expense shortcut opts into the saved group-split flow.
        selectedPayerID = currentUserID
        payForOthers = startWithFullSplit
        method = startWithFullSplit ? .equalAll : .noSplit
        noSplitAssignee = currentUserID
        if selected.isEmpty { selected = Set(trip.members.map(\.id)) }
        if let prefillTitle { title = prefillTitle }
        if let prefillAmount, prefillAmount > 0 { amountText = Self.formatted(prefillAmount) }
        if let prefillLocation {
            expenseLocation = prefillLocation
        }
    }

    private static func formatted(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)).grouping(.never))
    }

    /// Returns nil for incomplete splits. Editing preserves fields outside this form,
    /// including identity, deletion metadata, and the previous receipt on upload failure.
    func preparedExpense(for trip: Trip, currentUserID: Person.ID, editing: Expense? = nil) -> Expense? {
        // When the receipt has items, the total and split come from the per-item config;
        // otherwise they come from the single expense-level split.
        let amountToSave: Double
        let shares: [Person.ID: Double]
        if items.isEmpty {
            let outcome = result(for: trip, currentUserID: currentUserID)
            guard total > 0, outcome.isValid else { return nil }
            amountToSave = total
            shares = outcome.owed.filter { $0.value > 0.005 }
        } else {
            let outcome = allocatedShares(trip, currentUserID: currentUserID)
            guard itemsTotal > 0, outcome.valid else { return nil }
            amountToSave = grandTotal
            shares = outcome.shares.filter { $0.value > 0.005 }
        }

        let participantIDs = Set(shares.keys)
        let resolvedTitle = title.trimmingCharacters(in: .whitespaces).isEmpty ? "Expense" : title
        // Tax/tip only apply to the per-item receipt flow.
        let savedTax = items.isEmpty ? 0 : taxAmount
        let savedTip = items.isEmpty ? 0 : tipAmount

        if let editing {
            var updated = editing
            updated.title = resolvedTitle
            updated.amount = amountToSave
            updated.payerID = payer(fallback: currentUserID)
            updated.participantIDs = participantIDs
            updated.date = date
            updated.shares = shares
            updated.items = items
            updated.receiptURL = receiptURL ?? editing.receiptURL
            updated.tax = savedTax
            updated.tip = savedTip
            updated.location = expenseLocation
            return updated
        } else {
            return Expense(
                id: expenseID,
                title: resolvedTitle,
                amount: amountToSave,
                payerID: payer(fallback: currentUserID),
                participantIDs: participantIDs,
                date: date,
                shares: shares,
                receiptURL: receiptURL,
                items: items,
                tax: savedTax,
                tip: savedTip,
                location: expenseLocation
            )
        }
    }
}
