import SwiftUI
import Observation
import PhotosUI
import UIKit
import VisionKit

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
        tip: Double = 0
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
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, amount, payerID, participantIDs, date, shares, receiptURL, items, tax, tip
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

/// A trip the user creates or belongs to. The `creatorID` may assign expenses to any
/// member; other members can only log expenses they paid themselves.
struct Trip: Identifiable, Codable {
    var id = UUID()
    var name: String
    var currencyCode: String
    var creatorID: Person.ID
    var members: [Person]
    var budgets: [Person.ID: Double]
    var expenses: [Expense] = []

    /// Recorded settlement payments toward this trip's debts, keyed by
    /// `"<debtorID>-><creditorID>"`. Stored on the trip so settle-up progress
    /// syncs to the cloud alongside members, budgets, and expenses.
    var settlementRecords: [String: [SettlementRecord]] = [:]

    init(
        id: UUID = UUID(),
        name: String,
        currencyCode: String,
        creatorID: Person.ID,
        members: [Person],
        budgets: [Person.ID: Double],
        expenses: [Expense] = [],
        settlementRecords: [String: [SettlementRecord]] = [:]
    ) {
        self.id = id
        self.name = name
        self.currencyCode = currencyCode
        self.creatorID = creatorID
        self.members = members
        self.budgets = budgets
        self.expenses = expenses
        self.settlementRecords = settlementRecords
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, currencyCode, creatorID, members, budgets, expenses, settlementRecords
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
        settlementRecords = try c.decodeIfPresent([String: [SettlementRecord]].self, forKey: .settlementRecords) ?? [:]
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
    func spent(for userID: Person.ID) -> Double {
        expenses.reduce(0) { $0 + share(for: userID, in: $1) }
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

    /// The minimal set of transfers that settles every member's balance.
    func settlements() -> [Settlement] {
        SplitEngine.settleUp(net: netBalances(), people: members)
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
        copy.expenses = expenses.map { expense in
            var updated = expense
            if updated.payerID == oldID { updated.payerID = newID }
            if updated.participantIDs.remove(oldID) != nil { updated.participantIDs.insert(newID) }
            return updated
        }
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

/// The app's in-memory source of truth for the current user and their trips.
/// All balance figures on the home screen are derived from here.
@Observable
final class TripStore {
    /// The home card always reports in USD, regardless of each trip's own currency.
    static let baseCurrency = "USD"

    var currentUser: Person
    var trips: [Trip]

    /// The signed-in user's profile photo, persisted across launches as JPEG data.
    var profileImageData: Data?

    /// Exchange rates with base USD (`usdRates["EUR"]` = EUR per 1 USD), used to
    /// convert each trip's currency into USD for the aggregated home card.
    var usdRates: [String: Double] = [:]

    /// The signed-in user's Supabase access token. Set by the app when the auth
    /// session changes; persistence to the cloud is skipped while this is nil.
    var accessToken: String?

    /// Live cloud-sync status, surfaced in the UI so failed saves aren't silent.
    enum SyncState: Equatable { case idle, syncing, failed }
    var syncState: SyncState = .idle

    /// IDs of trips deleted locally whose cloud delete hasn't succeeded yet (e.g. the
    /// delete happened offline). Persisted so the deletion survives relaunch, retried on
    /// the next sync, and used to stop `loadFromCloud` from resurrecting them.
    private(set) var pendingDeletions: Set<Trip.ID> = []

    /// The user's editable display name and photo, persisted to `UserDefaults`.
    private let profileKey = "tripsplit.profile"
    private static let pendingDeletionsKey = "tripsplit.pendingDeletions"
    private struct StoredProfile: Codable {
        var name: String
        var imageData: Data?
    }

    init() {
        let stored = Self.loadProfile(key: profileKey)
        currentUser = Person(name: stored?.name ?? "", color: Color(hex: 0x6366F1))
        profileImageData = stored?.imageData
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

    /// Updates the signed-in user's display name and photo, persisting both so they
    /// survive across launches.
    func updateProfile(name: String, imageData: Data?) {
        currentUser.name = name
        profileImageData = imageData
        let stored = StoredProfile(name: name, imageData: imageData)
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: profileKey)
        }
    }

    private static func loadProfile(key: String) -> StoredProfile? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(StoredProfile.self, from: data)
    }

    /// Trips the current user created or is a member of.
    var myTrips: [Trip] {
        trips.filter { trip in trip.members.contains { $0.id == currentUser.id } }
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
            usdRates = rates
        }
    }

    private func aggregate(_ value: (Trip) -> Double) -> Double {
        SplitEngine.roundToTwo(myTrips.reduce(0) { $0 + toUSD(value($1), from: $1.currencyCode) })
    }

    var totalBudget: Double { aggregate { $0.budget(for: currentUser.id) } }
    var totalSpent: Double { aggregate { $0.spent(for: currentUser.id) } }
    var budgetAvailable: Double { SplitEngine.roundToTwo(totalBudget - totalSpent) }
    var totalYouOwe: Double { aggregate { $0.owed(by: currentUser.id) } }
    var totalOwedToYou: Double { aggregate { $0.owed(to: currentUser.id) } }

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

    /// Removes an expense from a trip and syncs the change.
    func deleteExpense(_ expenseID: Expense.ID, from tripID: Trip.ID) {
        guard let index = trips.firstIndex(where: { $0.id == tripID }) else { return }
        trips[index].expenses.removeAll { $0.id == expenseID }
        persist(trips[index])
    }

    /// Replaces a whole trip (name, members, budgets, …) and syncs the change.
    func updateTrip(_ trip: Trip) {
        guard let index = trips.firstIndex(where: { $0.id == trip.id }) else { return }
        trips[index] = trip
        persist(trip)
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
        trips.removeAll { $0.id == tripID }
        pendingDeletions.insert(tripID)
        savePendingDeletions()

        guard let accessToken else { return }
        syncState = .syncing
        Task {
            do {
                try await TripsRepository.shared.delete(id: tripID, accessToken: accessToken)
                await MainActor.run {
                    self.pendingDeletions.remove(tripID)
                    self.savePendingDeletions()
                    self.syncState = .idle
                }
            } catch {
                await MainActor.run { self.syncState = .failed }
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
                try await TripsRepository.shared.delete(id: tripID, accessToken: accessToken)
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

    /// Aligns the in-memory user's identity with their authenticated account, so trip
    /// membership (and every balance figure derived from `currentUser.id`) resolves
    /// consistently across launches and devices. The id is the Supabase user's stable
    /// UUID, read from the access token's `sub` claim — no extra network call, and it
    /// works for already-persisted sessions too.
    func bindIdentity(accessToken: String?) {
        guard let accessToken, let uuid = Self.userID(fromJWT: accessToken) else { return }
        currentUser.id = uuid
    }

    /// Extracts the `sub` (subject = user id) claim from a JWT access token.
    private static func userID(fromJWT token: String) -> UUID? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sub = json["sub"] as? String else { return nil }
        return UUID(uuidString: sub)
    }

    /// Loads the signed-in user's trips from Supabase, replacing the in-memory list.
    /// No-op when signed out (the app stays usable with local-only trips).
    ///
    /// Each row is re-anchored to the current user's stable id so trips created under a
    /// previous (random) local identity still show up and settle correctly. Any trip
    /// that needed re-anchoring is pushed back once so the cloud copy heals itself.
    func loadFromCloud() async {
        guard let accessToken else { return }

        // Retry any queued deletions first so a trip pending deletion can't come back.
        await flushPendingDeletions(accessToken: accessToken)

        // Keep whatever we have if the server is unreachable; only replace on success.
        let loaded: [Trip]
        do { loaded = try await TripsRepository.shared.fetch(accessToken: accessToken) }
        catch { return }
        var healed: [Trip] = []
        var changed: [Trip] = []
        for trip in loaded {
            // Skip trips still queued for deletion (their cloud delete hasn't landed yet).
            if pendingDeletions.contains(trip.id) { continue }
            let anchored = trip.reanchoringCreator(to: currentUser.id)
            healed.append(anchored)
            if anchored.creatorID != trip.creatorID { changed.append(anchored) }
        }
        await MainActor.run { self.trips = healed }
        for trip in changed { persist(trip) }
    }

    /// Pushes a single trip (members, budgets, and expenses) to Supabase, updating
    /// `syncState` so the UI can show progress and surface failures.
    private func persist(_ trip: Trip) {
        guard let accessToken else { return }
        syncState = .syncing
        Task {
            do {
                try await TripsRepository.shared.upsert(trip, accessToken: accessToken)
                await MainActor.run { self.syncState = .idle }
            } catch {
                await MainActor.run { self.syncState = .failed }
            }
        }
    }

    /// Re-pushes every trip to Supabase. Used by the "Retry" action after a failed save.
    func retrySync() {
        guard let accessToken else { return }
        syncState = .syncing
        Task {
            do {
                let deletionsCleared = await flushPendingDeletions(accessToken: accessToken)
                for trip in trips {
                    try await TripsRepository.shared.upsert(trip, accessToken: accessToken)
                }
                await MainActor.run { self.syncState = deletionsCleared ? .idle : .failed }
            } catch {
                await MainActor.run { self.syncState = .failed }
            }
        }
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
}

// MARK: - Trips repository (Supabase PostgREST)

/// Persists trips to a single `trips` table in Supabase, storing each trip as a
/// JSON blob in a `jsonb` column. Row ownership is enforced by RLS via `auth.uid()`,
/// so the client only ever sends the access token — never a user id.
///
/// Run `supabase_schema.sql` (at the repo root) once in the Supabase SQL editor to
/// create the table and its row-level-security policy.
actor TripsRepository {
    static let shared = TripsRepository()

    private let session = URLSession.shared

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

    /// Fetches every trip owned by the token's user. Decodes rows individually so a
    /// single malformed trip can't drop the entire list. Throws only on network/HTTP
    /// failure, letting callers distinguish "couldn't reach the server" from "no trips".
    func fetch(accessToken: String) async throws -> [Trip] {
        let data = try await send("GET", "/rest/v1/trips?select=data&order=updated_at.desc", accessToken: accessToken)
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let dataValue = row["data"],
                  let dataData = try? JSONSerialization.data(withJSONObject: dataValue) else { return nil }
            return try? decoder.decode(Trip.self, from: dataData)
        }
    }

    /// Inserts or updates a trip (keyed on its id) for the token's user.
    func upsert(_ trip: Trip, accessToken: String) async throws {
        // Wrap the encoded trip as the `data` jsonb value alongside its primary key.
        let tripJSON = try JSONSerialization.jsonObject(with: encoder.encode(trip))
        let body = try JSONSerialization.data(withJSONObject: [
            "id": trip.id.uuidString,
            "data": tripJSON,
        ])
        _ = try await send(
            "POST",
            "/rest/v1/trips?on_conflict=id",
            accessToken: accessToken,
            body: body,
            extraHeaders: ["Prefer": "resolution=merge-duplicates,return=minimal"]
        )
    }

    /// Deletes a trip the user owns.
    func delete(id: Trip.ID, accessToken: String) async throws {
        _ = try await send("DELETE", "/rest/v1/trips?id=eq.\(id.uuidString)", accessToken: accessToken)
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

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AuthError(message: "Sync request failed.")
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
let memberPalette: [UInt32] = [0x10B981, 0xF59E0B, 0xEC4899, 0x3B82F6, 0x8B5CF6, 0xEF4444, 0x14B8A6, 0xF97316]

// MARK: - Add Trip

/// A sheet for creating a trip: name, currency, the creator's personal budget, and members.
struct AddTripView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(TripStore.self) private var store

    @State private var name = ""
    @State private var currency = "USD"
    @State private var budgetText = ""
    @State private var memberName = ""
    @State private var members: [Person] = []

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: Theme.sheetGradient,
                    startPoint: .top, endPoint: .bottom
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 18) {
                        detailsCard
                        budgetCard
                        membersCard
                    }
                    .padding()
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("Add Trip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { create() }.disabled(!canCreate)
                }
            }
        }
    }

