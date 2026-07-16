import SwiftUI

// MARK: - Trip Models

/// A single expense within a trip. The payer fronts the whole `amount`; everyone in
/// `participantIDs` shares it equally, mirroring TripSplit's equal-split debts.
struct Expense: Identifiable, Codable {
    var id = UUID()
    var title: String
    var amount: Double
    var payerID: Person.ID
    var participantIDs: Set<Person.ID>
    var date: Date

    /// Explicit per-member owed amounts produced by the split configuration (equal,
    /// selected, single-payer, percentage, or by amount). When non-empty this defines
    /// the split exactly; otherwise the expense falls back to an equal split across
    /// `participantIDs`. Older expenses without this field keep working unchanged.
    var shares: [Person.ID: Double] = [:]

    /// Public URL of the uploaded receipt image in Supabase Storage, if any.
    var receiptURL: String? = nil

    /// Line items scanned from the receipt, shown for reference on the expense.
    var items: [ReceiptItem] = []

    /// Tax and tip allocated across the items (already folded into `shares` and
    /// `amount`); kept so editing can re-show and re-distribute them.
    var tax: Double = 0
    var tip: Double = 0

    /// When set, the expense has been soft-deleted: it's removed from the active split
    /// and settle-up math but retained in `Trip.deletedExpenses` so it still counts
    /// against the budget (deleting doesn't refund budget headroom) and can be restored.
    var deletedAt: Date? = nil

    init(
        id: UUID = UUID(),
        title: String,
        amount: Double,
        payerID: Person.ID,
        participantIDs: Set<Person.ID>,
        date: Date,
        shares: [Person.ID: Double] = [:],
        receiptURL: String? = nil,
        items: [ReceiptItem] = [],
        tax: Double = 0,
        tip: Double = 0,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.amount = amount
        self.payerID = payerID
        self.participantIDs = participantIDs
        self.date = date
        self.shares = shares
        self.receiptURL = receiptURL
        self.items = items
        self.tax = tax
        self.tip = tip
        self.deletedAt = deletedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, amount, payerID, participantIDs, date, shares, receiptURL, items, tax, tip, deletedAt
    }

    // Custom decoder so expenses saved before `shares`/`receiptURL`/`items` existed still
    // load (synthesized Decodable would throw on the missing keys rather than defaulting).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decode(String.self, forKey: .title)
        amount = try c.decode(Double.self, forKey: .amount)
        payerID = try c.decode(Person.ID.self, forKey: .payerID)
        participantIDs = try c.decodeIfPresent(Set<Person.ID>.self, forKey: .participantIDs) ?? []
        date = try c.decode(Date.self, forKey: .date)
        shares = try c.decodeIfPresent([Person.ID: Double].self, forKey: .shares) ?? [:]
        receiptURL = try c.decodeIfPresent(String.self, forKey: .receiptURL)
        items = try c.decodeIfPresent([ReceiptItem].self, forKey: .items) ?? []
        tax = try c.decodeIfPresent(Double.self, forKey: .tax) ?? 0
        tip = try c.decodeIfPresent(Double.self, forKey: .tip) ?? 0
        deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt)
    }
}

/// A single line item read off a receipt (name + price) with its own split
/// configuration, so different items on one receipt can be split different ways
/// (e.g. a shared appetizer split equally, a cocktail assigned to one person).
struct ReceiptItem: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var price: Double

    var splitMethod: SplitMethod = .equalAll
    /// Members included when `splitMethod == .equalSelected`.
    var participantIDs: Set<Person.ID> = []
    /// The single person charged when `splitMethod == .noSplit`.
    var soloPayerID: Person.ID? = nil
    /// Per-member percentages / exact amounts for the matching methods.
    var percentages: [Person.ID: Double] = [:]
    var amounts: [Person.ID: Double] = [:]

    init(
        id: UUID = UUID(),
        name: String,
        price: Double,
        splitMethod: SplitMethod = .equalAll,
        participantIDs: Set<Person.ID> = [],
        soloPayerID: Person.ID? = nil,
        percentages: [Person.ID: Double] = [:],
        amounts: [Person.ID: Double] = [:]
    ) {
        self.id = id
        self.name = name
        self.price = price
        self.splitMethod = splitMethod
        self.participantIDs = participantIDs
        self.soloPayerID = soloPayerID
        self.percentages = percentages
        self.amounts = amounts
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, price, splitMethod, participantIDs, soloPayerID, percentages, amounts
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        price = try c.decode(Double.self, forKey: .price)
        splitMethod = try c.decodeIfPresent(SplitMethod.self, forKey: .splitMethod) ?? .equalAll
        participantIDs = try c.decodeIfPresent(Set<Person.ID>.self, forKey: .participantIDs) ?? []
        soloPayerID = try c.decodeIfPresent(Person.ID.self, forKey: .soloPayerID)
        percentages = try c.decodeIfPresent([Person.ID: Double].self, forKey: .percentages) ?? [:]
        amounts = try c.decodeIfPresent([Person.ID: Double].self, forKey: .amounts) ?? [:]
    }
}

