import SwiftUI

/// The TripSplit-style main dashboard: greeting, balance card, quick actions,
/// and recent transactions.
struct HomeScreen: View {
    var isActive = true
    @Environment(TripStore.self) private var store
    @Environment(AuthStore.self) private var auth
    @AppStorage("appearancePreference") private var appearance: AppearancePreference = .system
    @State private var showAddTrip = false
    @State private var showSettings = false
    @State private var showSignInAlert = false
    @State private var selectedTrip: Trip?

    /// The quick action a user tapped, awaiting a trip choice.
    private enum QuickAction { case split, addExpense }
    @State private var pendingAction: QuickAction?
    @State private var showTripPicker = false
    @State private var pendingTrip: Trip?
    @State private var splitTrip: Trip?
    @State private var expenseTrip: Trip?
    @State private var tripToDelete: Trip?
    @State private var showArchivedTrips = false
    @State private var expandedTripIDs: Set<Trip.ID> = []
    @State private var isSelectingTransactions = false
    @State private var selectedTransactionIDs: Set<Transaction.ID> = []
    @State private var transactionsPendingDelete: [Transaction]?

    var body: some View {
        Group {
            if isActive {
                homeContent
            } else {
                Color.clear.ignoresSafeArea()
            }
        }
    }

    private var homeContent: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    syncBanner
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .animation(.snappy, value: store.syncState)
                    BalanceCard()
                    quickActions
                    tripsSection
                    recentTransactions
                }
                .padding(.horizontal)
                .padding(.bottom, 110)
            }
            .background { AppBackground() }
            .navigationTitle("Hi, \(greetingName)")
            .refreshable {
                await store.loadFromCloud()
                await store.refreshRates()
            }
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    appearanceToggle
                    Button {
                        showSettings = true
                    } label: {
                        ProfileAvatar(
                            imageData: store.profileImageData,
                            initials: store.currentUser.initials,
                            size: 34
                        )
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Profile & settings"))
                }
            }
        }
        .sheet(isPresented: $showAddTrip) {
            AddTripView()
        }
        .sheet(isPresented: $showSettings) {
            SettingsScreen()
        }
        .sheet(isPresented: $showArchivedTrips) {
            ArchivedTripsSheet()
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
        .signInRequiredAlert(isPresented: $showSignInAlert)
        .task {
            // Load USD exchange rates so the balance card can normalize every trip's currency.
            await store.refreshRates()
        }
    }

    /// Starts a quick action by asking which trip to use (or prompting to create one).
    private func startQuickAction(_ action: QuickAction) {
        guard auth.isAuthenticated else {
            showSignInAlert = true
            return
        }
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
                    .font(.app(.headline))
                    .padding(.leading, 4)
                Spacer()
                Button {
                    if auth.isAuthenticated { showAddTrip = true } else { showSignInAlert = true }
                } label: {
                    Label("Add Trip", systemImage: "plus")
                        .font(.app(.subheadline, .semibold))
                        .foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 44)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.tint(Theme.accent).interactive(), in: .capsule)
            }

            if store.myTrips.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "suitcase")
                        .font(.app(.largeTitle))
                        .foregroundStyle(.tertiary)
                    Text("No trips yet")
                        .font(.app(.subheadline, .medium))
                    Text("Create a trip to start tracking expenses.")
                        .font(.app(.caption))
                        .foregroundStyle(.secondary)
                    Button {
                        if auth.isAuthenticated { showAddTrip = true } else { showSignInAlert = true }
                    } label: {
                        Label("Create your first trip", systemImage: "plus")
                            .font(.app(.subheadline, .semibold))
                            .foregroundStyle(Theme.onAccent)
                            .padding(.horizontal, 18)
                            .frame(minHeight: 44)
                            .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.tint(Theme.accent).interactive(), in: .capsule)
                    .padding(.top, 4)
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
                            .contentShape(.contextMenuPreview, .rect(cornerRadius: 24))
                            .contextMenu {
                                Button {
                                    withAnimation(.snappy) {
                                        store.setArchived(true, for: trip.id)
                                    }
                                } label: {
                                    Label("Archive Trip", systemImage: "archivebox")
                                }
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

            if !store.archivedTrips.isEmpty {
                Button { showArchivedTrips = true } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "archivebox")
                            .font(.app(.subheadline, .semibold))
                            .foregroundStyle(.secondary)
                        Text("Archived Trips")
                            .font(.app(.subheadline, .semibold))
                        Text(verbatim: "\(store.archivedTrips.count)")
                            .font(.app(.caption, .bold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.secondary.opacity(0.15), in: .capsule)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.app(.caption, .bold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 48)
                    .contentShape(.rect(cornerRadius: 16))
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
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
                Text("Saving to cloud…").font(.app(.caption, .medium)).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .glassEffect(.regular, in: .rect(cornerRadius: 14))
        case .failed:
            SyncFailureBanner()
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
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .accessibilityLabel("Appearance: \(appearance.label)")
    }

    private var quickActions: some View {
        // No section header: two labeled buttons explain themselves, and dropping
        // the header keeps the balance card + actions + trips above the fold.
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
                        category: "Paid by \(payerLabel)",
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

    /// Transactions rolled up per trip, ordered by each trip's most recent expense.
    /// Summarizing per trip keeps the home feed short; tapping a trip reveals its rows.
    private var transactionGroups: [TripTransactionGroup] {
        let byTrip = Dictionary(grouping: allTransactions, by: \.tripID)
        return store.myTrips.compactMap { trip -> TripTransactionGroup? in
            guard let transactions = byTrip[trip.id], !transactions.isEmpty else { return nil }
            return TripTransactionGroup(
                id: trip.id,
                name: trip.name,
                currencyCode: trip.currencyCode,
                total: transactions.reduce(0) { $0 + $1.amount },
                latestDate: transactions[0].sortDate,
                transactions: transactions
            )
        }
        .sorted { $0.latestDate > $1.latestDate }
    }

    private var recentTransactions: some View {
        // Materialized once per render: `transactionGroups` walks every trip's expenses,
        // formats dates, and sorts — referencing the computed property from each spot
        // below would redo all of that several times per body pass.
        let groups = transactionGroups
        // Selection only applies to rows the user can currently see (expanded trips).
        let visibleDeletableTransactions = groups
            .filter { expandedTripIDs.contains($0.id) }
            .flatMap(\.transactions)
            .filter(\.canDelete)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recent Transactions")
                    .font(.app(.headline))
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
                    .font(.app(.subheadline, .semibold))
                    .foregroundStyle(Theme.accent)
                    .buttonStyle(.plain)
                    .frame(minHeight: 44)
                    .contentShape(.rect)

                    Button("Cancel") {
                        isSelectingTransactions = false
                        selectedTransactionIDs.removeAll()
                    }
                    .font(.app(.subheadline, .semibold))
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
                    .frame(minHeight: 44)
                    .contentShape(.rect)
                    .padding(.leading, 12)
                } else if !visibleDeletableTransactions.isEmpty {
                    Button("Select") {
                        isSelectingTransactions = true
                    }
                    .font(.app(.subheadline, .semibold))
                    .foregroundStyle(Theme.accent)
                    .buttonStyle(.plain)
                    .frame(minHeight: 44)
                    .contentShape(.rect)
                }
            }

            if groups.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "tray")
                        .font(.app(.largeTitle))
                        .foregroundStyle(.tertiary)
                    Text("No transactions yet")
                        .font(.app(.subheadline, .medium))
                    Text("Add an expense to a trip to see it here.")
                        .font(.app(.caption))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
                .glassEffect(.regular, in: .rect(cornerRadius: 20))
            } else {
                GlassEffectContainer(spacing: 12) {
                    // Lazy so expanding a large trip only builds the rows scrolled into view.
                    LazyVStack(spacing: 12) {
                        ForEach(groups) { group in
                            tripGroupCard(group)
                        }
                    }
                }

                if isSelectingTransactions {
                    Button(role: .destructive) {
                        transactionsPendingDelete = groups
                            .flatMap(\.transactions)
                            .filter { selectedTransactionIDs.contains($0.id) }
                    } label: {
                        Text("Delete\(selectedTransactionIDs.isEmpty ? "" : " (\(selectedTransactionIDs.count))")")
                            .font(.app(.subheadline, .semibold))
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

    /// One trip's summary card: a compact header (name, count, total) that expands
    /// on tap to reveal that trip's transactions, newest first. Swiping the header
    /// left archives the trip (only the header, so the expense rows keep their own
    /// swipe-to-delete gesture).
    @ViewBuilder
    private func tripGroupCard(_ group: TripTransactionGroup) -> some View {
        let isExpanded = expandedTripIDs.contains(group.id)
        VStack(spacing: 0) {
            SwipeActionsRow(actions: [
                RowSwipeAction(label: "Archive", icon: "archivebox.fill", tint: Theme.accent) {
                    withAnimation(.snappy) { store.setArchived(true, for: group.id) }
                }
            ]) {
                groupHeaderButton(group, isExpanded: isExpanded)
            }

            if isExpanded {
                VStack(spacing: 0) {
                    ForEach(group.transactions) { transaction in
                        Divider().padding(.leading, 14)
                        transactionRow(transaction)
                    }
                }
            }
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }

    private func groupHeaderButton(_ group: TripTransactionGroup, isExpanded: Bool) -> some View {
        Button {
                withAnimation(.snappy) {
                    if isExpanded {
                        expandedTripIDs.remove(group.id)
                        // Collapsed rows are no longer visible — drop them from selection.
                        selectedTransactionIDs.subtract(group.transactions.map(\.id))
                    } else {
                        expandedTripIDs.insert(group.id)
                    }
                }
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: group.name)
                            .font(.app(.subheadline, .semibold))
                            .lineLimit(1)
                        Text("\(group.transactions.count) expense\(group.transactions.count == 1 ? "" : "s") • \(group.latestDate.formatted(date: .abbreviated, time: .omitted))")
                            .font(.app(.caption))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Text(money(group.total, group.currencyCode))
                        .font(.app(.subheadline, .semibold))
                        .monospacedDigit()
                    Image(systemName: "chevron.down")
                        .font(.app(.caption, .bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .padding(14)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
    }

    /// A single expense row inside an expanded trip card, honoring selection mode
    /// and swipe-to-delete exactly like the old flat list did.
    @ViewBuilder
    private func transactionRow(_ transaction: Transaction) -> some View {
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

    /// Deletes the underlying expense for each transaction and exits selection mode.
    private func deleteTransactions(_ transactions: [Transaction]) {
        let groupedByTrip = Dictionary(grouping: transactions, by: \.tripID)
        for (tripID, tripTransactions) in groupedByTrip {
            store.deleteExpenses(Set(tripTransactions.map(\.expenseID)), from: tripID)
        }
        selectedTransactionIDs.removeAll()
        isSelectingTransactions = false
    }
}

// MARK: - Balance Card

/// A quiet budget summary. Totals are aggregated across every trip the user is part of;
/// currency conversion stays available as a separate utility sheet so the summary never
/// disappears or changes height.
/// Retryable "couldn't save to cloud" banner. Shown inline on Home and overlaid on
/// every other tab (see `ContentView`), so a failed trip save is never silent no
/// matter where the edit happened — itinerary edits in Explore included.
struct SyncFailureBanner: View {
    @Environment(TripStore.self) private var store

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.icloud.fill").foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 1) {
                Text("Couldn't save to cloud").font(.app(.caption, .bold)).foregroundStyle(.white)
                Text(store.syncErrorMessage ?? "Changes are saved on this device only.")
                    .font(.app(.caption2)).foregroundStyle(.white.opacity(0.85))
            }
            Spacer()
            Button { store.retrySync() } label: {
                Text("Retry").font(.app(.caption, .bold)).foregroundStyle(Color(hex: 0xDC2626))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.white, in: .capsule)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color(hex: 0xDC2626), in: .rect(cornerRadius: 14))
    }
}

struct BalanceCard: View {
    @Environment(TripStore.self) private var store
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage("displayCurrency") private var displayCurrency = "USD"
    @State private var showConverter = false
    @State private var showBudgetInfo = false

    var body: some View {
        budgetFace
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
        .sheet(isPresented: $showConverter) {
            CurrencyConverterCard()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(.regularMaterial)
        }
    }

    private var budgetFace: some View {
        // One pass over the trips for all four figures (see `TripStore.homeTotals`).
        let totals = store.homeTotals(in: displayCurrency)
        let hasBudget = totals.budget > 0
        let fraction = hasBudget ? totals.spent / totals.budget : 0
        let isOver = hasBudget && totals.spent > totals.budget
        let isNear = hasBudget && !isOver && fraction >= 0.8
        // Accents mirror the trip cards: indigo healthy, amber near, red over.
        let statusColor = isOver ? Color(hex: 0xDC2626)
            : isNear ? Color(hex: 0xD97706)
            : Theme.accent
        let heroValue = hasBudget
            ? (isOver
                ? summaryMoney(totals.spent - totals.budget, displayCurrency, compact: true)
                : summaryMoney(totals.available, displayCurrency, compact: true))
            : summaryMoney(totals.spent, displayCurrency, compact: true)
        // Without a budget the hero figure is a spending total, not headroom — say so
        // plainly, and title the card "Spending" so it doesn't promise a budget it
        // doesn't have.
        let heroLabel = !hasBudget ? "Total spent" : (isOver ? "Over budget" : "Remaining")
        let statusText = isOver ? "Over budget" : isNear ? "Near limit" : "On track"

        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 4) {
                Text("Overview")
                    .font(.app(.subheadline, .semibold))
                Button {
                    showBudgetInfo = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(.app(.footnote, .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 40, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("How your budget is calculated")
                .popover(isPresented: $showBudgetInfo) {
                    budgetInfoPopover
                        .presentationCompactAdaptation(.popover)
                }
                Spacer()
                Button {
                    showConverter = true
                } label: {
                    Label("Convert", systemImage: "arrow.left.arrow.right")
                        .font(.app(.subheadline, .semibold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 4)
                        .frame(minHeight: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Currency converter")
            }

            // VoiceOver receives the financial summary as one coherent element while the
            // info and converter controls above remain independently actionable.
            VStack(alignment: .leading, spacing: 14) {
                // Hero band: the headline figure on the left, the two facts that qualify
                // it (health, share of budget used) right-aligned opposite it, so the row
                // carries weight across the full card width instead of trailing off.
                HStack(alignment: .bottom, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: heroValue)
                            .font(.app(.largeTitle, .bold))
                            .foregroundStyle(isOver ? statusColor : .primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)
                        HStack(spacing: 5) {
                            Text(LocalizedStringKey(heroLabel))
                            Text(verbatim: "·")
                            Text(verbatim: displayCurrency)
                            Text(verbatim: "·")
                            Text("\(store.myTrips.count) trips")
                        }
                        .font(.app(.subheadline))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    }

                    if hasBudget {
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 5) {
                            Text(LocalizedStringKey(statusText))
                                .font(.app(.caption, .semibold))
                                .foregroundStyle(statusColor)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(statusColor.opacity(0.12), in: .capsule)
                            Text("\(Int((fraction * 100).rounded()))% of budget")
                                .font(.app(.caption))
                                .foregroundStyle(.secondary)
                        }
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    }
                }

                if hasBudget {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.08))
                            Capsule()
                                .fill(statusColor)
                                .frame(width: geo.size.width * min(1, max(0, fraction)))
                                .animation(.easeInOut(duration: 0.4), value: fraction)
                        }
                    }
                    .frame(height: 8)
                } else {
                    Text("No budget set · Set one inside a trip")
                        .font(.app(.caption))
                        .foregroundStyle(.secondary)
                }

                statGrid(totals, hasBudget: hasBudget)

                if !totals.unavailableCurrencies.isEmpty {
                    Text("Some trips need an exchange-rate refresh")
                        .font(.app(.caption2))
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 34))
    }

    /// The four supporting figures as equal tiles: budget health on the top row,
    /// settlement on the bottom. Giving them one shared shape and size stops the
    /// settlement pair from reading as an afterthought below the budget line, and
    /// fills the card's width evenly. Columns collapse to a single stack at
    /// accessibility text sizes, where two tiles per row would truncate.
    private func statGrid(_ totals: TripStore.HomeTotals, hasBudget: Bool) -> some View {
        let boxes = [
            statBox(
                label: "SPENT",
                value: summaryMoney(totals.spent, displayCurrency),
                valueColor: Theme.accent,
                background: Theme.accent.opacity(0.10)
            ),
            statBox(
                label: "BUDGET",
                value: hasBudget ? summaryMoney(totals.budget, displayCurrency) : String(localized: "Not set"),
                valueColor: hasBudget ? .primary : .secondary,
                background: Color.primary.opacity(0.05)
            ),
            // A zero balance is neutral news, so it stays grey — red and green are
            // reserved for amounts that actually need settling.
            statBox(
                label: "YOU OWE",
                value: summaryMoney(totals.youOwe, displayCurrency),
                valueColor: totals.youOwe > 0 ? Color(hex: 0xDC2626) : .secondary,
                background: totals.youOwe > 0 ? Color(hex: 0xDC2626).opacity(0.10) : Color.primary.opacity(0.05)
            ),
            statBox(
                label: "OWED TO YOU",
                value: summaryMoney(totals.owedToYou, displayCurrency),
                valueColor: totals.owedToYou > 0 ? Color(hex: 0x16A34A) : .secondary,
                background: totals.owedToYou > 0 ? Color(hex: 0x16A34A).opacity(0.10) : Color.primary.opacity(0.05)
            )
        ]

        return Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 8) { ForEach(0..<4, id: \.self) { boxes[$0] } }
            } else {
                Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                    GridRow { boxes[0]; boxes[1] }
                    GridRow { boxes[2]; boxes[3] }
                }
            }
        }
    }

    /// One tile in `statGrid`. Mirrors `UserTripCard.statBox` so the home summary and
    /// the trip cards below it read as the same family.
    private func statBox(label: String, value: String, valueColor: Color, background: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(LocalizedStringKey(label))
                .font(.app(.caption2, .semibold)).tracking(0.5)
                .foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.8)
            Text(verbatim: value)
                .font(.app(.subheadline, .bold))
                .foregroundStyle(valueColor)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10).padding(.horizontal, 12)
        .background(background, in: .rect(cornerRadius: 12))
    }

    /// Explains where the headline budget figure comes from: only budgets the user has
    /// explicitly set on their trips count, each converted to their selected home currency.
    private var budgetInfoPopover: some View {
        let me = store.currentUser.id
        let budgetedTrips = store.myTrips.filter { $0.budget(for: me) > 0 }.count
        let totalTrips = store.myTrips.count

        return VStack(alignment: .leading, spacing: 8) {
            Text("How your budget adds up")
                .font(.app(.subheadline, .bold))
            if budgetedTrips > 0 {
                Text("This total is the sum of the budgets you set in each trip, converted to your home currency (\(displayCurrency)). Right now \(budgetedTrips) of your \(totalTrips) trips have a budget set — trips without one add nothing.")
            } else {
                Text("There is no total budget because you haven't set one in any trip yet. Set a budget inside a trip and it will be added here in your home currency (\(displayCurrency)).")
            }
        }
        .font(.app(.footnote))
        .foregroundStyle(.primary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(14)
        .frame(width: 290, alignment: .leading)
    }

    /// Keeps whole amounts clean, adds grouping for readability, and uses compact notation
    /// only for very large hero figures where the alternative would force heavy scaling.
    private func summaryMoney(_ value: Double, _ code: String, compact: Bool = false) -> String {
        let absolute = abs(value)
        let number: String
        if compact && absolute >= 1_000_000 {
            number = value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
        } else {
            number = value.formatted(.number.precision(.fractionLength(0...2)))
        }
        return "\(currencySymbol(code))\(number)"
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
            : [Theme.accent, Theme.accentSecondary]
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
                    .font(.app(.caption, .semibold))
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
                .font(.app(.caption2, .bold))
            Text(isOver ? "Over budget" : "Near limit")
                .font(.app(.caption2, .bold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(accent, in: .capsule)
    }

    // MARK: Body content

    private var titleRow: some View {
        HStack(spacing: 8) {
            Text(trip.name).font(.app(.headline, .bold)).lineLimit(1)
            Spacer(minLength: 6)
            HStack(spacing: 4) {
                Image(systemName: "person.2.fill").font(.app(.caption2))
                Text("\(trip.members.count)").font(.app(.caption, .semibold))
            }
            .foregroundStyle(.secondary)
        }
    }

    private var dateRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "calendar").font(.app(.caption))
            Text(trip.dateRangeText ?? "\(trip.expenses.count) expense\(trip.expenses.count == 1 ? "" : "s")")
                .font(.app(.caption))
        }
        .foregroundStyle(.secondary)
    }

    private var budgetBoxes: some View {
        HStack(spacing: 12) {
            statBox(
                label: "SPENT",
                value: money(spent, trip.currencyCode),
                valueColor: Theme.accent,
                background: Theme.accent.opacity(0.10)
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
            Text(LocalizedStringKey(label))
                .font(.app(.caption2, .semibold)).tracking(0.5)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.app(.subheadline, .bold)).foregroundStyle(valueColor)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10).padding(.horizontal, 12)
        .background(background, in: .rect(cornerRadius: 12))
    }

    private var progress: some View {
        VStack(spacing: 6) {
            HStack {
                Text("Budget Usage").font(.app(.caption)).foregroundStyle(.secondary)
                Spacer()
                Text(hasBudget ? "\(Int(percent.rounded()))%" : "No budget set")
                    .font(.app(.caption, .semibold))
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

/// A focused currency utility presented from `BalanceCard` as a half-sheet. The last-used
/// pair persists across launches; first use starts with the most common active-trip currency
/// and converts into the home currency.
struct CurrencyConverterCard: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(TripStore.self) private var store
    @State private var amountText = "100"
    @State private var rates: [String: Double] = [:]
    @State private var isLoading = false
    @State private var errorMessage: String?
    @FocusState private var amountIsFocused: Bool
    @AppStorage("displayCurrency") private var displayCurrency = "USD"
    @AppStorage("converterFromCurrency") private var from = "USD"
    @AppStorage("converterToCurrency") private var to = "EUR"
    @AppStorage("hasSavedConverterPair") private var hasSavedPair = false

    private var rate: Double? { from == to ? 1 : rates[to] }

    private var converted: Double? {
        guard let amount = parsedAmount, let rate else { return nil }
        return amount * rate
    }

    private var parsedAmount: Double? {
        Double(amountText.replacingOccurrences(of: Locale.current.groupingSeparator ?? ",", with: "")
            .replacingOccurrences(of: Locale.current.decimalSeparator ?? ".", with: "."))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    currencyRow(title: "From", selection: $from) {
                        TextField("0", text: $amountText)
                            .keyboardType(.decimalPad)
                            .focused($amountIsFocused)
                            .font(.app(.title2, .semibold))
                            .lineLimit(1)
                            .accessibilityLabel("Amount to convert")
                    }

                    Button(action: swapCurrencies) {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.app(.subheadline, .semibold))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 44, height: 44)
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Swap currencies")

                    currencyRow(title: "To", selection: $to) {
                        Group {
                            if let converted {
                                Text(verbatim: converted.formatted(.number.precision(.fractionLength(0...2))))
                            } else {
                                Text(verbatim: "—")
                            }
                        }
                        .font(.app(.title, .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                        .accessibilityLabel("Converted amount")
                    }

                    Group {
                        if let rate {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(verbatim: String(format: "1 %@ = %.4f %@", from, rate, to))
                                Text("Rates refreshed within 30 minutes")
                            }
                        } else if let errorMessage {
                            Label(LocalizedStringKey(errorMessage), systemImage: "wifi.exclamationmark")
                        } else if isLoading {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Loading rates…")
                            }
                        }
                    }
                    .font(.app(.caption))
                    .foregroundStyle(.secondary)
                }
                .padding(20)
            }
            .background { AppBackground() }
            .navigationTitle("Convert")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { amountIsFocused = false }
                }
            }
        }
        .onAppear(perform: configureInitialPair)
        .task(id: from) {
            await loadRates(for: from)
        }
    }

    private func currencyRow<Content: View>(
        title: LocalizedStringKey,
        selection: Binding<String>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.app(.caption, .semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                content()
                    .frame(maxWidth: .infinity, alignment: .leading)
                currencyMenu(selection: selection)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 64)
            .background(.secondary.opacity(0.10), in: .rect(cornerRadius: 16))
        }
    }

    private func currencyMenu(selection: Binding<String>) -> some View {
        Menu {
            Picker("Currency", selection: selection) {
                ForEach(supportedCurrencies, id: \.self) { code in
                    Text(verbatim: code).tag(code)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(verbatim: selection.wrappedValue).font(.app(.subheadline, .semibold))
                Image(systemName: "chevron.down").font(.app(.caption2, .bold))
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(.secondary.opacity(0.12), in: .capsule)
            .contentShape(.capsule)
        }
    }

    private func configureInitialPair() {
        guard !hasSavedPair else { return }
        let preferredFrom = mostCommonTripCurrency ?? "USD"
        from = preferredFrom
        to = displayCurrency
        if from == to {
            from = supportedCurrencies.first(where: { $0 != to }) ?? "EUR"
        }
        hasSavedPair = true
    }

    private var mostCommonTripCurrency: String? {
        var counts: [String: Int] = [:]
        var winner: String?
        var winningCount = 0
        for trip in store.myTrips {
            let code = trip.currencyCode
            counts[code, default: 0] += 1
            if counts[code, default: 0] > winningCount {
                winner = code
                winningCount = counts[code, default: 0]
            }
        }
        return winner
    }

    private func swapCurrencies() {
        (from, to) = (to, from)
    }

    private func loadRates(for requestedBase: String) async {
        isLoading = true
        errorMessage = nil
        rates = [:]
        do {
            let fetched = try await CurrencyService.shared.rates(base: requestedBase)
            guard !Task.isCancelled, from == requestedBase else { return }
            rates = fetched
        } catch {
            guard !Task.isCancelled, from == requestedBase else { return }
            errorMessage = "Couldn't load rates. Check your connection."
        }
        if from == requestedBase { isLoading = false }
    }
}

// MARK: - Quick Action Button

/// A compact pill action: a small gradient icon and a single label, on liquid glass.
struct QuickActionButton: View {
    let title: LocalizedStringKey
    let icon: String
    let colors: [Color]
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.app(.body, .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(
                        LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: .circle
                    )
                Text(title).font(.app(.subheadline, .semibold))
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            // The label has transparent gaps (spacer, padding); without an explicit
            // shape only the icon and text hit-test, leaving dead zones mid-button.
            .contentShape(.capsule)
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
                        .font(.app(.subheadline))
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
            .background { AppBackground() }
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
                    .font(.app(.subheadline, .semibold))
                    .lineLimit(1)
                Text(trip.dateRangeText ?? "\(trip.expenses.count) expense\(trip.expenses.count == 1 ? "" : "s")")
                    .font(.app(.caption))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.app(.caption, .bold))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect(cornerRadius: 18))
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18))
    }
}

