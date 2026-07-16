import SwiftUI
import Observation
import Combine
import ImageIO
import PhotosUI
import UIKit
import VisionKit
import MapKit

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

// MARK: - Trip Store

/// Latest-wins writer for the offline trips snapshot. Rapid UI mutations used to spawn
/// one detached full-array JSON encode/write each, allowing redundant work and an older
/// snapshot to finish after a newer one. This actor debounces writes and verifies the
/// caller's revision again after encoding before touching disk.
private actor TripsCacheWriter {
    private var latestRevision = 0
    private var pendingTask: Task<Void, Never>?

    func schedule(trips: [Trip], at url: URL, revision: Int) {
        guard revision > latestRevision else { return }
        latestRevision = revision
        pendingTask?.cancel()
        pendingTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let data = await Task.detached(priority: .utility) {
                try? JSONEncoder().encode(trips)
            }.value
            guard !Task.isCancelled, revision == latestRevision, let data else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    func cancel(through revision: Int) {
        // Ignore an older account-cancellation message if a newer account's scheduled
        // write reached the actor first.
        guard revision >= latestRevision else { return }
        latestRevision = revision
        pendingTask?.cancel()
        pendingTask = nil
    }
}

/// The app's in-memory source of truth for the current user and their trips.
/// All balance figures on the home screen are derived from here.
///
/// Main-actor isolated so its `@Observable` state (`trips`, `syncState`, `currentUser`, …)
/// is only ever mutated on the main thread. Network I/O still runs off-main because the
/// actual requests live in their own actors (`TripsRepository`, `ReceiptStorage`, …) and
/// the `await` points release the main thread. Mutating observable state off the main
/// thread (as the old non-isolated `persist`/`loadFromCloud` did) is undefined behavior
/// and was crashing the app right after sign-in once a trip needed re-syncing.
@Observable
@MainActor
final class TripStore {
    /// The home card always reports in USD, regardless of each trip's own currency.
    static let baseCurrency = "USD"

    var currentUser: Person
    var trips: [Trip]

    /// The signed-in user's profile photo, persisted across launches as JPEG data.
    var profileImageData: Data?

    /// The signed-in user's cloud-backed personal information (name, birthday, bio,
    /// visited places). Loaded from `public.profiles` on sign-in and saved back on edit;
    /// `displayName`/`avatarPath` are mirrored onto `currentUser`.
    var userProfile = UserProfile()

    /// Exchange rates with base USD (`usdRates["EUR"]` = EUR per 1 USD), used to
    /// convert each trip's currency into USD for the aggregated home card.
    var usdRates: [String: Double] = [:]

    /// The signed-in user's Supabase access token. Set by the app when the auth
    /// session changes; persistence to the cloud is skipped while this is nil.
    var accessToken: String?

    /// Called when Supabase rejects a request because the access token expired.
    @ObservationIgnored var refreshAccessToken: (() async throws -> String?)?

    /// Live cloud-sync status, surfaced in the UI so failed saves aren't silent.
    enum SyncState: Equatable { case idle, syncing, failed }
    var syncState: SyncState = .idle

    /// A user-facing reason for the most recent sync failure (e.g. an expired session),
    /// shown in the failure banner. Nil for generic server/HTTP failures.
    var syncErrorMessage: String?

    /// Number of in-flight cloud saves. The "Saving to cloud…" banner is only shown when a
    /// save is still running after a short grace period — flipping `syncState` synchronously
    /// on every tap inserted/removed the banner (a full home-screen relayout) twice per
    /// mutation, which is what made buttons feel laggy.
    @ObservationIgnored private var activeSaveCount = 0

    /// Persistence is latest-wins per trip. A burst of edits gets one cloud write after a
    /// short debounce; edits arriving during a request are serialized into one follow-up
    /// request, so an older response can never overwrite a newer snapshot.
    @ObservationIgnored private var pendingTripSaves: [Trip.ID: Trip] = [:]
    @ObservationIgnored private var tripSaveRevisions: [Trip.ID: Int] = [:]
    @ObservationIgnored private var tripSaveTasks: [Trip.ID: Task<Void, Never>] = [:]
    @ObservationIgnored private var tripSaveWorkerIDs: [Trip.ID: UUID] = [:]

    /// The offline cache is also debounced and revisioned so rapid edits don't repeatedly
    /// encode the complete trips array or finish writes out of order.
    @ObservationIgnored private let cacheWriter = TripsCacheWriter()
    @ObservationIgnored private var cacheRevision = 0

    /// Marks a cloud save as started; shows the syncing banner only if it's still running
    /// after 400 ms so quick saves never cause layout churn.
    private func beginSyncActivity() {
        activeSaveCount += 1
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            if activeSaveCount > 0 && syncState != .failed { syncState = .syncing }
        }
    }

    /// Marks a cloud save as finished, updating the visible state once nothing is in flight.
    private func endSyncActivity(failed: Bool, message: String? = nil) {
        activeSaveCount = max(0, activeSaveCount - 1)
        if failed {
            syncState = .failed
            syncErrorMessage = message
        } else if activeSaveCount == 0 {
            syncState = .idle
            syncErrorMessage = nil
        }
    }

    /// Builds the failure-banner subtitle. Client-side problems (session/network, which
    /// carry no HTTP status) already have a meaningful message. For a server rejection
    /// (401/403 — where an unauthenticated write surfaces), it probes whether the session
    /// is actually accepted, so we can tell "your session isn't reaching the server"
    /// (sign in again) from a transient/genuine-permission error.
    private func syncFailureMessage(_ error: Error) async -> String? {
        guard let authError = error as? AuthError else { return nil }
        if authError.statusCode == nil { return authError.message }
        guard authError.statusCode == 401 || authError.statusCode == 403 else { return nil }
        guard let token = try? await authorizedAccessToken(),
              await AuthService.shared.isSessionAccepted(accessToken: token) else {
            return "Your session isn't reaching the server. Please sign out and sign in again."
        }
        return nil
    }

    /// IDs of trips deleted locally whose cloud delete hasn't succeeded yet (e.g. the
    /// delete happened offline). Persisted so the deletion survives relaunch, retried on
    /// the next sync, and used to stop `loadFromCloud` from resurrecting them.
    private(set) var pendingDeletions: Set<Trip.ID> = []

    private static let pendingDeletionsKey = "tripsplit.pendingDeletions"
    private struct StoredProfile: Codable {
        var name: String
        var imageData: Data?
        var avatarURL: String?
        // Optional so profiles cached before these fields existed still decode.
        var dateOfBirth: Date?
        var bio: String?
        var visitedPlaces: [String]?
        var savedPlaceKeys: [String]?
        var savedDestinationIDs: [String]?
    }

    /// Returns a UserDefaults key scoped to the given user UUID, so different accounts
    /// on the same device never share profile data.
    private static func profileKey(for userID: UUID) -> String {
        "tripsplit.profile.\(userID.uuidString)"
    }

    init() {
        currentUser = Person(name: "", color: Color(hex: 0x6366F1))
        profileImageData = nil
        trips = []
        pendingDeletions = Self.loadPendingDeletions()
    }

    private static func loadPendingDeletions() -> Set<Trip.ID> {
        guard let raw = UserDefaults.standard.array(forKey: pendingDeletionsKey) as? [String] else { return [] }
        return Set(raw.compactMap(UUID.init(uuidString:)))
    }

    private func savePendingDeletions() {
        UserDefaults.standard.set(pendingDeletions.map(\.uuidString), forKey: Self.pendingDeletionsKey)
    }

    // MARK: Local trips cache (instant/offline launch)

    /// On-disk snapshot of the signed-in user's trips so a relaunch paints real data
    /// immediately (including offline) instead of an empty list while `loadFromCloud`
    /// round-trips. Keyed by user UUID so accounts on the same device never see each
    /// other's trips. Lives in Caches: losing it only costs the instant first paint —
    /// Supabase stays the source of truth.
    nonisolated private static func tripsCacheURL(for userID: UUID) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("trips-\(userID.uuidString.lowercased()).json")
    }

    /// Snapshots the current trips and writes them to the local cache off the main actor.
    private func cacheTripsLocally() {
        let snapshot = trips
        let userID = currentUser.id
        cacheRevision += 1
        let revision = cacheRevision
        let url = Self.tripsCacheURL(for: userID)
        Task {
            await cacheWriter.schedule(trips: snapshot, at: url, revision: revision)
        }
    }

    private func cancelPendingCacheWrite() {
        cacheRevision += 1
        let revision = cacheRevision
        Task { await cacheWriter.cancel(through: revision) }
    }

    nonisolated private static func loadCachedTrips(for userID: UUID) -> [Trip]? {
        guard let data = try? Data(contentsOf: tripsCacheURL(for: userID)) else { return nil }
        return try? JSONDecoder().decode([Trip].self, from: data)
    }

    /// Fills an empty trips list from the local cache while the cloud fetch is in flight.
    /// Only ever *fills* — if `loadFromCloud` lands first (or the user switched accounts
    /// mid-read), the cached copy is discarded so it can never clobber fresher data.
    private func restoreCachedTrips(for userID: UUID) {
        guard trips.isEmpty else { return }
        Task {
            let cached = await Task.detached(priority: .userInitiated) {
                Self.loadCachedTrips(for: userID)
            }.value
            guard let cached, !cached.isEmpty,
                  self.trips.isEmpty, self.currentUser.id == userID else { return }
            self.trips = cached.filter { !self.pendingDeletions.contains($0.id) }
        }
    }

    /// Updates the signed-in user's display name and photo, persisting both so they
    /// survive across launches. Also pushes the updated name into every trip immediately.
    func updateProfile(name: String, imageData: Data?) {
        let nameChanged = currentUser.name != name
        currentUser.name = name
        userProfile.displayName = name
        profileImageData = imageData
        persistLocalProfile()
        guard nameChanged else { return }
        for index in trips.indices {
            if let memberIndex = trips[index].members.firstIndex(where: { $0.id == currentUser.id }) {
                trips[index].members[memberIndex].name = name
                persist(trips[index])
            }
        }
    }

    /// Uploads the given JPEG to Supabase Storage as the user's avatar, stores the storage
    /// path on `currentUser.avatarURL`, and pushes the updated Person into every trip so
    /// other members see the new photo on their next sync. (The field name is historical;
    /// it now holds a path that `signedImageURL` resolves at display time.)
    func uploadAndSetAvatar(_ jpeg: Data) async {
        guard let accessToken = try? await authorizedAccessToken() else { return }
        let path = "\(currentUser.id.uuidString.lowercased())/profile.jpg"
        guard let url = try? await withFreshTokenIfNeeded(initialToken: accessToken, operation: { token in
            try await ReceiptStorage.shared.upload(jpeg, path: path, accessToken: token)
        }) else { return }
        currentUser.avatarURL = url
        userProfile.avatarPath = url
        // Persist locally so the URL survives a relaunch.
        persistLocalProfile()
        // Push the updated Person (name + avatarURL) into every trip the user belongs to
        // so other members pick up the change on their next loadFromCloud.
        for index in trips.indices {
            if let memberIndex = trips[index].members.firstIndex(where: { $0.id == currentUser.id }) {
                trips[index].members[memberIndex].name = currentUser.name
                trips[index].members[memberIndex].avatarURL = url
                persist(trips[index])
            }
        }
    }

    /// Clears the in-memory profile. Called on sign-out so the next account starts blank.
    func resetProfile() {
        currentUser.name = ""
        profileImageData = nil
        userProfile = UserProfile()
    }

    /// Writes the full profile (name, photo, avatar path, birthday, bio, places) to
    /// UserDefaults keyed by user UUID, so it survives relaunches and account switches.
    private func persistLocalProfile() {
        let stored = StoredProfile(
            name: currentUser.name,
            imageData: profileImageData,
            avatarURL: currentUser.avatarURL,
            dateOfBirth: userProfile.dateOfBirth,
            bio: userProfile.bio,
            visitedPlaces: userProfile.visitedPlaces,
            savedPlaceKeys: userProfile.savedPlaceKeys,
            savedDestinationIDs: userProfile.savedDestinationIDs
        )
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: Self.profileKey(for: currentUser.id))
        }
    }

    /// Saves an edited profile: applies it locally (and to every trip via the display
    /// name), uploads a new avatar when the photo changed, then upserts the row in
    /// `public.profiles` so the profile follows the account to other devices.
    ///
    /// `imageData == nil` means "no new photo picked", not "remove" — after a reinstall
    /// the local JPEG cache is empty while the cloud avatar still exists, and treating
    /// nil as removal wiped it. Removal is explicit via `removePhoto`.
    func saveProfile(_ profile: UserProfile, imageData: Data?, removePhoto: Bool = false) async {
        userProfile = profile
        userProfile.avatarPath = currentUser.avatarURL
        let previousImageData = profileImageData
        updateProfile(name: profile.displayName,
                      imageData: removePhoto ? nil : (imageData ?? profileImageData))
        if let imageData, !removePhoto, imageData != previousImageData || currentUser.avatarURL == nil {
            await uploadAndSetAvatar(imageData)
        } else if removePhoto {
            currentUser.avatarURL = nil
            userProfile.avatarPath = nil
            persistLocalProfile()
        }
        await pushProfileToCloud()
    }

    /// Updates the cloud-backed bookmark lists (map places and/or Explore destinations),
    /// persisting locally and upserting `public.profiles` so they survive reinstalls.
    func updateSavedPlaces(mapKeys: [String]? = nil, destinationIDs: [String]? = nil) {
        if let mapKeys { userProfile.savedPlaceKeys = mapKeys }
        if let destinationIDs { userProfile.savedDestinationIDs = destinationIDs }
        persistLocalProfile()
        Task { await pushProfileToCloud() }
    }

    /// Loads the account's profile row from Supabase, replacing the local cache. When
    /// the cloud row is still empty (fresh account or pre-profile install) but a local
    /// profile exists, the local one is pushed up instead.
    func loadProfileFromCloud() async {
        guard let accessToken = try? await authorizedAccessToken() else { return }
        let userID = currentUser.id
        guard let fetched = try? await withFreshTokenIfNeeded(initialToken: accessToken, operation: { token in
            try await ProfilesRepository.shared.fetch(userID: userID, accessToken: token)
        }) else { return }

        if fetched.displayName.trimmingCharacters(in: .whitespaces).isEmpty && !currentUser.name.isEmpty {
            // Cloud row never populated — seed it from this device's profile.
            await pushProfileToCloud()
            return
        }
        // Bookmarks saved on this device before the cloud fetch (e.g. while offline, or
        // made before bookmarks became cloud-backed) are merged in rather than clobbered.
        let localPlaceKeys = userProfile.savedPlaceKeys
        let localDestinationIDs = userProfile.savedDestinationIDs
        userProfile = fetched
        userProfile.savedPlaceKeys = fetched.savedPlaceKeys
            + localPlaceKeys.filter { !fetched.savedPlaceKeys.contains($0) }
        userProfile.savedDestinationIDs = fetched.savedDestinationIDs
            + localDestinationIDs.filter { !fetched.savedDestinationIDs.contains($0) }
        currentUser.name = fetched.displayName
        if let path = fetched.avatarPath, !path.isEmpty {
            currentUser.avatarURL = path
        }
        persistLocalProfile()
        if userProfile.savedPlaceKeys != fetched.savedPlaceKeys
            || userProfile.savedDestinationIDs != fetched.savedDestinationIDs {
            await pushProfileToCloud()
        }
    }

    /// Upserts the in-memory profile into `public.profiles`. Best-effort: failures are
    /// logged but not surfaced, since the local copy is already saved.
    private func pushProfileToCloud() async {
        guard let accessToken = try? await authorizedAccessToken() else { return }
        var profile = userProfile
        profile.displayName = currentUser.name
        profile.avatarPath = currentUser.avatarURL
        let userID = currentUser.id
        do {
            try await withFreshTokenIfNeeded(initialToken: accessToken) { token in
                try await ProfilesRepository.shared.update(profile, userID: userID, accessToken: token)
            }
        } catch {
            BackendSecurity.log("Profile cloud save failed", error: error)
        }
    }

    private static func loadProfile(for userID: UUID) -> StoredProfile? {
        let key = profileKey(for: userID)
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(StoredProfile.self, from: data)
    }

    /// Active (non-archived) trips available on this device. Cloud loads are already
    /// filtered by Supabase RLS, so every fetched row is a trip this account can access.
    /// Trips the user archived are excluded here so they drop out of the home cards,
    /// totals, and pickers, but remain reachable via `archivedTrips`.
    var myTrips: [Trip] { trips.filter { !$0.isArchived(for: currentUser.id) } }

    /// Trips the signed-in user has archived for themselves.
    var archivedTrips: [Trip] { trips.filter { $0.isArchived(for: currentUser.id) } }

    /// Archives or restores a trip for the current user only. Archiving is view state,
    /// not deletion: the trip stays in the cloud and stays visible to other members.
    func setArchived(_ archived: Bool, for tripID: Trip.ID) {
        guard let index = trips.firstIndex(where: { $0.id == tripID }) else { return }
        let me = currentUser.id
        if archived {
            guard !trips[index].archivedBy.contains(me) else { return }
            trips[index].archivedBy.append(me)
        } else {
            trips[index].archivedBy.removeAll { $0 == me }
        }
        persist(trips[index])
    }

    /// Converts an amount in `code` into USD using the cached rates. Falls back to the
    /// original amount when a rate is unavailable (e.g. offline before rates load).
    func toUSD(_ amount: Double, from code: String) -> Double {
        if code == Self.baseCurrency { return amount }
        guard let rate = usdRates[code], rate > 0 else { return amount }
        return amount / rate
    }

    /// Loads USD-based rates so the home card can normalize every trip's currency.
    func refreshRates() async {
        if let rates = try? await CurrencyService.shared.rates(base: Self.baseCurrency) {
            if rates != usdRates {
                usdRates = rates
            }
        }
    }

    /// The multiplier to convert an amount from `from` into `to` (e.g. 1 USD → ~25,000 VND).
    /// Returns 1 when the currencies match, or `nil` when live rates can't be fetched so
    /// callers can avoid silently relabeling amounts without actually converting them.
    func conversionRate(from: String, to: String) async -> Double? {
        if from == to { return 1 }
        guard let rates = try? await CurrencyService.shared.rates(base: from),
              let rate = rates[to], rate > 0 else { return nil }
        return rate
    }

    /// Returns a copy of `trip` with every monetary value multiplied by `rate`: member
    /// budgets, each expense's amount / tax / tip / per-member shares / receipt-item prices
    /// and exact-amount splits, and recorded settlement payments. Used when a trip's
    /// currency changes so stored amounts reflect the real converted value instead of being
    /// relabeled (e.g. a 100 USD expense becoming the equivalent VND amount, not "100 ₫").
    func applyingCurrencyConversion(_ trip: Trip, rate: Double) -> Trip {
        func conv(_ value: Double) -> Double { SplitEngine.roundToTwo(value * rate) }
        var converted = trip
        converted.budgets = converted.budgets.mapValues(conv)
        func convertExpense(_ expense: Expense) -> Expense {
            var e = expense
            e.amount = conv(e.amount)
            e.tax = conv(e.tax)
            e.tip = conv(e.tip)
            e.shares = e.shares.mapValues(conv)
            e.items = e.items.map { item in
                var i = item
                i.price = conv(i.price)
                i.amounts = i.amounts.mapValues(conv)
                return i
            }
            return e
        }
        converted.expenses = converted.expenses.map(convertExpense)
        converted.deletedExpenses = converted.deletedExpenses.map(convertExpense)
        converted.settlementRecords = converted.settlementRecords.mapValues { records in
            records.map { record in
                var r = record
                r.amount = conv(r.amount)
                return r
            }
        }
        if var itinerary = converted.itinerary {
            itinerary.totalBudget = conv(itinerary.totalBudget)
            itinerary.days = itinerary.days.map { day in
                var d = day
                d.stops = d.stops.map { stop in
                    var s = stop
                    s.cost = conv(s.cost)
                    return s
                }
                return d
            }
            if var suggestion = itinerary.suggestion {
                suggestion.days = suggestion.days.map { day in
                    var d = day
                    d.stops = d.stops.map { stop in
                        var s = stop
                        s.cost = conv(s.cost)
                        return s
                    }
                    return d
                }
                itinerary.suggestion = suggestion
            }
            converted.itinerary = itinerary
        }
        return converted
    }

    /// All four home-card figures, aggregated in USD. Computed in a single pass over the
    /// trips so `settlements()` (the expensive part, O(members² × expenses)) runs once per
    /// trip per render instead of once per figure.
    struct HomeTotals {
        var budget = 0.0, spent = 0.0, youOwe = 0.0, owedToYou = 0.0
        var available: Double { SplitEngine.roundToTwo(budget - spent) }
    }

    var homeTotals: HomeTotals {
        var totals = HomeTotals()
        let me = currentUser.id
        for trip in myTrips {
            let code = trip.currencyCode
            totals.budget += toUSD(trip.budget(for: me), from: code)
            totals.spent += toUSD(trip.spent(for: me), from: code)
            for s in trip.settlements() {
                let key = "\(s.from.id.uuidString)->\(s.to.id.uuidString)"
                let confirmed = (trip.settlementRecords[key] ?? [])
                    .filter { $0.status == .confirmed }
                    .reduce(0.0) { $0 + $1.amount }
                let remaining = max(0, SplitEngine.roundToTwo(s.amount - confirmed))
                if s.from.id == me { totals.youOwe += toUSD(remaining, from: code) }
                if s.to.id == me { totals.owedToYou += toUSD(remaining, from: code) }
            }
        }
        totals.budget = SplitEngine.roundToTwo(totals.budget)
        totals.spent = SplitEngine.roundToTwo(totals.spent)
        totals.youOwe = SplitEngine.roundToTwo(totals.youOwe)
        totals.owedToYou = SplitEngine.roundToTwo(totals.owedToYou)
        return totals
    }

    func trip(_ id: Trip.ID) -> Trip? { trips.first { $0.id == id } }

    func isCreator(of trip: Trip) -> Bool { trip.creatorID == currentUser.id }

    func addTrip(_ trip: Trip) {
        trips.append(trip)
        persist(trip)
    }

    func addExpense(_ expense: Expense, to tripID: Trip.ID) {
        guard let index = trips.firstIndex(where: { $0.id == tripID }) else { return }
        trips[index].expenses.append(expense)
        persist(trips[index])
    }

    /// Replaces an existing expense (matched by id) and syncs the change.
    func updateExpense(_ expense: Expense, in tripID: Trip.ID) {
        guard let index = trips.firstIndex(where: { $0.id == tripID }),
              let expenseIndex = trips[index].expenses.firstIndex(where: { $0.id == expense.id }) else { return }
        trips[index].expenses[expenseIndex] = expense
        persist(trips[index])
    }

    /// Soft-deletes an expense: pulls it out of the active split/settle math and into
    /// the trip's "Recently Deleted" list. It still counts toward `spent(for:)`, so the
    /// budget isn't refunded, and it can be restored later. Comments are kept so a
    /// restore brings the whole thread back.
    func deleteExpense(_ expenseID: Expense.ID, from tripID: Trip.ID) {
        guard let index = trips.firstIndex(where: { $0.id == tripID }),
              let eIndex = trips[index].expenses.firstIndex(where: { $0.id == expenseID }) else { return }
        var removed = trips[index].expenses.remove(at: eIndex)
        removed.deletedAt = Date()
        trips[index].deletedExpenses.insert(removed, at: 0)
        persist(trips[index])
    }

    /// Soft-deletes multiple expenses from one trip with a single cloud write. Used by the
    /// home screen's multi-select delete so a batch action doesn't fan out into N upserts.
    func deleteExpenses(_ expenseIDs: Set<Expense.ID>, from tripID: Trip.ID) {
        guard !expenseIDs.isEmpty,
              let index = trips.firstIndex(where: { $0.id == tripID }) else { return }
        var removed: [Expense] = []
        trips[index].expenses.removeAll { expense in
            guard expenseIDs.contains(expense.id) else { return false }
            var deleted = expense
            deleted.deletedAt = Date()
            removed.append(deleted)
            return true
        }
        guard !removed.isEmpty else { return }
        trips[index].deletedExpenses.insert(contentsOf: removed, at: 0)
        persist(trips[index])
    }

    /// Restores a previously soft-deleted expense back into the active list, returning it
    /// to the split/settle math (its budget contribution was never removed).
    func restoreExpense(_ expenseID: Expense.ID, in tripID: Trip.ID) {
        guard let index = trips.firstIndex(where: { $0.id == tripID }),
              let dIndex = trips[index].deletedExpenses.firstIndex(where: { $0.id == expenseID }) else { return }
        var restored = trips[index].deletedExpenses.remove(at: dIndex)
        restored.deletedAt = nil
        trips[index].expenses.append(restored)
        persist(trips[index])
    }

    /// Replaces a whole trip (name, members, budgets, …) and syncs the change.
    func updateTrip(_ trip: Trip) {
        guard let index = trips.firstIndex(where: { $0.id == trip.id }) else { return }
        trips[index] = trip
        persist(trip)
    }

    func addManualMember(name: String, to tripID: Trip.ID) {
        guard let index = trips.firstIndex(where: { $0.id == tripID }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let color = Color(hex: memberPalette[max(trips[index].members.count - 1, 0) % memberPalette.count])
        let member = Person(name: trimmed, color: color)
        trips[index].members.append(member)
        trips[index].budgets[member.id] = 0
        persist(trips[index])
    }

    func inviteMember(email: String, displayName: String?, to tripID: Trip.ID) async throws {
        guard let index = trips.firstIndex(where: { $0.id == tripID }) else { return }
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmedEmail.isEmpty else { return }
        guard let accessToken = try await authorizedAccessToken() else {
            throw AuthError(message: "Sign in to invite members.")
        }

        let result = try await withFreshTokenIfNeeded(initialToken: accessToken) { token in
            try await TripsRepository.shared.inviteMember(tripID: tripID, email: trimmedEmail, accessToken: token)
        }
        guard result.accepted, let userID = result.memberUserID else {
            throw AuthError(message: "No TripSplit account was found for \(trimmedEmail). Ask them to sign up first, then invite them again.")
        }

        if !trips[index].members.contains(where: { $0.id == userID }) {
            let resolvedName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallbackName = trimmedEmail.split(separator: "@").first.map(String.init) ?? trimmedEmail
            let color = Color(hex: memberPalette[max(trips[index].members.count - 1, 0) % memberPalette.count])
            trips[index].members.append(Person(id: userID, name: resolvedName?.isEmpty == false ? resolvedName! : fallbackName, color: color))
            trips[index].budgets[userID] = trips[index].budgets[userID] ?? 0
            persist(trips[index])
        }
    }

    func createInvitationLink(for tripID: Trip.ID) async throws -> URL {
        guard let accessToken = try await authorizedAccessToken() else {
            throw AuthError(message: "Sign in to create an invitation link.")
        }
        let token = try await withFreshTokenIfNeeded(initialToken: accessToken) { token in
            try await TripsRepository.shared.createInvitationLink(tripID: tripID, accessToken: token)
        }
        var components = URLComponents()
        components.scheme = "tripsplit"
        components.host = "invite"
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        guard let url = components.url else {
            throw AuthError(message: "Couldn't create an invitation link.")
        }
        return url
    }

    func acceptInvitationLink(_ url: URL) async throws {
        guard url.scheme == "tripsplit", url.host == "invite",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let token = components.queryItems?.first(where: { $0.name == "token" })?.value,
              !token.isEmpty else { return }
        guard let accessToken = try await authorizedAccessToken() else {
            throw AuthError(message: "Sign in to accept this invitation.")
        }
        let tripID = try await withFreshTokenIfNeeded(initialToken: accessToken) { tokenValue in
            try await TripsRepository.shared.acceptInvitation(token: token, accessToken: tokenValue)
        }
        await loadFromCloud()
        guard let index = trips.firstIndex(where: { $0.id == tripID }),
              !trips[index].members.contains(where: { $0.id == currentUser.id }) else { return }
        trips[index].members.append(currentUser)
        trips[index].budgets[currentUser.id] = trips[index].budgets[currentUser.id] ?? 0
        persist(trips[index])
    }

    /// Sets a member's budget on a trip and syncs the change.
    func setBudget(_ amount: Double, for userID: Person.ID, in tripID: Trip.ID) {
        guard let index = trips.firstIndex(where: { $0.id == tripID }) else { return }
        trips[index].budgets[userID] = amount
        persist(trips[index])
    }

    /// Deletes a trip locally and from the cloud. If the cloud delete fails (or there's
    /// no token yet), the id is queued so the deletion is retried later and the trip isn't
    /// resurrected by `loadFromCloud` in the meantime.
    func deleteTrip(_ tripID: Trip.ID) {
        cancelScheduledSave(for: tripID)
        trips.removeAll { $0.id == tripID }
        pendingDeletions.insert(tripID)
        savePendingDeletions()
        cacheTripsLocally()

        beginSyncActivity()
        Task {
            do {
                guard let accessToken = try await authorizedAccessToken(requireServerAccepted: true) else {
                    self.endSyncActivity(failed: false)
                    return
                }
                try await TripsRepository.shared.delete(id: tripID, accessToken: accessToken)
                self.pendingDeletions.remove(tripID)
                self.savePendingDeletions()
                self.endSyncActivity(failed: false)
            } catch {
                self.endSyncActivity(failed: true)
            }
        }
    }

    /// Retries any queued cloud deletions, removing each id from the queue once Supabase
    /// confirms it's gone. Returns whether every pending deletion succeeded.
    @discardableResult
    private func flushPendingDeletions(accessToken: String) async -> Bool {
        var allSucceeded = true
        for tripID in pendingDeletions {
            do {
                try await withFreshTokenIfNeeded(initialToken: accessToken) { token in
                    try await TripsRepository.shared.delete(id: tripID, accessToken: token)
                }
                await MainActor.run {
                    self.pendingDeletions.remove(tripID)
                    self.savePendingDeletions()
                }
            } catch {
                allSucceeded = false
            }
        }
        return allSucceeded
    }

    // MARK: Supabase sync

    /// Aligns the in-memory user's identity with their authenticated account, so shared
    /// trips and every balance figure derived from `currentUser.id` resolve consistently
    /// across launches and devices. The id is the Supabase user's stable UUID, read from
    /// the access token's `sub` claim.
    func bindIdentity(accessToken: String?) {
        guard let accessToken, let uuid = Self.userID(fromJWT: accessToken) else {
            // Signed out — clear in-memory profile and trips so nothing from the
            // previous account stays on screen. The per-user disk cache is kept, so
            // signing back in repaints instantly via `restoreCachedTrips`.
            cancelScheduledTripSaves()
            cancelPendingCacheWrite()
            resetProfile()
            feedPostsByTrip = [:]
            resetSignedImageURLs()
            trips = []
            return
        }
        // Identity changed: drop cached feeds so a different account never sees the
        // previous user's loaded posts.
        if currentUser.id != uuid {
            cancelScheduledTripSaves()
            cancelPendingCacheWrite()
            feedPostsByTrip = [:]
            resetSignedImageURLs()
        }
        currentUser.id = uuid
        // Load this specific user's saved profile (name, photo, avatarURL) keyed to their UUID.
        let stored = Self.loadProfile(for: uuid)
        currentUser.name = stored?.name ?? ""
        profileImageData = stored?.imageData
        currentUser.avatarURL = stored?.avatarURL
        userProfile = UserProfile()
        userProfile.displayName = stored?.name ?? ""
        userProfile.avatarPath = stored?.avatarURL
        userProfile.dateOfBirth = stored?.dateOfBirth
        userProfile.bio = stored?.bio ?? ""
        userProfile.visitedPlaces = stored?.visitedPlaces ?? []
        userProfile.savedPlaceKeys = stored?.savedPlaceKeys ?? Self.legacySavedList("mapSavedPlaceKeys")
        userProfile.savedDestinationIDs = stored?.savedDestinationIDs ?? Self.legacySavedList("exploreSavedDestinationIDs")
        // Paint this user's locally cached trips right away; loadFromCloud replaces them
        // with the authoritative copy as soon as the network round-trip finishes.
        restoreCachedTrips(for: uuid)
    }

    /// Reads a bookmark list saved by pre-cloud versions as a "|"-joined @AppStorage
    /// string, so existing bookmarks are carried into the cloud-backed profile.
    private static func legacySavedList(_ key: String) -> [String] {
        (UserDefaults.standard.string(forKey: key) ?? "")
            .split(separator: "|").map(String.init)
    }

    /// Decodes a JWT's payload (its middle segment) into a claims dictionary.
    nonisolated fileprivate static func jwtPayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Extracts the `sub` (subject = user id) claim from a JWT access token.
    nonisolated fileprivate static func userID(fromJWT token: String) -> UUID? {
        guard let sub = jwtPayload(token)?["sub"] as? String else { return nil }
        return UUID(uuidString: sub)
    }

    /// The token's expiry (`exp`), if present.
    nonisolated fileprivate static func expiration(fromJWT token: String) -> Date? {
        guard let exp = jwtPayload(token)?["exp"] as? Double else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    /// Whether `token` is a well-formed Supabase *user* JWT (carries a `sub`) that isn't
    /// already expired or about to expire. A write sent with a token that fails this check
    /// would reach Postgres as the anonymous role (`auth.uid()` null → RLS 403), so callers
    /// refresh instead of sending it.
    nonisolated fileprivate static func isUsableUserToken(_ token: String, now: Date = Date()) -> Bool {
        guard userID(fromJWT: token) != nil else { return false }
        guard jwtPayload(token)?["role"] as? String == "authenticated" else { return false }
        guard let exp = expiration(fromJWT: token) else { return true }
        return exp.timeIntervalSince(now) > 30
    }

    /// Loads the signed-in user's trips from Supabase, replacing the in-memory list.
    /// No-op when signed out (the app stays usable with local-only trips).
    ///
    /// Each creator-owned row is re-anchored to the signed-in user's stable id so trips
    /// created under a previous random local identity still show up and settle correctly.
    /// Shared trips created by other accounts are left with their original creator id.
    func loadFromCloud() async {
        guard let accessToken = try? await authorizedAccessToken() else { return }

        // Retry any queued deletions first so a trip pending deletion can't come back.
        await flushPendingDeletions(accessToken: accessToken)

        // Keep whatever we have if the server is unreachable; only replace on success.
        let loaded: [Trip]
        do {
            loaded = try await withFreshTokenIfNeeded(initialToken: accessToken) { token in
                try await TripsRepository.shared.fetch(accessToken: token)
            }
        }
        catch { return }
        var healed: [Trip] = []
        var toPersist: Set<Trip.ID> = []
        for trip in loaded {
            // Skip trips still queued for deletion (their cloud delete hasn't landed yet).
            if pendingDeletions.contains(trip.id) { continue }
            var anchored = trip.creatorID == currentUser.id || trip.members.contains { $0.id == currentUser.id }
                ? trip
                : trip.reanchoringCreator(to: currentUser.id)
            if anchored.creatorID != trip.creatorID { toPersist.insert(anchored.id) }
            // Keep the current user's name and avatar up-to-date so other members see
            // the latest profile without requiring an explicit trip edit.
            if let idx = anchored.members.firstIndex(where: { $0.id == currentUser.id }) {
                let stored = anchored.members[idx]
                if stored.name != currentUser.name || stored.avatarURL != currentUser.avatarURL {
                    anchored.members[idx].name = currentUser.name
                    anchored.members[idx].avatarURL = currentUser.avatarURL
                    toPersist.insert(anchored.id)
                }
            }
            healed.append(anchored)
        }
        // Never let the reload clobber local state the cloud hasn't seen yet:
        // - a trip with a save still in flight keeps its local (newer) copy rather
        //   than briefly rolling back to the stale cloud version;
        // - a trip missing from the cloud entirely (its first save failed, e.g.
        //   while the session was broken) is kept and re-uploaded instead of
        //   silently dropped — dropping it here destroyed the only copy.
        let cloudIDs = Set(healed.map(\.id))
        var merged = healed.map { pendingTripSaves[$0.id] ?? $0 }
        let localOnly = trips.filter { !cloudIDs.contains($0.id) && !pendingDeletions.contains($0.id) }
        merged.append(contentsOf: localOnly)
        await MainActor.run { self.trips = merged }
        cacheTripsLocally()
        for trip in merged where toPersist.contains(trip.id) { persist(trip) }
        for trip in localOnly { persist(trip) }
    }

    /// Pushes a single shared trip (members, budgets, and expenses) to Supabase, updating
    /// `syncState` so the UI can show progress and surface failures.
    private func persist(_ trip: Trip) {
        // Every local mutation funnels through here, so this keeps the offline snapshot
        // current even when the cloud save below fails or the user is offline.
        cacheTripsLocally()
        pendingTripSaves[trip.id] = trip
        tripSaveRevisions[trip.id, default: 0] += 1
        startSaveWorkerIfNeeded(for: trip.id)
    }

    private func startSaveWorkerIfNeeded(for tripID: Trip.ID) {
        guard tripSaveTasks[tripID] == nil else { return }
        let workerID = UUID()
        tripSaveWorkerIDs[tripID] = workerID
        tripSaveTasks[tripID] = Task { [weak self] in
            await self?.drainScheduledSaves(for: tripID, workerID: workerID)
        }
    }

    /// Debounces before each request and then drains at most one request at a time for a
    /// trip. JWT validity is checked locally on the happy path; the existing 401/403 retry
    /// pipeline refreshes rejected tokens, avoiding an extra `/auth/v1/user` round-trip on
    /// every tap-triggered save.
    private func drainScheduledSaves(for tripID: Trip.ID, workerID: UUID) async {
        defer { finishSaveWorker(for: tripID, workerID: workerID) }

        while !Task.isCancelled {
            guard let revision = tripSaveRevisions[tripID],
                  let trip = pendingTripSaves[tripID] else { return }

            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            // More edits arrived during the debounce; restart the quiet-time window with
            // the newest snapshot instead of sending this intermediate version.
            guard tripSaveRevisions[tripID] == revision else { continue }

            beginSyncActivity()
            let accessToken: String
            do {
                guard let token = try await authorizedAccessToken() else {
                    endSyncActivity(failed: false)
                    pendingTripSaves[tripID] = nil
                    tripSaveRevisions[tripID] = nil
                    return
                }
                accessToken = token
            } catch {
                if Task.isCancelled {
                    endSyncActivity(failed: false)
                } else {
                    let message = await syncFailureMessage(error)
                    endSyncActivity(failed: true, message: message)
                }
                pendingTripSaves[tripID] = nil
                tripSaveRevisions[tripID] = nil
                return
            }

            do {
                try await withFreshTokenIfNeeded(initialToken: accessToken) { token in
                    let cloudTrip = self.tripForCloudSave(trip, accessToken: token)
                    try await TripsRepository.shared.upsert(cloudTrip, accessToken: token)
                }
                endSyncActivity(failed: false)
            } catch {
                if Task.isCancelled {
                    endSyncActivity(failed: false)
                } else {
                    let message = await syncFailureMessage(error)
                    endSyncActivity(failed: true, message: message)
                }
                pendingTripSaves[tripID] = nil
                tripSaveRevisions[tripID] = nil
                return
            }

            guard tripSaveRevisions[tripID] == revision else { continue }
            pendingTripSaves[tripID] = nil
            tripSaveRevisions[tripID] = nil
            return
        }
    }

    private func finishSaveWorker(for tripID: Trip.ID, workerID: UUID) {
        guard tripSaveWorkerIDs[tripID] == workerID else { return }
        tripSaveTasks[tripID] = nil
        tripSaveWorkerIDs[tripID] = nil
    }

    private func cancelScheduledSave(for tripID: Trip.ID) {
        tripSaveWorkerIDs[tripID] = nil
        tripSaveTasks[tripID]?.cancel()
        tripSaveTasks[tripID] = nil
        pendingTripSaves[tripID] = nil
        tripSaveRevisions[tripID] = nil
    }

    private func cancelScheduledTripSaves() {
        tripSaveTasks.values.forEach { $0.cancel() }
        tripSaveTasks = [:]
        tripSaveWorkerIDs = [:]
        pendingTripSaves = [:]
        tripSaveRevisions = [:]
    }

    /// Re-pushes every trip to Supabase. Used by the "Retry" action after a failed save.
    func retrySync() {
        cancelScheduledTripSaves()
        // Explicit retry: show progress immediately (the user asked for it), and clear the
        // failed state so the delayed-banner logic doesn't suppress the spinner.
        syncState = .syncing
        activeSaveCount += 1
        Task {
            do {
                guard let accessToken = try await authorizedAccessToken(requireServerAccepted: true) else {
                    self.endSyncActivity(failed: false)
                    return
                }
                let deletionsCleared = await flushPendingDeletions(accessToken: accessToken)
                for trip in trips {
                    try await withFreshTokenIfNeeded(initialToken: accessToken) { token in
                        let cloudTrip = self.tripForCloudSave(trip, accessToken: token)
                        try await TripsRepository.shared.upsert(cloudTrip, accessToken: token)
                    }
                }
                self.endSyncActivity(failed: !deletionsCleared)
            } catch {
                let message = await self.syncFailureMessage(error)
                self.endSyncActivity(failed: true, message: message)
            }
        }
    }

    func uploadReceipt(_ jpeg: Data, path: String) async throws -> String {
        guard let accessToken = try await authorizedAccessToken() else {
            throw AuthError(message: "Sign in to upload the receipt photo.")
        }
        return try await withFreshTokenIfNeeded(initialToken: accessToken) { token in
            try await ReceiptStorage.shared.upload(jpeg, path: path, accessToken: token)
        }
    }

    /// Uploads a trip cover photo to the shared private `receipts` bucket and returns its
    /// storage path. The path is namespaced under the uploader's lowercased user id so
    /// storage RLS (which compares the leading folder to `auth.uid()`) accepts the write.
    func uploadTripCover(_ jpeg: Data, tripID: Trip.ID) async throws -> String {
        let path = "\(currentUser.id.uuidString.lowercased())/cover-\(tripID.uuidString.lowercased()).jpg"
        return try await uploadReceipt(jpeg, path: path)
    }

    /// Signed image URLs keyed by storage path, with the time they should be refreshed
    /// (kept under the server-side expiry so a cached URL never hands back an expired link).
    @ObservationIgnored private var signedURLCache: [String: (url: URL, refreshAfter: Date)] = [:]
    @ObservationIgnored private var signedURLTasks: [String: Task<URL?, Never>] = [:]

    /// Resolves a stored image reference (a storage path, or a legacy public/signed URL)
    /// into a currently-valid signed URL for display. Cached in-memory so repeated views of
    /// the same avatar/cover don't re-sign every render. Returns `nil` if signing fails
    /// (offline, signed out) so callers fall back to a placeholder.
    func signedImageURL(for stored: String) async -> URL? {
        let path = ReceiptStorage.storagePath(from: stored)
        guard !path.isEmpty else { return nil }
        if let cached = signedURLCache[path], cached.refreshAfter > Date() {
            return cached.url
        }
        if let task = signedURLTasks[path] {
            return await task.value
        }
        let task = Task<URL?, Never> {
            guard let accessToken = try? await self.authorizedAccessToken() else { return nil }
            do {
                let url = try await self.withFreshTokenIfNeeded(initialToken: accessToken) { token in
                    try await ReceiptStorage.shared.signedURL(path: path, expiresIn: 3600, accessToken: token)
                }
                await MainActor.run {
                    // Refresh a little before the 1-hour expiry so an in-flight load never 400s.
                    self.signedURLCache[path] = (url, Date().addingTimeInterval(50 * 60))
                }
                return url
            } catch {
                return nil
            }
        }
        signedURLTasks[path] = task
        let url = await task.value
        signedURLTasks[path] = nil
        return url
    }

    /// Returns a cover as a UIKit image for editing. Reuses the stable-path cache
    /// first, then refreshes from a signed URL when the image is not on this device.
    func editableTripCover(from stored: String) async -> UIImage? {
        let path = ReceiptStorage.storagePath(from: stored)
        guard !path.isEmpty else { return nil }
        if let cached = await ImageCache.shared.image(for: path) { return cached }
        guard let url = await signedImageURL(for: path) else { return nil }
        return await ImageCache.shared.download(from: url, for: path)
    }

    /// Clears expired signed URL entries and completed coalescing tasks when the account
    /// changes, so a new user never waits on or reuses another account's image signing.
    private func resetSignedImageURLs() {
        signedURLCache = [:]
        signedURLTasks.values.forEach { $0.cancel() }
        signedURLTasks = [:]
    }

    // Internal (not private): the trip-feed extension in FeedFeature.swift runs its
    // repository calls through the same token validation/refresh pipeline.
    func authorizedAccessToken(requireServerAccepted: Bool = false) async throws -> String? {
        // Reuse the stored token only while it's a real, non-expired user JWT. Sending an
        // expired/malformed one lets the request reach Postgres as the anonymous role,
        // where RLS rejects the write with a 403 (auth.uid() is null) — the failure mode
        // that produced silent "couldn't save to cloud" errors on device.
        if let accessToken, Self.isUsableUserToken(accessToken) {
            if !requireServerAccepted {
                return accessToken
            }
            if await AuthService.shared.isSessionAccepted(accessToken: accessToken) {
                return accessToken
            }
        }
        // No usable token: try to mint a fresh one from the refresh token.
        let hadToken = accessToken != nil
        let refreshed: String?
        do {
            refreshed = try await refreshAccessToken?()
        } catch {
            // Couldn't refresh. With no prior token this is just a signed-out, local-only
            // session (stay silent); with one, the session is genuinely broken (surface it).
            if hadToken {
                throw AuthError(message: "Your session expired. Please sign in again to sync.")
            }
            return nil
        }
        // Nil means there's no session to authenticate with — callers treat that as local-only.
        guard let refreshed else { return nil }
        await MainActor.run {
            self.accessToken = refreshed
            self.bindIdentity(accessToken: refreshed)
        }
        // A refresh that still doesn't yield a usable user token means the session is broken.
        guard Self.isUsableUserToken(refreshed) else {
            throw AuthError(message: "Your session expired. Please sign in again to sync.")
        }
        if requireServerAccepted {
            guard await AuthService.shared.isSessionAccepted(accessToken: refreshed) else {
                throw AuthError(message: "Your session isn't reaching the server. Please sign out and sign in again.")
            }
        }
        return refreshed
    }

    func withFreshTokenIfNeeded<T>(
        initialToken: String,
        operation: (String) async throws -> T
    ) async throws -> T {
        do {
            return try await operation(initialToken)
        } catch let error as AuthError where error.statusCode == 401 || error.statusCode == 403 {
            // 401 = the token was expired/rejected. A 403 with our RLS setup can mean the
            // write reached Postgres unauthenticated (auth.uid() null). Both are worth one
            // retry with a freshly minted token — but only when the refresh actually yields
            // a different one, so a genuine permission 403 (e.g. editing a trip you're not a
            // member of) isn't retried in vain.
            guard let refreshed = try await refreshAccessToken?(), refreshed != initialToken else { throw error }
            await MainActor.run {
                self.accessToken = refreshed
                self.bindIdentity(accessToken: refreshed)
            }
            return try await operation(refreshed)
        }
    }

    /// Ensures a local-only trip created under a pre-auth random UUID can be inserted under
    /// the signed-in account. Existing shared trips that already include the authenticated
    /// user keep their original creator/owner id.
    private func tripForCloudSave(_ trip: Trip, accessToken: String) -> Trip {
        guard let userID = Self.userID(fromJWT: accessToken),
              trip.creatorID != userID,
              !trip.members.contains(where: { $0.id == userID }) else {
            return trip
        }
        let reanchored = trip.reanchoringCreator(to: userID)
        if let index = trips.firstIndex(where: { $0.id == trip.id }) {
            trips[index] = reanchored
        }
        return reanchored
    }

    // MARK: Settlements

    func settleKey(_ settlement: Settlement) -> String {
        "\(settlement.from.id.uuidString)->\(settlement.to.id.uuidString)"
    }

    func history(tripID: Trip.ID, for settlement: Settlement) -> [SettlementRecord] {
        trip(tripID)?.settlementRecords[settleKey(settlement)] ?? []
    }

    func setHistory(_ records: [SettlementRecord], tripID: Trip.ID, for settlement: Settlement) {
        guard let index = trips.firstIndex(where: { $0.id == tripID }) else { return }
        trips[index].settlementRecords[settleKey(settlement)] = records
        persist(trips[index])
    }

    /// Remaining on a transfer = original amount minus confirmed settlement payments.
    func remaining(tripID: Trip.ID, for settlement: Settlement) -> Double {
        let confirmed = history(tripID: tripID, for: settlement)
            .filter { $0.status == .confirmed }
            .reduce(0) { $0 + $1.amount }
        return max(0, SplitEngine.roundToTwo(settlement.amount - confirmed))
    }

    func isFullySettled(tripID: Trip.ID, _ settlement: Settlement) -> Bool {
        remaining(tripID: tripID, for: settlement) <= 0.005
    }

    /// The creditor's one-tap "they paid me back": records the full remaining balance
    /// of a transfer as an already-confirmed payment, so the debt drops out of the
    /// Settle Up card and shows under the trip's History.
    func confirmSettled(tripID: Trip.ID, settlement: Settlement) {
        guard let index = trips.firstIndex(where: { $0.id == tripID }) else { return }
        let rem = remaining(tripID: tripID, for: settlement)
        guard rem > 0.005 else { return }
        trips[index].settlementRecords[settleKey(settlement), default: []].insert(
            SettlementRecord(
                amount: rem, method: .cash,
                note: String(localized: "Marked as paid"),
                status: .confirmed, date: Date()
            ),
            at: 0
        )
        persist(trips[index])
    }

    // MARK: Comments

    func comments(for expenseID: Expense.ID, in tripID: Trip.ID) -> [ExpenseComment] {
        trip(tripID)?.comments[expenseID.uuidString] ?? []
    }

    func addComment(_ text: String, to expenseID: Expense.ID, in tripID: Trip.ID) {
        guard let index = trips.firstIndex(where: { $0.id == tripID }) else { return }
        let comment = ExpenseComment(
            authorID: currentUser.id,
            authorName: currentUser.name,
            text: text
        )
        trips[index].comments[expenseID.uuidString, default: []].append(comment)
        persist(trips[index])
    }

    func deleteComment(_ commentID: ExpenseComment.ID, from expenseID: Expense.ID, in tripID: Trip.ID) {
        guard let index = trips.firstIndex(where: { $0.id == tripID }) else { return }
        trips[index].comments[expenseID.uuidString]?.removeAll { $0.id == commentID }
        persist(trips[index])
    }

    // MARK: Feed state

    /// Feed posts per trip, newest first. Posts live in their own `trip_feed_posts`
    /// table (see `FeedFeature.swift`), loaded on demand when the Feed tab opens and
    /// mutated optimistically by the feed methods in that file. State lives here (not
    /// in the extension) because extensions can't add storage to an @Observable class.
    var feedPostsByTrip: [Trip.ID: [FeedPost]] = [:]
}

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

// MARK: - Currency helper

/// Maps a currency code to its display symbol, defaulting to `$`.
func currencySymbol(_ code: String) -> String {
    switch code {
    case "EUR": "€"
    case "GBP": "£"
    case "JPY", "CNY": "¥"
    case "KRW": "₩"
    case "THB": "฿"
    case "VND": "₫"
    case "INR": "₹"
    default: "$"
    }
}

let supportedCurrencies = ["USD", "EUR", "GBP", "JPY", "CAD", "AUD", "CNY", "KRW", "THB", "SGD", "VND", "INR"]

/// Colors assigned to newly added trip members, in rotation.
/// Muted, harmonized hues for member avatars — distinguishable but calm, since a
/// trip screen can show a dozen avatars at once (rendered as soft tints by
/// `InitialsAvatar`, which is what keeps existing saturated stored colors calm too).
let memberPalette: [UInt32] = [0x5B8DBE, 0x5FA98C, 0xC0895E, 0x9282C0, 0xC07B85, 0x5FA3B0, 0x8FA05E, 0xB08FC0]

/// Prepares user-picked images for upload/display without keeping full-resolution originals
/// around in SwiftUI state. ImageIO thumbnails avoid a large decode for camera-roll photos.
enum UploadImagePreparation {
    static func preparedImage(
        from data: Data,
        maxPixelSize: Int,
        compressionQuality: CGFloat
    ) async -> (image: UIImage, jpeg: Data)? {
        await Task.detached(priority: .userInitiated) {
            autoreleasepool {
                guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                ]
                guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                    return nil
                }
                let image = UIImage(cgImage: cgImage)
                guard let jpeg = image.jpegData(compressionQuality: compressionQuality) else { return nil }
                return (image, jpeg)
            }
        }.value
    }

    static func jpegData(
        from data: Data,
        maxPixelSize: Int,
        compressionQuality: CGFloat
    ) async -> Data? {
        (await preparedImage(from: data, maxPixelSize: maxPixelSize, compressionQuality: compressionQuality))?.jpeg
    }

    static func jpegData(
        from image: UIImage,
        maxPixelSize: CGFloat,
        compressionQuality: CGFloat
    ) async -> Data? {
        await Task.detached(priority: .userInitiated) {
            autoreleasepool {
                let longestSide = max(image.size.width, image.size.height)
                let output: UIImage
                if longestSide > maxPixelSize {
                    let scale = maxPixelSize / longestSide
                    let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                    // scale = 1 so `newSize` IS the pixel size — the renderer default is
                    // the screen scale (3x on device), which would triple the dimensions
                    // and can OOM-kill the app on a full-size photo.
                    let format = UIGraphicsImageRendererFormat.default()
                    format.scale = 1
                    let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
                    output = renderer.image { _ in
                        image.draw(in: CGRect(origin: .zero, size: newSize))
                    }
                } else {
                    output = image
                }
                return output.jpegData(compressionQuality: compressionQuality)
            }
        }.value
    }
}

