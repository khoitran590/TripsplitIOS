import SwiftUI
import Observation

// MARK: - Trip Models

/// A single expense within a trip. The payer fronts the whole `amount`; everyone in
/// `participantIDs` shares it equally, mirroring TripSplit's equal-split debts.
struct Expense: Identifiable {
    let id = UUID()
    var title: String
    var amount: Double
    var payerID: Person.ID
    var participantIDs: Set<Person.ID>
    var date: Date
}

/// A trip the user creates or belongs to. The `creatorID` may assign expenses to any
/// member; other members can only log expenses they paid themselves.
struct Trip: Identifiable {
    let id = UUID()
    var name: String
    var currencyCode: String
    var creatorID: Person.ID
    var members: [Person]
    var budgets: [Person.ID: Double]
    var expenses: [Expense] = []
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

    /// Exchange rates with base USD (`usdRates["EUR"]` = EUR per 1 USD), used to
    /// convert each trip's currency into USD for the aggregated home card.
    var usdRates: [String: Double] = [:]

    /// Recorded settlement payments, keyed by `"<tripID>|<debtorID>-><creditorID>"`.
    var settlementHistory: [String: [SettlementRecord]] = [:]

    init() {
        currentUser = Person(name: "Benjamin", color: Color(hex: 0x6366F1))
        trips = []
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

    func addTrip(_ trip: Trip) { trips.append(trip) }

    func addExpense(_ expense: Expense, to tripID: Trip.ID) {
        guard let index = trips.firstIndex(where: { $0.id == tripID }) else { return }
        trips[index].expenses.append(expense)
    }

    // MARK: Settlements

    func settleKey(tripID: Trip.ID, _ settlement: Settlement) -> String {
        "\(tripID.uuidString)|\(settlement.from.id.uuidString)->\(settlement.to.id.uuidString)"
    }

    func history(tripID: Trip.ID, for settlement: Settlement) -> [SettlementRecord] {
        settlementHistory[settleKey(tripID: tripID, settlement)] ?? []
    }

    func setHistory(_ records: [SettlementRecord], tripID: Trip.ID, for settlement: Settlement) {
        settlementHistory[settleKey(tripID: tripID, settlement)] = records
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
                    colors: [Color(hex: 0xF8F9FF), Color(.systemBackground)],
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
                .background(.secondary.opacity(0.12), in: .rect(cornerRadius: 12))

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
            .background(.secondary.opacity(0.12), in: .rect(cornerRadius: 12))
        }
    }

    private var membersCard: some View {
        TripCard(title: "Members", icon: "person.2.fill") {
            HStack {
                avatar(store.currentUser, size: 30)
                Text("\(store.currentUser.name) (You · creator)")
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
                    .background(.secondary.opacity(0.12), in: .rect(cornerRadius: 12))
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

    private var trip: Trip? { store.trip(tripID) }

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [Color(hex: 0xF8F9FF), Color(.systemBackground)],
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
                ForEach(trip.expenses) { expense in
                    expenseRow(trip, expense)
                    if expense.id != trip.expenses.last?.id { Divider() }
                }
            }
        }
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
                    .foregroundStyle(expense.payerID == me ? Color(hex: 0x10B981) : Color(hex: 0xEF4444))
            }
        }
        .padding(.vertical, 4)
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

    @State private var title = ""
    @State private var amountText = ""
    @State private var payerID: Person.ID?
    @State private var participants: Set<Person.ID> = []
    @State private var date = Date()

    private var trip: Trip? { store.trip(tripID) }
    private var isCreator: Bool { trip.map { store.isCreator(of: $0) } ?? false }

    private var canSave: Bool {
        (Double(amountText) ?? 0) > 0 && !participants.isEmpty
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [Color(hex: 0xF8F9FF), Color(.systemBackground)],
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
            .navigationTitle("Add Expense")
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
                .background(.secondary.opacity(0.12), in: .rect(cornerRadius: 12))

            HStack(spacing: 2) {
                Text(currencySymbol(trip.currencyCode)).foregroundStyle(.secondary)
                TextField("0.00", text: $amountText)
                    .keyboardType(.decimalPad)
            }
            .font(.title3.weight(.semibold))
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(.secondary.opacity(0.12), in: .rect(cornerRadius: 12))

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
        let expense = Expense(
            title: title.trimmingCharacters(in: .whitespaces).isEmpty ? "Expense" : title,
            amount: amount,
            payerID: payer,
            participantIDs: participants,
            date: date
        )
        store.addExpense(expense, to: trip.id)
        dismiss()
    }
}

// MARK: - Shared pieces

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
