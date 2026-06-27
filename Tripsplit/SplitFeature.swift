import SwiftUI

// MARK: - Models

/// A trip member who can pay for or share in an expense.
struct Person: Identifiable, Hashable, Codable {
    var id = UUID()
    var name: String
    var color: Color
    /// Public URL of the member's profile picture in Supabase Storage, if they have one.
    var avatarURL: String? = nil

    var initials: String {
        let parts = name.split(separator: " ")
        let letters = parts.prefix(2).compactMap { $0.first }
        return String(letters).uppercased()
    }

    // `Color` isn't `Codable`, so members persist their color as a hex integer.
    private enum CodingKeys: String, CodingKey { case id, name, colorHex, avatarURL }

    init(id: UUID = UUID(), name: String, color: Color, avatarURL: String? = nil) {
        self.id = id
        self.name = name
        self.color = color
        self.avatarURL = avatarURL
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        color = Color(hex: try container.decode(UInt32.self, forKey: .colorHex))
        avatarURL = try container.decodeIfPresent(String.self, forKey: .avatarURL)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(color.hexValue, forKey: .colorHex)
        try container.encodeIfPresent(avatarURL, forKey: .avatarURL)
    }
}

/// The supported ways to split an expense, mirroring TripSplit's `splitMethods`.
enum SplitMethod: String, CaseIterable, Identifiable, Codable {
    case equalAll = "Split Equally (All)"
    case equalSelected = "Split Equally (Selected)"
    case noSplit = "No Split (Single Payer)"
    case percentage = "Split by Percentage"
    case amount = "Split by Amount"

    var id: Self { self }

    var shortLabel: String {
        switch self {
        case .equalAll: "Equal"
        case .equalSelected: "Selected"
        case .noSplit: "Single"
        case .percentage: "Percent"
        case .amount: "Amount"
        }
    }

    var icon: String {
        switch self {
        case .equalAll: "person.3.fill"
        case .equalSelected: "person.crop.circle.badge.checkmark"
        case .noSplit: "person.fill"
        case .percentage: "percent"
        case .amount: "dollarsign.circle.fill"
        }
    }
}

// MARK: - Split Engine

/// The result of computing a split: each person's share, net balance, and validity.
struct SplitResult {
    /// Each person's share of the bill.
    var owed: [Person.ID: Double] = [:]
    /// Net balance per person: what they paid minus what they owe.
    /// Positive means the group owes them; negative means they owe the group.
    var net: [Person.ID: Double] = [:]
    var isValid: Bool = true
    var message: String?
}

/// Suggested transfer to settle up: `from` pays `to` the given `amount`.
struct Settlement: Identifiable {
    let id = UUID()
    let from: Person
    let to: Person
    let amount: Double
}

/// How a settlement payment was made, mirroring TripSplit's settlement payment methods.
enum PaymentMethod: String, CaseIterable, Identifiable, Codable {
    case cash = "Cash"
    case venmo = "Venmo"
    case paypal = "PayPal"
    case cashapp = "Cash App"

    var id: Self { self }

    var icon: String {
        switch self {
        case .cash: "banknote.fill"
        case .venmo: "v.circle.fill"
        case .paypal: "p.circle.fill"
        case .cashapp: "dollarsign.circle.fill"
        }
    }
}

/// The lifecycle of a settlement request, mirroring TripSplit's `status` field:
/// the debtor records a `pending` payment and the creditor confirms or declines it.
enum SettlementStatus: String, Codable {
    case pending, confirmed, rejected
}

/// A recorded settlement payment toward a debt between two people.
struct SettlementRecord: Identifiable, Codable {
    let id = UUID()
    var amount: Double
    var method: PaymentMethod
    var note: String
    var status: SettlementStatus
    let date: Date
}

/// Pure split calculation, faithful to TripSplit's `calculateSplitPreview` +
/// `splitService` rounding, with exact-cent remainder distribution added so the
/// per-person shares always reconcile to the bill total.
enum SplitEngine {