// MARK: - Cover photo cropping

/// A just-picked photo waiting to be cropped; `Identifiable` so it can drive
/// a `.sheet(item:)` presentation.
struct CoverCropCandidate: Identifiable {
    let id = UUID()
    let image: UIImage
}

/// Full-screen crop step shown after picking a trip cover photo: pinch to zoom and
/// drag to reposition the image under a fixed cover-shaped window, then confirm.
/// The framed region is rendered out as a new `UIImage` via `onCrop`.
struct CoverCropView: View {
    let image: UIImage
    let onCrop: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    /// Cover images render in wide cards (the 170pt-tall add-trip hero, trip rows),
    /// so the crop window matches that landscape shape.
    private static let cropAspect: CGFloat = 16.0 / 9.0

    @State private var zoom: CGFloat = 1
    @State private var steadyZoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var steadyOffset: CGSize = .zero
    /// The crop window's on-screen size, captured from layout so `crop()` can map
    /// gesture points back to image pixels.
    @State private var lastCropSize: CGSize = .zero

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let cropSize = cropWindowSize(in: geo.size)
                ZStack {
                    Color.black.ignoresSafeArea()

                    imageLayer(cropSize: cropSize)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()

                    // Dim everything outside the crop window.
                    Rectangle()
                        .fill(.black.opacity(0.55))
                        .reverseMask {
                            RoundedRectangle(cornerRadius: 20)
                                .frame(width: cropSize.width, height: cropSize.height)
                        }
                        .allowsHitTesting(false)
                        .ignoresSafeArea()

                    RoundedRectangle(cornerRadius: 20)
                        .strokeBorder(.white.opacity(0.9), lineWidth: 1.5)
                        .frame(width: cropSize.width, height: cropSize.height)
                        .allowsHitTesting(false)

                    Text("Pinch to zoom, drag to reposition")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.4), in: .capsule)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 24)
                        .allowsHitTesting(false)
                }
                .contentShape(.rect)
                .gesture(dragGesture(cropSize: cropSize).simultaneously(with: zoomGesture(cropSize: cropSize)))
                .onAppear { lastCropSize = cropSize }
                .onChange(of: geo.size) { _, newSize in
                    lastCropSize = cropWindowSize(in: newSize)
                    offset = clampedOffset(offset, zoom: zoom, cropSize: lastCropSize)
                    steadyOffset = offset
                }
            }
            .navigationTitle("Adjust photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.black.opacity(0.6), for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        crop()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func cropWindowSize(in container: CGSize) -> CGSize {
        let width = max(container.width - 40, 1)
        return CGSize(width: width, height: width / Self.cropAspect)
    }

    /// The image size on screen at zoom 1: aspect-fill of the crop window.
    private func fittedSize(cropSize: CGSize) -> CGSize {
        let fill = max(cropSize.width / max(image.size.width, 1),
                       cropSize.height / max(image.size.height, 1))
        return CGSize(width: image.size.width * fill, height: image.size.height * fill)
    }

    private func imageLayer(cropSize: CGSize) -> some View {
        let fitted = fittedSize(cropSize: cropSize)
        return Image(uiImage: image)
            .resizable()
            .frame(width: fitted.width, height: fitted.height)
            .scaleEffect(zoom)
            .offset(offset)
    }

    private func dragGesture(cropSize: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                offset = CGSize(width: steadyOffset.width + value.translation.width,
                                height: steadyOffset.height + value.translation.height)
            }
            .onEnded { _ in
                offset = clampedOffset(offset, zoom: zoom, cropSize: cropSize)
                steadyOffset = offset
            }
    }

    private func zoomGesture(cropSize: CGSize) -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                zoom = min(max(steadyZoom * value, 1), 6)
            }
            .onEnded { _ in
                steadyZoom = zoom
                offset = clampedOffset(offset, zoom: zoom, cropSize: cropSize)
                steadyOffset = offset
            }
    }

    /// Keeps the image covering the whole crop window (no gaps at the edges).
    private func clampedOffset(_ proposed: CGSize, zoom: CGFloat, cropSize: CGSize) -> CGSize {
        let fitted = fittedSize(cropSize: cropSize)
        let shownWidth = fitted.width * zoom
        let shownHeight = fitted.height * zoom
        let maxX = max((shownWidth - cropSize.width) / 2, 0)
        let maxY = max((shownHeight - cropSize.height) / 2, 0)
        return CGSize(width: min(max(proposed.width, -maxX), maxX),
                      height: min(max(proposed.height, -maxY), maxY))
    }

    /// Renders the crop window's contents into a new image (capped at 1600px wide —
    /// the same budget `UploadImagePreparation` uses for cover uploads).
    private func crop() {
        let outputWidth: CGFloat = 1_600
        let screenCrop = lastCropSize
        guard screenCrop.width > 0 else { return onCrop(image) }
        let fitted = fittedSize(cropSize: screenCrop)
        let shown = CGSize(width: fitted.width * zoom, height: fitted.height * zoom)
        let originX = (screenCrop.width - shown.width) / 2 + offset.width
        let originY = (screenCrop.height - shown.height) / 2 + offset.height
        let renderScale = outputWidth / screenCrop.width
        let outputSize = CGSize(width: outputWidth, height: outputWidth / Self.cropAspect)

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: outputSize, format: format)
        let cropped = renderer.image { _ in
            image.draw(in: CGRect(x: originX * renderScale,
                                  y: originY * renderScale,
                                  width: shown.width * renderScale,
                                  height: shown.height * renderScale))
        }
        onCrop(cropped)
    }
}