/// A comment on an expense, visible to all trip members.
struct ExpenseComment: Identifiable, Codable {
    var id = UUID()
    var authorID: Person.ID
    var authorName: String
    var text: String
    var date: Date
    /// Set when the author edits the comment after posting; nil for untouched comments.
    var editedAt: Date?

    private enum CodingKeys: String, CodingKey {
        case id, authorID, authorName, text, date, editedAt
    }

    init(id: UUID = UUID(), authorID: Person.ID, authorName: String, text: String, date: Date = Date(), editedAt: Date? = nil) {
        self.id = id
        self.authorID = authorID
        self.authorName = authorName
        self.text = text
        self.date = date
        self.editedAt = editedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        authorID = try c.decode(Person.ID.self, forKey: .authorID)
        authorName = try c.decodeIfPresent(String.self, forKey: .authorName) ?? ""
        text = try c.decode(String.self, forKey: .text)
        date = try c.decode(Date.self, forKey: .date)
        editedAt = try c.decodeIfPresent(Date.self, forKey: .editedAt)
    }
}

/// A shared trip. The creator owns the row, and any invited Supabase user in
/// `trip_members` may read/update the same cloud copy. `members` are the bill-splitting
/// participants shown in the app; authenticated participants use their Supabase user id.
struct Trip: Identifiable, Codable {
    var id = UUID()
    var name: String
    var currencyCode: String
    var creatorID: Person.ID
    var members: [Person]
    var budgets: [Person.ID: Double]
    var expenses: [Expense] = []

    /// Soft-deleted expenses, most-recent first. Kept out of the active split/settle
    /// math but still counted in `spent(for:)` so deleting doesn't refund budget, and
    /// surfaced in the trip's "Recently Deleted" list where they can be restored.
    var deletedExpenses: [Expense] = []

    /// Recorded settlement payments toward this trip's debts, keyed by
    /// `"<debtorID>-><creditorID>"`. Stored on the trip so settle-up progress
    /// syncs to the shared cloud row alongside members, budgets, and expenses.
    var settlementRecords: [String: [SettlementRecord]] = [:]

    var comments: [String: [ExpenseComment]] = [:]

    /// Optional trip metadata surfaced in the redesigned trip cards and hero header.
    /// All optional so trips saved before these existed keep loading.
    var location: String? = nil
    var startDate: Date? = nil
    var endDate: Date? = nil
    /// Public URL of the uploaded cover photo (in the shared `receipts` bucket).
    var coverImageURL: String? = nil

    /// When true, any invited member (not just the creator) may record an expense paid by
    /// someone other than themselves. The creator can always do this; this flag only
    /// extends the ability to other signed-in members. Manually-added members aren't app
    /// users, so the permission doesn't apply to them.
    var allowMembersToPayForOthers: Bool = false

    /// Members who archived this trip for themselves. Per-user view state kept in the
    /// shared blob so it follows the account across devices without hiding the trip
    /// for anyone else on it.
    var archivedBy: [Person.ID] = []

    /// User-built day-by-day plan (Explore tab). Optional so trips saved before the
    /// planner existed keep loading; trips carrying one also surface as itinerary
    /// cards in Explore.
    var itinerary: Itinerary? = nil

    init(
        id: UUID = UUID(),
        name: String,
        currencyCode: String,
        creatorID: Person.ID,
        members: [Person],
        budgets: [Person.ID: Double],
        expenses: [Expense] = [],
        deletedExpenses: [Expense] = [],
        settlementRecords: [String: [SettlementRecord]] = [:],
        comments: [String: [ExpenseComment]] = [:],
        location: String? = nil,
        startDate: Date? = nil,
        endDate: Date? = nil,
        coverImageURL: String? = nil,
        allowMembersToPayForOthers: Bool = false,
        archivedBy: [Person.ID] = [],
        itinerary: Itinerary? = nil
    ) {
        self.id = id
        self.name = name
        self.currencyCode = currencyCode
        self.creatorID = creatorID
        self.members = members
        self.budgets = budgets
        self.expenses = expenses
        self.deletedExpenses = deletedExpenses
        self.settlementRecords = settlementRecords
        self.comments = comments
        self.location = location
        self.startDate = startDate
        self.endDate = endDate
        self.coverImageURL = coverImageURL
        self.allowMembersToPayForOthers = allowMembersToPayForOthers
        self.archivedBy = archivedBy
        self.itinerary = itinerary
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, currencyCode, creatorID, members, budgets, expenses, deletedExpenses, settlementRecords, comments
        case location, startDate, endDate, coverImageURL, allowMembersToPayForOthers, archivedBy, itinerary
    }

