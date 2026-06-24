import SwiftUI
import Observation

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
}

extension Trip {
    /// A member's equal share of one expense (zero if they don't participate).
    func share(for userID: Person.ID, in expense: Expense) -> Double {
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

    /// The user's editable display name and photo, persisted to `UserDefaults`.
    private let profileKey = "tripsplit.profile"
    private struct StoredProfile: Codable {
        var name: String
        var imageData: Data?
    }

    init() {
        let stored = Self.loadProfile(key: profileKey)
        currentUser = Person(name: stored?.name ?? "", color: Color(hex: 0x6366F1))
        profileImageData = stored?.imageData
        trips = []
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

    /// Deletes a trip locally and from the cloud.
    func deleteTrip(_ tripID: Trip.ID) {
        trips.removeAll { $0.id == tripID }
        guard let accessToken else { return }
        Task { try? await TripsRepository.shared.delete(id: tripID, accessToken: accessToken) }
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
        guard let loaded = try? await TripsRepository.shared.fetch(accessToken: accessToken) else { return }
        var healed: [Trip] = []
        var changed: [Trip] = []
        for trip in loaded {
            let anchored = trip.reanchoringCreator(to: currentUser.id)
            healed.append(anchored)
            if anchored.creatorID != trip.creatorID { changed.append(anchored) }
        }
        await MainActor.run { self.trips = healed }
        for trip in changed { persist(trip) }
    }

    /// Pushes a single trip (members, budgets, and expenses) to Supabase.
    private func persist(_ trip: Trip) {
        guard let accessToken else { return }
        Task { try? await TripsRepository.shared.upsert(trip, accessToken: accessToken) }
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

    /// One persisted row: the trip's id plus its JSON payload.
    private struct Row: Decodable { let data: Trip }

    /// Fetches every trip owned by the token's user.
    func fetch(accessToken: String) async throws -> [Trip] {
        let data = try await send("GET", "/rest/v1/trips?select=data&order=updated_at.desc", accessToken: accessToken)
        return (try? decoder.decode([Row].self, from: data))?.map(\.data) ?? []
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
    @State private var participants: Set<Person.ID> = []
    @State private var date = Date()

    private var isEditing: Bool { editing != nil }
    private var trip: Trip? { store.trip(tripID) }
    private var isCreator: Bool { trip.map { store.isCreator(of: $0) } ?? false }

    private var canSave: Bool {
        (Double(amountText) ?? 0) > 0 && !participants.isEmpty
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
                            amountCard(trip)
                            payerCard(trip)
                            participantsCard(trip)
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
                    Button("Save") { save() }.disabled(!canSave)
                }
            }
            .onAppear(perform: configureDefaults)
        }
    }

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

    private func participantsCard(_ trip: Trip) -> some View {
        TripCard(title: "Split between", icon: "person.3.fill") {
            ForEach(trip.members) { member in
                Button {
                    if participants.contains(member.id) { participants.remove(member.id) }
                    else { participants.insert(member.id) }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: participants.contains(member.id) ? "checkmark.square.fill" : "square")
                            .foregroundStyle(Color(hex: 0x6366F1))
                        avatar(member, size: 30)
                        Text(member.id == store.currentUser.id ? "You" : member.name)
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        if participants.contains(member.id), let amount = Double(amountText), !participants.isEmpty {
                            Text(money(SplitEngine.roundToTwo(amount / Double(participants.count)), trip.currencyCode))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
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

    private func configureDefaults() {
        guard let trip else { return }
        if let editing {
            // Prefill once from the expense being edited.
            title = editing.title
            amountText = editing.amount.formatted(.number.precision(.fractionLength(0...2)).grouping(.never))
            payerID = editing.payerID
            participants = editing.participantIDs
            date = editing.date
            return
        }
        if payerID == nil {
            // Creators and members alike default to paying themselves.
            payerID = store.currentUser.id
        }
        if participants.isEmpty {
            participants = Set(trip.members.map(\.id))
        }
    }

    private func save() {
        guard let trip, let amount = Double(amountText), amount > 0, !participants.isEmpty else { return }
        let payer = isCreator ? (payerID ?? store.currentUser.id) : store.currentUser.id
        let resolvedTitle = title.trimmingCharacters(in: .whitespaces).isEmpty ? "Expense" : title
        if let editing {
            var updated = editing
            updated.title = resolvedTitle
            updated.amount = amount
            updated.payerID = payer
            updated.participantIDs = participants
            updated.date = date
            store.updateExpense(updated, in: trip.id)
        } else {
            let expense = Expense(
                title: resolvedTitle,
                amount: amount,
                payerID: payer,
                participantIDs: participants,
                date: date
            )
            store.addExpense(expense, to: trip.id)
        }
        dismiss()
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
            Button(role: .destructive) {
                withAnimation(settle) { offset = 0 }
                startOffset = 0
                onDelete()
            } label: {
                Image(systemName: "trash.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: actionWidth)
                    .frame(maxHeight: .infinity)
            }
            .background(Theme.negative, in: .rect(cornerRadius: 12))

            content
                .offset(x: offset)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 18)
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
