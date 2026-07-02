import SwiftUI

/// The TripSplit-style main dashboard: greeting, balance card, quick actions,
/// and recent transactions.
struct HomeScreen: View {
    @Environment(TripStore.self) private var store
    @AppStorage("appearancePreference") private var appearance: AppearancePreference = .system
    @State private var showAddTrip = false
    @State private var selectedTrip: Trip?

    /// The quick action a user tapped, awaiting a trip choice.
    private enum QuickAction { case split, addExpense }
    @State private var pendingAction: QuickAction?
    @State private var showTripPicker = false
    @State private var pendingTrip: Trip?
    @State private var splitTrip: Trip?
    @State private var expenseTrip: Trip?
    @State private var tripToDelete: Trip?
    @State private var showAllTransactions = false
    @State private var isSelectingTransactions = false
    @State private var selectedTransactionIDs: Set<Transaction.ID> = []
    @State private var transactionsPendingDelete: [Transaction]?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    syncBanner
                    BalanceCard()
                    quickActions
                    tripsSection
                    recentTransactions
                }
                .padding(.horizontal)
                .padding(.bottom, 90)
                // Animate the sync banner in/out instead of snapping the whole layout.
                .animation(.snappy, value: store.syncState)
            }
            .background {
                LinearGradient(
                    colors: Theme.homeGradient,
                    startPoint: .top, endPoint: .bottom
                )
                .ignoresSafeArea()
            }
            .navigationTitle("Hi, \(greetingName)")
            .refreshable {
                await store.loadFromCloud()
                await store.refreshRates()
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 8) {
                        appearanceToggle
                        ProfileAvatar(
                            imageData: store.profileImageData,
                            initials: store.currentUser.initials,
                            size: 34
                        )
                    }
                }
            }
        }
        .sheet(isPresented: $showAddTrip) {
            AddTripView()
        }
        .sheet(item: $selectedTrip) { trip in
            TripDetailView(tripID: trip.id)
        }
        .sheet(item: $splitTrip) { trip in
            SplitView(people: trip.members, currencyCode: trip.currencyCode)
        }
        .sheet(item: $expenseTrip) { trip in
            AddExpenseView(tripID: trip.id)
        }
        .sheet(isPresented: $showTripPicker, onDismiss: routePendingAction) {
            TripPickerSheet(
                trips: store.myTrips,
                prompt: pendingAction == .split ? "Split a bill within which trip?" : "Add an expense to which trip?"
            ) { trip in
                pendingTrip = trip
                showTripPicker = false
            }
            .presentationDetents([.medium, .large])
            .presentationBackground(.regularMaterial)
        }
        .confirmationDialog(
            "Delete this trip?",
            isPresented: Binding(get: { tripToDelete != nil }, set: { if !$0 { tripToDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Trip", role: .destructive) {
                if let tripToDelete { store.deleteTrip(tripToDelete.id) }
                tripToDelete = nil
            }
            Button("Cancel", role: .cancel) { tripToDelete = nil }
        } message: {
            Text(tripToDelete.map { "“\($0.name)” and its expenses will be removed from your synced trips." } ?? "")
        }
        .task {
            // Load USD exchange rates so the balance card can normalize every trip's currency.
            await store.refreshRates()
        }
    }

    /// Starts a quick action by asking which trip to use (or prompting to create one).
    private func startQuickAction(_ action: QuickAction) {
        guard !store.myTrips.isEmpty else {
            showAddTrip = true
            return
        }
        pendingAction = action
        showTripPicker = true
    }

    /// After the trip-picker sheet dismisses, opens the chosen trip's split or add-expense
    /// sheet. Routing here (rather than while the picker is still up) avoids presenting two
    /// sheets at once, which SwiftUI drops.
    private func routePendingAction() {
        defer { pendingAction = nil; pendingTrip = nil }
        guard let trip = pendingTrip else { return }
        switch pendingAction {
        case .split: splitTrip = trip
        case .addExpense: expenseTrip = trip
        case nil: break
        }
    }

    private var tripsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Your Trips")
                    .font(.headline)
                    .padding(.leading, 4)
                Spacer()
                Button {
                    showAddTrip = true
                } label: {
                    Label("Add Trip", systemImage: "plus")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.tint(Color(hex: 0x6366F1)).interactive(), in: .capsule)
            }

            if store.myTrips.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "suitcase")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text("No trips yet")
                        .font(.subheadline.weight(.medium))
                    Text("Create a trip to start tracking expenses.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
                .glassEffect(.regular, in: .rect(cornerRadius: 20))
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(store.myTrips) { trip in
                            Button { selectedTrip = trip } label: {
                                TripRow(trip: trip, currentUserID: store.currentUser.id)
                                    .frame(width: 300)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                if store.isCreator(of: trip) {
                                    Button(role: .destructive) {
                                        tripToDelete = trip
                                    } label: {
                                        Label("Delete Trip", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                    .padding(.vertical, 6)
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)
                .scrollClipDisabled()
            }
        }
    }

    /// Surfaces cloud-sync status so a failed save isn't silent: a spinner while saving
    /// and a retryable error banner when a save couldn't reach Supabase.
    @ViewBuilder
    private var syncBanner: some View {
        switch store.syncState {
        case .idle:
            EmptyView()
        case .syncing:
            HStack(spacing: 8) {
                ProgressView()
                Text("Saving to cloud…").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .glassEffect(.regular, in: .rect(cornerRadius: 14))
        case .failed:
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.icloud.fill").foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Couldn't save to cloud").font(.caption.weight(.bold)).foregroundStyle(.white)
                    Text("Changes are saved on this device only.").font(.caption2).foregroundStyle(.white.opacity(0.85))
                }
                Spacer()
                Button { store.retrySync() } label: {
                    Text("Retry").font(.caption.weight(.bold)).foregroundStyle(Color(hex: 0xDC2626))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.white, in: .capsule)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Color(hex: 0xDC2626), in: .rect(cornerRadius: 14))
        }
    }

    /// The first-name greeting, falling back to a friendly default until the user
    /// sets their name in Settings → Personal Information.
    private var greetingName: String {
        let trimmed = store.currentUser.name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "there" : trimmed
    }

    private var appearanceToggle: some View {
        Menu {
            Picker("Appearance", selection: $appearance) {
                ForEach(AppearancePreference.allCases) { option in
                    Label(option.label, systemImage: option.icon).tag(option)
                }
            }
        } label: {
            Image(systemName: appearance.icon)
        }
        .accessibilityLabel("Appearance: \(appearance.label)")
    }

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quick Actions")
                .font(.headline)
                .padding(.leading, 4)

            HStack(spacing: 12) {
                QuickActionButton(
                    title: "Split",
                    icon: "divide.circle.fill",
                    colors: [Color(hex: 0x818CF8), Color(hex: 0x4F46E5)]
                ) { startQuickAction(.split) }

                QuickActionButton(
                    title: "Add Expense",
                    icon: "plus.circle.fill",
                    colors: [Color(hex: 0x34D399), Color(hex: 0x059669)]
                ) { startQuickAction(.addExpense) }
            }
        }
    }

    /// Every expense across the user's trips, newest first, as transaction rows.
    /// This drives the "Recent Transactions" card so it reflects real activity.
    private var allTransactions: [Transaction] {
        store.myTrips
            .flatMap { trip in
                trip.expenses.map { expense in
                    let payer = trip.members.first { $0.id == expense.payerID }
                    let payerLabel = payer.map { $0.id == store.currentUser.id ? "You" : $0.name } ?? "—"
                    return Transaction(
                        tripID: trip.id,
                        expenseID: expense.id,
                        name: expense.title,
                        category: "\(trip.name) • Paid by \(payerLabel)",
                        date: expense.date.formatted(date: .abbreviated, time: .omitted),
                        amount: expense.amount,
                        currencyCode: trip.currencyCode,
                        color: payer?.color ?? Theme.accent,
                        sortDate: expense.date,
                        canDelete: store.isCreator(of: trip) || expense.payerID == store.currentUser.id
                    )
                }
            }
            .sorted { $0.sortDate > $1.sortDate }
    }

    private var recentTransactions: some View {
        // Materialized once per render: `allTransactions` walks every trip's expenses,
        // formats dates, and sorts — referencing the computed property from each spot
        // below would redo all of that several times per body pass.
        let all = allTransactions
        let transactions = showAllTransactions ? all : Array(all.prefix(5))
        let visibleDeletableTransactions = transactions.filter(\.canDelete)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recent Transactions")
                    .font(.headline)
                    .padding(.leading, 4)
                Spacer()
                if isSelectingTransactions {
                    Button(selectedTransactionIDs.count == visibleDeletableTransactions.count ? "Deselect All" : "Select All") {
                        if selectedTransactionIDs.count == visibleDeletableTransactions.count {
                            selectedTransactionIDs.removeAll()
                        } else {
                            selectedTransactionIDs = Set(visibleDeletableTransactions.map(\.id))
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .buttonStyle(.plain)

                    Button("Cancel") {
                        withAnimation(.snappy) {
                            isSelectingTransactions = false
                            selectedTransactionIDs.removeAll()
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
                    .padding(.leading, 12)
                } else {
                    if all.count > 5 {
                        Button {
                            withAnimation(.snappy) { showAllTransactions.toggle() }
                        } label: {
                            Text(showAllTransactions ? "Show Less" : "See All")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.accent)
                        }
                        .buttonStyle(.plain)
                    }
                    if !visibleDeletableTransactions.isEmpty {
                        Button("Select") {
                            withAnimation(.snappy) { isSelectingTransactions = true }
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .buttonStyle(.plain)
                        .padding(.leading, 12)
                    }
                }
            }

            if all.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "tray")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text("No transactions yet")
                        .font(.subheadline.weight(.medium))
                    Text("Add an expense to a trip to see it here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
                .glassEffect(.regular, in: .rect(cornerRadius: 20))
            } else {
                GlassEffectContainer(spacing: 12) {
                    VStack(spacing: 12) {
                        ForEach(transactions) { transaction in
                            if isSelectingTransactions {
                                TransactionRow(
                                    transaction: transaction,
                                    isSelected: transaction.canDelete ? selectedTransactionIDs.contains(transaction.id) : nil
                                ) {
                                    guard transaction.canDelete else { return }
                                    if selectedTransactionIDs.contains(transaction.id) {
                                        selectedTransactionIDs.remove(transaction.id)
                                    } else {
                                        selectedTransactionIDs.insert(transaction.id)
                                    }
                                }
                                .opacity(transaction.canDelete ? 1 : 0.5)
                            } else if transaction.canDelete {
                                SwipeToDeleteRow {
                                    transactionsPendingDelete = [transaction]
                                } content: {
                                    TransactionRow(transaction: transaction)
                                }
                            } else {
                                TransactionRow(transaction: transaction)
                            }
                        }
                    }
                }

                if isSelectingTransactions {
                    Button(role: .destructive) {
                        transactionsPendingDelete = all.filter { selectedTransactionIDs.contains($0.id) }
                    } label: {
                        Text("Delete\(selectedTransactionIDs.isEmpty ? "" : " (\(selectedTransactionIDs.count))")")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.negative)
                    .disabled(selectedTransactionIDs.isEmpty)
                    .padding(.top, 4)
                }
            }
        }
        .confirmationDialog(
            "Delete transaction\(transactionsPendingDelete.map { $0.count == 1 ? "" : "s" } ?? "")?",
            isPresented: Binding(
                get: { transactionsPendingDelete != nil },
                set: { if !$0 { transactionsPendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(transactionsPendingDelete.map { "Delete \($0.count) Transaction\($0.count == 1 ? "" : "s")" } ?? "Delete", role: .destructive) {
                if let pending = transactionsPendingDelete { deleteTransactions(pending) }
                transactionsPendingDelete = nil
            }
            Button("Cancel", role: .cancel) { transactionsPendingDelete = nil }
        } message: {
            Text("This removes the expense from its trip for everyone it's shared with.")
        }
    }

    /// Deletes the underlying expense for each transaction and exits selection mode.
    private func deleteTransactions(_ transactions: [Transaction]) {
        let groupedByTrip = Dictionary(grouping: transactions, by: \.tripID)
        for (tripID, tripTransactions) in groupedByTrip {
            store.deleteExpenses(Set(tripTransactions.map(\.expenseID)), from: tripID)
        }
        selectedTransactionIDs.removeAll()
        withAnimation(.snappy) { isSelectingTransactions = false }
    }
}

// MARK: - Balance Card

/// The gradient budget card. Totals are aggregated across every trip the user is part of.
/// Tapping the convert button flips the card to reveal a live currency converter on the back.
struct BalanceCard: View {
    @Environment(TripStore.self) private var store
    @State private var showConverter = false

    var body: some View {
        ZStack {
            budgetFace
                .opacity(showConverter ? 0 : 1)
                .allowsHitTesting(!showConverter)

            CurrencyConverterCard(onClose: flip)
                .opacity(showConverter ? 1 : 0)
                .allowsHitTesting(showConverter)
        }
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
    }

    private func flip() {
        withAnimation(.easeInOut(duration: 0.28)) {
            showConverter.toggle()
        }
    }

    private var budgetFace: some View {
        // One pass over the trips for all four figures (see `TripStore.homeTotals`).
        let totals = store.homeTotals
        return VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("Budget Available", systemImage: "wallet.bifold.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.95))
                Spacer()
                Button(action: flip) {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel("Currency converter")
            }

            Text(money(totals.available, "USD"))
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            HStack {
                Label("Total spent", systemImage: "wallet.bifold")
                    .font(.footnote.weight(.medium))
                Text(money(totals.spent, "USD")).font(.footnote.weight(.semibold))
                Spacer()
                if !store.myTrips.isEmpty {
                    Text("Across \(store.myTrips.count) trip\(store.myTrips.count == 1 ? "" : "s")")
                        .font(.footnote)
                }
            }
            .foregroundStyle(.white.opacity(0.85))

            HStack(spacing: 12) {
                infoColumn(icon: "arrow.up.right", label: "You owe", value: money(totals.youOwe, "USD"))
                infoColumn(icon: "arrow.down.left", label: "People owe", value: money(totals.owedToYou, "USD"))
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [Color(hex: 0xB8E6F5), Color(hex: 0x5B9BD5), Color(hex: 0x2E4A8B)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        )
        .clipShape(.rect(cornerRadius: 34))
    }

    private func infoColumn(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 32, height: 32)
                .background(.white.opacity(0.15), in: .circle)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.caption)
                Text(value).font(.subheadline.weight(.semibold))
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Trip Row

/// A summary card for one trip on the home screen. Adapted from the capstone's
/// `UserTripCard`: the signed-in user's spent/remaining budget shown as paired stat
/// boxes, a budget-usage bar that shifts color as they approach (amber) or exceed (red)
/// their limit, a member badge, a budget-health badge, and a "View trip" affordance —
/// plus this app's core owe / owed status.
struct TripRow: View {
    let trip: Trip
    let currentUserID: Person.ID

    // Budget health (per the signed-in user's own budget on this trip). Computed once at
    // init: `spent(for:)` walks every expense, and the card reads these values from half a
    // dozen subviews, so recomputing per access made each card render O(subviews × expenses).
    private let budget: Double
    private let spent: Double
    private let remaining: Double
    private let hasBudget: Bool
    private let percent: Double
    private let isOver: Bool
    private let isNear: Bool

    init(trip: Trip, currentUserID: Person.ID) {
        self.trip = trip
        self.currentUserID = currentUserID
        let budget = trip.budget(for: currentUserID)
        let spent = trip.spent(for: currentUserID)
        self.budget = budget
        self.spent = spent
        self.remaining = budget - spent
        self.hasBudget = budget > 0
        self.percent = budget > 0 ? (spent / budget) * 100 : 0
        self.isOver = budget > 0 && spent > budget
        self.isNear = budget > 0 && spent <= budget && percent >= 80
    }

    private var accent: Color {
        isOver ? Color(hex: 0xDC2626) : isNear ? Color(hex: 0xD97706) : Color(hex: 0x16A34A)
    }
    private var progressColors: [Color] {
        isOver ? [Color(hex: 0xF87171), Color(hex: 0xDC2626)]
            : isNear ? [Color(hex: 0xFBBF24), Color(hex: 0xD97706)]
            : [Color(hex: 0x6366F1), Color(hex: 0x8B5CF6)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            cover
            VStack(alignment: .leading, spacing: 12) {
                titleRow
                dateRow
                budgetBoxes
                progress
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial)
        }
        .clipShape(.rect(cornerRadius: 24))
        .overlay(
            RoundedRectangle(cornerRadius: 24)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.18), radius: 10, y: 5)
    }

    // MARK: Cover

    private var cover: some View {
        TripCoverView(trip: trip)
            .frame(height: 130)
            .frame(maxWidth: .infinity)
            .clipped()
            .overlay {
                LinearGradient(
                    colors: [.clear, .clear, .black.opacity(0.55)],
                    startPoint: .top, endPoint: .bottom
                )
            }
            .overlay(alignment: .bottomLeading) {
                Label(trip.location?.isEmpty == false ? trip.location! : trip.name,
                      systemImage: "mappin.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(12)
            }
            .overlay(alignment: .topTrailing) {
                if isOver || isNear { healthBadge.padding(12) }
            }
    }

    private var healthBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: isOver ? "exclamationmark.triangle.fill" : "gauge.high")
                .font(.system(size: 10, weight: .bold))
            Text(isOver ? "Over budget" : "Near limit")
                .font(.system(size: 11, weight: .bold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(accent, in: .capsule)
    }

    // MARK: Body content

    private var titleRow: some View {
        HStack(spacing: 8) {
            Text(trip.name).font(.headline.weight(.bold)).lineLimit(1)
            Spacer(minLength: 6)
            HStack(spacing: 4) {
                Image(systemName: "person.2.fill").font(.system(size: 11))
                Text("\(trip.members.count)").font(.caption.weight(.semibold))
            }
            .foregroundStyle(.secondary)
        }
    }

    private var dateRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "calendar").font(.caption)
            Text(trip.dateRangeText ?? "\(trip.expenses.count) expense\(trip.expenses.count == 1 ? "" : "s")")
                .font(.caption)
        }
        .foregroundStyle(.secondary)
    }

    private var budgetBoxes: some View {
        HStack(spacing: 12) {
            statBox(
                label: "SPENT",
                value: money(spent, trip.currencyCode),
                valueColor: Color(hex: 0x6366F1),
                background: Color(hex: 0x6366F1).opacity(0.10)
            )
            statBox(
                label: isOver ? "OVER BY" : "REMAINING",
                value: money(abs(remaining), trip.currencyCode),
                valueColor: accent,
                background: (isOver ? Color(hex: 0xDC2626) : Color(hex: 0x16A34A)).opacity(0.12)
            )
        }
    }

    private func statBox(label: String, value: String, valueColor: Color, background: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .semibold)).tracking(0.5)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.bold)).foregroundStyle(valueColor)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10).padding(.horizontal, 12)
        .background(background, in: .rect(cornerRadius: 12))
    }

    private var progress: some View {
        VStack(spacing: 6) {
            HStack {
                Text("Budget Usage").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(hasBudget ? "\(Int(percent.rounded()))%" : "No budget set")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isOver || isNear ? accent : .secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.1))
                    Capsule()
                        .fill(LinearGradient(colors: progressColors, startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * min(1, max(0, percent / 100)))
                }
            }
            .frame(height: 8)
        }
    }
}