    // Custom decoder so trips saved before `settlementRecords` (and the new expense
    // fields) existed still load instead of throwing on the missing key.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        currencyCode = try c.decode(String.self, forKey: .currencyCode)
        creatorID = try c.decode(Person.ID.self, forKey: .creatorID)
        members = try c.decode([Person].self, forKey: .members)
        budgets = try c.decodeIfPresent([Person.ID: Double].self, forKey: .budgets) ?? [:]
        expenses = try c.decodeIfPresent([Expense].self, forKey: .expenses) ?? []
        deletedExpenses = try c.decodeIfPresent([Expense].self, forKey: .deletedExpenses) ?? []
        settlementRecords = try c.decodeIfPresent([String: [SettlementRecord]].self, forKey: .settlementRecords) ?? [:]
        comments = try c.decodeIfPresent([String: [ExpenseComment]].self, forKey: .comments) ?? [:]
        location = try c.decodeIfPresent(String.self, forKey: .location)
        startDate = try c.decodeIfPresent(Date.self, forKey: .startDate)
        endDate = try c.decodeIfPresent(Date.self, forKey: .endDate)
        coverImageURL = try c.decodeIfPresent(String.self, forKey: .coverImageURL)
        allowMembersToPayForOthers = try c.decodeIfPresent(Bool.self, forKey: .allowMembersToPayForOthers) ?? false
        archivedBy = try c.decodeIfPresent([Person.ID].self, forKey: .archivedBy) ?? []
        itinerary = try c.decodeIfPresent(Itinerary.self, forKey: .itinerary)
    }

    /// Whether `userID` has archived this trip for themselves.
    func isArchived(for userID: Person.ID) -> Bool { archivedBy.contains(userID) }

    /// A human-readable date range, e.g. "Apr 1–30, 2025", "Apr 28 – May 3, 2025", or a
    /// single date when only one is set. `nil` when no dates are present.
    var dateRangeText: String? {
        let cal = Calendar.current
        switch (startDate, endDate) {
        case let (start?, end?):
            if cal.isDate(start, inSameDayAs: end) {
                return start.formatted(.dateTime.month(.abbreviated).day().year())
            }
            // Same month & year → "Apr 1–30, 2025"
            if cal.component(.year, from: start) == cal.component(.year, from: end),
               cal.component(.month, from: start) == cal.component(.month, from: end) {
                let head = start.formatted(.dateTime.month(.abbreviated).day())
                let endDay = cal.component(.day, from: end)
                let year = cal.component(.year, from: start)
                return "\(head)–\(endDay), \(year)"
            }
            let head = start.formatted(.dateTime.month(.abbreviated).day())
            let tail = end.formatted(.dateTime.month(.abbreviated).day().year())
            return "\(head) – \(tail)"
        case let (start?, nil):
            return start.formatted(.dateTime.month(.abbreviated).day().year())
        case let (nil, end?):
            return end.formatted(.dateTime.month(.abbreviated).day().year())
        case (nil, nil):
            return nil
        }
    }
}

extension Trip {
    /// A member's share of one expense. Uses the expense's explicit per-member `shares`
    /// when present (set by the split configuration); otherwise falls back to an equal
    /// split across `participantIDs`.
    func share(for userID: Person.ID, in expense: Expense) -> Double {
        if !expense.shares.isEmpty {
            return SplitEngine.roundToTwo(expense.shares[userID] ?? 0)
        }
        guard expense.participantIDs.contains(userID) else { return 0 }
        return SplitEngine.roundToTwo(expense.amount / Double(max(expense.participantIDs.count, 1)))
    }

    /// What the user personally consumed across the trip (their share of every expense).
    /// Deleted expenses are still counted here so removing an expense doesn't refund
    /// budget headroom — the spend stays committed against the budget.
    func spent(for userID: Person.ID) -> Double {
        (expenses + deletedExpenses).reduce(0) { $0 + share(for: userID, in: $1) }
    }

    /// What the user owes others (their share of expenses paid by someone else).
    func owed(by userID: Person.ID) -> Double {
        expenses.reduce(0) { sum, expense in
            expense.payerID == userID ? sum : sum + share(for: userID, in: expense)
        }
    }

    /// What others owe the user (the rest of the bill on expenses the user paid).
    func owed(to userID: Person.ID) -> Double {
        expenses.reduce(0) { sum, expense in
            guard expense.payerID == userID else { return sum }
            return sum + SplitEngine.roundToTwo(expense.amount - share(for: userID, in: expense))
        }
    }

    func budget(for userID: Person.ID) -> Double { budgets[userID] ?? 0 }

