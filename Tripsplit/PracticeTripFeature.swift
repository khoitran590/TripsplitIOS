import SwiftUI

/// Value-only sandbox: no auth, repositories, persistence, global caches, or real
/// TripStore. Ending the presentation simply discards this independent value.
struct PracticeTrip {
    var trip: Trip
    var draft: ExpenseDraft

    init() {
        let people = [Person(name: "You", color: .blue), Person(name: "Jamie", color: .orange), Person(name: "Sam", color: .green)]
        trip = Trip(name: "Practice weekend", currencyCode: "USD", creatorID: people[0].id,
                    members: people, budgets: [:], allowMembersToPayForOthers: true)
        draft = ExpenseDraft(trip: trip, currentUserID: people[0].id, startWithFullSplit: true,
                             prefillTitle: "Dinner", prefillAmount: 60)
    }

    mutating func useSampleReceipt() {
        draft = ExpenseDraft(trip: trip, currentUserID: trip.creatorID, startWithFullSplit: true)
        draft.title = "Sample dinner receipt"
        draft.items = [ReceiptItem(name: "Noodles", price: 30), ReceiptItem(name: "Dumplings", price: 12), ReceiptItem(name: "Drinks", price: 9)]
        draft.taxText = "4.08"
        draft.tipText = "7.65"
    }

    @discardableResult mutating func saveExpense() -> Bool {
        guard let expense = draft.preparedExpense(for: trip, currentUserID: trip.creatorID) else { return false }
        trip.expenses.append(expense)
        draft = ExpenseDraft(trip: trip, currentUserID: trip.creatorID, startWithFullSplit: true)
        return true
    }

    mutating func confirmPracticePayment(_ settlement: Settlement) {
        let key = "\(settlement.from.id.uuidString)->\(settlement.to.id.uuidString)"
        trip.settlementRecords[key, default: []].append(
            SettlementRecord(amount: remaining(settlement), method: .cash, note: "Practice only", status: .confirmed, date: Date())
        )
    }

    func remaining(_ settlement: Settlement) -> Double {
        let key = "\(settlement.from.id.uuidString)->\(settlement.to.id.uuidString)"
        let paid = (trip.settlementRecords[key] ?? []).filter { $0.status == .confirmed }.reduce(0) { $0 + $1.amount }
        return max(0, SplitEngine.roundToTwo(settlement.amount - paid))
    }
}

struct PracticeTripView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var practice = PracticeTrip()
    @State private var saved = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Sample data only. Changes stay in this practice trip and are discarded when you exit.")
                }
                Section("1. Add a shared expense") {
                    TextField("Expense name", text: $practice.draft.title)
                    if practice.draft.items.isEmpty {
                        TextField("Amount in USD", text: $practice.draft.amountText).keyboardType(.decimalPad)
                    }
                    Picker("Who paid?", selection: $practice.draft.selectedPayerID) {
                        ForEach(practice.trip.members) { person in
                            Text(verbatim: person.name).tag(Optional(person.id))
                        }
                    }
                    Button("Load sample receipt") { practice.useSampleReceipt(); saved = false }
                        .frame(minHeight: 44)
                    if !practice.draft.items.isEmpty {
                        Text("Review the sample items. Choose who shares each one.")
                        ForEach(practice.draft.items.indices, id: \.self) { index in
                            VStack(alignment: .leading) {
                                Text("\(practice.draft.items[index].name) · \(money(practice.draft.items[index].price, "USD"))")
                                Picker("Shared by", selection: Binding(
                                    get: { practice.draft.items[index].soloPayerID },
                                    set: { id in
                                        practice.draft.items[index].soloPayerID = id
                                        practice.draft.items[index].splitMethod = id == nil ? .equalAll : .noSplit
                                    }
                                )) {
                                    Text("Everyone").tag(Optional<Person.ID>.none)
                                    ForEach(practice.trip.members) { person in Text(verbatim: person.name).tag(Optional(person.id)) }
                                }
                            }
                        }
                        TextField("Tax", text: $practice.draft.taxText).keyboardType(.decimalPad)
                        TextField("Tip", text: $practice.draft.tipText).keyboardType(.decimalPad)
                    }
                }
                Section("2. Check each person's share") {
                    let shares = practice.draft.items.isEmpty
                        ? practice.draft.result(for: practice.trip, currentUserID: practice.trip.creatorID).owed
                        : practice.draft.allocatedShares(practice.trip, currentUserID: practice.trip.creatorID).shares
                    ForEach(practice.trip.members) { person in
                        LabeledContent { Text(verbatim: money(shares[person.id] ?? 0, "USD")) }
                            label: { Text(verbatim: person.name) }
                    }
                    Button("Save practice expense") { saved = practice.saveExpense() }
                        .frame(minHeight: 44)
                        .disabled(!practice.draft.canSave(practice.trip, currentUserID: practice.trip.creatorID))
                    if saved { Text("Expense saved. See who owes whom below.").accessibilityIdentifier("practice-expense-saved") }
                }
                if !practice.trip.expenses.isEmpty {
                    Section("3. See balances and record a repayment") {
                        Text("These suggested payments are practice only. TripSplit records repayments made outside the app.")
                        ForEach(practice.trip.settlements()) { settlement in
                            let remaining = practice.remaining(settlement)
                            VStack(alignment: .leading, spacing: 8) {
                                Text("\(settlement.from.name) owes \(settlement.to.name) \(money(remaining, "USD"))")
                                if remaining > 0 {
                                    Button("Confirm practice repayment") { practice.confirmPracticePayment(settlement) }
                                        .frame(minHeight: 44)
                                } else { Text("Practice repayment confirmed") }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Practice trip")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Exit practice") { dismiss() } }
            }
            .accessibilityIdentifier("practice-trip")
        }
    }
}