    /// Rounds to two decimals using the same epsilon trick as `mathHelpers.roundToTwo`.
    static func roundToTwo(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return ((value + Double.ulpOfOne) * 100).rounded() / 100
    }

    /// Splits `total` across `count` people, distributing leftover cents to the
    /// first people so the parts sum exactly to `total` (largest-remainder method).
    static func equalShares(total: Double, count: Int) -> [Double] {
        guard count > 0 else { return [] }
        let totalCents = Int((total * 100).rounded())
        let base = totalCents / count
        let remainder = totalCents - base * count
        return (0..<count).map { index in
            Double(base + (index < remainder ? 1 : 0)) / 100.0
        }
    }

    /// Splits `amount` across people in proportion to `weights` (e.g. allocating tax/tip
    /// by each person's subtotal share), distributing leftover cents by largest remainder
    /// so the parts sum exactly to `amount`. Returns an empty map if there's no weight.
    static func allocateProportionally(_ amount: Double, weights: [Person.ID: Double]) -> [Person.ID: Double] {
        let totalWeight = weights.values.reduce(0, +)
        let cents = Int((amount * 100).rounded())
        guard totalWeight > 0, cents != 0 else { return [:] }

        let keys = Array(weights.keys)
        let exact = keys.map { Double(cents) * ((weights[$0] ?? 0) / totalWeight) }
        var base = exact.map { Int($0.rounded(.down)) }
        var leftover = cents - base.reduce(0, +)

        // Hand the remaining cents to the largest fractional remainders first.
        for index in (0..<keys.count).sorted(by: { (exact[$0] - Double(base[$0])) > (exact[$1] - Double(base[$1])) }) {
            guard leftover > 0 else { break }
            base[index] += 1
            leftover -= 1
        }

        return Dictionary(uniqueKeysWithValues: zip(keys, base.map { Double($0) / 100.0 }))
    }

    /// Computes the per-person shares and net balances for the given configuration.
    static func calculate(
        total: Double,
        method: SplitMethod,
        people: [Person],
        payer: Person.ID,
        selected: Set<Person.ID>,
        noSplitAssignee: Person.ID?,
        percentages: [Person.ID: Double],
        amounts: [Person.ID: Double]
    ) -> SplitResult {
        var result = SplitResult()
        var owed: [Person.ID: Double] = [:]
        people.forEach { owed[$0.id] = 0 }

        switch method {
        case .equalAll:
            let shares = equalShares(total: total, count: people.count)
            for (person, share) in zip(people, shares) { owed[person.id] = share }

        case .equalSelected:
            let chosen = people.filter { selected.contains($0.id) }
            guard !chosen.isEmpty else {
                result.isValid = false
                result.message = "Select at least one person to split between."
                result.owed = owed
                return result
            }
            let shares = equalShares(total: total, count: chosen.count)
            for (person, share) in zip(chosen, shares) { owed[person.id] = share }

        case .noSplit:
            guard let assignee = noSplitAssignee else {
                result.isValid = false
                result.message = "Choose who this expense belongs to."
                result.owed = owed
                return result
            }
            owed[assignee] = roundToTwo(total)

        case .percentage:
            let sum = people.reduce(0) { $0 + (percentages[$1.id] ?? 0) }
            for person in people {
                owed[person.id] = roundToTwo(total * (percentages[person.id] ?? 0) / 100.0)
            }
            if abs(sum - 100) > 0.01 {
                result.isValid = false
                result.message = String(format: "Percentages must add up to 100%% (now %.1f%%).", sum)
            }

        case .amount:
            let sum = people.reduce(0) { $0 + (amounts[$1.id] ?? 0) }
            for person in people {
                owed[person.id] = roundToTwo(amounts[person.id] ?? 0)
            }
            if abs(sum - total) > 0.01 {
                result.isValid = false
                result.message = String(format: "Amounts must add up to %.2f (now %.2f).", total, sum)
            }
        }

        // Net balance: the payer fronted the whole bill, everyone owes their share.
        var net: [Person.ID: Double] = [:]
        for person in people {
            let paid = person.id == payer ? total : 0
            net[person.id] = roundToTwo(paid - (owed[person.id] ?? 0))
        }

        result.owed = owed
        result.net = net
        return result
    }