    private var detailsCard: some View {
        TripCard(title: "Trip details", icon: "suitcase.fill") {
            TextField("Trip name", text: $name)
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Theme.fieldBackground, in: .rect(cornerRadius: 12))

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

    private var membersCard: some View {
        TripCard(title: "Members", icon: "person.2.fill") {
            HStack {
                avatar(store.currentUser, size: 30)
                Text(store.currentUser.name.isEmpty ? "You (creator)" : "\(store.currentUser.name) (You · creator)")
                    .font(.subheadline.weight(.medium))
                Spacer()
            }

            ForEach(members) { member in
                HStack {
                    avatar(member, size: 30)
                    Text(member.name).font(.subheadline.weight(.medium))
                    Spacer()
                    Button {
                        members.removeAll { $0.id == member.id }
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 10) {
                TextField("Add member name", text: $memberName)
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
                .glassEffect(.regular.tint(Color(hex: 0x6366F1)).interactive(), in: .circle)
                .disabled(memberName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
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
        let trip = Trip(
            name: name.trimmingCharacters(in: .whitespaces),
            currencyCode: currency,
            creatorID: me.id,
            members: [me] + members,
            budgets: [me.id: Double(budgetText) ?? 0]
        )
        store.addTrip(trip)
        dismiss()
    }
}

// MARK: - Trip Detail

/// Shows a trip's budget summary, members, and expenses, with an "Add Expense" action.
struct TripDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(TripStore.self) private var store
    let tripID: Trip.ID

    @State private var showAddExpense = false
    @State private var activeSettlement: Settlement?
    @State private var editingExpense: Expense?

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
                    ScrollView {
                        VStack(spacing: 18) {
                            summaryCard(trip)
                            settleCard(trip)
                            membersCard(trip)
                            expensesCard(trip)
                        }
                        .padding()
                        .padding(.bottom, 24)
                    }
                } else {
                    ContentUnavailableView("Trip not found", systemImage: "suitcase")
                }
            }
            .navigationTitle(trip?.name ?? "Trip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        showAddExpense = true
                    } label: {
                        Label("Add Expense", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showAddExpense) {
                AddExpenseView(tripID: tripID)
            }
            .sheet(item: $editingExpense) { expense in
                AddExpenseView(tripID: tripID, editing: expense)
            }
            .sheet(item: $activeSettlement) { settlement in
                SettleView(
                    settlement: settlement,
                    history: historyBinding(for: settlement),
                    currencyCode: trip?.currencyCode ?? "USD"
                )
            }
        }
    }

    private func historyBinding(for settlement: Settlement) -> Binding<[SettlementRecord]> {
        Binding(
            get: { store.history(tripID: tripID, for: settlement) },
            set: { store.setHistory($0, tripID: tripID, for: settlement) }
        )
    }

    @ViewBuilder
    private func settleCard(_ trip: Trip) -> some View {
        let settlements = trip.settlements()
        TripCard(title: "Settle Up", icon: "arrow.left.arrow.right.circle.fill") {
            if settlements.isEmpty {
                Text("All settled up — no transfers needed.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                Text("Tap a transfer to record a payment.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                ForEach(settlements) { settlement in
                    Button {
                        activeSettlement = settlement
                    } label: {
                        settleRow(trip, settlement)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func settleRow(_ trip: Trip, _ settlement: Settlement) -> some View {
        let me = store.currentUser.id
        let fromLabel = settlement.from.id == me ? "You" : settlement.from.name
        let toLabel = settlement.to.id == me ? "you" : settlement.to.name
        return HStack(spacing: 8) {
            avatar(settlement.from, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(fromLabel).fontWeight(.semibold)
                    Image(systemName: "arrow.right")
                        .font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                    Text(toLabel).fontWeight(.semibold)
                }
                .font(.subheadline)
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
            }
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
        }
        .contentShape(.rect)
        .padding(.vertical, 4)
    }

    private func summaryCard(_ trip: Trip) -> some View {
        let me = store.currentUser.id
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Your budget", systemImage: "wallet.bifold.fill")
                    .font(.headline)
                Spacer()
                if store.isCreator(of: trip) {
                    Text("Creator")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color(hex: 0x6366F1))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Color(hex: 0x6366F1).opacity(0.15), in: .capsule)
                }
            }

            Text(money(trip.remainingBudget(for: me), trip.currencyCode))
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(trip.remainingBudget(for: me) < 0 ? Color(hex: 0xEF4444) : .primary)
            Text("remaining of \(money(trip.budget(for: me), trip.currencyCode)) budget")
                .font(.footnote).foregroundStyle(.secondary)

            // Budget-usage bar: fills toward the limit and turns red once exceeded.
            let budgetTotal = trip.budget(for: me)
            if budgetTotal > 0 {
                let fraction = min(trip.spent(for: me) / budgetTotal, 1)
                let overBudget = trip.spent(for: me) > budgetTotal
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.fieldBackground)
                        Capsule()
                            .fill(overBudget ? Theme.negative : Theme.positive)
                            .frame(width: max(0, geo.size.width * fraction))
                    }
                }
                .frame(height: 8)
            }

            Divider()

            HStack {
                statColumn("Spent", money(trip.spent(for: me), trip.currencyCode), .primary)
                Spacer()
                statColumn("You owe", money(trip.owed(by: me), trip.currencyCode), Color(hex: 0xEF4444))
                Spacer()
                statColumn("You're owed", money(trip.owed(to: me), trip.currencyCode), Color(hex: 0x10B981))
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }

    private func membersCard(_ trip: Trip) -> some View {
        TripCard(title: "Members (\(trip.members.count))", icon: "person.2.fill") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(trip.members) { member in
                        VStack(spacing: 6) {
                            avatar(member, size: 40)
                            Text(member.id == store.currentUser.id ? "You" : member.name)
                                .font(.caption)
                                .lineLimit(1)
                        }
                        .frame(width: 64)
                    }
                }
            }
        }
    }

    private func expensesCard(_ trip: Trip) -> some View {
        TripCard(title: "Expenses (\(trip.expenses.count))", icon: "list.bullet.rectangle.fill") {
            if trip.expenses.isEmpty {
                Text("No expenses yet. Tap Add Expense to log one.")
                    .font(.subheadline).italic()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 8) {
                    ForEach(trip.expenses) { expense in
                        if canModify(trip, expense) {
                            SwipeToDeleteRow {
                                store.deleteExpense(expense.id, from: trip.id)
                            } content: {
                                Button { editingExpense = expense } label: {
                                    expenseRow(trip, expense)
                                }
                                .buttonStyle(.plain)
                            }
                        } else {
                            expenseRow(trip, expense)
                        }
                    }
                }
            }
        }
    }

    /// Whether the signed-in user may edit or delete an expense: the trip creator can
    /// modify any expense; other members can modify only the ones they paid.
    private func canModify(_ trip: Trip, _ expense: Expense) -> Bool {
        store.isCreator(of: trip) || expense.payerID == store.currentUser.id
    }

    private func expenseRow(_ trip: Trip, _ expense: Expense) -> some View {
        let payer = trip.members.first { $0.id == expense.payerID }
        let me = store.currentUser.id
        let yourShare = trip.share(for: me, in: expense)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(expense.title).font(.subheadline.weight(.semibold))
                    Text("Paid by \(payer.map { $0.id == me ? "you" : $0.name } ?? "—") • \(expense.date.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(money(expense.amount, trip.currencyCode))
                    .font(.subheadline.weight(.semibold))
            }
            if expense.participantIDs.contains(me) {
                Text("Your share: \(money(yourShare, trip.currencyCode))")
                    .font(.caption)
                    .foregroundStyle(expense.payerID == me ? Theme.positive : Theme.negative)
            }
            if expense.receiptURL != nil || !expense.items.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "doc.text.viewfinder")
                    Text(expense.items.isEmpty ? "Receipt" : "Receipt • \(expense.items.count) item\(expense.items.count == 1 ? "" : "s")")
                }
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .background(Theme.fieldBackground, in: .rect(cornerRadius: 12))
    }

    private func statColumn(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.bold)).foregroundStyle(color)
        }
    }
}

