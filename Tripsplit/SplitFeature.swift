import SwiftUI



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
                .font(.app(.subheadline, .medium))
                .foregroundStyle(.secondary)
            HStack(spacing: 2) {
                Text(currencySymbol(currencyCode)).font(.app(.title, .semibold)).foregroundStyle(.secondary)
                TextField("0.00", text: $amountText)
                    .font(.app(size: 40, weight: .bold))
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
                                Text(LocalizedStringKey(option.shortLabel))
                            }
                            .font(.app(.subheadline, .semibold))
                            .foregroundStyle(method == option ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(
                            method == option ? .regular.tint(Theme.accent).interactive() : .regular.interactive(),
                            in: .capsule
                        )
                    }
                }
            }
            Text(LocalizedStringKey(method.rawValue))
                .font(.app(.footnote))
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
                .font(.app(.headline))

            if let message = result.message, !result.isValid {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.app(.footnote, .medium))
                    .foregroundStyle(Color(hex: 0xEF4444))
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(hex: 0xEF4444).opacity(0.12), in: .rect(cornerRadius: 12))
            }

            ForEach(people) { person in
                HStack {
                    avatar(person)
                    Text(person.id == payer ? LocalizedStringKey("\(person.name) (Payer)") : LocalizedStringKey(person.name))
                        .font(.app(.subheadline, .medium))
                    Spacer()
                    Text(currency(result.owed[person.id] ?? 0))
                        .font(.app(.subheadline, .semibold))
                }
            }

            Divider()

            let settlements = SplitEngine.settleUp(net: result.net, people: people)
            if result.isValid && !settlements.isEmpty {
                Text("Settle up")
                    .font(.app(.subheadline, .semibold))
                    .foregroundStyle(.secondary)
                ForEach(settlements) { settlement in
                    Button {
                        activeSettlement = settlement
                    } label: {
                        HStack(spacing: 6) {
                            Text(displayName(settlement.from)).fontWeight(.semibold)
                            Image(systemName: "arrow.right")
                                .font(.app(.caption, .bold))
                                .foregroundStyle(.secondary)
                            Text(displayName(settlement.to)).fontWeight(.semibold)
                            Spacer()
                            if isFullySettled(settlement) {
                                Label("Settled", systemImage: "checkmark.seal.fill")
                                    .font(.app(.caption, .semibold))
                                    .foregroundStyle(Color(hex: 0x10B981))
                            } else {
                                Text(currency(remainingAmount(for: settlement)))
                                    .fontWeight(.semibold)
                                    .foregroundStyle(Color(hex: 0x10B981))
                            }
                            Image(systemName: "chevron.right")
                                .font(.app(.caption2, .bold))
                                .foregroundStyle(.tertiary)
                        }
                        .font(.app(.subheadline))
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            } else if result.isValid {
                Text("All settled up — nothing owed.")
                    .font(.app(.subheadline))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(Theme.accent.opacity(0.08)), in: .rect(cornerRadius: 24))
    }

    // MARK: Reusable pieces

    private func cardSection<Content: View>(
        title: LocalizedStringKey, icon: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.app(.headline))
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }

    private func chip(_ title: String, selected: Bool, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.app(.subheadline, .semibold))
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
                    .font(.app(size: 18))
                    .foregroundStyle(Theme.accent)
            }
            avatar(person)
            Text(person.name).font(.app(.subheadline, .medium))
            Spacer()
            Text(trailing).font(.app(.subheadline, .semibold)).foregroundStyle(.secondary)
        }
    }

    private func inputRow(_ person: Person, suffix: String, binding: Binding<String>) -> some View {
        HStack(spacing: 12) {
            avatar(person)
            Text(person.name).font(.app(.subheadline, .medium))
            Spacer()
            HStack(spacing: 2) {
                if suffix == "$" { Text(currencySymbol(currencyCode)).foregroundStyle(.secondary) }
                TextField("0", text: binding)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 64)
                if suffix == "%" { Text("%").foregroundStyle(.secondary) }
            }
            .font(.app(.subheadline, .semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.secondary.opacity(0.12), in: .rect(cornerRadius: 10))
        }
    }

    private func summaryLine(label: LocalizedStringKey, value: String, target: String) -> some View {
        HStack {
            Text(label).font(.app(.subheadline, .semibold))
            Spacer()
            Text("\(value) / \(target)")
                .font(.app(.subheadline, .semibold))
                .foregroundStyle(result.isValid ? Color(hex: 0x10B981) : Color(hex: 0xEF4444))
        }
    }

    private func avatar(_ person: Person) -> some View {
        InitialsAvatar(person: person, size: 32)
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
    var tripName: String? = nil
    /// When set, only this user (the debtor) may record new payments; others can only approve/decline.
    var currentUserID: Person.ID? = nil

    @State private var amountText = ""
    @State private var note = ""
    @State private var method: PaymentMethod = .cash
    @AppStorage("defaultPaymentMethod") private var defaultPaymentMethod = PaymentMethod.cash.rawValue

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
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: settlementShareText) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share payment request")
                }
            }
        }
        .onAppear { method = PaymentMethod(rawValue: defaultPaymentMethod) ?? .cash }
    }

    // MARK: Cards

    private var overviewCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Settlement Overview", systemImage: "arrow.left.arrow.right.circle.fill")
                .font(.app(.headline))

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
                .font(.app(.headline))

            HStack(spacing: 2) {
                Text(currencySymbol(currencyCode)).foregroundStyle(.secondary)
                TextField("0.00", text: $amountText)
                    .keyboardType(.decimalPad)
            }
            .font(.app(.title3, .semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(.secondary.opacity(0.12), in: .rect(cornerRadius: 12))

            TextField("Add a note (optional)", text: $note, axis: .vertical)
                .lineLimit(1...3)
                .font(.app(.subheadline))
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(.secondary.opacity(0.12), in: .rect(cornerRadius: 12))

            Text("Payment method")
                .font(.app(.subheadline, .semibold))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(PaymentMethod.allCases) { option in
                        Button {
                            method = option
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: option.icon)
                                Text(LocalizedStringKey(option.rawValue))
                            }
                            .font(.app(.subheadline, .semibold))
                            .foregroundStyle(method == option ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(
                            method == option ? .regular.tint(Theme.accent).interactive() : .regular.interactive(),
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
                .font(.app(.headline))

            if history.isEmpty {
                Text("No settlement history found for this debt.")
                    .font(.app(.subheadline))
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

    private func detailRow(icon: String, label: LocalizedStringKey, person: Person) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.app(size: 14, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 22)
            Text(label).font(.app(.subheadline)).foregroundStyle(.secondary)
            Spacer()
            avatar(person)
            Text(person.name.isEmpty ? "—" : person.name)
                .font(.app(.subheadline, .semibold))
        }
    }

    private func amountColumn(title: LocalizedStringKey, value: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.app(.caption)).foregroundStyle(.secondary)
            Text(currency(value)).font(.app(.title3, .bold)).foregroundStyle(color)
        }
    }

    private func settleButton(
        title: LocalizedStringKey, icon: String, tint: Color, enabled: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.app(.subheadline, .semibold))
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
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(currency(entry.amount)).font(.app(.subheadline, .semibold))
                    Text("\(entry.method.rawValue) • \(entry.date.formatted(date: .abbreviated, time: .omitted))")
                        .font(.app(.caption))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                statusBadge(entry.status)
            }
            if !entry.note.isEmpty {
                Text(entry.note).font(.app(.caption)).foregroundStyle(.secondary)
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

    private func actionPill(title: LocalizedStringKey, icon: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.app(.caption, .semibold))
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
        return Text(LocalizedStringKey(text))
            .font(.app(.caption2, .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(color.opacity(0.15), in: .capsule)
    }

    private func avatar(_ person: Person) -> some View {
        InitialsAvatar(person: person, size: 28)
    }

    private func currency(_ value: Double) -> String {
        money(value, currencyCode)
    }

    private var settlementShareText: String {
        TripExport.settlementText(
            settlement: settlement,
            remaining: remaining,
            currencyCode: currencyCode,
            tripName: tripName
        )
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