    /// Greedy debt simplification: produces the minimum-ish set of transfers that
    /// settles every net balance. (TripSplit settles manually; this is a helper.)
    static func settleUp(net: [Person.ID: Double], people: [Person]) -> [Settlement] {
        let lookup = Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0) })
        var creditors = net.filter { $0.value > 0.005 }
            .map { (id: $0.key, amount: $0.value) }
            .sorted { $0.amount > $1.amount }
        var debtors = net.filter { $0.value < -0.005 }
            .map { (id: $0.key, amount: -$0.value) }
            .sorted { $0.amount > $1.amount }

        var settlements: [Settlement] = []
        var ci = 0, di = 0
        while ci < creditors.count && di < debtors.count {
            let pay = min(creditors[ci].amount, debtors[di].amount)
            if let from = lookup[debtors[di].id], let to = lookup[creditors[ci].id] {
                settlements.append(Settlement(from: from, to: to, amount: roundToTwo(pay)))
            }
            creditors[ci].amount -= pay
            debtors[di].amount -= pay
            if creditors[ci].amount <= 0.005 { ci += 1 }
            if debtors[di].amount <= 0.005 { di += 1 }
        }
        return settlements
    }
}

// MARK: - Split View

/// The expense-splitting screen reached from the home "Split" button.
struct SplitView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var people: [Person] = SplitView.samplepeople
    @State private var amountText = ""
    @State private var method: SplitMethod = .equalAll
    @State private var payer: Person.ID
    @State private var selected: Set<Person.ID>
    @State private var noSplitAssignee: Person.ID
    @State private var percentages: [Person.ID: Double] = [:]
    @State private var amounts: [Person.ID: Double] = [:]

    /// Recorded settlement payments, keyed by `"<debtorID>-><creditorID>"` so that
    /// settle-up progress persists while the split is recomputed.
    @State private var settlementHistory: [String: [SettlementRecord]] = [:]
    /// The settlement currently presented in the settle-up sheet.
    @State private var activeSettlement: Settlement?

    /// Currency code used to format amounts; defaults to USD for a standalone split.
    private let currencyCode: String

    /// Splits a bill among `people`. When called without members it falls back to the
    /// sample people, so the standalone split calculator still works.
    init(people: [Person]? = nil, currencyCode: String = "USD") {
        let resolved = people.flatMap { $0.isEmpty ? nil : $0 } ?? SplitView.samplepeople
        _people = State(initialValue: resolved)
        _payer = State(initialValue: resolved[0].id)
        _selected = State(initialValue: Set(resolved.map(\.id)))
        _noSplitAssignee = State(initialValue: resolved[0].id)
        self.currencyCode = currencyCode
    }

    private var total: Double { Double(amountText) ?? 0 }

    private var result: SplitResult {
        SplitEngine.calculate(
            total: total, method: method, people: people, payer: payer,
            selected: selected, noSplitAssignee: noSplitAssignee,
            percentages: percentages, amounts: amounts
        )
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
                        amountCard
                        payerCard
                        methodCard
                        configurationCard
                        reviewCard
                    }
                    .padding()
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("Split Expense")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .sheet(item: $activeSettlement) { settlement in
                SettleView(settlement: settlement, history: historyBinding(for: settlement), currencyCode: currencyCode)
            }
        }
    }

    // MARK: Cards

    private var amountCard: some View {
        VStack(spacing: 6) {
            Text("Total Amount")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            HStack(spacing: 2) {
                Text(currencySymbol(currencyCode)).font(.title.weight(.semibold)).foregroundStyle(.secondary)
                TextField("0.00", text: $amountText)
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.center)
                    .fixedSize()
            }
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }

    private var payerCard: some View {
        cardSection(title: "Paid by", icon: "creditcard.fill") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(people) { person in
                        chip(person.name, selected: payer == person.id, color: person.color) {
                            payer = person.id
                        }
                    }
                }
            }
        }
    }

    private var methodCard: some View {
        cardSection(title: "Split method", icon: "slider.horizontal.3") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(SplitMethod.allCases) { option in
                        Button {
                            withAnimation(.snappy) { method = option }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: option.icon)
                                Text(option.shortLabel)
                            }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(method == option ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(
                            method == option ? .regular.tint(Color(hex: 0x6366F1)).interactive() : .regular.interactive(),
                            in: .capsule
                        )
                    }
                }
            }
            Text(method.rawValue)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var configurationCard: some View {
        switch method {
        case .equalAll:
            cardSection(title: "Splitting between everyone", icon: "person.3.fill") {
                ForEach(people) { person in
                    personRow(person, trailing: currency(result.owed[person.id] ?? 0))
                }
            }
        case .equalSelected:
            cardSection(title: "Select people", icon: "checklist") {
                ForEach(people) { person in
                    Button {
                        if selected.contains(person.id) { selected.remove(person.id) }
                        else { selected.insert(person.id) }
                    } label: {
                        personRow(
                            person,
                            leadingSystemImage: selected.contains(person.id) ? "checkmark.square.fill" : "square",
                            trailing: selected.contains(person.id) ? currency(result.owed[person.id] ?? 0) : "—"
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        case .noSplit:
            cardSection(title: "Belongs to", icon: "person.fill") {
                ForEach(people) { person in
                    Button {
                        noSplitAssignee = person.id
                    } label: {
                        personRow(
                            person,
                            leadingSystemImage: noSplitAssignee == person.id ? "largecircle.fill.circle" : "circle",
                            trailing: noSplitAssignee == person.id ? currency(total) : "—"
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        case .percentage:
            cardSection(title: "Enter percentages", icon: "percent") {
                ForEach(people) { person in
                    inputRow(person, suffix: "%", binding: percentageBinding(person.id))
                }
                let sum = people.reduce(0) { $0 + (percentages[$1.id] ?? 0) }
                summaryLine(label: "Total", value: String(format: "%.1f%%", sum), target: "100%")
            }
        case .amount:
            cardSection(title: "Enter amounts", icon: "dollarsign.circle.fill") {
                ForEach(people) { person in
                    inputRow(person, suffix: "$", binding: amountBinding(person.id))
                }
                let sum = people.reduce(0) { $0 + (amounts[$1.id] ?? 0) }
                summaryLine(label: "Total", value: currency(sum), target: currency(total))
            }
        }
    }

    private var reviewCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Split Review", systemImage: "list.bullet.rectangle.fill")
                .font(.headline)

            if let message = result.message, !result.isValid {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Color(hex: 0xEF4444))
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(hex: 0xEF4444).opacity(0.12), in: .rect(cornerRadius: 12))
            }

            ForEach(people) { person in
                HStack {
                    avatar(person)
                    Text(person.name + (person.id == payer ? " (Payer)" : ""))
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Text(currency(result.owed[person.id] ?? 0))
                        .font(.subheadline.weight(.semibold))
                }
            }

            Divider()

            let settlements = SplitEngine.settleUp(net: result.net, people: people)
            if result.isValid && !settlements.isEmpty {
                Text("Settle up")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(settlements) { settlement in
                    Button {
                        activeSettlement = settlement
                    } label: {
                        HStack(spacing: 6) {
                            Text(displayName(settlement.from)).fontWeight(.semibold)
                            Image(systemName: "arrow.right")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)
                            Text(displayName(settlement.to)).fontWeight(.semibold)
                            Spacer()
                            if isFullySettled(settlement) {
                                Label("Settled", systemImage: "checkmark.seal.fill")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Color(hex: 0x10B981))
                            } else {
                                Text(currency(remainingAmount(for: settlement)))
                                    .fontWeight(.semibold)
                                    .foregroundStyle(Color(hex: 0x10B981))
                            }
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.tertiary)
                        }
                        .font(.subheadline)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            } else if result.isValid {
                Text("All settled up — nothing owed.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(Color(hex: 0x6366F1).opacity(0.08)), in: .rect(cornerRadius: 24))
    }

    // MARK: Reusable pieces

    private func cardSection<Content: View>(
        title: String, icon: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.headline)
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }

    private func chip(_ title: String, selected: Bool, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
        }
        .buttonStyle(.plain)
        .glassEffect(selected ? .regular.tint(color).interactive() : .regular.interactive(), in: .capsule)
    }

    private func personRow(
        _ person: Person,
        leadingSystemImage: String? = nil,
        trailing: String
    ) -> some View {
        HStack(spacing: 12) {
            if let leadingSystemImage {
                Image(systemName: leadingSystemImage)
                    .font(.system(size: 18))
                    .foregroundStyle(Color(hex: 0x6366F1))
            }
            avatar(person)
            Text(person.name).font(.subheadline.weight(.medium))
            Spacer()
            Text(trailing).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
        }
    }

    private func inputRow(_ person: Person, suffix: String, binding: Binding<String>) -> some View {
        HStack(spacing: 12) {
            avatar(person)
            Text(person.name).font(.subheadline.weight(.medium))
            Spacer()
            HStack(spacing: 2) {
                if suffix == "$" { Text(currencySymbol(currencyCode)).foregroundStyle(.secondary) }
                TextField("0", text: binding)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 64)
                if suffix == "%" { Text("%").foregroundStyle(.secondary) }
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.secondary.opacity(0.12), in: .rect(cornerRadius: 10))
        }
    }

    private func summaryLine(label: String, value: String, target: String) -> some View {
        HStack {
            Text(label).font(.subheadline.weight(.semibold))
            Spacer()
            Text("\(value) / \(target)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(result.isValid ? Color(hex: 0x10B981) : Color(hex: 0xEF4444))
        }
    }

    private func avatar(_ person: Person) -> some View {
        Text(person.initials)
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 32, height: 32)
            .background(person.color, in: .circle)
    }

    private func currency(_ value: Double) -> String {
        money(value, currencyCode)
    }

    /// Falls back to a person's index-based label when their name is blank.
    private func displayName(_ person: Person) -> String {
        guard person.name.isEmpty else { return person.name }
        let index = people.firstIndex(of: person).map { $0 + 1 } ?? 0
        return "Person \(index)"
    }

    // MARK: Settlement helpers

    private func settleKey(_ s: Settlement) -> String {
        "\(s.from.id.uuidString)->\(s.to.id.uuidString)"
    }

    private func historyBinding(for s: Settlement) -> Binding<[SettlementRecord]> {
        let key = settleKey(s)
        return Binding(
            get: { settlementHistory[key] ?? [] },
            set: { settlementHistory[key] = $0 }
        )
    }

    /// Remaining debt = original transfer minus confirmed settlements (TripSplit's rule).
    private func remainingAmount(for s: Settlement) -> Double {
        let confirmed = (settlementHistory[settleKey(s)] ?? [])
            .filter { $0.status == .confirmed }
            .reduce(0) { $0 + $1.amount }
        return max(0, SplitEngine.roundToTwo(s.amount - confirmed))
    }

    private func isFullySettled(_ s: Settlement) -> Bool {
        remainingAmount(for: s) <= 0.005
    }

    // MARK: Bindings

    private func percentageBinding(_ id: Person.ID) -> Binding<String> {
        Binding(
            get: { percentages[id].map { $0 == 0 ? "" : String(format: "%g", $0) } ?? "" },
            set: { percentages[id] = Double($0) ?? 0 }
        )
    }

    private func amountBinding(_ id: Person.ID) -> Binding<String> {
        Binding(
            get: { amounts[id].map { $0 == 0 ? "" : String(format: "%g", $0) } ?? "" },
            set: { amounts[id] = Double($0) ?? 0 }
        )
    }

    static let samplepeople: [Person] = [
        Person(name: "", color: Color(hex: 0x6366F1)),
        Person(name: "", color: Color(hex: 0x10B981)),
        Person(name: "", color: Color(hex: 0xF59E0B)),
        Person(name: "", color: Color(hex: 0xEC4899)),
    ]
}

// MARK: - Settle View

/// The settle-up screen reached by tapping a suggested transfer in the split review.
/// Mirrors TripSplit's `SettlementScreen`: an overview, a record-a-payment form, and a
/// history list where the creditor confirms or declines each pending payment. The
/// remaining balance is driven only by *confirmed* payments, exactly like the original.
struct SettleView: View {
    @Environment(\.dismiss) private var dismiss

    let settlement: Settlement
    @Binding var history: [SettlementRecord]
    /// Currency code used to format amounts; defaults to USD for the split review.
    var currencyCode: String = "USD"
    /// When set, only this user (the debtor) may record new payments; others can only approve/decline.
    var currentUserID: Person.ID? = nil

    @State private var amountText = ""
    @State private var note = ""
    @State private var method: PaymentMethod = .cash

    /// Only confirmed payments count toward the settled total (faithful to TripSplit).
    private var confirmedSettled: Double {
        history.filter { $0.status == .confirmed }.reduce(0) { $0 + $1.amount }
    }

    private var remaining: Double {
        max(0, SplitEngine.roundToTwo(settlement.amount - confirmedSettled))
    }

    private var enteredAmount: Double { Double(amountText) ?? 0 }

    private var canSettleInput: Bool {
        enteredAmount > 0 && enteredAmount <= remaining + 0.005
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
                        overviewCard
                        if remaining > 0.005 && (currentUserID == nil || settlement.from.id == currentUserID) {
                            recordCard
                        }
                        historyCard
                    }
                    .padding()
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("Settle Up")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    // MARK: Cards

    private var overviewCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Settlement Overview", systemImage: "arrow.left.arrow.right.circle.fill")
                .font(.headline)

            detailRow(icon: "person.fill", label: "Debtor", person: settlement.from)
            detailRow(icon: "creditcard.fill", label: "Creditor", person: settlement.to)

            Divider()

            HStack(alignment: .top) {
                amountColumn(title: "Total Owed", value: settlement.amount, color: .primary)
                Spacer()
                amountColumn(
                    title: "Remaining", value: remaining,
                    color: remaining <= 0.005 ? Color(hex: 0x10B981) : Color(hex: 0xEF4444)
                )
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }

    private var recordCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Record a Payment", systemImage: "square.and.pencil")
                .font(.headline)

            HStack(spacing: 2) {
                Text(currencySymbol(currencyCode)).foregroundStyle(.secondary)
                TextField("0.00", text: $amountText)
                    .keyboardType(.decimalPad)
            }
            .font(.title3.weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(.secondary.opacity(0.12), in: .rect(cornerRadius: 12))

            TextField("Add a note (optional)", text: $note, axis: .vertical)
                .lineLimit(1...3)
                .font(.subheadline)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(.secondary.opacity(0.12), in: .rect(cornerRadius: 12))

            Text("Payment method")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(PaymentMethod.allCases) { option in
                        Button {
                            method = option
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: option.icon)
                                Text(option.rawValue)
                            }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(method == option ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(
                            method == option ? .regular.tint(Color(hex: 0x6366F1)).interactive() : .regular.interactive(),
                            in: .capsule
                        )
                    }
                }
            }

            HStack(spacing: 10) {
                settleButton(
                    title: "Settle Input", icon: "arrow.left.arrow.right",
                    tint: Color(hex: 0x10B981), enabled: canSettleInput
                ) { record(amount: enteredAmount) }

                settleButton(
                    title: "Settle Full", icon: "checkmark.circle.fill",
                    tint: Color(hex: 0x3B82F6), enabled: remaining > 0.005
                ) { record(amount: remaining) }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }

    private var historyCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Settlement History", systemImage: "clock.arrow.circlepath")
                .font(.headline)

            if history.isEmpty {
                Text("No settlement history found for this debt.")
                    .font(.subheadline)
                    .italic()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                ForEach(history) { entry in
                    historyRow(entry)
                    if entry.id != history.last?.id { Divider() }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }

    // MARK: Reusable pieces

    private func detailRow(icon: String, label: String, person: Person) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color(hex: 0x6366F1))
                .frame(width: 22)
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            avatar(person)
            Text(person.name.isEmpty ? "—" : person.name)
                .font(.subheadline.weight(.semibold))
        }
    }

    private func amountColumn(title: String, value: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(currency(value)).font(.title3.weight(.bold)).foregroundStyle(color)
        }
    }

    private func settleButton(
        title: String, icon: String, tint: Color, enabled: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(tint).interactive(), in: .capsule)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }

    private func historyRow(_ entry: SettlementRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: entry.method.icon)
                    .foregroundStyle(Color(hex: 0x6366F1))
                VStack(alignment: .leading, spacing: 2) {
                    Text(currency(entry.amount)).font(.subheadline.weight(.semibold))
                    Text("\(entry.method.rawValue) • \(entry.date.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                statusBadge(entry.status)
            }
            if !entry.note.isEmpty {
                Text(entry.note).font(.caption).foregroundStyle(.secondary)
            }
            if entry.status == .pending {
                HStack(spacing: 10) {
                    actionPill(title: "Approve", icon: "checkmark", tint: Color(hex: 0x10B981)) {
                        update(entry, to: .confirmed)
                    }
                    actionPill(title: "Decline", icon: "xmark", tint: Color(hex: 0xEF4444)) {
                        update(entry, to: .rejected)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func actionPill(title: String, icon: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(tint).interactive(), in: .capsule)
    }

    private func statusBadge(_ status: SettlementStatus) -> some View {
        let (text, color): (String, Color) = switch status {
        case .pending: ("Pending", Color(hex: 0xF59E0B))
        case .confirmed: ("Confirmed", Color(hex: 0x10B981))
        case .rejected: ("Declined", Color(hex: 0xEF4444))
        }
        return Text(text)
            .font(.caption2.weight(.bold))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(color.opacity(0.15), in: .capsule)
    }

    private func avatar(_ person: Person) -> some View {
        Text(person.initials)
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(person.color, in: .circle)
    }

    private func currency(_ value: Double) -> String {
        money(value, currencyCode)
    }

    // MARK: Actions

    /// Records a new payment as `pending`, mirroring the debtor-initiated flow.
    private func record(amount: Double) {
        let amt = SplitEngine.roundToTwo(amount)
        guard amt > 0 else { return }
        history.insert(
            SettlementRecord(amount: amt, method: method, note: note, status: .pending, date: Date()),
            at: 0
        )
        amountText = ""
        note = ""
    }

    private func update(_ entry: SettlementRecord, to status: SettlementStatus) {
        guard let index = history.firstIndex(where: { $0.id == entry.id }) else { return }
        history[index].status = status
    }
}

// MARK: - Color helper

extension Color {
    /// Creates a color from a 24-bit RGB hex value, e.g. `0x6366F1`.
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

#Preview {
    SplitView()
}