// MARK: - Currency Converter

/// A live currency converter backed by the Exchange Rates API. Rendered as the back face
/// of `BalanceCard`; `onClose` flips the card back to the budget summary.
struct CurrencyConverterCard: View {
    var onClose: (() -> Void)? = nil

    private let currencies = ["USD", "EUR", "GBP", "JPY", "CAD", "AUD", "CNY", "KRW", "THB", "SGD", "VND", "INR"]

    @State private var amountText = "100"
    @State private var from = "USD"
    @State private var to = "EUR"
    @State private var rates: [String: Double] = [:]
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var rate: Double? { rates[to] }

    private var converted: Double? {
        guard let amount = Double(amountText), let rate else { return nil }
        return amount * rate
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Currency Converter", systemImage: "arrow.left.arrow.right.circle.fill")
                    .font(.headline)
                Spacer()
                if isLoading {
                    ProgressView().controlSize(.small)
                }
                if let onClose {
                    Button(action: onClose) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.primary)
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .accessibilityLabel("Back to budget")
                }
            }

            HStack(spacing: 12) {
                TextField("0", text: $amountText)
                    .keyboardType(.decimalPad)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(.secondary.opacity(0.12), in: .rect(cornerRadius: 12))

                currencyMenu(selection: $from)
                    .onChange(of: from) { _, _ in Task { await loadRates() } }

                Image(systemName: "arrow.right")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.secondary)

                currencyMenu(selection: $to)
            }

            Divider()

            if let errorMessage {
                Label(errorMessage, systemImage: "wifi.exclamationmark")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text(converted.map { String(format: "%.2f", $0) } ?? "—")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                    Text(to)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                if let rate {
                    Text(String(format: "1 %@ = %.4f %@", from, rate, to))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 34))
        .task { await loadRates() }
    }

    private func currencyMenu(selection: Binding<String>) -> some View {
        Menu {
            Picker("Currency", selection: selection) {
                ForEach(currencies, id: \.self) { Text($0).tag($0) }
            }
        } label: {
            HStack(spacing: 4) {
                Text(selection.wrappedValue).font(.subheadline.weight(.semibold))
                Image(systemName: "chevron.down").font(.caption2.weight(.bold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.secondary.opacity(0.12), in: .capsule)
        }
    }

    private func loadRates() async {
        isLoading = true
        errorMessage = nil
        do {
            rates = try await CurrencyService.shared.rates(base: from)
        } catch {
            errorMessage = "Couldn't load rates. Check your connection."
        }
        isLoading = false
    }
}

// MARK: - Quick Action Button

/// A compact pill action: a small gradient icon and a single label, on liquid glass.
struct QuickActionButton: View {
    let title: String
    let icon: String
    let colors: [Color]
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(
                        LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: .circle
                    )
                Text(title).font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
    }
}