private extension View {
    /// Punches `mask` out of the view (inverse mask), used for the crop-window dimming.
    func reverseMask<Mask: View>(@ViewBuilder _ mask: () -> Mask) -> some View {
        self.mask {
            Rectangle()
                .overlay(alignment: .center) {
                    mask().blendMode(.destinationOut)
                }
                .compositingGroup()
        }
    }
}

// MARK: - Add Trip

/// A sheet for creating a trip: name, currency, the owner's personal budget, and local participants.
struct AddTripView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(TripStore.self) private var store

    @State private var name = ""
    @State private var location = ""
    @State private var hasDates = false
    @State private var startDate = Date()
    @State private var endDate = Date()
    @State private var currency = "USD"
    @State private var budgetText = ""
    @State private var memberName = ""
    @State private var members: [Person] = []
    @State private var coverPick: PhotosPickerItem?
    @State private var coverImage: UIImage?
    @State private var coverJPEG: Data?
    @State private var cropCandidate: CoverCropCandidate?
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !isSaving
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()

                ScrollView {
                    VStack(spacing: 18) {
                        coverHero
                        header
                        whereCard
                        datesCard
                        budgetCard
                        tripmatesCard
                        if let errorMessage {
                            Text(errorMessage)
                                .font(.caption)
                                .foregroundStyle(Theme.negative)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding()
                    .padding(.bottom, 12)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) { startPlanningButton }
            .onChange(of: coverPick) { _, pick in
                guard let pick else { return }
                Task {
                    guard let data = try? await pick.loadTransferable(type: Data.self) else { return }
                    // Downscale/normalize first, then let the user frame the shot.
                    if let prepared = await UploadImagePreparation.preparedImage(
                        from: data,
                        maxPixelSize: 1_600,
                        compressionQuality: 0.72
                    ) {
                        cropCandidate = CoverCropCandidate(image: prepared.image)
                    } else if let image = UIImage(data: data) {
                        cropCandidate = CoverCropCandidate(image: image)
                    }
                    coverPick = nil
                }
            }
            .fullScreenCover(item: $cropCandidate) { candidate in
                CoverCropView(image: candidate.image) { cropped in
                    coverImage = cropped
                    coverJPEG = nil // Recompressed from the cropped image at save time.
                }
            }
        }
    }

    /// Wanderlog-style full-bleed cover header: the picked photo (or a themed gradient
    /// placeholder) with a small glass "Add photo" chip floating over its corner.
    private var coverHero: some View {
        ZStack(alignment: .bottomTrailing) {
            ZStack {
                if let coverImage {
                    Image(uiImage: coverImage).resizable().scaledToFill()
                } else {
                    LinearGradient(
                        colors: [Theme.accent, Theme.accentSecondary],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                    Image(systemName: "airplane.departure")
                        .font(.system(size: 42, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
            .frame(height: 170)
            .frame(maxWidth: .infinity)
            .clipped()
            .clipShape(.rect(cornerRadius: 28))

            PhotosPicker(selection: $coverPick, matching: .images) {
                Label(coverImage == nil ? "Add photo" : "Change photo", systemImage: "camera.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.tint(.black.opacity(0.35)).interactive(), in: .capsule)
            .padding(12)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Plan a new trip")
                .font(.system(.largeTitle).weight(.bold))
            Text("Name it, pick a place, and bring your crew.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var whereCard: some View {
        TripCard(title: "Where to?", icon: "mappin.and.ellipse") {
            HStack(spacing: 10) {
                Image(systemName: "suitcase.fill").foregroundStyle(.secondary)
                TextField("Trip name (e.g. Summer in Tokyo)", text: $name)
                    .font(.body.weight(.semibold))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Theme.fieldBackground, in: .rect(cornerRadius: 12))

            LocationField(text: $location)

            HStack {
                Text("Currency").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Picker("Currency", selection: $currency) {
                        ForEach(supportedCurrencies, id: \.self) { Text($0).tag($0) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(currency).font(.subheadline.weight(.semibold))
                        Image(systemName: "chevron.down").font(.caption2.weight(.bold))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.secondary.opacity(0.12), in: .capsule)
                }
            }
        }
    }

    private var datesCard: some View {
        TripCard(title: "When?", icon: "calendar") {
            Toggle("Add travel dates", isOn: $hasDates.animation(.snappy))
                .font(.subheadline.weight(.medium))
                .tint(Theme.accent)
            if hasDates {
                DatePicker("Start", selection: $startDate, displayedComponents: .date)
                    .font(.subheadline)
                DatePicker("End", selection: $endDate, in: startDate..., displayedComponents: .date)
                    .font(.subheadline)
            }
        }
    }

    /// The pinned bottom call-to-action, mirroring Wanderlog's "Start planning".
    private var startPlanningButton: some View {
        Button {
            create()
        } label: {
            Group {
                if isSaving {
                    ProgressView().tint(.white)
                } else {
                    Label("Start planning", systemImage: "arrow.right")
                        .labelStyle(.titleAndIcon)
                        .font(.headline)
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(Theme.accent).interactive(), in: .capsule)
        .disabled(!canCreate)
        .opacity(canCreate ? 1 : 0.5)
        .padding(.horizontal)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    private var budgetCard: some View {
        TripCard(title: "Your budget", icon: "wallet.bifold.fill") {
            Text("How much you can personally spend on this trip.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack(spacing: 2) {
                Text(currencySymbol(currency)).foregroundStyle(.secondary)
                TextField("0.00", text: $budgetText)
                    .keyboardType(.decimalPad)
            }
            .font(.title3.weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Theme.fieldBackground, in: .rect(cornerRadius: 12))
        }
    }

    private var tripmatesCard: some View {
        TripCard(title: "Tripmates", icon: "person.2.fill") {
            Text("You can invite people with an account after the trip is created.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            // Everyone on the trip so far, as removable chips (owner first, fixed).
            FlowLayout(spacing: 8) {
                if store.currentUser.name.isEmpty {
                    tripmateChip(person: store.currentUser, label: Text("You"), removable: false)
                } else {
                    tripmateChip(person: store.currentUser, label: Text("\(store.currentUser.name) (You)"), removable: false)
                }
                ForEach(members) { member in
                    tripmateChip(person: member, label: Text(verbatim: member.name), removable: true)
                }
            }

            HStack(spacing: 10) {
                TextField("Add tripmate name", text: $memberName)
                    .submitLabel(.done)
                    .onSubmit { addMember() }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Theme.fieldBackground, in: .rect(cornerRadius: 12))
                Button { addMember() } label: {
                    Image(systemName: "plus")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.tint(Theme.accent).interactive(), in: .circle)
                .disabled(memberName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func tripmateChip(person: Person, label: Text, removable: Bool) -> some View {
        HStack(spacing: 6) {
            avatar(person, size: 24)
            label
                .font(.footnote.weight(.medium))
                .lineLimit(1)
            if removable {
                Button {
                    members.removeAll { $0.id == person.id }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, 5)
        .padding(.trailing, removable ? 8 : 11)
        .padding(.vertical, 5)
        .background(person.color.opacity(0.12), in: .capsule)
    }

    private func addMember() {
        let trimmed = memberName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let color = Color(hex: memberPalette[members.count % memberPalette.count])
        members.append(Person(name: trimmed, color: color))
        memberName = ""
    }

    private func create() {
        let me = store.currentUser
        let trimmedLocation = location.trimmingCharacters(in: .whitespaces)
        var trip = Trip(
            name: name.trimmingCharacters(in: .whitespaces),
            currencyCode: currency,
            creatorID: me.id,
            members: [me] + members,
            budgets: [me.id: Double(budgetText) ?? 0],
            location: trimmedLocation.isEmpty ? nil : trimmedLocation,
            startDate: hasDates ? startDate : nil,
            endDate: hasDates ? endDate : nil
        )
        isSaving = true
        errorMessage = nil
        Task {
            if let coverImage {
                let jpeg: Data?
                if let coverJPEG {
                    jpeg = coverJPEG
                } else {
                    jpeg = await UploadImagePreparation.jpegData(
                        from: coverImage,
                        maxPixelSize: 1_600,
                        compressionQuality: 0.72
                    )
                }
                guard let jpeg else {
                    errorMessage = "Couldn't prepare the cover photo."
                    isSaving = false
                    return
                }
                do {
                    trip.coverImageURL = try await store.uploadTripCover(jpeg, tripID: trip.id)
                } catch {
                    errorMessage = (error as? AuthError)?.message ?? "Couldn't upload the cover photo."
                    isSaving = false
                    return
                }
            }
            store.addTrip(trip)
            isSaving = false
            dismiss()
        }
    }
}

// MARK: - Edit Trip

/// Edits a trip's name, location, dates, currency, cover photo, and the signed-in user's
/// budget. Available to the trip owner from the detail hero header.
struct EditTripView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(TripStore.self) private var store
    let tripID: Trip.ID

    @State private var name = ""
    @State private var location = ""
    @State private var hasDates = false
    @State private var startDate = Date()
    @State private var endDate = Date()
    @State private var currency = "USD"
    @State private var budgetText = ""
    @State private var coverPick: PhotosPickerItem?
    @State private var coverImage: UIImage?
    @State private var coverJPEG: Data?
    @State private var cropCandidate: CoverCropCandidate?
    @State private var isLoadingCurrentCover = false
    @State private var allowMembersToPayForOthers = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var loaded = false

    /// The trip's currency and the user's budget at load time, so switching the currency
    /// picker can re-derive the converted budget from a stable origin (rather than
    /// compounding conversions) and `save()` knows whether a conversion is needed.
    @State private var originalCurrency = "USD"
    @State private var originalBudget: Double = 0

    private var trip: Trip? { store.trip(tripID) }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !isSaving
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(colors: Theme.sheetGradient, startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 18) {
                        coverCard
                        detailsCard
                        datesCard
                        budgetCard
                        permissionsCard
                        if let errorMessage {
                            Text(errorMessage)
                                .font(.caption)
                                .foregroundStyle(Theme.negative)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding()
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("Edit Trip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") { save() }.disabled(!canSave)
                    }
                }
            }
            .task { load() }
            .onChange(of: currency) { _, _ in currencyChanged() }
            .onChange(of: coverPick) { _, pick in
                guard let pick else { return }
                Task {
                    guard let data = try? await pick.loadTransferable(type: Data.self) else { return }
                    // Downscale/normalize first, then let the user frame the shot.
                    if let prepared = await UploadImagePreparation.preparedImage(
                        from: data,
                        maxPixelSize: 1_600,
                        compressionQuality: 0.72
                    ) {
                        cropCandidate = CoverCropCandidate(image: prepared.image)
                    } else if let image = UIImage(data: data) {
                        cropCandidate = CoverCropCandidate(image: image)
                    }
                    coverPick = nil
                }
            }
            .fullScreenCover(item: $cropCandidate) { candidate in
                CoverCropView(image: candidate.image) { cropped in
                    coverImage = cropped
                    coverJPEG = nil // Recompressed from the cropped image at save time.
                }
            }
        }
    }

    private var coverCard: some View {
        TripCard(title: "Cover Photo", icon: "photo.fill") {
            ZStack {
                if let coverImage {
                    Image(uiImage: coverImage).resizable().scaledToFill()
                } else if let trip {
                    TripCoverView(trip: trip)
                }
            }
            .frame(height: 150)
            .frame(maxWidth: .infinity)
            .clipped()
            .clipShape(.rect(cornerRadius: 14))

            PhotosPicker(selection: $coverPick, matching: .images) {
                Label("Change Photo", systemImage: "photo.on.rectangle.angled")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.tint(Theme.accent).interactive(), in: .capsule)

            if coverImage != nil || trip?.coverImageURL?.isEmpty == false {
                Button { adjustCurrentCover() } label: {
                    HStack(spacing: 7) {
                        if isLoadingCurrentCover { ProgressView().controlSize(.small) }
                        Label("Resize or reposition", systemImage: "crop")
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
                .disabled(isLoadingCurrentCover)
            }
        }
    }

    private func adjustCurrentCover() {
        if let coverImage {
            cropCandidate = CoverCropCandidate(image: coverImage)
            return
        }
        guard let stored = trip?.coverImageURL, !stored.isEmpty else { return }
        isLoadingCurrentCover = true
        Task {
            defer { isLoadingCurrentCover = false }
            if let image = await store.editableTripCover(from: stored) {
                cropCandidate = CoverCropCandidate(image: image)
            } else {
                errorMessage = "Couldn't load the current cover photo. Check your connection and try again."
            }
        }
    }

    private var detailsCard: some View {
        TripCard(title: "Trip details", icon: "suitcase.fill") {
            TextField("Trip name", text: $name)
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(Theme.fieldBackground, in: .rect(cornerRadius: 12))

            LocationField(text: $location)

            HStack {
                Text("Currency").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Picker("Currency", selection: $currency) {
                        ForEach(supportedCurrencies, id: \.self) { Text($0).tag($0) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(currency).font(.subheadline.weight(.semibold))
                        Image(systemName: "chevron.down").font(.caption2.weight(.bold))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.secondary.opacity(0.12), in: .capsule)
                }
            }

            if currency != originalCurrency {
                Label("Existing expenses and budgets will be converted to \(currency) at today's rate.", systemImage: "arrow.left.arrow.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var datesCard: some View {
        TripCard(title: "Dates", icon: "calendar") {
            Toggle("Add travel dates", isOn: $hasDates.animation(.snappy))
                .font(.subheadline.weight(.medium))
            if hasDates {
                DatePicker("Start", selection: $startDate, displayedComponents: .date)
                    .font(.subheadline)
                DatePicker("End", selection: $endDate, in: startDate..., displayedComponents: .date)
                    .font(.subheadline)
            }
        }
    }

    private var budgetCard: some View {
        TripCard(title: "Your budget", icon: "wallet.bifold.fill") {
            Text("How much you can personally spend on this trip.")
                .font(.footnote).foregroundStyle(.secondary)
            HStack(spacing: 2) {
                Text(currencySymbol(currency)).foregroundStyle(.secondary)
                TextField("0.00", text: $budgetText).keyboardType(.decimalPad)
            }
            .font(.title3.weight(.semibold))
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(Theme.fieldBackground, in: .rect(cornerRadius: 12))
        }
    }

    private var permissionsCard: some View {
        TripCard(title: "Permissions", icon: "person.badge.key.fill") {
            Toggle(isOn: $allowMembersToPayForOthers) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Members can pay for others")
                        .font(.subheadline.weight(.medium))
                    Text("Let invited members record an expense paid by someone else. You can always do this.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func load() {
        guard !loaded, let trip else { return }
        name = trip.name
        location = trip.location ?? ""
        currency = trip.currencyCode
        originalCurrency = trip.currencyCode
        let budget = trip.budget(for: store.currentUser.id)
        originalBudget = budget
        budgetText = budget > 0 ? String(format: "%g", budget) : ""
        if let start = trip.startDate { startDate = start; hasDates = true }
        if let end = trip.endDate { endDate = end; hasDates = true }
        allowMembersToPayForOthers = trip.allowMembersToPayForOthers
        loaded = true
    }

    /// When the currency picker changes, re-derive the displayed budget from the original
    /// value so the field shows the converted amount the user is about to save. Re-deriving
    /// from `originalBudget` (rather than the current text) avoids compounding conversions
    /// when the user switches currencies several times.
    private func currencyChanged() {
        guard loaded else { return }
        guard currency != originalCurrency else {
            budgetText = originalBudget > 0 ? String(format: "%g", originalBudget) : ""
            return
        }
        Task {
            guard let rate = await store.conversionRate(from: originalCurrency, to: currency) else { return }
            budgetText = originalBudget > 0 ? String(format: "%g", SplitEngine.roundToTwo(originalBudget * rate)) : ""
        }
    }

    private func save() {
        guard var updated = trip else { return }
        isSaving = true
        errorMessage = nil
        Task {
            if let coverImage {
                let jpeg: Data?
                if let coverJPEG {
                    jpeg = coverJPEG
                } else {
                    jpeg = await UploadImagePreparation.jpegData(
                        from: coverImage,
                        maxPixelSize: 1_600,
                        compressionQuality: 0.72
                    )
                }
                guard let jpeg else {
                    errorMessage = "Couldn't prepare the cover photo."
                    isSaving = false
                    return
                }
                do {
                    updated.coverImageURL = try await store.uploadTripCover(jpeg, tripID: tripID)
                } catch {
                    errorMessage = (error as? AuthError)?.message ?? "Couldn't upload the cover photo."
                    isSaving = false
                    return
                }
            }
            // Currency change: convert every stored amount (expenses, shares, tax/tip,
            // settlements, budgets) by the live rate so they reflect real converted value
            // rather than being relabeled. Abort if rates are unavailable so we never
            // silently mislabel amounts (e.g. a 100 USD expense as "100 ₫").
            if currency != originalCurrency {
                guard let rate = await store.conversionRate(from: originalCurrency, to: currency) else {
                    errorMessage = "Couldn't fetch the exchange rate to convert amounts. Check your connection and try again."
                    isSaving = false
                    return
                }
                updated = store.applyingCurrencyConversion(updated, rate: rate)
            }

            let trimmedLocation = location.trimmingCharacters(in: .whitespaces)
            updated.name = name.trimmingCharacters(in: .whitespaces)
            updated.location = trimmedLocation.isEmpty ? nil : trimmedLocation
            updated.currencyCode = currency
            updated.startDate = hasDates ? startDate : nil
            updated.endDate = hasDates ? endDate : nil
            updated.allowMembersToPayForOthers = allowMembersToPayForOthers
            // The budget field is shown (and auto-converted) in the new currency, so save it
            // as typed — this also honors a manual budget edit over the converted default.
            updated.budgets[store.currentUser.id] = Double(budgetText) ?? 0
            store.updateTrip(updated)
            isSaving = false
            dismiss()
        }
    }
}

// MARK: - Trip Detail

/// Shows a trip's budget summary, members, and expenses, with an "Add Expense" action.
struct TripDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(TripStore.self) private var store
    @Environment(AuthStore.self) private var auth
    let tripID: Trip.ID

    @State private var showAddExpense = false
    @State private var showEditTrip = false
    @State private var showSignInAlert = false
    @State private var scrollToSettle = false
    @State private var activeSettlement: Settlement?
    @State private var settlementToConfirm: Settlement?
    @State private var expandedCreditors: Set<Person.ID> = []
    @State private var showSettleInfo = false
    @State private var manualMemberName = ""
    @State private var inviteEmail = ""
    @State private var inviteMessage: String?
    @State private var inviteLink: URL?
    @State private var isInviting = false
    @State private var isGeneratingLink = false
    @State private var detailTab: TripDetailTab = .overview

    private enum TripDetailTab: String, CaseIterable {
        case overview, feed
    }

    private var trip: Trip? { store.trip(tripID) }

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: Theme.sheetGradient,
                    startPoint: .top, endPoint: .bottom
                )
                .ignoresSafeArea()

                if let trip {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(spacing: 0) {
                                heroHeader(trip)
                                VStack(spacing: 18) {
                                    detailTabPicker
                                    switch detailTab {
                                    case .overview:
                                        tripDetailsCard(trip)
                                        itineraryCard(trip)
                                        budgetOverviewCard(trip)
                                        if trip.members.count >= 2 && !trip.expenses.isEmpty {
                                            OneTimeTipBanner(
                                                key: "tipSettleUpDismissed",
                                                icon: "arrow.left.arrow.right.circle.fill",
                                                message: "TripSplit works out who owes whom below — tap a payment to record it once it's settled."
                                            )
                                        }
                                        yourDebtsCard(trip)
                                        settleCard(trip).id("settle")
                                        membersCard(trip)
                                        expensesCard(trip)
                                        if !trip.deletedExpenses.isEmpty {
                                            recentlyDeletedCard(trip)
                                        }
                                    case .feed:
                                        TripFeedView(tripID: tripID)
                                    }
                                }
                                .padding()
                                .padding(.top, 18)
                                .padding(.bottom, 24)
                                .background(
                                    LinearGradient(
                                        colors: Theme.sheetGradient,
                                        startPoint: .top, endPoint: .bottom
                                    ),
                                    in: .rect(topLeadingRadius: 28, topTrailingRadius: 28)
                                )
                                // Pull the content sheet up over the photo's bottom so the
                                // cover fades under a rounded card edge instead of a hard cut.
                                .padding(.top, -28)
                            }
                        }
                        .ignoresSafeArea(edges: .top)
                        .onChange(of: scrollToSettle) { _, shouldScroll in
                            guard shouldScroll else { return }
                            detailTab = .overview
                            withAnimation(.snappy) { proxy.scrollTo("settle", anchor: .top) }
                            scrollToSettle = false
                        }
                    }
                } else {
                    ContentUnavailableView("Trip not found", systemImage: "suitcase")
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .signInRequiredAlert(isPresented: $showSignInAlert)
            .sheet(isPresented: $showAddExpense) {
                AddExpenseView(tripID: tripID)
            }
            .sheet(isPresented: $showEditTrip) {
                EditTripView(tripID: tripID)
            }
            .sheet(isPresented: $showSettleInfo) {
                SettleMathInfoView()
            }
            .sheet(item: $activeSettlement) { settlement in
                SettleView(
                    settlement: settlement,
                    history: historyBinding(for: settlement),
                    currencyCode: trip?.currencyCode ?? "USD",
                    currentUserID: store.currentUser.id
                )
            }
            .alert(
                "Confirm payment",
                isPresented: Binding(
                    get: { settlementToConfirm != nil },
                    set: { if !$0 { settlementToConfirm = nil } }
                ),
                presenting: settlementToConfirm
            ) { settlement in
                Button("Mark as Paid") {
                    withAnimation(.snappy) {
                        store.confirmSettled(tripID: tripID, settlement: settlement)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { settlement in
                Text("Did \(settlement.from.name) pay you back \(money(store.remaining(tripID: tripID, for: settlement), trip?.currencyCode ?? "USD"))?")
            }
        }
    }

    // MARK: Hero header

    private func heroHeader(_ trip: Trip) -> some View {
        ZStack(alignment: .bottomLeading) {
            TripCoverView(trip: trip)
                .frame(height: 440)
                .frame(maxWidth: .infinity)
                .clipped()
                .overlay {
                    LinearGradient(
                        colors: [.black.opacity(0.35), .clear, .clear, .black.opacity(0.7)],
                        startPoint: .top, endPoint: .bottom
                    )
                }

            VStack(alignment: .leading, spacing: 12) {
                Text("NOW EXPLORING")
                    .font(.caption.weight(.bold)).tracking(2)
                    .foregroundStyle(.white.opacity(0.85))
                Text(trip.name)
                    .font(.system(size: 36, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                if let location = trip.location, !location.isEmpty {
                    Text(location)
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.9))
                } else if let range = trip.dateRangeText {
                    Text(range)
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.9))
                }
                travelersRow(trip)
                heroActions(trip)
            }
            .padding(20)
            .padding(.bottom, 40)
        }
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.black.opacity(0.35), in: .circle)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .padding(.top, 60)
            .padding(.trailing, 20)
        }
    }

    private func travelersRow(_ trip: Trip) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: -8) {
                ForEach(trip.members.prefix(3)) { member in
                    Text(member.initials)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(member.color, in: .circle)
                        .overlay(Circle().strokeBorder(.white.opacity(0.7), lineWidth: 1.5))
                }
            }
            Text("\(trip.members.count) traveler\(trip.members.count == 1 ? "" : "s")")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
        }
    }

    private func heroActions(_ trip: Trip) -> some View {
        HStack(spacing: 10) {
            heroButton("Add Expense", icon: "plus") {
                if auth.isAuthenticated { showAddExpense = true } else { showSignInAlert = true }
            }
            if store.isCreator(of: trip) {
                heroButton("Edit Trip", icon: "calendar") {
                    if auth.isAuthenticated { showEditTrip = true } else { showSignInAlert = true }
                }
            }
            heroButton("Settle Up", icon: "person.2.fill") { scrollToSettle = true }
        }
        .padding(.top, 4)
    }

    private func heroButton(_ title: LocalizedStringKey, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.caption.weight(.semibold))
                Text(title).font(.caption.weight(.semibold)).lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    // MARK: Detail tabs

    private var detailTabPicker: some View {
        HStack(spacing: 8) {
            detailTabButton(.overview, title: "Overview", icon: "list.bullet.rectangle")
            detailTabButton(.feed, title: "Feed", icon: "photo.on.rectangle.angled")
        }
    }

    private func detailTabButton(_ tab: TripDetailTab, title: LocalizedStringKey, icon: String) -> some View {
        Button {
            withAnimation(.snappy) { detailTab = tab }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.caption.weight(.semibold))
                Text(title).font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(detailTab == tab ? Color.white : .secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                detailTab == tab ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.fieldBackground),
                in: .capsule
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: Detail cards

    private func tripDetailsCard(_ trip: Trip) -> some View {
        TripCard(title: "Trip Details", icon: "calendar") {
            HStack(spacing: 12) {
                detailTile(
                    icon: "calendar",
                    label: "Date",
                    value: trip.dateRangeText ?? "Not set"
                )
                detailTile(
                    icon: "mappin.and.ellipse",
                    label: "Location",
                    value: trip.location?.isEmpty == false ? trip.location! : "Not set"
                )
            }
        }
    }

    private func detailTile(icon: String, label: LocalizedStringKey, value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.subheadline.weight(.semibold))
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.fieldBackground, in: .rect(cornerRadius: 12))
    }

    private func budgetOverviewCard(_ trip: Trip) -> some View {
        let me = store.currentUser.id
        let budget = trip.budget(for: me)
        let spent = trip.spent(for: me)
        let remaining = trip.remainingBudget(for: me)
        let overBudget = budget > 0 && spent > budget
        // A $0 budget has no separate "over budget" state, so retain the negative
        // balance to make spending against it visible in the Remaining tile.
        let displayedRemaining = budget == 0 ? remaining : abs(remaining)
        let usedFraction = budget > 0 ? spent / budget : 0
        let nearBudget = budget > 0 && usedFraction >= 0.8 && !overBudget
        let barColor = overBudget ? Theme.negative : (nearBudget ? Theme.warning : Theme.positive)
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Budget Overview", systemImage: "wallet.bifold.fill").font(.headline)
                Spacer()
                if store.isCreator(of: trip) {
                    Button {
                        if auth.isAuthenticated { showEditTrip = true } else { showSignInAlert = true }
                    } label: {
                        Text("Edit Budget")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(.secondary.opacity(0.14), in: .capsule)
                            .frame(minHeight: 44)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Total Budget").font(.caption).foregroundStyle(.secondary)
                Text(money(budget, trip.currencyCode))
                    .font(.system(size: 30, weight: .bold))
            }

            if budget > 0 {
                let fraction = min(usedFraction, 1)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.fieldBackground)
                        Capsule()
                            .fill(barColor)
                            .frame(width: max(0, geo.size.width * fraction))
                    }
                }
                .frame(height: 8)

                if nearBudget || overBudget {
                    HStack(spacing: 8) {
                        Image(systemName: overBudget ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .font(.subheadline.weight(.semibold))
                        Text(overBudget
                            ? "You've gone over budget."
                            : "Heads up — you've used \(Int((usedFraction * 100).rounded()))% of your budget.")
                            .font(.footnote.weight(.medium))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(barColor)
                    .padding(.vertical, 8).padding(.horizontal, 12)
                    .background(barColor.opacity(0.12), in: .rect(cornerRadius: 12))
                }
            }

            HStack(spacing: 12) {
                budgetTile("Spent So Far", money(spent, trip.currencyCode), Theme.accent)
                budgetTile(
                    overBudget ? "Over Budget" : "Remaining",
                    money(displayedRemaining, trip.currencyCode),
                    barColor
                )
            }

            Divider()

            let owed = trip.remainingOwed(for: me)
            HStack {
                statColumn("You owe", money(owed.by, trip.currencyCode), Color(hex: 0xEF4444))
                Spacer()
                statColumn("You're owed", money(owed.to, trip.currencyCode), Color(hex: 0x10B981))
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }

    private func budgetTile(_ label: LocalizedStringKey, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .semibold)).tracking(0.5)
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.bold)).foregroundStyle(color)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10).padding(.horizontal, 12)
        .background(color.opacity(0.10), in: .rect(cornerRadius: 12))
    }

    private func historyBinding(for settlement: Settlement) -> Binding<[SettlementRecord]> {
        Binding(
            get: { store.history(tripID: tripID, for: settlement) },
            set: { store.setHistory($0, tripID: tripID, for: settlement) }
        )
    }

    @ViewBuilder
    /// Personal "pay back" summary for the signed-in viewer: every settlement where
    /// they are the debtor, listed creditor-by-creditor so they can see at a glance
    /// whom to pay. Only account-backed members (the trip owner or invited users) can
    /// be `store.currentUser`, so the card never renders for manually added members —
    /// their `Person.ID` is a random UUID that no signed-in viewer matches.
    private func yourDebtsCard(_ trip: Trip) -> some View {
        let me = store.currentUser.id
        let myDebts = trip.settlements().filter { $0.from.id == me }
        return Group {
            if trip.members.contains(where: { $0.id == me }), !myDebts.isEmpty {
                TripCard(title: "You Need to Pay Back", icon: "arrow.up.right.circle.fill") {
                    ForEach(myDebts) { settlement in
                        Button {
                            activeSettlement = settlement
                        } label: {
                            yourDebtRow(trip, settlement)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func yourDebtRow(_ trip: Trip, _ settlement: Settlement) -> some View {
        let settled = store.isFullySettled(tripID: tripID, settlement)
        return HStack(spacing: 8) {
            avatar(settlement.to, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: settlement.to.name)
                    .font(.subheadline).fontWeight(.semibold)
                if settled {
                    Text("Settled").font(.caption).foregroundStyle(Color(hex: 0x10B981))
                } else {
                    Text("Tap to record a payment")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if settled {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(Color(hex: 0x10B981))
            } else {
                Text(money(store.remaining(tripID: tripID, for: settlement), trip.currencyCode))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.negative)
            }
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
    }

    private func settleCard(_ trip: Trip) -> some View {
        // Confirmed-paid transfers drop out of this card and reappear under History.
        let settlements = trip.settlements().filter { !store.isFullySettled(tripID: tripID, $0) }
        return TripCard(title: "Settle Up", icon: "arrow.left.arrow.right.circle.fill") {
            if settlements.isEmpty {
                Text("All settled up — no transfers needed.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                HStack(spacing: 6) {
                    Text("Tap a person to see who owes them.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        showSettleInfo = true
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("How settle up is calculated"))
                }
                let groups = creditorGroups(settlements)
                ForEach(groups, id: \.creditor.id) { group in
                    creditorRow(trip, group)
                    if expandedCreditors.contains(group.creditor.id) {
                        ForEach(group.settlements) { settlement in
                            Button {
                                activeSettlement = settlement
                            } label: {
                                settleRow(trip, settlement)
                            }
                            .buttonStyle(.plain)
                            .padding(.leading, 24)
                        }
                    }
                }
            }
        }
    }

    private func creditorGroups(_ settlements: [Settlement]) -> [(creditor: Person, settlements: [Settlement])] {
        var order: [Person.ID] = []
        var byCreditor: [Person.ID: (creditor: Person, settlements: [Settlement])] = [:]
        for settlement in settlements {
            if byCreditor[settlement.to.id] == nil {
                order.append(settlement.to.id)
                byCreditor[settlement.to.id] = (settlement.to, [])
            }
            byCreditor[settlement.to.id]?.settlements.append(settlement)
        }
        return order.compactMap { byCreditor[$0] }
    }

    private func creditorRow(_ trip: Trip, _ group: (creditor: Person, settlements: [Settlement])) -> some View {
        let me = store.currentUser.id
        let name = group.creditor.id == me ? "You" : group.creditor.name
        let totalRemaining = group.settlements.reduce(0) { $0 + store.remaining(tripID: tripID, for: $1) }
        let isExpanded = expandedCreditors.contains(group.creditor.id)
        return Button {
            withAnimation(.snappy) {
                if isExpanded {
                    expandedCreditors.remove(group.creditor.id)
                } else {
                    expandedCreditors.insert(group.creditor.id)
                }
            }
        } label: {
            HStack(spacing: 8) {
                avatar(group.creditor, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey(name))
                        .font(.subheadline).fontWeight(.semibold)
                    Text("Owed by \(group.settlements.count) \(group.settlements.count == 1 ? "person" : "people")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if totalRemaining <= 0 {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(Color(hex: 0x10B981))
                } else {
                    Text(money(totalRemaining, trip.currencyCode))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color(hex: 0x10B981))
                }
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            // Padding before contentShape so the whole padded row hit-tests,
            // not just the inner rect.
            .padding(.vertical, 4)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func settleRow(_ trip: Trip, _ settlement: Settlement) -> some View {
        let me = store.currentUser.id
        let fromLabel = settlement.from.id == me ? "You" : settlement.from.name
        return HStack(spacing: 8) {
            avatar(settlement.from, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(fromLabel))
                    .font(.subheadline).fontWeight(.semibold)
                if store.isFullySettled(tripID: tripID, settlement) {
                    Text("Settled").font(.caption).foregroundStyle(Color(hex: 0x10B981))
                }
            }
            Spacer()
            if store.isFullySettled(tripID: tripID, settlement) {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(Color(hex: 0x10B981))
            } else {
                Text(money(store.remaining(tripID: tripID, for: settlement), trip.currencyCode))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color(hex: 0x10B981))
                // Only the creditor can confirm they were actually paid back.
                if settlement.to.id == me {
                    Button {
                        settlementToConfirm = settlement
                    } label: {
                        Text("Mark Paid")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color(hex: 0x10B981))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Color(hex: 0x10B981).opacity(0.15), in: .capsule)
                            .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                }
            }
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
    }

    private struct SettleMathInfoView: View {
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        step(number: 1, icon: "creditcard.fill",
                             title: "Add up what each person paid",
                             detail: "Every expense counts fully toward the person who fronted the money.")
                        step(number: 2, icon: "chart.pie.fill",
                             title: "Work out each person's share",
                             detail: "Each expense is divided using its own split settings — equally, by percentage, by exact amounts, or assigned to one person.")
                        step(number: 3, icon: "scalemass.fill",
                             title: "Net it out",
                             detail: "Balance = paid − share. A positive balance means the group owes you; a negative one means you owe the group.")
                        step(number: 4, icon: "arrow.triangle.swap",
                             title: "Settle with the fewest payments",
                             detail: "The biggest debtor pays the biggest creditor until both hit zero, then the next pair, and so on. You might pay someone who didn't cover your expense — but everyone ends up paid back exactly what they're owed.")
                    }
                    .padding(20)
                }
                .navigationTitle("How Settle Up works")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark")
                        }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }

        private func step(number: Int, icon: String, title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Theme.accent, in: .circle)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Step \(number)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func membersCard(_ trip: Trip) -> some View {
        TripCard(title: "Members (\(trip.members.count))", icon: "person.2.fill") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(trip.members) { member in
                        VStack(spacing: 6) {
                            AvatarView(
                                person: member,
                                imageData: member.id == store.currentUser.id ? store.profileImageData : nil,
                                size: 40
                            )
                            Text(LocalizedStringKey(member.id == store.currentUser.id ? "You" : member.name))
                                .font(.caption)
                                .lineLimit(1)
                            if member.id == trip.creatorID {
                                Text("Organizer")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(Theme.accent)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Theme.accent.opacity(0.14), in: .capsule)
                            }
                        }
                        .frame(width: 74)
                    }
                }
            }

            if store.isCreator(of: trip) {
                Divider()
                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        TextField("Add manual member", text: $manualMemberName)
                            .font(.subheadline)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Theme.fieldBackground, in: .rect(cornerRadius: 12))
                        Button { addManualMember(trip) } label: {
                            Image(systemName: "plus")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.white)
                                .frame(width: 40, height: 40)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.tint(Theme.accent).interactive(), in: .circle)
                        .disabled(manualMemberName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    TextField("Invite by email", text: $inviteEmail)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                        .autocorrectionDisabled()
                        .font(.subheadline)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Theme.fieldBackground, in: .rect(cornerRadius: 12))

                    Button { invite(trip) } label: {
                        HStack(spacing: 8) {
                            if isInviting { ProgressView().tint(.white) }
                            Label("Invite Member", systemImage: "person.badge.plus")
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.tint(Theme.accent).interactive(), in: .capsule)
                    .disabled(inviteEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isInviting)
                    .opacity(inviteEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isInviting ? 0.55 : 1)

                    if let inviteMessage {
                        Text(inviteMessage)
                            .font(.caption)
                            .foregroundStyle(inviteMessage.localizedCaseInsensitiveContains("invited") || inviteMessage.localizedCaseInsensitiveContains("copied") ? Theme.positive : Theme.negative)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Divider()

                    Button { generateInviteLink(trip) } label: {
                        HStack(spacing: 8) {
                            if isGeneratingLink { ProgressView().tint(.white) }
                            Label("Generate Invitation Link", systemImage: "link")
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.tint(Color(hex: 0x10B981)).interactive(), in: .capsule)
                    .disabled(isGeneratingLink)

                    if let inviteLink {
                        HStack(spacing: 8) {
                            Text(inviteLink.absoluteString)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button {
                                UIPasteboard.general.string = inviteLink.absoluteString
                                inviteMessage = String(localized: "Invitation link copied.")
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.caption.weight(.bold))
                                    .frame(width: 38, height: 38)
                                    .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            ShareLink(item: inviteLink) {
                                Image(systemName: "square.and.arrow.up")
                                    .font(.caption.weight(.bold))
                                    .frame(width: 38, height: 38)
                                    .contentShape(.rect)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Theme.fieldBackground, in: .rect(cornerRadius: 12))
                    }
                }
            }
        }
    }

    private func addManualMember(_ trip: Trip) {
        store.addManualMember(name: manualMemberName, to: trip.id)
        manualMemberName = ""
    }

    private func invite(_ trip: Trip) {
        inviteMessage = nil
        isInviting = true
        let email = inviteEmail
        Task {
            do {
                try await store.inviteMember(email: email, displayName: "", to: trip.id)
                inviteEmail = ""
                inviteMessage = String(localized: "Member invited and added to this trip.")
            } catch {
                inviteMessage = (error as? AuthError)?.message ?? error.localizedDescription
            }
            isInviting = false
        }
    }

    private func generateInviteLink(_ trip: Trip) {
        inviteMessage = nil
        isGeneratingLink = true
        Task {
            do {
                inviteLink = try await store.createInvitationLink(for: trip.id)
                inviteMessage = String(localized: "Invitation link ready to share.")
            } catch {
                inviteMessage = (error as? AuthError)?.message ?? error.localizedDescription
            }
            isGeneratingLink = false
        }
    }

    /// Entry point to the day-by-day planner (ItineraryFeature.swift): opens the plan
    /// when one exists, or seeds one from the trip's dates and budget so itineraries
    /// are reachable from the Trips side, not just Explore.
    @ViewBuilder
    private func itineraryCard(_ trip: Trip) -> some View {
        TripCard(title: "Itinerary", icon: "map.fill") {
            if let itinerary = trip.itinerary {
                let stopCount = itinerary.days.reduce(0) { $0 + $1.stops.count }
                NavigationLink {
                    ItineraryDetailView(tripID: trip.id, showsTripLink: false)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "calendar.day.timeline.left")
                            .font(.title3)
                            .foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Day-by-day plan")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text("\(itinerary.days.count) day\(itinerary.days.count == 1 ? "" : "s") · \(stopCount) stop\(stopCount == 1 ? "" : "s") planned")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(12)
                    .background(Theme.fieldBackground, in: .rect(cornerRadius: 14))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            } else {
                Text("Plan each day of this trip: places to go, things to do, and where to eat.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button {
                    seedItinerary(trip)
                } label: {
                    Label("Plan day-by-day itinerary", systemImage: "map.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.tint(Theme.accent).interactive(), in: .capsule)
            }
        }
    }

    /// Creates an empty plan sized to the trip's date range (or 3 days without dates),
    /// budgeted with the signed-in user's trip budget.
    private func seedItinerary(_ trip: Trip) {
        let dayCount: Int
        if let start = trip.startDate, let end = trip.endDate {
            let cal = Calendar.current
            let span = cal.dateComponents([.day], from: cal.startOfDay(for: start), to: cal.startOfDay(for: end)).day ?? 0
            dayCount = min(max(span + 1, 1), 30)
        } else {
            dayCount = 3
        }
        let itinerary = Itinerary(
            totalBudget: trip.budget(for: store.currentUser.id),
            days: (0..<dayCount).map { _ in ItineraryDay() }
        )
        store.updateItinerary(itinerary, in: trip.id)
    }

    private func expensesCard(_ trip: Trip) -> some View {
        let settled = trip.settlements().filter { store.isFullySettled(tripID: tripID, $0) }
        return TripCard(title: "History", icon: "clock.arrow.circlepath") {
            if trip.expenses.isEmpty {
                Text("No expenses yet. Tap Add Expense to log one.")
                    .font(.subheadline).italic()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                Text("Expenses (\(trip.expenses.count))")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                // Eager (not Lazy) on purpose: a LazyVStack here re-measured rows as
                // they scrolled back into view, hitching the scroll-up out of this card.
                VStack(spacing: 8) {
                    ForEach(trip.expenses) { expense in
                        let link = NavigationLink {
                            ExpenseDetailView(tripID: tripID, expense: expense)
                        } label: {
                            expenseRow(trip, expense)
                        }
                        .buttonStyle(.plain)

                        if canModify(trip, expense) {
                            SwipeToDeleteRow {
                                store.deleteExpense(expense.id, from: trip.id)
                            } content: {
                                link
                            }
                        } else {
                            link
                        }
                    }
                }
            }

            if !settled.isEmpty {
                Divider()
                Text("Settled payments")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(settled) { settlement in
                    Button {
                        activeSettlement = settlement
                    } label: {
                        settledPaymentRow(trip, settlement)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// A confirmed-paid transfer, shown under History once the creditor marks it paid.
    private func settledPaymentRow(_ trip: Trip, _ settlement: Settlement) -> some View {
        let me = store.currentUser.id
        let fromLabel = settlement.from.id == me ? String(localized: "You") : settlement.from.name
        let toLabel = settlement.to.id == me ? String(localized: "you") : settlement.to.name
        let paidDate = store.history(tripID: tripID, for: settlement)
            .filter { $0.status == .confirmed }
            .map(\.date).max()
        return HStack(spacing: 8) {
            avatar(settlement.from, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(fromLabel) paid \(toLabel)")
                    .font(.subheadline).fontWeight(.semibold)
                if let paidDate {
                    Text(paidDate.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(money(settlement.amount, trip.currencyCode))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Label("Paid", systemImage: "checkmark.seal.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color(hex: 0x10B981))
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
    }

    /// Whether the signed-in account may edit or delete an expense. The trip owner may
    /// edit everything; shared members can edit expenses they personally paid.
    private func canModify(_ trip: Trip, _ expense: Expense) -> Bool {
        store.isCreator(of: trip) || expense.payerID == store.currentUser.id
    }

    private func recentlyDeletedCard(_ trip: Trip) -> some View {
        TripCard(title: "Recently Deleted (\(trip.deletedExpenses.count))", icon: "trash") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Deleted expenses still count toward your budget. Restore one to add it back to the split.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                ForEach(trip.deletedExpenses) { expense in
                    deletedExpenseRow(trip, expense)
                }
            }
        }
    }

    private func deletedExpenseRow(_ trip: Trip, _ expense: Expense) -> some View {
        let payer = trip.members.first { $0.id == expense.payerID }
        let me = store.currentUser.id
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(expense.title)
                    .font(.subheadline.weight(.semibold))
                    .strikethrough(color: .secondary)
                    .foregroundStyle(.secondary)
                let payerText = payer.map { $0.id == me ? "you" : $0.name } ?? "—"
                let deletedText = expense.deletedAt.map { " • deleted \($0.formatted(date: .abbreviated, time: .omitted))" } ?? ""
                Text("Paid by \(payerText)\(deletedText)")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
            Text(money(expense.amount, trip.currencyCode))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            if canModify(trip, expense) {
                Button {
                    store.restoreExpense(expense.id, in: trip.id)
                } label: {
                    Text("Restore")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Theme.accent.opacity(0.16), in: .capsule)
                        .foregroundStyle(Theme.accent)
                        .frame(minHeight: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }

    private func expenseRow(_ trip: Trip, _ expense: Expense) -> some View {
        let payer = trip.members.first { $0.id == expense.payerID }
        let me = store.currentUser.id
        let yourShare = trip.share(for: me, in: expense)
        return HStack(alignment: .top, spacing: 12) {
            if let payer {
                AvatarView(
                    person: payer,
                    imageData: payer.id == me ? store.profileImageData : nil,
                    size: 34
                )
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(expense.title).font(.subheadline.weight(.semibold))
                        Text("Paid by \(payer.map { $0.id == me ? "you" : $0.name } ?? "—") • \(expense.date.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(money(expense.amount, trip.currencyCode))
                        .font(.subheadline.weight(.semibold))
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)
                }
                if expense.participantIDs.contains(me) {
                    Text("Your share: \(money(yourShare, trip.currencyCode))")
                        .font(.caption)
                        .foregroundStyle(expense.payerID == me ? Theme.positive : Theme.negative)
                }
                HStack(spacing: 10) {
                    if expense.receiptURL != nil || !expense.items.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.text.viewfinder")
                            Text(expense.items.isEmpty ? "Receipt" : "Receipt • \(expense.items.count) item\(expense.items.count == 1 ? "" : "s")")
                        }
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                    }
                    let commentCount = trip.comments[expense.id.uuidString]?.count ?? 0
                    if commentCount > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "bubble.left.fill")
                            Text("\(commentCount)")
                        }
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .background(Theme.fieldBackground, in: .rect(cornerRadius: 12))
    }

    private func statColumn(_ title: LocalizedStringKey, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.bold)).foregroundStyle(color)
        }
    }
}

// MARK: - Expense Detail

struct ExpenseDetailView: View {
    @Environment(TripStore.self) private var store
    let tripID: Trip.ID
    let expense: Expense

    @State private var commentText = ""
    @State private var editingExpense: Expense?
    @FocusState private var commentFieldFocused: Bool

    private var trip: Trip? { store.trip(tripID) }

    private var currentExpense: Expense? {
        trip?.expenses.first { $0.id == expense.id }
    }

    private var comments: [ExpenseComment] {
        trip?.comments[expense.id.uuidString] ?? []
    }

    private var canModify: Bool {
        guard let trip else { return false }
        return store.isCreator(of: trip) || expense.payerID == store.currentUser.id
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: Theme.sheetGradient,
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 18) {
                    summaryCard
                    receiptItemsCard
                    if let trip { participantsCard(trip) }
                    commentsCard
                }
                .padding()
                .padding(.bottom, 24)
            }
        }
        .navigationTitle(expense.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if canModify {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Edit") { editingExpense = currentExpense ?? expense }
                }
            }
        }
        .sheet(item: $editingExpense) { exp in
            AddExpenseView(tripID: tripID, editing: exp)
        }
    }

    private var summaryCard: some View {
        let exp = currentExpense ?? expense
        let payer = trip?.members.first { $0.id == exp.payerID }
        let me = store.currentUser.id

        return TripCard(title: "Details", icon: "info.circle.fill") {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(money(exp.amount, trip?.currencyCode ?? "USD"))
                        .font(.system(size: 28, weight: .bold))
                    Text(exp.date.formatted(date: .long, time: .omitted))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider()

            HStack(spacing: 10) {
                if let payer {
                    avatar(payer, size: 30)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Paid by").font(.caption).foregroundStyle(.secondary)
                    Text(LocalizedStringKey(payer.map { $0.id == me ? "You" : $0.name } ?? "—"))
                        .font(.subheadline.weight(.semibold))
                }
                Spacer()
            }

            if exp.receiptURL != nil || !exp.items.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text.viewfinder")
                    Text(exp.items.isEmpty ? "Receipt attached" : "Receipt • \(exp.items.count) item\(exp.items.count == 1 ? "" : "s")")
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            }
        }
    }

    /// The scanned/entered line items with their prices, plus tax/tip and a total, so the
    /// breakdown behind an itemized expense is visible instead of just an item count.
    @ViewBuilder
    private var receiptItemsCard: some View {
        let exp = currentExpense ?? expense
        let currency = trip?.currencyCode ?? "USD"
        if !exp.items.isEmpty {
            TripCard(title: "Receipt Items", icon: "list.bullet.rectangle.fill") {
                ForEach(exp.items) { item in
                    HStack(spacing: 10) {
                        Text(item.name)
                            .font(.subheadline)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(money(item.price, currency))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }

                if exp.tax > 0 || exp.tip > 0 {
                    Divider()
                    if exp.tax > 0 { receiptTotalRow(label: "Tax", value: money(exp.tax, currency)) }
                    if exp.tip > 0 { receiptTotalRow(label: "Tip", value: money(exp.tip, currency)) }
                }

                Divider()
                receiptTotalRow(label: "Total", value: money(exp.amount, currency), emphasized: true)
            }
        }
    }

    private func receiptTotalRow(label: LocalizedStringKey, value: String, emphasized: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(emphasized ? .subheadline.weight(.semibold) : .subheadline)
                .foregroundStyle(emphasized ? .primary : .secondary)
            Spacer()
            Text(value)
                .font(emphasized ? .subheadline.weight(.bold) : .subheadline.weight(.medium))
                .foregroundStyle(emphasized ? .primary : .secondary)
                .monospacedDigit()
        }
    }

    private func participantsCard(_ trip: Trip) -> some View {
        let exp = currentExpense ?? expense
        let me = store.currentUser.id

        return TripCard(title: "Split", icon: "person.2.fill") {
            ForEach(trip.members) { member in
                let share = trip.share(for: member.id, in: exp)
                if share > 0.005 {
                    HStack(spacing: 10) {
                        avatar(member, size: 30)
                        Text(LocalizedStringKey(member.id == me ? "You" : member.name))
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        Text(money(share, trip.currencyCode))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var commentsCard: some View {
        TripCard(title: "Comments (\(comments.count))", icon: "bubble.left.and.bubble.right.fill") {
            if comments.isEmpty {
                Text("No comments yet")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                ForEach(comments) { comment in
                    commentRow(comment)
                    if comment.id != comments.last?.id {
                        Divider()
                    }
                }
            }

            Divider()

            HStack(spacing: 10) {
                TextField("Add a comment…", text: $commentText, axis: .vertical)
                    .lineLimit(1...4)
                    .font(.subheadline)
                    .focused($commentFieldFocused)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Theme.fieldBackground, in: .rect(cornerRadius: 12))

                Button {
                    addComment()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .disabled(commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.4 : 1)
            }
        }
    }

    private func commentRow(_ comment: ExpenseComment) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                let member = trip?.members.first { $0.id == comment.authorID }
                if let member {
                    avatar(member, size: 24)
                }
                Text(LocalizedStringKey(comment.authorID == store.currentUser.id ? "You" : comment.authorName))
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(comment.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                if comment.authorID == store.currentUser.id || (trip.map { store.isCreator(of: $0) } ?? false) {
                    Button {
                        store.deleteComment(comment.id, from: expense.id, in: tripID)
                    } label: {
                        Image(systemName: "trash")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            Text(comment.text)
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
    }

    private func addComment() {
        let text = commentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        store.addComment(text, to: expense.id, in: tripID)
        commentText = ""
        commentFieldFocused = false
    }
}

// MARK: - Add Expense

/// A sheet for logging an expense. The trip owner may assign any local participant as
/// payer and choose who shares it.
struct AddExpenseView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(TripStore.self) private var store
    let tripID: Trip.ID
    /// When set, the sheet edits this expense in place instead of creating a new one.
    var editing: Expense? = nil

    @State private var title = ""
    @State private var amountText = ""
    @State private var date = Date()

    // Split configuration (mirrors the capstone's per-method split: equal/all,
    // equal/selected, single-payer, percentage, by-amount).
    @State private var method: SplitMethod = .equalAll
    @State private var selected: Set<Person.ID> = []
    @State private var noSplitAssignee: Person.ID?
    @State private var percentages: [Person.ID: Double] = [:]
    @State private var amounts: [Person.ID: Double] = [:]

    // Receipt scanning + upload.
    @State private var expenseID = UUID()
    @State private var receiptPick: PhotosPickerItem?
    @State private var receiptImage: UIImage?
    @State private var items: [ReceiptItem] = []
    @State private var receiptURL: String?
    @State private var isScanning = false
    @State private var isUploading = false
    @State private var configuringIndex: Int?
    @State private var showCamera = false
    @State private var taxText = ""
    @State private var tipText = ""
    @State private var uploadError: String?
    @State private var isSaving = false
    /// When false (default) the expense only covers the current user's share.
    /// Toggling true unlocks the full split-method picker and per-item configuration.
    @State private var payForOthers = false
    /// Who fronted the expense. `nil` falls back to the current user; the creator (or any
    /// invited member when the trip allows it) can switch this to another member.
    @State private var selectedPayerID: Person.ID?
    /// Removed items kept so a deletion can be undone (most-recent first).
    @State private var removedItems: [(item: ReceiptItem, index: Int)] = []

    private var isEditing: Bool { editing != nil }
    private var trip: Trip? { store.trip(tripID) }
    private var isCreator: Bool { trip.map { store.isCreator(of: $0) } ?? false }

    private var total: Double { Double(amountText) ?? 0 }
    private var resolvedPayer: Person.ID { selectedPayerID ?? store.currentUser.id }

    /// The creator can always record an expense paid by another member; other (invited)
    /// members can only when the trip's `allowMembersToPayForOthers` permission is on.
    private var canChoosePayer: Bool {
        isCreator || (trip?.allowMembersToPayForOthers ?? false)
    }

    /// Live split computation, reused for validation, the per-person preview, and save.
    private func result(for trip: Trip) -> SplitResult {
        SplitEngine.calculate(
            total: total,
            method: method,
            people: trip.members,
            payer: resolvedPayer,
            selected: selected,
            noSplitAssignee: noSplitAssignee ?? resolvedPayer,
            percentages: percentages,
            amounts: amounts
        )
    }

    private func canSave(_ trip: Trip) -> Bool {
        if !items.isEmpty {
            return itemsTotal > 0 && allocatedShares(trip).valid
        }
        return total > 0 && result(for: trip).isValid
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: Theme.sheetGradient,
                    startPoint: .top, endPoint: .bottom
                )
                .ignoresSafeArea()

                if let trip {
                    ScrollView {
                        VStack(spacing: 18) {
                            if !isEditing {
                                OneTimeTipBanner(
                                    key: "tipScanReceiptDismissed",
                                    icon: "doc.text.viewfinder",
                                    message: "Skip the typing: scan the receipt with the Camera button below and the items, tax, and tip fill in automatically."
                                )
                            }
                            amountCard(trip)
                            payerCard(trip)
                            receiptCard(trip)
                            if items.isEmpty {
                                splitCard(trip)
                            } else {
                                taxTipCard(trip)
                                itemSplitsCard(trip)
                            }
                        }
                        .padding()
                        .padding(.bottom, 24)
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Expense" : "Add Expense")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") { Task { await save() } }
                            .disabled(!(trip.map(canSave) ?? false))
                    }
                }
            }
            .onAppear(perform: configureDefaults)
            // In itemized mode the expense total is item prices + tax + tip; keep the
            // amount field in lockstep instead of asking the user to copy it over.
            .onChange(of: grandTotal) {
                if !items.isEmpty { amountText = formatted(grandTotal) }
            }
            .onChange(of: receiptPick) { _, newValue in
                guard let newValue else { return }
                Task { await handlePickedReceipt(newValue) }
            }
            .fullScreenCover(isPresented: $showCamera) {
                DocumentCameraView { image in
                    showCamera = false
                    guard let image else { return }
                    Task { await processReceipt(image, originalData: nil) }
                }
                .ignoresSafeArea()
            }
            .sheet(isPresented: Binding(
                get: { configuringIndex != nil },
                set: { if !$0 { configuringIndex = nil } }
            )) {
                if let index = configuringIndex, items.indices.contains(index), let trip {
                    ItemSplitConfigView(
                        item: $items[index],
                        members: trip.members,
                        payer: resolvedPayer,
                        currencyCode: trip.currencyCode,
                        currentUserID: store.currentUser.id
                    )
                }
            }
        }
    }

    // MARK: Receipt

    private func receiptCard(_ trip: Trip) -> some View {
        TripCard(title: "Receipt & Items", icon: "doc.text.viewfinder") {
            if receiptImage == nil && items.isEmpty && removedItems.isEmpty {
                Text("Scan a receipt to fill in the items and total for you.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let receiptImage {
                Image(uiImage: receiptImage)
                    .resizable().scaledToFill()
                    .frame(maxWidth: .infinity).frame(height: 150)
                    .clipped()
                    .clipShape(.rect(cornerRadius: 12))
            }

            HStack(spacing: 10) {
                if VNDocumentCameraViewController.isSupported {
                    Button {
                        showCamera = true
                    } label: {
                        receiptActionLabel(icon: "camera.fill", title: "Camera")
                    }
                    .buttonStyle(.plain)
                }

                PhotosPicker(selection: $receiptPick, matching: .images) {
                    receiptActionLabel(
                        icon: receiptImage == nil ? "photo.on.rectangle" : "arrow.triangle.2.circlepath",
                        title: receiptImage == nil ? "Library" : "Replace"
                    )
                }
                .buttonStyle(.plain)
            }

            if isScanning {
                HStack(spacing: 6) {
                    ProgressView()
                    Text("Scanning…").font(.caption).foregroundStyle(.secondary)
                }
            } else if isUploading {
                HStack(spacing: 6) {
                    ProgressView()
                    Text("Uploading…").font(.caption).foregroundStyle(.secondary)
                }
            } else if let uploadError {
                VStack(alignment: .leading, spacing: 6) {
                    Label(uploadError, systemImage: "exclamationmark.icloud.fill")
                        .font(.caption).foregroundStyle(Theme.negative)
                    if let receiptImage {
                        Button("Retry upload") {
                            Task { await uploadReceipt(receiptImage, originalData: nil) }
                        }
                        .font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                        .buttonStyle(.plain)
                    }
                }
            } else if receiptURL != nil {
                Label("Receipt photo saved", systemImage: "checkmark.icloud.fill")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if !items.isEmpty || !removedItems.isEmpty {
                itemsEditor(trip)
            } else if receiptImage != nil && !isScanning {
                Text("No items detected — enter the amount manually below.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            // Quiet entry point into itemized mode without a scan: one tap adds a first
            // blank line and the editor (plus tax/tip and per-item splits) appears.
            if items.isEmpty && removedItems.isEmpty && !isScanning {
                Button {
                    withAnimation(.snappy) { addBlankItem(trip) }
                } label: {
                    Label("Or add items manually", systemImage: "plus.circle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func receiptActionLabel(icon: String, title: LocalizedStringKey) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
            Text(title).font(.subheadline.weight(.semibold))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Theme.fieldBackground, in: .rect(cornerRadius: 12))
    }

    private func itemsEditor(_ trip: Trip) -> some View {
        VStack(spacing: 8) {
            HStack {
                Text("Items (\(items.count))").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("Total \(money(itemsTotal, trip.currencyCode))").font(.caption.weight(.semibold))
            }
            ForEach($items) { $item in
                HStack(spacing: 8) {
                    TextField("Item", text: $item.name)
                        .font(.subheadline)
                    Spacer(minLength: 6)
                    Text(currencySymbol(trip.currencyCode)).font(.subheadline).foregroundStyle(.secondary)
                    TextField("0.00", value: $item.price, format: .number.precision(.fractionLength(2)))
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 64)
                    Button {
                        removeItem(item)
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Theme.fieldBackground, in: .rect(cornerRadius: 10))
            }

            HStack {
                Button {
                    addBlankItem(trip)
                } label: {
                    Label("Add item", systemImage: "plus.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)

                Spacer()

                if let last = removedItems.first {
                    Button {
                        undoRemove()
                    } label: {
                        Label("Undo \"\(last.item.name)\"", systemImage: "arrow.uturn.backward")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                }
            }

        }
    }

    /// Removes an item, remembering it (and its position) so the removal can be undone.
    private func removeItem(_ item: ReceiptItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        removedItems.insert((item, index), at: 0)
        items.remove(at: index)
        amountText = formatted(grandTotal)
    }

    /// Restores the most recently removed item to its original position.
    private func undoRemove() {
        guard let restored = removedItems.first else { return }
        removedItems.removeFirst()
        let index = min(restored.index, items.count)
        items.insert(restored.item, at: index)
        amountText = formatted(grandTotal)
    }

    /// Appends a blank item the user can fill in for something the scan missed.
    private func addBlankItem(_ trip: Trip) {
        var item = ReceiptItem(name: "", price: 0)
        if payForOthers {
            item.splitMethod = .equalAll
            item.participantIDs = Set(trip.members.map(\.id))
        } else {
            item.splitMethod = .equalSelected
            item.participantIDs = [store.currentUser.id]
        }
        items.append(item)
    }

    private var itemsTotal: Double {
        SplitEngine.roundToTwo(items.reduce(0) { $0 + $1.price })
    }

    private var taxAmount: Double { max(0, Double(taxText) ?? 0) }
    private var tipAmount: Double { max(0, Double(tipText) ?? 0) }
    private var extras: Double { SplitEngine.roundToTwo(taxAmount + tipAmount) }
    /// Items subtotal plus tax and tip — the amount actually charged.
    private var grandTotal: Double { SplitEngine.roundToTwo(itemsTotal + extras) }

    @MainActor
    private func handlePickedReceipt(_ pick: PhotosPickerItem) async {
        guard let data = try? await pick.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else { return }
        await processReceipt(image, originalData: data)
    }

    /// Scans an image (from the photo picker or the live camera), populates the editable
    /// item list plus any detected tax/tip, and uploads the photo in the background.
    @MainActor
    private func processReceipt(_ image: UIImage, originalData: Data?) async {
        receiptImage = image

        // A freshly picked/replaced photo invalidates the previous scan and upload. Clear
        // the old upload state so the scanning process starts over AND the new image
        // actually re-uploads — the upload guard (`receiptURL == nil`) otherwise skips the
        // upload whenever a URL was already set, silently persisting the previous photo.
        receiptURL = nil
        uploadError = nil

        isScanning = true
        let scan = await ReceiptScanner.scan(image, accessToken: store.accessToken)
        isScanning = false
        if !scan.items.isEmpty {
            removedItems = []
            let everyone = Set(store.trip(tripID)?.members.map(\.id) ?? [])
            items = scan.items.map { item in
                var configured = item
                if payForOthers {
                    configured.splitMethod = .equalAll
                    configured.participantIDs = everyone
                } else {
                    configured.splitMethod = .equalSelected
                    configured.participantIDs = [store.currentUser.id]
                }
                return configured
            }
            if let tax = scan.tax { taxText = formatted(tax) }
            if let tip = scan.tip { tipText = formatted(tip) }
            amountText = formatted(grandTotal)
        }

        // Upload in the background; the URL is attached on save (and the save path retries
        // if this hasn't finished or failed by the time the user taps Save).
        await uploadReceipt(image, originalData: originalData)
    }

    /// Uploads the current receipt image to Supabase Storage, recording the public URL on
    /// success or a user-facing reason on failure. Safe to call again to retry.
    @MainActor
    private func uploadReceipt(_ image: UIImage, originalData: Data?) async {
        guard receiptURL == nil else { return }
        guard store.accessToken != nil else {
            uploadError = "Sign in to upload the receipt photo."
            return
        }
        let preparedJPEG: Data?
        if let originalData {
            preparedJPEG = await UploadImagePreparation.jpegData(
                from: originalData,
                maxPixelSize: 2_200,
                compressionQuality: 0.72
            )
        } else {
            preparedJPEG = await UploadImagePreparation.jpegData(
                from: image,
                maxPixelSize: 2_200,
                compressionQuality: 0.72
            )
        }
        let jpeg = preparedJPEG ?? originalData ?? Data()
        guard !jpeg.isEmpty else { uploadError = "Couldn't read the receipt image."; return }

        // Lowercase the id: the storage RLS policy compares the leading folder against
        // `auth.uid()::text`, which Postgres renders lowercase, whereas Swift's
        // `uuidString` is uppercase — a mismatch trips "violates row-level security".
        let path = "\(store.currentUser.id.uuidString.lowercased())/\(expenseID.uuidString.lowercased()).jpg"
        isUploading = true
        uploadError = nil
        do {
            receiptURL = try await store.uploadReceipt(jpeg, path: path)
        } catch {
            uploadError = (error as? AuthError)?.message ?? "Receipt upload failed."
        }
        isUploading = false
    }

    // MARK: Amount + payer

    private func amountCard(_ trip: Trip) -> some View {
        TripCard(title: "Expense", icon: "dollarsign.circle.fill") {
            TextField("Title (e.g. Dinner)", text: $title)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(Theme.fieldBackground, in: .rect(cornerRadius: 12))

            HStack(spacing: 2) {
                Text(currencySymbol(trip.currencyCode)).foregroundStyle(.secondary)
                TextField("0.00", text: $amountText)
                    .keyboardType(.decimalPad)
                    .disabled(!items.isEmpty)
            }
            .font(.title3.weight(.semibold))
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(Theme.fieldBackground, in: .rect(cornerRadius: 12))

            if !items.isEmpty {
                Text("Total is calculated from the items, tax, and tip below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            DatePicker("Date", selection: $date, displayedComponents: .date)
                .font(.subheadline)
        }
    }

    private func payerCard(_ trip: Trip) -> some View {
        let payer = trip.members.first { $0.id == resolvedPayer } ?? store.currentUser
        let isMe = payer.id == store.currentUser.id
        return TripCard(title: "Paid by", icon: "creditcard.fill") {
            if canChoosePayer {
                Menu {
                    ForEach(trip.members) { member in
                        Button {
                            selectedPayerID = member.id
                        } label: {
                            let label = LocalizedStringKey(member.id == store.currentUser.id ? "You" : member.name)
                            if member.id == resolvedPayer {
                                Label(label, systemImage: "checkmark")
                            } else {
                                Text(label)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 10) {
                        avatar(payer, size: 30)
                        Text(LocalizedStringKey(isMe ? "You" : payer.name)).font(.subheadline.weight(.medium))
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Theme.fieldBackground, in: .rect(cornerRadius: 12))
                }
            } else {
                HStack {
                    avatar(payer, size: 30)
                    Text(LocalizedStringKey(isMe ? "You" : payer.name)).font(.subheadline.weight(.medium))
                    Spacer()
                }
            }
        }
    }

    // MARK: Split

    private func splitCard(_ trip: Trip) -> some View {
        let outcome = result(for: trip)
        return TripCard(title: "Split", icon: "divide.circle.fill") {
            payForOthersButton(trip)

            if payForOthers {
                Menu {
                    ForEach(SplitMethod.allCases) { option in
                        Button {
                            method = option
                            configureForMethod(trip)
                        } label: {
                            Label(LocalizedStringKey(option.rawValue), systemImage: option.icon)
                        }
                    }
                } label: {
                    HStack {
                        Image(systemName: method.icon)
                        Text(LocalizedStringKey(method.rawValue)).font(.subheadline.weight(.semibold))
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .background(Theme.fieldBackground, in: .rect(cornerRadius: 12))
                }

                switch method {
                case .equalAll:
                    Text("Split equally across all \(trip.members.count) member\(trip.members.count == 1 ? "" : "s").")
                        .font(.caption).foregroundStyle(.secondary)
                case .equalSelected:
                    memberToggleList(trip)
                case .noSplit:
                    singlePayerList(trip)
                case .percentage:
                    valueFields(trip, unit: "%", values: $percentages)
                case .amount:
                    valueFields(trip, unit: currencySymbol(trip.currencyCode), values: $amounts)
                }
            }

            if let message = outcome.message, !outcome.isValid {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.negative)
            }

            sharePreview(trip, outcome)
        }
    }

    /// Toggle button that switches between "just me" and "pay for others" modes.
    private func payForOthersButton(_ trip: Trip) -> some View {
        Button {
            withAnimation(.snappy) {
                payForOthers.toggle()
                if payForOthers {
                    method = .equalAll
                    configureForMethod(trip)
                    if !items.isEmpty {
                        let everyone = Set(trip.members.map(\.id))
                        items = items.map {
                            var u = $0
                            u.splitMethod = .equalAll
                            u.participantIDs = everyone
                            return u
                        }
                        amountText = formatted(grandTotal)
                    }
                } else {
                    method = .noSplit
                    noSplitAssignee = store.currentUser.id
                    if !items.isEmpty {
                        items = items.map {
                            var u = $0
                            u.splitMethod = .equalSelected
                            u.participantIDs = [store.currentUser.id]
                            return u
                        }
                        amountText = formatted(grandTotal)
                    }
                }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: payForOthers ? "checkmark.square.fill" : "square")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pay for others")
                        .font(.subheadline.weight(.semibold))
                    Text(payForOthers ? "Covering other members' expenses" : "Only covering your own share")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func memberToggleList(_ trip: Trip) -> some View {
        ForEach(trip.members) { member in
            Button {
                if selected.contains(member.id) { selected.remove(member.id) }
                else { selected.insert(member.id) }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: selected.contains(member.id) ? "checkmark.square.fill" : "square")
                        .foregroundStyle(Theme.accent)
                    avatar(member, size: 30)
                    Text(LocalizedStringKey(member.id == store.currentUser.id ? "You" : member.name))
                        .font(.subheadline.weight(.medium))
                    Spacer()
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
    }

    private func singlePayerList(_ trip: Trip) -> some View {
        ForEach(trip.members) { member in
            Button {
                noSplitAssignee = member.id
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: (noSplitAssignee ?? resolvedPayer) == member.id ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(Theme.accent)
                    avatar(member, size: 30)
                    Text(LocalizedStringKey(member.id == store.currentUser.id ? "You" : member.name))
                        .font(.subheadline.weight(.medium))
                    Spacer()
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
    }

    private func valueFields(_ trip: Trip, unit: String, values: Binding<[Person.ID: Double]>) -> some View {
        ForEach(trip.members) { member in
            HStack(spacing: 10) {
                avatar(member, size: 30)
                Text(LocalizedStringKey(member.id == store.currentUser.id ? "You" : member.name))
                    .font(.subheadline.weight(.medium))
                Spacer()
                TextField("0", value: Binding(
                    get: { values.wrappedValue[member.id] ?? 0 },
                    set: { values.wrappedValue[member.id] = $0 }
                ), format: .number)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 64)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(Theme.fieldBackground, in: .rect(cornerRadius: 10))
                Text(unit).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private func sharePreview(_ trip: Trip, _ outcome: SplitResult) -> some View {
        VStack(spacing: 4) {
            ForEach(trip.members) { member in
                let owed = outcome.owed[member.id] ?? 0
                if owed > 0.005 {
                    HStack {
                        Text(LocalizedStringKey(member.id == store.currentUser.id ? "You" : member.name))
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(money(owed, trip.currencyCode)).font(.caption.weight(.semibold))
                    }
                }
            }
        }
        .padding(.top, 2)
    }

    private func chip(label: String, selected: Bool, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .padding(.horizontal, 14).padding(.vertical, 9)
        }
        .buttonStyle(.plain)
        .glassEffect(selected ? .regular.tint(color).interactive() : .regular.interactive(), in: .capsule)
    }

    // MARK: Per-item split

    /// Each scanned item carries its own split; the expense total per member is the sum
    /// of that member's share across every item. Mirrors the capstone's per-item model.
    private func perItemShares(_ trip: Trip) -> (shares: [Person.ID: Double], valid: Bool) {
        var totals: [Person.ID: Double] = [:]
        var valid = true
        for item in items {
            let outcome = SplitEngine.calculate(
                total: item.price,
                method: item.splitMethod,
                people: trip.members,
                payer: resolvedPayer,
                selected: item.participantIDs,
                noSplitAssignee: item.soloPayerID ?? resolvedPayer,
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
    private func allocatedShares(_ trip: Trip) -> (shares: [Person.ID: Double], valid: Bool) {
        let base = perItemShares(trip)
        guard extras > 0.005 else { return base }

        let allocation = SplitEngine.allocateProportionally(extras, weights: base.shares)
        var combined = base.shares
        for (id, add) in allocation {
            combined[id] = SplitEngine.roundToTwo((combined[id] ?? 0) + add)
        }
        return (combined, base.valid)
    }

    private func taxTipCard(_ trip: Trip) -> some View {
        TripCard(title: "Tax & tip", icon: "percent") {
            Text("Allocated across items by each person's subtotal.")
                .font(.caption).foregroundStyle(.secondary)
            extraField(trip, title: "Tax", text: $taxText)
            extraField(trip, title: "Tip", text: $tipText)
        }
    }

    private func extraField(_ trip: Trip, title: LocalizedStringKey, text: Binding<String>) -> some View {
        HStack(spacing: 10) {
            Text(title).font(.subheadline.weight(.medium))
            Spacer()
            Text(currencySymbol(trip.currencyCode)).font(.subheadline).foregroundStyle(.secondary)
            TextField("0.00", text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(Theme.fieldBackground, in: .rect(cornerRadius: 10))
        }
    }

    private func itemSplitsCard(_ trip: Trip) -> some View {
        let outcome = allocatedShares(trip)
        return TripCard(title: "Item splits", icon: "list.bullet.indent") {
            payForOthersButton(trip)

            Text("Tap an item to choose how it's split.")
                .font(.caption).foregroundStyle(.secondary)

            ForEach(items.indices, id: \.self) { index in
                let item = items[index]
                Button {
                    if item.splitMethod == .equalSelected && item.participantIDs.isEmpty {
                        items[index].participantIDs = Set(trip.members.map(\.id))
                    }
                    configuringIndex = index
                } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Label(LocalizedStringKey(item.splitMethod.rawValue), systemImage: item.splitMethod.icon)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 6)
                        Text(money(item.price, trip.currencyCode)).font(.subheadline.weight(.semibold))
                        Image(systemName: "slider.horizontal.3").foregroundStyle(Theme.accent)
                    }
                    .contentShape(.rect)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(Theme.fieldBackground, in: .rect(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }

            if !outcome.valid {
                Label("Some items still need a valid split.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.medium)).foregroundStyle(Theme.negative)
            }

            Divider()
            totalRow("Subtotal", itemsTotal, trip)
            if taxAmount > 0.005 { totalRow("Tax", taxAmount, trip) }
            if tipAmount > 0.005 { totalRow("Tip", tipAmount, trip) }
            totalRow("Total", grandTotal, trip, bold: true)

            Divider()
            Text("Each person owes").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(trip.members) { member in
                let owed = outcome.shares[member.id] ?? 0
                if owed > 0.005 {
                    HStack {
                        Text(LocalizedStringKey(member.id == store.currentUser.id ? "You" : member.name))
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(money(owed, trip.currencyCode)).font(.caption.weight(.semibold))
                    }
                }
            }
        }
    }

    private func totalRow(_ label: LocalizedStringKey, _ value: Double, _ trip: Trip, bold: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(bold ? .caption.weight(.bold) : .caption)
                .foregroundStyle(bold ? .primary : .secondary)
            Spacer()
            Text(money(value, trip.currencyCode))
                .font(.caption.weight(bold ? .bold : .semibold))
        }
    }

    // MARK: Defaults + save

    /// Sets sensible defaults when switching split methods.
    private func configureForMethod(_ trip: Trip) {
        switch method {
        case .equalSelected:
            if selected.isEmpty { selected = Set(trip.members.map(\.id)) }
        case .noSplit:
            if noSplitAssignee == nil { noSplitAssignee = resolvedPayer }
        default:
            break
        }
    }

    private func formatted(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)).grouping(.never))
    }

    private func configureDefaults() {
        guard let trip else { return }
        if let editing {
            expenseID = editing.id
            selectedPayerID = editing.payerID
            title = editing.title
            amountText = formatted(editing.amount)
            date = editing.date
            items = editing.items
            receiptURL = editing.receiptURL
            selected = editing.participantIDs
            if editing.tax > 0 { taxText = formatted(editing.tax) }
            if editing.tip > 0 { tipText = formatted(editing.tip) }
            // Reconstruct an editable split from the stored per-member shares.
            if !editing.shares.isEmpty {
                method = .amount
                amounts = editing.shares
            }
            // Restore "pay for others" if anyone besides the current user was included.
            let me = store.currentUser.id
            payForOthers = editing.participantIDs.contains(where: { $0 != me })
                || editing.shares.keys.contains(where: { $0 != me })
            return
        }
        // Default: the user only covers their own share, paid by themselves.
        selectedPayerID = store.currentUser.id
        payForOthers = false
        method = .noSplit
        noSplitAssignee = store.currentUser.id
        if selected.isEmpty { selected = Set(trip.members.map(\.id)) }
    }

    @MainActor
    private func save() async {
        guard let trip else { return }

        // If a receipt photo was captured but its upload hasn't landed (still in flight,
        // or failed earlier), make one more attempt so the URL is attached before saving.
        // The expense is saved regardless — the photo is optional, the split data isn't.
        if let receiptImage, receiptURL == nil {
            isSaving = true
            await uploadReceipt(receiptImage, originalData: nil)
            isSaving = false
        }

        // When the receipt has items, the total and split come from the per-item config;
        // otherwise they come from the single expense-level split.
        let amountToSave: Double
        let shares: [Person.ID: Double]
        if items.isEmpty {
            let outcome = result(for: trip)
            guard total > 0, outcome.isValid else { return }
            amountToSave = total
            shares = outcome.owed.filter { $0.value > 0.005 }
        } else {
            let outcome = allocatedShares(trip)
            guard itemsTotal > 0, outcome.valid else { return }
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
            updated.payerID = resolvedPayer
            updated.participantIDs = participantIDs
            updated.date = date
            updated.shares = shares
            updated.items = items
            updated.receiptURL = receiptURL ?? editing.receiptURL
            updated.tax = savedTax
            updated.tip = savedTip
            store.updateExpense(updated, in: trip.id)
        } else {
            let expense = Expense(
                id: expenseID,
                title: resolvedTitle,
                amount: amountToSave,
                payerID: resolvedPayer,
                participantIDs: participantIDs,
                date: date,
                shares: shares,
                receiptURL: receiptURL,
                items: items,
                tax: savedTax,
                tip: savedTip
            )
            store.addExpense(expense, to: trip.id)
        }
        dismiss()
    }
}

// MARK: - Per-item split configuration

/// Configures how a single receipt item is split (equal/all, equal/selected,
/// single-payer, percentage, or by amount). Edits write straight back into the bound
/// `ReceiptItem`; the parent aggregates each item's shares into the expense total.
struct ItemSplitConfigView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var item: ReceiptItem
    let members: [Person]
    let payer: Person.ID
    let currencyCode: String
    let currentUserID: Person.ID

    private var outcome: SplitResult {
        SplitEngine.calculate(
            total: item.price,
            method: item.splitMethod,
            people: members,
            payer: payer,
            selected: item.participantIDs,
            noSplitAssignee: item.soloPayerID ?? payer,
            percentages: item.percentages,
            amounts: item.amounts
        )
    }

    private func name(_ member: Person) -> String { member.id == currentUserID ? "You" : member.name }

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(colors: Theme.sheetGradient, startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 18) {
                        TripCard(title: LocalizedStringKey(item.name), icon: "tag.fill") {
                            HStack {
                                Text("Item total").font(.subheadline).foregroundStyle(.secondary)
                                Spacer()
                                Text(money(item.price, currencyCode)).font(.subheadline.weight(.bold))
                            }
                        }
                        methodCard
                    }
                    .padding()
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("Split item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.disabled(!outcome.isValid)
                }
            }
        }
    }

    private var methodCard: some View {
        TripCard(title: "Split", icon: "divide.circle.fill") {
            Menu {
                ForEach(SplitMethod.allCases) { option in
                    Button {
                        item.splitMethod = option
                        if option == .equalSelected && item.participantIDs.isEmpty {
                            item.participantIDs = Set(members.map(\.id))
                        }
                        if option == .noSplit && item.soloPayerID == nil {
                            item.soloPayerID = payer
                        }
                    } label: {
                        Label(LocalizedStringKey(option.rawValue), systemImage: option.icon)
                    }
                }
            } label: {
                HStack {
                    Image(systemName: item.splitMethod.icon)
                    Text(LocalizedStringKey(item.splitMethod.rawValue)).font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary)
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(Theme.fieldBackground, in: .rect(cornerRadius: 12))
            }

            switch item.splitMethod {
            case .equalAll:
                Text("Split equally across all \(members.count) member\(members.count == 1 ? "" : "s").")
                    .font(.caption).foregroundStyle(.secondary)
            case .equalSelected:
                ForEach(members) { member in
                    Button {
                        if item.participantIDs.contains(member.id) { item.participantIDs.remove(member.id) }
                        else { item.participantIDs.insert(member.id) }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: item.participantIDs.contains(member.id) ? "checkmark.square.fill" : "square")
                                .foregroundStyle(Theme.accent)
                            avatar(member, size: 30)
                            Text(LocalizedStringKey(name(member))).font(.subheadline.weight(.medium))
                            Spacer()
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            case .noSplit:
                ForEach(members) { member in
                    Button { item.soloPayerID = member.id } label: {
                        HStack(spacing: 12) {
                            Image(systemName: (item.soloPayerID ?? payer) == member.id ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(Theme.accent)
                            avatar(member, size: 30)
                            Text(LocalizedStringKey(name(member))).font(.subheadline.weight(.medium))
                            Spacer()
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            case .percentage:
                valueFields(unit: "%", values: $item.percentages)
            case .amount:
                valueFields(unit: currencySymbol(currencyCode), values: $item.amounts)
            }

            if let message = outcome.message, !outcome.isValid {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.medium)).foregroundStyle(Theme.negative)
            }

            ForEach(members) { member in
                let owed = outcome.owed[member.id] ?? 0
                if owed > 0.005 {
                    HStack {
                        Text(LocalizedStringKey(name(member))).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(money(owed, currencyCode)).font(.caption.weight(.semibold))
                    }
                }
            }
        }
    }

    private func valueFields(unit: String, values: Binding<[Person.ID: Double]>) -> some View {
        ForEach(members) { member in
            HStack(spacing: 10) {
                avatar(member, size: 30)
                Text(LocalizedStringKey(name(member))).font(.subheadline.weight(.medium))
                Spacer()
                TextField("0", value: Binding(
                    get: { values.wrappedValue[member.id] ?? 0 },
                    set: { values.wrappedValue[member.id] = $0 }
                ), format: .number)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 64)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(Theme.fieldBackground, in: .rect(cornerRadius: 10))
                Text(unit).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Shared pieces

/// One button revealed by swiping a `SwipeActionsRow` left.
struct RowSwipeAction: Identifiable {
    let id = UUID()
    /// Accessibility name for the action (e.g. "Delete", "Archive").
    let label: LocalizedStringKey
    let icon: String
    let tint: Color
    let handler: () -> Void
}

/// A row wrapper that reveals action buttons when swiped left, giving the app's custom
/// card rows the `List` swipe-actions affordance without adopting `List`. Actions are
/// ordered inner → outer; the outermost (last) one hugs the screen edge and also fires
/// on a Mail-style full swipe. A flick opens/closes the row even short of halfway, and
/// tapping an open row closes it instead of activating the row's own button.
struct SwipeActionsRow<Content: View>: View {
    let actions: [RowSwipeAction]
    @ViewBuilder var content: Content

    @State private var offset: CGFloat = 0
    @State private var startOffset: CGFloat = 0
    @State private var rowWidth: CGFloat = 0
    /// Dragged far enough that releasing fires the edge action.
    @State private var isPastFullSwipe = false
    private let actionWidth: CGFloat = 76
    private let settle = Animation.spring(response: 0.3, dampingFraction: 0.8)

    private var openWidth: CGFloat { CGFloat(actions.count) * actionWidth }
    private var fullSwipeThreshold: CGFloat { max(openWidth + 76, rowWidth * 0.55) }

    var body: some View {
        ZStack(alignment: .trailing) {
            // The actions are sized to exactly the swiped-open width and only drawn while
            // open, so they never sit behind (and bleed through) a translucent glass row.
            if offset < 0 {
                actionButtons
            }

            content
                .offset(x: offset)
                .overlay {
                    // First tap on an open row closes it instead of triggering the
                    // row's own tap/navigation.
                    if offset != 0 {
                        Color.clear
                            .contentShape(.rect)
                            .onTapGesture { close() }
                            .offset(x: offset)
                    }
                }
                .highPriorityGesture(drag)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rowWidth = $0 }
    }

    private var actionButtons: some View {
        let revealed = -offset
        return HStack(spacing: isPastFullSwipe ? 0 : 5) {
            ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                let isEdge = index == actions.count - 1
                let width: CGFloat = isPastFullSwipe
                    ? (isEdge ? revealed : 0)
                    : max((revealed - 5 * CGFloat(actions.count - 1)) / CGFloat(actions.count), 0)
                Button {
                    trigger(action)
                } label: {
                    Image(systemName: action.icon)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: width)
                        .frame(maxHeight: .infinity)
                        .background(action.tint, in: .rect(cornerRadius: 20))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(action.label))
            }
        }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                // Only react to predominantly-horizontal drags so vertical
                // scrolling still wins inside the enclosing ScrollView.
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                let travelLimit = rowWidth > 0 ? rowWidth : openWidth
                offset = min(0, max(startOffset + value.translation.width, -travelLimit))
                let nowPast = rowWidth > 0 && offset < -fullSwipeThreshold
                if nowPast != isPastFullSwipe {
                    withAnimation(settle) { isPastFullSwipe = nowPast }
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }
            }
            .onEnded { value in
                if isPastFullSwipe, let edge = actions.last {
                    trigger(edge)
                    return
                }
                // Settle using the projected end point so a quick flick opens or
                // closes the row without needing to drag past halfway.
                let projected = startOffset + value.predictedEndTranslation.width
                let opened = projected < -openWidth / 2
                withAnimation(settle) { offset = opened ? -openWidth : 0 }
                startOffset = opened ? -openWidth : 0
            }
    }

    private func trigger(_ action: RowSwipeAction) {
        close()
        action.handler()
    }

    private func close() {
        withAnimation(settle) {
            offset = 0
            isPastFullSwipe = false
        }
        startOffset = 0
    }
}

/// A `SwipeActionsRow` with the single destructive delete action, preserving the
/// original swipe-to-delete call sites.
struct SwipeToDeleteRow<Content: View>: View {
    let onDelete: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        SwipeActionsRow(actions: [
            RowSwipeAction(label: "Delete", icon: "trash.fill", tint: Theme.negative, handler: onDelete)
        ]) {
            content
        }
    }
}

/// A standard Liquid Glass card with a labeled header, used across the trip screens.
struct TripCard<Content: View>: View {
    let title: LocalizedStringKey
    let icon: String
    @ViewBuilder let content: Content

    init(title: LocalizedStringKey, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon).font(.headline)
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }
}

// MARK: - Location autocomplete

/// Wraps `MKLocalSearchCompleter` — Apple's built-in places autocomplete, which needs no
/// API key and no location permission — to publish place suggestions as the user types a
/// trip destination.
@MainActor
final class PlaceSearchCompleter: NSObject, ObservableObject {
    @Published var suggestions: [MKLocalSearchCompletion] = []
    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        // Bias toward places (cities, regions, landmarks) rather than precise street
        // addresses, which suit a trip destination.
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func update(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            suggestions = []
            return
        }
        completer.queryFragment = trimmed
    }

    func clear() { suggestions = [] }
}

extension PlaceSearchCompleter: MKLocalSearchCompleterDelegate {
    // Completer callbacks are delivered on the main thread, so it's safe to read results
    // and update published state directly via `assumeIsolated`.
    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        MainActor.assumeIsolated { suggestions = completer.results }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        MainActor.assumeIsolated { suggestions = [] }
    }
}

/// A trip-location text field that shows Apple Maps autocomplete suggestions as the user
/// types, filling the field with the chosen place. Used in Add/Edit Trip.
struct LocationField: View {
    @Binding var text: String
    var placeholder = "Location (e.g. Vietnam)"

    @StateObject private var completer = PlaceSearchCompleter()
    @FocusState private var focused: Bool
    /// True while filling the field from a tapped suggestion, so `onChange` doesn't
    /// immediately re-query and reopen the list.
    @State private var isSelecting = false

    private var visibleSuggestions: [MKLocalSearchCompletion] {
        Array(completer.suggestions.prefix(5))
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "mappin.and.ellipse").foregroundStyle(.secondary)
                TextField(placeholder, text: $text)
                    .focused($focused)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                if !text.isEmpty {
                    Button {
                        text = ""
                        completer.clear()
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(Theme.fieldBackground, in: .rect(cornerRadius: 12))

            if focused && !visibleSuggestions.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(visibleSuggestions.enumerated()), id: \.offset) { index, suggestion in
                        Button { select(suggestion) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "mappin.circle.fill")
                                    .foregroundStyle(Theme.accent)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(suggestion.title)
                                        .font(.subheadline).foregroundStyle(.primary)
                                    if !suggestion.subtitle.isEmpty {
                                        Text(suggestion.subtitle)
                                            .font(.caption).foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.vertical, 10)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        if index < visibleSuggestions.count - 1 { Divider() }
                    }
                }
                .background(Theme.fieldBackground, in: .rect(cornerRadius: 12))
            }
        }
        .onChange(of: text) { _, newValue in
            if isSelecting { isSelecting = false; return }
            completer.update(query: newValue)
        }
    }

    private func select(_ suggestion: MKLocalSearchCompletion) {
        isSelecting = true
        text = suggestion.title
        completer.clear()
        focused = false
    }
}

// MARK: - Trip cover

/// The hero image for a trip: the uploaded cover photo if one exists, otherwise a
/// deterministic gradient (seeded by the trip id) topped with a travel glyph, so every
/// trip looks distinct even before a photo is added. Used by the home cards and the
/// trip detail hero header.
struct TripCoverView: View {
    let trip: Trip

    /// Curated cover gradients; one is chosen deterministically per trip.
    private static let palettes: [[UInt32]] = [
        [0x6366F1, 0x8B5CF6, 0xA855F7],
        [0x0EA5E9, 0x2563EB, 0x4338CA],
        [0x10B981, 0x059669, 0x047857],
        [0xF59E0B, 0xEA580C, 0xDC2626],
        [0xEC4899, 0xDB2777, 0x9333EA],
        [0x14B8A6, 0x0D9488, 0x0F766E],
        [0xF43F5E, 0xE11D48, 0xBE123C],
        [0x3B82F6, 0x6366F1, 0x8B5CF6],
    ]

    private var palette: [Color] {
        // Seed from raw UUID bytes, not `hashValue`: String hashing is seeded per launch,
        // so hashValue-based selection re-rolled every cover's gradient on each run (and
        // hashed the string on every render). Byte math is stable and effectively free.
        let bytes = trip.id.uuid
        let index = Int(bytes.0 ^ bytes.7 ^ bytes.15) % Self.palettes.count
        return Self.palettes[index].map { Color(hex: $0) }
    }

    private var gradient: some View {
        LinearGradient(colors: palette, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var body: some View {
        // The gradient is the layout base: it has no intrinsic size, so it always fills
        // exactly the proposed frame. The photo is drawn as an *overlay* — overlays never
        // influence the parent's layout size, so a wide `scaledToFill` image can't make the
        // cover (and the scroll content above it) grow beyond the screen. `.clipped()` then
        // trims the overflow to the cover's bounds.
        gradient
            .overlay { photoOrGlyph }
            .clipped()
    }

    @ViewBuilder
    private var photoOrGlyph: some View {
        if let stored = trip.coverImageURL, !stored.isEmpty {
            CachedStorageImage(path: stored) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .loading:
                    ProgressView().tint(.white)
                case .failure:
                    glyph
                }
            }
        } else {
            glyph
        }
    }

    private var glyph: some View {
        Image(systemName: "airplane.departure")
            .font(.system(size: 44, weight: .semibold))
            .foregroundStyle(.white.opacity(0.28))
    }
}

/// A colored initials avatar for a person (no image — initials only).
private func avatar(_ person: Person, size: CGFloat) -> some View {
    InitialsAvatar(person: person, size: size)
}

/// Soft-tinted initials circle: the member's color as a light wash with tinted
/// initials, instead of a fully saturated disc. Lists full of members read much
/// calmer this way while each person keeps their identifying hue.
struct InitialsAvatar: View {
    let person: Person
    let size: CGFloat

    var body: some View {
        Text(person.initials)
            .font(.system(size: size * 0.4, weight: .bold))
            .foregroundStyle(person.color)
            .frame(width: size, height: size)
            .background(person.color.opacity(0.16), in: .circle)
            .overlay(Circle().strokeBorder(person.color.opacity(0.28), lineWidth: 1))
    }
}

/// Avatar that shows a real photo when available.
/// Priority: local `imageData` (current user) → remote `person.avatarURL` → colored initials.
struct AvatarView: View {
    let person: Person
    var imageData: Data? = nil
    let size: CGFloat

    var body: some View {
        Group {
            if let data = imageData, let ui = UIImage(data: data) {
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(.circle)
            } else if let stored = person.avatarURL, !stored.isEmpty {
                CachedStorageImage(path: stored) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                            .frame(width: size, height: size)
                            .clipShape(.circle)
                    } else {
                        initialsCircle
                    }
                }
            } else {
                initialsCircle
            }
        }
    }

    private var initialsCircle: some View {
        InitialsAvatar(person: person, size: size)
    }
}

/// Formats a value with a currency code's symbol, e.g. `€12.50`.
func money(_ value: Double, _ code: String) -> String {
    "\(currencySymbol(code))\(String(format: "%.2f", value))"
}