    func remainingBudget(for userID: Person.ID) -> Double {
        budget(for: userID) - spent(for: userID)
    }

    /// Total a member fronted across the trip (full amount of expenses they paid).
    func paid(by userID: Person.ID) -> Double {
        expenses.reduce(0) { $0 + ($1.payerID == userID ? $1.amount : 0) }
    }

    /// Net balance per member: positive means the group owes them, negative means
    /// they owe the group. Mirrors `SplitEngine`'s net definition for one expense.
    func netBalances() -> [Person.ID: Double] {
        var net: [Person.ID: Double] = [:]
        for member in members {
            net[member.id] = SplitEngine.roundToTwo(paid(by: member.id) - spent(for: member.id))
        }
        return net
    }

    /// The transfers that settle the trip: greedy debt simplification over each member's
    /// net balance (`SplitEngine.settleUp`), so most debtors clear their whole balance
    /// with one payment instead of paying every payer separately. A debt may be routed
    /// to a creditor whose expenses the debtor didn't share in — the per-pair "who
    /// actually owes whom" detail lives on each expense; this list is the cheapest way
    /// to zero everyone out. The engine walks members in list order, so the same
    /// balances always produce the same pairs (recorded payments are keyed by pair).
    func settlements() -> [Settlement] {
        SplitEngine.settleUp(net: netBalances(), people: members)
    }

    /// Amount this user still owes others after subtracting confirmed settlement payments.
    func remainingOwed(by userID: Person.ID) -> Double {
        settlements()
            .filter { $0.from.id == userID }
            .reduce(0.0) { sum, s in
                let key = "\(s.from.id.uuidString)->\(s.to.id.uuidString)"
                let confirmed = (settlementRecords[key] ?? [])
                    .filter { $0.status == .confirmed }
                    .reduce(0.0) { $0 + $1.amount }
                return sum + max(0, SplitEngine.roundToTwo(s.amount - confirmed))
            }
    }

    /// Amount others still owe this user after subtracting confirmed settlement payments.
    func remainingOwed(to userID: Person.ID) -> Double {
        settlements()
            .filter { $0.to.id == userID }
            .reduce(0.0) { sum, s in
                let key = "\(s.from.id.uuidString)->\(s.to.id.uuidString)"
                let confirmed = (settlementRecords[key] ?? [])
                    .filter { $0.status == .confirmed }
                    .reduce(0.0) { $0 + $1.amount }
                return sum + max(0, SplitEngine.roundToTwo(s.amount - confirmed))
            }
    }

    /// Both remaining-owed figures for a user in one `settlements()` pass — the settlement
    /// computation is the expensive part, so callers that need both (e.g. the budget
    /// overview card) shouldn't run it twice.
    func remainingOwed(for userID: Person.ID) -> (by: Double, to: Double) {
        var by = 0.0, to = 0.0
        for s in settlements() {
            guard s.from.id == userID || s.to.id == userID else { continue }
            let key = "\(s.from.id.uuidString)->\(s.to.id.uuidString)"
            let confirmed = (settlementRecords[key] ?? [])
                .filter { $0.status == .confirmed }
                .reduce(0.0) { $0 + $1.amount }
            let remaining = max(0, SplitEngine.roundToTwo(s.amount - confirmed))
            if s.from.id == userID { by += remaining }
            if s.to.id == userID { to += remaining }
        }
        return (by, to)
    }

    /// Rewrites the original creator's member id to `newID` everywhere it appears —
    /// `creatorID`, the member list, budgets, expense payers/participants, and settlement
    /// keys — so a trip loaded from the cloud lines up with the signed-in user's stable
    /// identity even when it was created under a previous (random) local id.
    func reanchoringCreator(to newID: Person.ID) -> Trip {
        let oldID = creatorID
        guard oldID != newID else { return self }
        var copy = self
        copy.creatorID = newID
        copy.members = members.map { member in
            guard member.id == oldID else { return member }
            var renamed = member
            renamed.id = newID
            return renamed
        }
        if let budget = copy.budgets.removeValue(forKey: oldID) { copy.budgets[newID] = budget }
        func reanchor(_ expense: Expense) -> Expense {
            var updated = expense
            if updated.payerID == oldID { updated.payerID = newID }
            if updated.participantIDs.remove(oldID) != nil { updated.participantIDs.insert(newID) }
            return updated
        }
        copy.expenses = expenses.map(reanchor)
        copy.deletedExpenses = deletedExpenses.map(reanchor)
        copy.settlementRecords = Dictionary(
            settlementRecords.map { key, value in
                (key.replacingOccurrences(of: oldID.uuidString, with: newID.uuidString), value)
            },
            uniquingKeysWith: { first, _ in first }
        )
        return copy
    }
}
