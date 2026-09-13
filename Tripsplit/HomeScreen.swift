import SwiftUI

/// The TripSplit-style main dashboard: greeting, balance card, quick actions,
/// and recent transactions.
struct HomeScreen: View {
    var isActive = true
    var onBrowseIdeas: () -> Void = {}
    @Environment(TripStore.self) private var store
    @Environment(AuthStore.self) private var auth
    @Environment(\.colorScheme) private var colorScheme
    @State private var showAddTrip = false
    @State private var showSignInAlert = false
    @State private var resumeAddTripAfterSignIn = false
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

    private var highContrastInk: Color { colorScheme == .dark ? .white : .black }
    private var highContrastSurface: Color { colorScheme == .dark ? .black : .white }

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
                VStack(alignment: .leading, spacing: Theme.Space.section) {
                    syncBanner
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .animation(.snappy, value: store.syncState)
                    BalanceCard()
                    quickActions
                    tripsSection
                    recentTransactions
                }
                .padding(.horizontal, Theme.contentInset)
                .padding(.bottom, 110)
            }
            .background { AppBackground() }
            .navigationTitle("Your trips")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { AppearanceToggle() }
            }
            .refreshable {
                // A deliberate refresh must bypass the repository's short-lived launch
                // cache or another trip member's recent edits remain invisible.
                await store.loadFromCloud(forceRefresh: true)
                await store.refreshRates()
            }
        }
        .sheet(isPresented: $showAddTrip) {
            AddTripView()
        }
        .sheet(isPresented: $showArchivedTrips) {
            ArchivedTripsSheet()
        }
        .sheet(item: $selectedTrip) { trip in
            TripDetailView(tripID: trip.id)
        }
        .sheet(item: $splitTrip) { trip in
            AddExpenseView(tripID: trip.id, startWithFullSplit: true)
        }
        .sheet(item: $expenseTrip) { trip in
            AddExpenseView(tripID: trip.id)
        }
        .sheet(isPresented: $showTripPicker, onDismiss: routePendingAction) {
            TripPickerSheet(
                trips: store.myTrips,
                prompt: pendingAction == .split ? "Split an expense in which trip?" : "Add an expense to which trip?"
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
        .sheet(isPresented: $showSignInAlert) {
            AuthenticationSheet(reason: "Sign in to create trips and save shared expenses.")
        }
        .onChange(of: auth.isAuthenticated) { _, signedIn in
            guard signedIn else { return }
            if resumeAddTripAfterSignIn {
                resumeAddTripAfterSignIn = false
                showAddTrip = true
            } else if pendingAction != nil {
                if store.myTrips.isEmpty { showAddTrip = true }
                else { showTripPicker = true }
            }
        }
        .task {
            // Load USD exchange rates so the balance card can normalize every trip's currency.
            await store.refreshRates()
        }
    }

    /// Starts a quick action by asking which trip to use (or prompting to create one).
    private func startQuickAction(_ action: QuickAction) {
        pendingAction = action
        guard auth.isAuthenticated else {
            showSignInAlert = true
            return
        }
        guard !store.myTrips.isEmpty else {
            showAddTrip = true
            return
        }
        showTripPicker = true
    }

    private func requestAddTrip() {
        guard auth.isAuthenticated else {
            resumeAddTripAfterSignIn = true
            showSignInAlert = true
            return
        }
        showAddTrip = true
    }

    /// After the trip-picker sheet dismisses, opens the chosen trip's saved split or add-expense
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
                Text("Trips")
                    .homeSectionHeading()
                    .padding(.leading, 4)
                Spacer()
                Button {
                    requestAddTrip()
                } label: {
                    Label("Add Trip", systemImage: "plus")
                        .font(Theme.Typography.rowTitle)
                        .foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 44)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .actionFill(tint: Theme.accent)

            }

            if store.myTrips.isEmpty {
                if store.cloudLoadState == .loading && auth.isAuthenticated {
                    VStack(spacing: 12) {
                        AppLoadingStateView(
                            title: "Loading your trips…",
                            message: "Syncing the latest plans and expenses."
                        )
                    }
                } else {
                    if case .failed(let message) = store.cloudLoadState {
                        cloudLoadFailure(message)
                    }
                    emptyTripsCard
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(store.myTrips) { trip in
                            Button { selectedTrip = trip } label: {
                                TripRow(trip: trip, currentUserID: store.currentUser.id)
                                    .frame(width: 300)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("trip-card-\(trip.id.uuidString)")
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
                            .font(Theme.Typography.rowTitle)
                            .foregroundStyle(.secondary)
                        Text("Archived")
                            .font(Theme.Typography.rowTitle)
                        Text(verbatim: "\(store.archivedTrips.count)")
                            .font(.app(.caption, .bold))
                            .foregroundStyle(.secondary)
                            .pillTint(Color.secondary.opacity(0.15), horizontal: 8, vertical: 3)
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
                .cardOnlyGlass(cornerRadius: 16)
            }
        }

    }

    private var emptyTripsCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "suitcase")
                .font(.app(.largeTitle))
                .foregroundStyle(Theme.textSecondary)
                .accessibilityHidden(true)
            Text("No trips yet")
                .font(.app(.subheadline, .medium))
            Text("Start with a guide or create an empty trip when you already know where you're going.")
                .font(Theme.Typography.metadata)
                .foregroundStyle(highContrastInk)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(highContrastSurface, in: .rect(cornerRadius: 12))
            Button {
                onBrowseIdeas()
            } label: {
                Label("Browse trip ideas", systemImage: "sparkles")
                    .font(Theme.Typography.rowTitle)
                    .foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 18)
                    .frame(minHeight: 44)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .actionFill(tint: Theme.accent)

            .padding(.top, 4)

            Button {
                requestAddTrip()
            } label: {
                Label("Create empty trip", systemImage: "plus")
                    .font(Theme.Typography.rowTitle)
                    .foregroundStyle(highContrastInk)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 48)
                    .background(highContrastSurface, in: .capsule)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .homePanel()
    }

    private func cloudLoadFailure(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "wifi.exclamationmark")
                .foregroundStyle(Theme.negative)
            VStack(alignment: .leading, spacing: 3) {
                Text("Couldn't refresh trips")
                    .font(Theme.Typography.rowTitle)
                Text(verbatim: message)
                    .font(Theme.Typography.metadata)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Retry") {
                Task { await store.loadFromCloud(forceRefresh: true) }
            }
            .font(.app(.caption, .semibold))
            .buttonStyle(.bordered)
            .tint(Theme.accent)
        }
        .panelPadding(horizontal: 14, vertical: 14)
        .homeGlassPanel(cornerRadius: 16)
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
            .panelPadding(horizontal: 14, vertical: 10)
            .homeGlassPanel(cornerRadius: 14)
        case .failed:
            SyncFailureBanner()
        }
    }

    private var quickActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { expenseActions }
            VStack(spacing: 10) { expenseActions }
        }
    }

    @ViewBuilder
    private var expenseActions: some View {
        Button { startQuickAction(.addExpense) } label: {
            Label("Add expense", systemImage: "plus")
                .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(AppActionStyle())

        Button { startQuickAction(.split) } label: {
            Label("Split expense", systemImage: "divide")
                .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(AppActionStyle(primary: false))
    }

    /// Collapsed groups need only totals, count, and their latest date. Only expanded
    /// groups construct and sort transaction rows; formatting happens in the row view.
    private var transactionGroups: [TripTransactionGroup] {
        store.myTrips.compactMap { trip -> TripTransactionGroup? in
            guard let latest = trip.expenses.lazy.map(\.date).max() else { return nil }
            var transactions: [Transaction] = []
            if expandedTripIDs.contains(trip.id) {
                let members = Dictionary(trip.members.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                transactions = trip.expenses.map { expense in
                    let payer = members[expense.payerID]
                    let payerLabel = payer.map { $0.id == store.currentUser.id ? "You" : $0.name } ?? "—"
                    return Transaction(
                        tripID: trip.id, expenseID: expense.id, name: expense.title,
                        category: "Paid by \(payerLabel)", amount: expense.amount,
                        currencyCode: trip.currencyCode, color: payer?.color ?? Theme.accent,
                        sortDate: expense.date,
                        canDelete: store.isCreator(of: trip) || expense.payerID == store.currentUser.id
                    )
                }.sorted { $0.sortDate > $1.sortDate }
            }
            return TripTransactionGroup(
                id: trip.id, name: trip.name, currencyCode: trip.currencyCode,
                total: trip.expenses.reduce(0) { $0 + $1.amount }, latestDate: latest,
                expenseCount: trip.expenses.count, transactions: transactions
            )
        }.sorted { $0.latestDate > $1.latestDate }
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
                Text("Recent")
                    .homeSectionHeading()
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
                    .font(Theme.Typography.rowTitle)
                    .foregroundStyle(Theme.accent)
                    .buttonStyle(.plain)
                    .frame(minHeight: 44)
                    .contentShape(.rect)

                    Button("Cancel") {
                        isSelectingTransactions = false
                        selectedTransactionIDs.removeAll()
                    }
                    .font(Theme.Typography.rowTitle)
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
                    .frame(minHeight: 44)
                    .contentShape(.rect)
                    .padding(.leading, 12)
                } else if !visibleDeletableTransactions.isEmpty {
                    Button("Select") {
                        isSelectingTransactions = true
                    }
                    .font(Theme.Typography.rowTitle)
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
                        .foregroundStyle(Theme.textSecondary)
                        .accessibilityHidden(true)
                    Text("No transactions yet")
                        .font(.app(.subheadline, .medium))
                    Text("Add an expense to a trip to see it here.")
                        .font(Theme.Typography.metadata)
                        .foregroundStyle(highContrastInk)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(highContrastSurface, in: .rect(cornerRadius: 12))
                }
                .frame(maxWidth: .infinity)
                // Keep the instruction above iOS's bottom scroll-edge fade and the
                // floating dock. At the old height the system faded the last line,
                // reducing its rendered contrast even over an opaque card.
                .padding(.vertical, 12)
                .homePanel()
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
                            .font(Theme.Typography.rowTitle)
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
        // Bounds the chapter itself; the trip groups inside carry hairlines.

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
                LazyVStack(spacing: 0) {
                    ForEach(group.transactions) { transaction in
                        rowDivider
                        transactionRow(transaction)
                    }
                }
            }
        }
        // Trip groups are peers within the transactions chapter, not chapters of their
        // own — a stack of section rules would flatten the hierarchy again.
        .homeGlassPanel()
    }

    @ViewBuilder
    private var rowDivider: some View {
        Divider().padding(.leading, 14)
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
                            .font(Theme.Typography.rowTitle)
                            .lineLimit(1)
                        Text("\(group.expenseCount) expense\(group.expenseCount == 1 ? "" : "s") • \(group.latestDate.formatted(date: .abbreviated, time: .omitted))")
                            .font(Theme.Typography.metadata)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Text(money(group.total, group.currencyCode))
                        .font(Theme.Typography.rowTitle)
                        .monospacedDigit()
                    Image(systemName: "chevron.down")
                        .font(.app(.caption, .bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
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
                    .background(.white, in: AnyShape(Capsule()))
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
    @State private var showBudgetBreakdown = false
    @State private var showTripPicker = false
    @State private var pickerPurpose: PickerPurpose?
    @State private var pendingTrip: Trip?
    @State private var breakdownTrip: Trip?
    @State private var selectedTrip: Trip?
    @State private var editTrip: Trip?
    @State private var isRefreshingRates = false

    private enum PickerPurpose { case budget, settle }

    var body: some View {
        Group {
            if !store.myTrips.isEmpty {
                budgetFace
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
            }
        }
        .sheet(isPresented: $showConverter) {
            CurrencyConverterCard()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(.regularMaterial)
        }
        .sheet(isPresented: $showBudgetBreakdown, onDismiss: openBreakdownTrip) {
            BudgetByTripSheet(
                trips: store.homeTotals(in: displayCurrency).budgetTrips,
                totalTripCount: store.myTrips.count
            ) { tripID in
                breakdownTrip = store.trip(tripID)
                showBudgetBreakdown = false
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackground(.regularMaterial)
        }
        .sheet(isPresented: $showTripPicker, onDismiss: routePickedTrip) {
            TripPickerSheet(
                trips: pickerTrips,
                prompt: pickerPurpose == .budget
                    ? "Which trip needs a personal budget?"
                    : "Which trip would you like to settle?"
            ) { trip in
                pendingTrip = trip
                showTripPicker = false
            }
            .presentationDetents([.medium, .large])
            .presentationBackground(.regularMaterial)
        }
        .sheet(item: $selectedTrip) { trip in
            TripDetailView(tripID: trip.id)
        }
        .sheet(item: $editTrip) { trip in
            EditTripView(tripID: trip.id)
        }
    }

    private var budgetFace: some View {
        // One pass over the trips for all four figures (see `TripStore.homeTotals`).
        let totals = store.homeTotals(in: displayCurrency)
        let hasBudget = totals.budgetedTripCount > 0
        let hasConvertedBudget = totals.budget > 0
        let fraction = hasConvertedBudget ? totals.spent / totals.budget : 0
        let isOver = hasConvertedBudget && totals.spent > totals.budget
        let isNear = hasConvertedBudget && !isOver && fraction >= 0.8
        // Budget health uses one semantic palette across the home summary and trip rows.
        let statusColor = isOver ? Theme.negative
            : isNear ? Theme.warning
            : Theme.positive
        let heroValue = hasBudget && !hasConvertedBudget
            ? "—"
            : hasBudget
            ? (isOver
                ? summaryMoney(totals.spent - totals.budget, displayCurrency, compact: true)
                : summaryMoney(totals.available, displayCurrency, compact: true))
            : summaryMoney(totals.spent, displayCurrency, compact: true)
        let heroLabel = !hasBudget ? "Total spent" : (isOver ? "Over budget" : "Remaining")
        let statusText = isOver ? "Over budget" : isNear ? "Running low" : "On track"
        let unbudgetedCount = totals.totalTripCount - totals.budgetedTripCount

        return VStack(alignment: .leading, spacing: 16) {
            (dynamicTypeSize.isAccessibilitySize
             ? AnyLayout(VStackLayout(alignment: .leading, spacing: Theme.Space.compact))
             : AnyLayout(HStackLayout(spacing: Theme.Space.compact))) {
                Group {
                    if hasBudget {
                        Text("Your budget")
                    } else {
                        Text("Spending")
                    }
                }
                .font(Theme.Typography.rowTitle)
                .foregroundStyle(Theme.ink)
                if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                HStack(spacing: Theme.Space.compact) {
                    Menu {
                        Picker("Home currency", selection: $displayCurrency) {
                            ForEach(supportedCurrencies, id: \.self) { code in
                                Text(verbatim: code).tag(code)
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Text(verbatim: displayCurrency).fixedSize()
                            Image(systemName: "chevron.down")
                                .font(.app(.caption2, .bold))
                        }
                        .font(.app(.caption, .semibold))
                        .padding(.horizontal, 11)
                        .frame(minHeight: 36)
                        .background {
                            Capsule().fill(Color.primary.opacity(0.07))
                        }
                        .contentShape(AnyShape(Capsule()))
                    }
                    .accessibilityLabel("Home currency")

                    Menu {
                        Button {
                            showConverter = true
                        } label: {
                            Label("Convert currencies", systemImage: "arrow.left.arrow.right")
                        }
                        Button {
                            showBudgetInfo = true
                        } label: {
                            Label("How totals work", systemImage: "info.circle")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 40, height: 40)
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("More budget options")
                    .popover(isPresented: $showBudgetInfo) {
                        budgetInfoPopover
                            .presentationCompactAdaptation(.popover)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 14) {
                Button {
                    if hasBudget { showBudgetBreakdown = true }
                } label: {
                    // At accessibility sizes the status label and the hero's caption
                    // cannot share a line — the caption gets squeezed into a two-word
                    // column and hyphenates. Stack them, as `statGrid` already does.
                    heroLayout {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: heroValue)
                                .font(.app(.largeTitle, .bold))
                                .foregroundStyle(isOver ? statusColor : Theme.ink)
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)

                            Group {
                                if hasConvertedBudget {
                                    Text("\(Text(LocalizedStringKey(heroLabel))) · \(summaryMoney(totals.budget, displayCurrency, compact: true)) budget")
                                } else if totals.budgetedTripCount == totals.totalTripCount {
                                    Text("\(Text(LocalizedStringKey(heroLabel))) · \(totals.totalTripCount) trips budgeted")
                                } else {
                                    Text("\(Text(LocalizedStringKey(heroLabel))) · \(totals.budgetedTripCount) of \(totals.totalTripCount) trips budgeted")
                                }
                            }
                            .fixedSize(horizontal: false, vertical: true)
                            .font(Theme.Typography.secondary)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                        }

                        if hasConvertedBudget {
                            Spacer(minLength: 8)
                            // Budget health as a glyph, not a sentence; the label is
                            // kept for VoiceOver.
                            Image(systemName: isOver ? "exclamationmark" : isNear ? "gauge.with.needle" : "checkmark")
                                .font(.app(.body, .bold))
                                .foregroundStyle(statusColor)
                                .frame(width: 44, height: 44)
                                .background(statusColor.opacity(0.12), in: .circle)
                                .accessibilityLabel(LocalizedStringKey(statusText))
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(!hasBudget)
                .accessibilityHint(hasBudget ? "Shows budget details by trip" : "")

                if hasConvertedBudget {
                    Button { showBudgetBreakdown = true } label: {
                        tripSegments(totals, isOver: isOver, isNear: isNear)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(Int((fraction * 100).rounded()))% of budget used")
                } else if hasBudget {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Updating rates…")
                            .font(Theme.Typography.metadata)
                            .foregroundStyle(.secondary)
                    }
                    .frame(minHeight: 44)
                } else {
                    noBudgetCallout
                }

                if totals.youOwe > 0 || totals.owedToYou > 0 {
                    settlementBand(totals)
                }

                if unbudgetedCount > 0 && hasBudget {
                    missingBudgetBand(count: unbudgetedCount)
                }

                if !totals.unavailableCurrencies.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .foregroundStyle(.secondary)
                        Text("Some trips need an exchange-rate refresh")
                            .font(.app(.caption2))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            refreshRates()
                        } label: {
                            if isRefreshingRates {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Refresh rates")
                                    .font(.app(.caption, .semibold))
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.accent)
                        .disabled(isRefreshingRates)
                    }
                }
            }
        }
        .panelPadding(horizontal: 16, vertical: 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Opens the screen: chapter air, no rule. Under the large navigation title a
        // rule here reads as an underline on the title, not as a boundary.
        .homePanel(cornerRadius: 24, elevated: true)
    }

    /// The hero figure and its status label side by side, stacking at accessibility
    /// sizes where they no longer fit on one line.
    private var heroLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .bottom, spacing: 12))
    }

    /// Spending as one bar split per trip, each segment in that trip's cover colour,
    /// with a swatch legend beneath — the visual stand-in for the old spent/budget
    /// stat boxes. Over budget, the bar scales to total spend so the overflow shows.
    private func tripSegments(_ totals: TripStore.HomeTotals, isOver: Bool, isNear: Bool) -> some View {
        let trips = totals.budgetTrips.filter { ($0.convertedSpent ?? 0) > 0 }
        let scale = max(totals.budget, totals.spent, 0.01)
        let statusColor = isOver ? Theme.negative : isNear ? Theme.warning : Theme.accent

        return VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(trips) { trip in
                        let fraction = (trip.convertedSpent ?? 0) / scale
                        Rectangle()
                            .fill(TripCoverView.palette(for: trip.id).first ?? Theme.accent)
                            .frame(width: max(2, geo.size.width * fraction))
                    }
                    if isOver {
                        // The overflow segment is the only place status colour appears.
                        Rectangle()
                            .fill(statusColor)
                            .frame(width: max(2, geo.size.width * (totals.spent - totals.budget) / scale))
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(height: 10)
            .background(Color.primary.opacity(0.08))
            .clipShape(.rect(cornerRadius: 5))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(trips) { trip in
                        HStack(spacing: 6) {
                            LinearGradient(
                                colors: TripCoverView.palette(for: trip.id),
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                            .frame(width: 22, height: 22)
                            .clipShape(.rect(cornerRadius: 7))
                            Text(verbatim: summaryMoney(trip.convertedSpent ?? 0, displayCurrency, compact: true))
                                .font(.app(.caption, .semibold))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(Text(verbatim: trip.name))
                    }
                }
            }
            .scrollClipDisabled()
        }
    }

    private var noBudgetCallout: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Plan spending before the trip")
                    .font(Theme.Typography.rowTitle)
                Text("Budgets are personal and set per trip.")
                    .font(Theme.Typography.metadata)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Set a budget", action: startBudgetFlow)
                .font(.app(.caption, .semibold))
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)

        }
        .calloutBlock(tint: Theme.accent.opacity(0.08), horizontal: 12, vertical: 12)
    }

    private func settlementBand(_ totals: TripStore.HomeTotals) -> some View {
        HStack(spacing: 6) {
            if totals.youOwe > 0 {
                Text("You owe").foregroundStyle(.secondary)
                Text(verbatim: summaryMoney(totals.youOwe, displayCurrency))
                    .foregroundStyle(Theme.negative)
            }
            if totals.youOwe > 0 && totals.owedToYou > 0 {
                Text(verbatim: "·").foregroundStyle(.tertiary)
            }
            if totals.owedToYou > 0 {
                Text("Owed to you").foregroundStyle(.secondary)
                Text(verbatim: summaryMoney(totals.owedToYou, displayCurrency))
                    .foregroundStyle(Theme.positive)
            }
            Spacer(minLength: 6)
            Button("Record payment", action: startSettleFlow)
                .font(.app(.caption, .semibold))
                .buttonStyle(.bordered)
                .tint(Theme.accent)

        }
        .font(.app(.caption, .semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.72)
        .calloutBlock(tint: Color.primary.opacity(0.045), vertical: 9)
    }

    private func missingBudgetBand(count: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(.secondary)
            if count == 1 {
                Text("1 trip has no budget")
            } else {
                Text("\(count) trips have no budget")
            }
            Spacer()
            Button("Set one", action: startBudgetFlow)
                .font(.app(.caption, .semibold))
                .foregroundStyle(Theme.accent)
        }
        .font(Theme.Typography.metadata)
        .calloutBlock(tint: Color.primary.opacity(0.035))
    }

    private var pickerTrips: [Trip] {
        switch pickerPurpose {
        case .budget:
            return store.myTrips.filter { $0.budget(for: store.currentUser.id) <= 0 }
        case .settle:
            let ids = Set(store.homeTotals(in: displayCurrency).settlementTripIDs)
            return store.myTrips.filter { ids.contains($0.id) }
        case nil:
            return []
        }
    }

    private func startBudgetFlow() {
        let trips = store.myTrips.filter { $0.budget(for: store.currentUser.id) <= 0 }
        if let trip = trips.first, trips.count == 1 {
            editTrip = trip
        } else if !trips.isEmpty {
            pickerPurpose = .budget
            showTripPicker = true
        }
    }

    private func startSettleFlow() {
        let ids = Set(store.homeTotals(in: displayCurrency).settlementTripIDs)
        let trips = store.myTrips.filter { ids.contains($0.id) }
        if let trip = trips.first, trips.count == 1 {
            selectedTrip = trip
        } else if !trips.isEmpty {
            pickerPurpose = .settle
            showTripPicker = true
        }
    }

    private func routePickedTrip() {
        defer { pendingTrip = nil; pickerPurpose = nil }
        guard let trip = pendingTrip else { return }
        switch pickerPurpose {
        case .budget: editTrip = trip
        case .settle: selectedTrip = trip
        case nil: break
        }
    }

    private func openBreakdownTrip() {
        defer { breakdownTrip = nil }
        if let breakdownTrip { selectedTrip = breakdownTrip }
    }

    private func refreshRates() {
        Task {
            isRefreshingRates = true
            await store.refreshRates()
            isRefreshingRates = false
        }
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

private struct BudgetByTripSheet: View {
    @Environment(\.dismiss) private var dismiss
    let trips: [TripStore.HomeBudgetTrip]
    let totalTripCount: Int
    let onSelect: (Trip.ID) -> Void

    private var sortedTrips: [TripStore.HomeBudgetTrip] {
        trips.sorted { left, right in
            left.spent / left.budget > right.spent / right.budget
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(sortedTrips) { trip in
                        Button { onSelect(trip.id) } label: {
                            budgetRow(trip)
                        }
                        .buttonStyle(.plain)
                    }

                    let missingCount = totalTripCount - trips.count
                    if missingCount > 0 {
                        HStack(spacing: 9) {
                            Image(systemName: "info.circle")
                            if missingCount == 1 {
                                Text("1 trip has no personal budget")
                            } else {
                                Text("\(missingCount) trips have no personal budget")
                            }
                        }
                        .font(Theme.Typography.metadata)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                        .padding(.top, 4)
                    }
                }
                .padding()
            }
            .background { AppBackground() }
            .navigationTitle("Budget by trip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func budgetRow(_ trip: TripStore.HomeBudgetTrip) -> some View {
        let fraction = trip.spent / trip.budget
        let isOver = trip.spent > trip.budget
        let isNear = !isOver && fraction >= 0.8
        let color = isOver ? Theme.negative
            : isNear ? Theme.warning
            : Theme.positive
        let colors = isOver ? [Theme.negative]
            : isNear ? [Theme.warning]
            : [Theme.positive]

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(verbatim: trip.name)
                    .font(Theme.Typography.rowTitle)
                    .lineLimit(1)
                Spacer()
                if isOver {
                    Text("Over by")
                    Text(verbatim: money(trip.spent - trip.budget, trip.currencyCode))
                } else {
                    Text("Remaining")
                    Text(verbatim: money(trip.budget - trip.spent, trip.currencyCode))
                }
                Image(systemName: "chevron.right")
                    .font(.app(.caption2, .bold))
            }
            .font(.app(.caption, .semibold))
            .foregroundStyle(color)

            MeterBar(fraction: fraction, colors: colors)

            HStack(spacing: 4) {
                Text(verbatim: money(trip.spent, trip.currencyCode))
                Text("of")
                Text(verbatim: money(trip.budget, trip.currencyCode))
                Spacer()
                Text(verbatim: "\(Int((fraction * 100).rounded()))%")
            }
            .font(Theme.Typography.metadata)
            .foregroundStyle(.secondary)
        }
        .panelPadding(horizontal: 14, vertical: 14)
        .homePanel(cornerRadius: 16)
        .contentShape(.rect(cornerRadius: 16))
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
        isOver ? Theme.negative : isNear ? Theme.warning : Theme.positive
    }
    private var progressColors: [Color] {
        isOver ? [Theme.negative]
            : isNear ? [Theme.warning]
            : [Theme.accent, Theme.accentSecondary]
    }

    var body: some View {
        Group {
            photoCard
        }
        .clipShape(.rect(cornerRadius: 24))
        .overlay(
            RoundedRectangle(cornerRadius: 24)
                .strokeBorder(
                    .white.opacity(0.12),
                    lineWidth: 0.5
                )
        )
        .shadow(color: .black.opacity(0.18), radius: 10, y: 5)
    }

    // MARK: Photo card (card themes)

    /// The cover is the whole card: location chip and member avatars along the top,
    /// title, dates, the remaining figure and a hairline meter on a scrim at the foot.
    private var photoCard: some View {
        TripCoverView(trip: trip)
            .frame(height: 220)
            .frame(maxWidth: .infinity)
            .clipped()
            .overlay {
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.18), location: 0),
                        .init(color: .clear, location: 0.25),
                        .init(color: .clear, location: 0.42),
                        .init(color: .black.opacity(0.68), location: 1)
                    ],
                    startPoint: .top, endPoint: .bottom
                )
            }
            .overlay(alignment: .topLeading) {
                if let location = trip.location, !location.isEmpty {
                    Label(location, systemImage: "mappin.circle.fill")
                        .font(.app(.caption, .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .frame(minHeight: 28)
                        .background(.white.opacity(0.22), in: .capsule)
                        .padding(14)
                }
            }
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 8) {
                    if isOver || isNear { healthBadge }
                    memberStack
                }
                .padding(14)
            }
            .overlay(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(alignment: .bottom, spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(trip.name)
                                .font(.app(.title3, .bold))
                                .lineLimit(1)
                            Text(trip.dateRangeText ?? "\(trip.expenses.count) expense\(trip.expenses.count == 1 ? "" : "s")")
                                .font(Theme.Typography.metadata)
                                .opacity(0.85)
                        }
                        Spacer(minLength: 8)
                        if hasBudget {
                            VStack(alignment: .trailing, spacing: 1) {
                                Text(money(abs(remaining), trip.currencyCode))
                                    .font(.app(.headline, .bold))
                                    .foregroundStyle(isOver ? Color(hex: 0xFCA5A5) : isNear ? Color(hex: 0xFBBF24) : .white)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                                Text(isOver ? "over" : "left")
                                    .font(.app(.caption2))
                                    .opacity(0.85)
                            }
                        }
                    }
                    if hasBudget {
                        MeterBar(
                            fraction: percent / 100,
                            colors: isOver ? [Color(hex: 0xFCA5A5)] : isNear ? [Color(hex: 0xFBBF24)] : [.white],
                            track: .white.opacity(0.28),
                            height: 4
                        )
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
            }
    }

    /// Up to three member avatars, overlapped, with a "+n" disc for the rest.
    private var memberStack: some View {
        let shown = Array(trip.members.prefix(3))
        let extra = trip.members.count - shown.count
        return HStack(spacing: -8) {
            ForEach(shown) { person in
                AvatarView(person: person, size: 26)
                    .overlay(Circle().strokeBorder(.black.opacity(0.35), lineWidth: 2))
            }
            if extra > 0 {
                Text(verbatim: "+\(extra)")
                    .font(.app(.caption2, .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(.white.opacity(0.3), in: .circle)
                    .overlay(Circle().strokeBorder(.black.opacity(0.35), lineWidth: 2))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(trip.members.count) members")
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
        .background(accent, in: AnyShape(Capsule()))
    }

    // MARK: Body content

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
                            .font(Theme.Typography.rowTitle)
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
                    .font(Theme.Typography.metadata)
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
                Text(verbatim: selection.wrappedValue).font(Theme.Typography.rowTitle)
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

/// A compact pill action with a decorative icon and a single accessible label.
struct QuickActionButton: View {
    let title: LocalizedStringKey
    let icon: String
    /// Gradient behind the icon disc on card themes.
    let tint: [Color]
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    private var highContrastInk: Color { colorScheme == .dark ? .white : .black }
    private var highContrastSurface: Color { colorScheme == .dark ? .black : .white }

    @ViewBuilder
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.app(.body, .bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(
                        LinearGradient(colors: tint, startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: .circle
                    )
                    // The title labels the whole button.
                    .accessibilityHidden(true)
                Text(title)
                    .font(.app(.body, .bold))
                    .foregroundStyle(highContrastInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            // The label has transparent gaps (spacer, padding); without an explicit
            // shape only the icon and text hit-test, leaving dead zones mid-button.
            .contentShape(.rect(cornerRadius: 20))
        }
        .buttonStyle(.plain)
        .background(highContrastSurface, in: .rect(cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20).strokeBorder(Theme.separator, lineWidth: 0.5)
        }
        .shadow(color: Theme.elevatedShadow, radius: 8, y: 3)
    }
}

// MARK: - Trip Picker

/// A glass sheet for choosing which trip a quick action (split / add expense) applies to,
/// replacing the stock confirmation dialog with legible, tappable trip rows.
struct TripPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let trips: [Trip]
    let prompt: LocalizedStringKey
    let onSelect: (Trip) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(prompt)
                        .font(Theme.Typography.secondary)
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
                Text(verbatim: trip.name)
                    .font(Theme.Typography.rowTitle)
                    .lineLimit(1)
                Text(trip.dateRangeText ?? "\(trip.expenses.count) expense\(trip.expenses.count == 1 ? "" : "s")")
                    .font(Theme.Typography.metadata)
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
        .readableSurface(cornerRadius: Theme.cardRadius)
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
                    .font(Theme.Typography.rowTitle)
                    .lineLimit(1)
                Text(trip.dateRangeText ?? "\(trip.expenses.count) expense\(trip.expenses.count == 1 ? "" : "s")")
                    .font(Theme.Typography.metadata)
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
        .readableSurface(cornerRadius: Theme.cardRadius)
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
    let expenseCount: Int
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
    var date: String { sortDate.formatted(date: .abbreviated, time: .omitted) }
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

            VStack(alignment: .leading, spacing: 3) {
                Text(transaction.name).font(Theme.Typography.rowTitle)
                // Payer as a colour dot rather than "Paid by …"; VoiceOver still
                // gets the words.
                HStack(spacing: 6) {
                    Circle()
                        .fill(transaction.color)
                        .frame(width: 8, height: 8)
                    Text(verbatim: transaction.date)
                        .font(Theme.Typography.metadata)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: "\(transaction.category), \(transaction.date)"))
            }
            Spacer()
            Text(money(transaction.amount, transaction.currencyCode))
                .font(Theme.Typography.rowTitle)
                .monospacedDigit()
                .foregroundStyle(Theme.ink)
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