// MARK: - Add Expense

/// A sheet for logging an expense. The trip creator may assign any member as payer and
/// choose who shares it; other members can only record expenses they paid themselves.
struct AddExpenseView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(TripStore.self) private var store
    let tripID: Trip.ID
    /// When set, the sheet edits this expense in place instead of creating a new one.
    var editing: Expense? = nil

    @State private var title = ""
    @State private var amountText = ""
    @State private var payerID: Person.ID?
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
    /// Removed items kept so a deletion can be undone (most-recent first).
    @State private var removedItems: [(item: ReceiptItem, index: Int)] = []

    private var isEditing: Bool { editing != nil }
    private var trip: Trip? { store.trip(tripID) }
    private var isCreator: Bool { trip.map { store.isCreator(of: $0) } ?? false }

    private var total: Double { Double(amountText) ?? 0 }
    private var resolvedPayer: Person.ID { isCreator ? (payerID ?? store.currentUser.id) : store.currentUser.id }

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
                            receiptCard(trip)
                            amountCard(trip)
                            payerCard(trip)
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
        TripCard(title: "Receipt", icon: "doc.text.viewfinder") {
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
        }
    }

    private func receiptActionLabel(icon: String, title: String) -> some View {
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

            Button {
                amountText = formatted(itemsTotal)
            } label: {
                Text("Use items total (\(money(itemsTotal, trip.currencyCode)))")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
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

    /// Appends a blank item the user can fill in for something the scan missed. It splits
    /// equally across everyone by default, matching freshly scanned items.
    private func addBlankItem(_ trip: Trip) {
        var item = ReceiptItem(name: "", price: 0)
        item.splitMethod = .equalAll
        item.participantIDs = Set(trip.members.map(\.id))
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

        isScanning = true
        let scan = await ReceiptScanner.scan(image)
        isScanning = false
        if !scan.items.isEmpty {
            // Each item starts split equally across everyone; the user can retune any item.
            removedItems = []
            let everyone = Set(store.trip(tripID)?.members.map(\.id) ?? [])
            items = scan.items.map { item in
                var configured = item
                configured.splitMethod = .equalAll
                configured.participantIDs = everyone
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
        guard let token = store.accessToken else {
            uploadError = "Sign in to upload the receipt photo."
            return
        }
        let jpeg = image.jpegData(compressionQuality: 0.7) ?? originalData ?? Data()
        guard !jpeg.isEmpty else { uploadError = "Couldn't read the receipt image."; return }

        // Lowercase the id: the storage RLS policy compares the leading folder against
        // `auth.uid()::text`, which Postgres renders lowercase, whereas Swift's
        // `uuidString` is uppercase — a mismatch trips "violates row-level security".
        let path = "\(store.currentUser.id.uuidString.lowercased())/\(expenseID.uuidString.lowercased()).jpg"
        isUploading = true
        uploadError = nil
        do {
            receiptURL = try await ReceiptStorage.shared.upload(jpeg, path: path, accessToken: token)
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
            }
            .font(.title3.weight(.semibold))
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(Theme.fieldBackground, in: .rect(cornerRadius: 12))

            DatePicker("Date", selection: $date, displayedComponents: .date)
                .font(.subheadline)
        }
    }

    private func payerCard(_ trip: Trip) -> some View {
        TripCard(title: "Paid by", icon: "creditcard.fill") {
            if isCreator {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(trip.members) { member in
                            chip(
                                label: member.id == store.currentUser.id ? "You" : member.name,
                                selected: payerID == member.id,
                                color: member.color
                            ) { payerID = member.id }
                        }
                    }
                }
            } else {
                HStack {
                    avatar(store.currentUser, size: 30)
                    Text("You").font(.subheadline.weight(.medium))
                    Spacer()
                    Text("Only the creator can assign payers.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Split

    private func splitCard(_ trip: Trip) -> some View {
        let outcome = result(for: trip)
        return TripCard(title: "Split", icon: "divide.circle.fill") {
            Menu {
                ForEach(SplitMethod.allCases) { option in
                    Button {
                        method = option
                        configureForMethod(trip)
                    } label: {
                        Label(option.rawValue, systemImage: option.icon)
                    }
                }
            } label: {
                HStack {
                    Image(systemName: method.icon)
                    Text(method.rawValue).font(.subheadline.weight(.semibold))
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

            if let message = outcome.message, !outcome.isValid {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.negative)
            }

            sharePreview(trip, outcome)
        }
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
                    Text(member.id == store.currentUser.id ? "You" : member.name)
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
                    Text(member.id == store.currentUser.id ? "You" : member.name)
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
                Text(member.id == store.currentUser.id ? "You" : member.name)
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
                        Text(member.id == store.currentUser.id ? "You" : member.name)
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

    private func extraField(_ trip: Trip, title: String, text: Binding<String>) -> some View {
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
                            Label(item.splitMethod.rawValue, systemImage: item.splitMethod.icon)
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
                        Text(member.id == store.currentUser.id ? "You" : member.name)
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(money(owed, trip.currencyCode)).font(.caption.weight(.semibold))
                    }
                }
            }
        }
    }

    private func totalRow(_ label: String, _ value: Double, _ trip: Trip, bold: Bool = false) -> some View {
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
            title = editing.title
            amountText = formatted(editing.amount)
            payerID = editing.payerID
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
            return
        }
        if payerID == nil { payerID = store.currentUser.id }
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
                        TripCard(title: item.name, icon: "tag.fill") {
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
                        Label(option.rawValue, systemImage: option.icon)
                    }
                }
            } label: {
                HStack {
                    Image(systemName: item.splitMethod.icon)
                    Text(item.splitMethod.rawValue).font(.subheadline.weight(.semibold))
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
                            Text(name(member)).font(.subheadline.weight(.medium))
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
                            Text(name(member)).font(.subheadline.weight(.medium))
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
                        Text(name(member)).font(.caption).foregroundStyle(.secondary)
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
                Text(name(member)).font(.subheadline.weight(.medium))
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

/// A row wrapper that reveals a destructive delete button when swiped left, giving the
/// app's custom card rows the `List` swipe-to-delete affordance without adopting `List`.
struct SwipeToDeleteRow<Content: View>: View {
    let onDelete: () -> Void
    @ViewBuilder var content: Content

    @State private var offset: CGFloat = 0
    @State private var startOffset: CGFloat = 0
    private let actionWidth: CGFloat = 76
    private let settle = Animation.spring(response: 0.3, dampingFraction: 0.8)

    var body: some View {
        ZStack(alignment: .trailing) {
            // The red action is sized to exactly the swiped-open width and only drawn while
            // open, so it never sits behind (and bleeds through) a translucent glass row.
            if offset < 0 {
                Button(role: .destructive) {
                    withAnimation(settle) { offset = 0 }
                    startOffset = 0
                    onDelete()
                } label: {
                    Image(systemName: "trash.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: min(-offset, actionWidth))
                        .frame(maxHeight: .infinity)
                        .background(Theme.negative, in: .rect(cornerRadius: 20))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }

            content
                .offset(x: offset)
                .highPriorityGesture(
                    DragGesture(minimumDistance: 20)
                        .onChanged { value in
                            // Only react to predominantly-horizontal drags so vertical
                            // scrolling still wins inside the enclosing ScrollView.
                            guard abs(value.translation.width) > abs(value.translation.height) else { return }
                            offset = min(0, max(startOffset + value.translation.width, -actionWidth))
                        }
                        .onEnded { _ in
                            let opened = offset < -actionWidth / 2
                            withAnimation(settle) { offset = opened ? -actionWidth : 0 }
                            startOffset = opened ? -actionWidth : 0
                        }
                )
        }
    }
}

/// A standard Liquid Glass card with a labeled header, used across the trip screens.
struct TripCard<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    init(title: String, icon: String, @ViewBuilder content: () -> Content) {
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

/// A colored initials avatar for a person.
private func avatar(_ person: Person, size: CGFloat) -> some View {
    Text(person.initials)
        .font(.system(size: size * 0.4, weight: .bold))
        .foregroundStyle(.white)
        .frame(width: size, height: size)
        .background(person.color, in: .circle)
}

/// Formats a value with a currency code's symbol, e.g. `€12.50`.
func money(_ value: Double, _ code: String) -> String {
    "\(currencySymbol(code))\(String(format: "%.2f", value))"
}