// MARK: - Trip Picker

/// A glass sheet for choosing which trip a quick action (split / add expense) applies to,
/// replacing the stock confirmation dialog with legible, tappable trip rows.
struct TripPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let trips: [Trip]
    let prompt: String
    let onSelect: (Trip) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(prompt)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.bottom, 2)

                    ForEach(trips) { trip in
                        Button { onSelect(trip) } label: { row(trip) }
                            .buttonStyle(.plain)
                    }
                }
                .padding()
            }
            .background {
                LinearGradient(colors: Theme.homeGradient, startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
            }
            .navigationTitle("Choose a Trip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func row(_ trip: Trip) -> some View {
        HStack(spacing: 12) {
            TripCoverView(trip: trip)
                .frame(width: 52, height: 52)
                .clipShape(.rect(cornerRadius: 14))

            VStack(alignment: .leading, spacing: 2) {
                Text(trip.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(trip.dateRangeText ?? "\(trip.expenses.count) expense\(trip.expenses.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18))
    }
}

// MARK: - Recent Transactions

struct Transaction: Identifiable {
    /// Stable identity tied to the underlying expense so selection survives re-renders.
    /// (A fresh `UUID()` here would change on every recompute of `allTransactions`,
    /// breaking multi-select.)
    var id: Expense.ID { expenseID }
    let tripID: Trip.ID
    let expenseID: Expense.ID
    let name: String
    let category: String
    let date: String
    let amount: Double
    let currencyCode: String
    let color: Color
    /// The underlying date, used to sort newest-first.
    let sortDate: Date
    /// Whether the signed-in account may delete the underlying expense (trip owner,
    /// or whoever paid it), mirroring `TripDetailView.canModify`.
    let canDelete: Bool

    var initials: String {
        let parts = name.split(separator: " ")
        return String(parts.prefix(2).compactMap(\.first)).uppercased()
    }
}

struct TransactionRow: View {
    let transaction: Transaction
    /// Non-nil while the list is in multi-select mode; toggled on tap instead of swiping.
    var isSelected: Bool? = nil
    var onTap: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 12) {
            if let isSelected {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Theme.accent : .secondary)
            }

            Text(transaction.initials)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(transaction.color, in: .circle)

            VStack(alignment: .leading, spacing: 2) {
                Text(transaction.name).font(.subheadline.weight(.semibold))
                Text("\(transaction.category) • \(transaction.date)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(money(transaction.amount, transaction.currencyCode))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .contentShape(.rect)
        .onTapGesture { onTap?() }
    }
}

#Preview {
    HomeScreen()
        .environment(TripStore())
}
