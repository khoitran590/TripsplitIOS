import SwiftUI

// MARK: - Models

/// A trip member who can pay for or share in an expense.
struct Person: Identifiable, Hashable {
    let id = UUID()
    var name: String
    var color: Color

    var initials: String {
        let parts = name.split(separator: " ")
        let letters = parts.prefix(2).compactMap { $0.first }
        return String(letters).uppercased()
    }
}

/// The supported ways to split an expense, mirroring TripSplit's `splitMethods`.
enum SplitMethod: String, CaseIterable, Identifiable {
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
    @State private var amountText = "120.00"
    @State private var method: SplitMethod = .equalAll
    @State private var payer: Person.ID
    @State private var selected: Set<Person.ID>
    @State private var noSplitAssignee: Person.ID
    @State private var percentages: [Person.ID: Double] = [:]
    @State private var amounts: [Person.ID: Double] = [:]

    init() {
        let people = SplitView.samplepeople
        _payer = State(initialValue: people[0].id)
        _selected = State(initialValue: Set(people.map(\.id)))
        _noSplitAssignee = State(initialValue: people[0].id)
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
                    colors: [Color(hex: 0xF8F9FF), Color(.systemBackground)],
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
        }
    }

    // MARK: Cards

    private var amountCard: some View {
        VStack(spacing: 6) {
            Text("Total Amount")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            HStack(spacing: 2) {
                Text("$").font(.title.weight(.semibold)).foregroundStyle(.secondary)
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
                    HStack(spacing: 6) {
                        Text(settlement.from.name).fontWeight(.semibold)
                        Image(systemName: "arrow.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                        Text(settlement.to.name).fontWeight(.semibold)
                        Spacer()
                        Text(currency(settlement.amount))
                            .fontWeight(.semibold)
                            .foregroundStyle(Color(hex: 0x10B981))
                    }
                    .font(.subheadline)
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
                if suffix == "$" { Text("$").foregroundStyle(.secondary) }
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
        String(format: "$%.2f", value)
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
        Person(name: "Benjamin", color: Color(hex: 0x6366F1)),
        Person(name: "Yuki", color: Color(hex: 0x10B981)),
        Person(name: "Sofia", color: Color(hex: 0xF59E0B)),
        Person(name: "Liam", color: Color(hex: 0xEC4899)),
    ]
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