// MARK: - Archived Trips

/// Lists trips the signed-in user archived: tap a row to reopen the trip, unarchive to
/// bring it back to Home, or (creators only) delete it outright. Archiving is per-account
/// view state, so nothing here affects what other trip members see.
struct ArchivedTripsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(TripStore.self) private var store
    @State private var openTrip: Trip?
    @State private var tripToDelete: Trip?

    var body: some View {
        NavigationStack {
            ScrollView {
                if store.archivedTrips.isEmpty {
                    ContentUnavailableView(
                        "No archived trips",
                        systemImage: "archivebox",
                        description: Text("Swipe or long-press a trip on Home to archive it.")
                    )
                    .padding(.top, 60)
                } else {
                    VStack(spacing: 12) {
                        Text("Archived trips are hidden from your Home screen and totals, but stay synced and visible to other members.")
                            .font(.app(.footnote))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                        ForEach(store.archivedTrips) { trip in
                            SwipeActionsRow(actions: swipeActions(for: trip)) {
                                Button { openTrip = trip } label: { row(trip) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding()
                }
            }
            .background { AppBackground() }
            .navigationTitle("Archived Trips")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .sheet(item: $openTrip) { trip in
            TripDetailView(tripID: trip.id)
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
    }

    /// Unarchive for everyone; delete stays creator-only and sits at the swipe edge
    /// (full swipe), matching the destructive-action convention.
    private func swipeActions(for trip: Trip) -> [RowSwipeAction] {
        var actions = [
            RowSwipeAction(label: "Unarchive", icon: "tray.and.arrow.up.fill", tint: Theme.accent) {
                unarchive(trip)
            }
        ]
        if store.isCreator(of: trip) {
            actions.append(
                RowSwipeAction(label: "Delete", icon: "trash.fill", tint: Theme.negative) {
                    tripToDelete = trip
                }
            )
        }
        return actions
    }

    private func unarchive(_ trip: Trip) {
        withAnimation(.snappy) { store.setArchived(false, for: trip.id) }
    }

    private func row(_ trip: Trip) -> some View {
        HStack(spacing: 12) {
            TripCoverView(trip: trip)
                .frame(width: 52, height: 52)
                .clipShape(.rect(cornerRadius: 14))

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: trip.name)
                    .font(.app(.subheadline, .semibold))
                    .lineLimit(1)
                Text(trip.dateRangeText ?? "\(trip.expenses.count) expense\(trip.expenses.count == 1 ? "" : "s")")
                    .font(.app(.caption))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button { unarchive(trip) } label: {
                Text("Unarchive")
                    .font(.app(.caption, .semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .background(Theme.accent.opacity(0.14), in: .capsule)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect(cornerRadius: 18))
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18))
    }
}

// MARK: - Recent Transactions

/// A trip's expenses rolled up for the home screen's compact "Recent Transactions"
/// section: one summary line per trip, expandable to its individual transactions.
struct TripTransactionGroup: Identifiable {
    let id: Trip.ID
    let name: String
    let currencyCode: String
    /// Sum of the trip's expenses, in the trip's own currency.
    let total: Double
    /// Date of the trip's most recent expense; orders the groups newest-first.
    let latestDate: Date
    /// The trip's transactions, newest first.
    let transactions: [Transaction]
}

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
                    .font(.app(.title3))
                    .foregroundStyle(isSelected ? Theme.accent : .secondary)
            }

            Text(transaction.initials)
                .font(.app(.caption, .bold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(transaction.color, in: .circle)

            VStack(alignment: .leading, spacing: 2) {
                Text(transaction.name).font(.app(.subheadline, .semibold))
                Text("\(transaction.category) • \(transaction.date)")
                    .font(.app(.caption))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(money(transaction.amount, transaction.currencyCode))
                .font(.app(.subheadline, .semibold))
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
        .padding(14)
        .contentShape(.rect)
        .onTapGesture { onTap?() }
    }
}

#Preview {
    HomeScreen()
        .environment(TripStore())
}
