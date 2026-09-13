import SwiftUI
import UIKit

// MARK: - Trip Detail

/// Shows a trip's budget summary, members, and expenses, with an "Add Expense" action.
struct TripDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(TripStore.self) private var store
    @Environment(AuthStore.self) private var auth
    let tripID: Trip.ID

    @State private var showAddExpense = false
    @State private var showEditTrip = false
    @State private var showSignInAlert = false
    @State private var protectedIntent: ProtectedIntent?
    @State private var scrollToSettle = false
    @State private var activeSettlement: Settlement?
    @State private var settlementToConfirm: Settlement?
    @State private var showSettleInfo = false
    @State private var memberToRemove: Person?
    @State private var showLeaveTripConfirmation = false
    @State private var invitations = TripInvitationState()
    @State private var membershipMessage: ActionFeedback?
    @State private var membershipActionBusy = false
    @State private var pendingInvitations: [TripsRepository.PendingInvitation] = []
    @State private var invitationToRevoke: TripsRepository.PendingInvitation?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private enum TripPage: Hashable {
        case history, balances, members, deleted
        var title: LocalizedStringKey {
            switch self {
            case .history: "Expense history"
            case .balances: "All balances"
            case .members: "Members & invitations"
            case .deleted: "Recently deleted"
            }
        }
    }

    @State private var detailTab: TripDetailTab = .overview
    @State private var expenseSearch = ""
    @State private var expensePayerID: Person.ID?
    @State private var expenseParticipantID: Person.ID?
    @State private var expenseReceiptOnly = false
    @State private var expenseDateWindow: ExpenseDateWindow = .all

    private enum TripDetailTab: String, CaseIterable {
        case overview, feed

        var title: LocalizedStringKey {
            switch self {
            case .overview: "Overview"
            case .feed: "Feed"
            }
        }
    }

    private enum ProtectedIntent { case addExpense, editTrip }

    private enum ExpenseDateWindow: String, CaseIterable, Identifiable {
        case all = "Any date", week = "Last 7 days", month = "Last 30 days"
        var id: Self { self }
        var cutoff: Date? {
            switch self {
            case .all: nil
            case .week: Calendar.current.date(byAdding: .day, value: -7, to: Date())
            case .month: Calendar.current.date(byAdding: .day, value: -30, to: Date())
            }
        }
    }

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
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(spacing: 0) {
                                heroHeader(trip)
                                VStack(spacing: Theme.Space.section) {
                                    actionTiles(trip)
                                    detailTabPicker
                                    switch detailTab {
                                    case .overview:
                                        budgetOverviewCard(trip)
                                        balancesCard(trip, preview: true).id("settle")
                                        itineraryCard(trip)
                                        recentExpensesCard(trip)
                                        NavigationLink(value: TripPage.members) {
                                            overviewLink("Members & invitations", icon: "person.2", value: "\(trip.members.count)")
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityIdentifier("trip-members")
                                    case .feed:
                                        TripFeedView(tripID: tripID)
                                    }
                                }
                                .padding(.horizontal, Theme.contentInset)
                                .padding(.top, 20)
                                .padding(.bottom, 40)
                                .background {
                                    LinearGradient(
                                        colors: Theme.sheetGradient,
                                        startPoint: .top, endPoint: .bottom
                                    )
                                    .clipShape(.rect(topLeadingRadius: 28, topTrailingRadius: 28))
                                }
                                // Pull the content sheet up over the photo's bottom so the
                                // cover fades under a rounded card edge instead of a hard cut.
                                .padding(.top, -28)
                            }
                        }
                        .ignoresSafeArea(edges: .top)
                        .onChange(of: scrollToSettle) { _, shouldScroll in
                            guard shouldScroll else { return }
                            detailTab = .overview
                            withAnimation(.snappy) { proxy.scrollTo("settle", anchor: .top) }
                            scrollToSettle = false
                        }
                    }
                } else {
                    ContentUnavailableView("Trip not found", systemImage: "suitcase")
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: TripPage.self) { page in
                tripPage(page)
            }
            .sheet(isPresented: $showSignInAlert) {
                AuthenticationSheet(reason: "Sign in to update this shared trip.")
            }
            .onChange(of: auth.isAuthenticated) { _, signedIn in
                guard signedIn, let intent = protectedIntent else { return }
                protectedIntent = nil
                switch intent {
                case .addExpense: showAddExpense = true
                case .editTrip: showEditTrip = true
                }
            }
            .sheet(isPresented: $showAddExpense) {
                AddExpenseView(tripID: tripID)
            }
            .sheet(isPresented: $showEditTrip) {
                EditTripView(tripID: tripID)
            }
            .sheet(isPresented: $showSettleInfo) {
                SettleMathInfoView()
            }
            .sheet(item: $activeSettlement) { settlement in
                SettleView(
                    settlement: settlement,
                    history: historyBinding(for: settlement),
                    currencyCode: trip?.currencyCode ?? "USD",
                    tripName: trip?.name,
                    currentUserID: store.currentUser.id
                )
            }
            .alert(
                "Confirm payment",
                isPresented: Binding(
                    get: { settlementToConfirm != nil },
                    set: { if !$0 { settlementToConfirm = nil } }
                ),
                presenting: settlementToConfirm
            ) { settlement in
                Button("Mark as Paid") {
                    withAnimation(.snappy) {
                        store.confirmSettled(tripID: tripID, settlement: settlement)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { settlement in
                Text("Did \(settlement.from.name) pay you back \(money(store.remaining(tripID: tripID, for: settlement), trip?.currencyCode ?? "USD"))?")
            }
            .confirmationDialog(
                "Remove this member's access?",
                isPresented: Binding(
                    get: { memberToRemove != nil },
                    set: { if !$0 { memberToRemove = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Remove Access", role: .destructive) {
                    guard let member = memberToRemove else { return }
                    memberToRemove = nil
                    removeMemberAccess(member)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("They will immediately lose trip and media access. Their historical expense identity remains so balances stay accurate.")
            }
            .confirmationDialog(
                "Leave this trip?",
                isPresented: $showLeaveTripConfirmation,
                titleVisibility: .visible
            ) {
                Button("Leave Trip", role: .destructive) { leaveTrip() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You will immediately lose access. Your historical expense identity remains for the other members' balances.")
            }
            .confirmationDialog(
                "Revoke this invitation?",
                isPresented: Binding(
                    get: { invitationToRevoke != nil },
                    set: { if !$0 { invitationToRevoke = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Revoke Invitation", role: .destructive) {
                    guard let invitation = invitationToRevoke else { return }
                    invitationToRevoke = nil
                    revokeInvitation(invitation)
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    // MARK: Hero header

    @ViewBuilder
    private func heroHeader(_ trip: Trip) -> some View {
        photoHeroHeader(trip)
    }

    /// The photo hero: location and date as chips, the title, and the members as an
    /// avatar stack — the facts the old "Trip Details" card repeated in words.
    private func photoHeroHeader(_ trip: Trip) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.content) {
            (dynamicTypeSize.isAccessibilitySize
             ? AnyLayout(VStackLayout(alignment: .leading, spacing: Theme.Space.compact))
             : AnyLayout(HStackLayout(spacing: Theme.Space.compact))) {
                if let location = trip.location, !location.isEmpty {
                    heroChip(location, icon: "mappin.circle.fill")
                }
                if let range = trip.dateRangeText {
                    heroChip(range, icon: "calendar")
                }
            }
            (dynamicTypeSize.isAccessibilitySize
             ? AnyLayout(VStackLayout(alignment: .leading, spacing: Theme.Space.content))
             : AnyLayout(HStackLayout(alignment: .bottom, spacing: Theme.Space.content))) {
                Text(trip.name)
                    .font(Theme.Typography.pageTitle)
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
                NavigationLink(value: TripPage.members) { memberStack(trip) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Members & invitations")
            }
        }
        .padding(.horizontal, Theme.Space.page)
        .padding(.top, 112)
        .padding(.bottom, 44)
        .frame(maxWidth: .infinity, minHeight: 320, alignment: .bottomLeading)
        .background {
            TripCoverView(trip: trip)
                .overlay {
                    LinearGradient(
                        colors: [.black.opacity(0.3), .black.opacity(0.15), .black.opacity(0.7)],
                        startPoint: .top, endPoint: .bottom
                    )
                }
        }
        .clipped()
        .overlay(alignment: .top) {
            HStack {
                heroCornerButton("xmark", label: "Close") { dismiss() }
                Spacer()
                if store.isCreator(of: trip) {
                    heroCornerButton("pencil", label: "Edit trip") {
                        requireAuthentication(for: .editTrip)
                    }
                }
                ShareLink(item: TripExport.text(trip)) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(.black.opacity(0.35), in: .circle)
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Share trip summary")
            }
            .padding(.top, 56)
            .padding(.horizontal, 20)
        }
    }

    private func heroChip(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(Theme.Typography.metadata)
            .foregroundStyle(.white)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .frame(minHeight: 28)
            .background(.white.opacity(0.22), in: .capsule)
    }

    private func heroCornerButton(_ icon: String, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(.black.opacity(0.35), in: .circle)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// Up to three member avatars, overlapped, with a "+n" disc for the rest. Tapping
    /// opens the members page, which lists everyone by name.
    private func memberStack(_ trip: Trip) -> some View {
        let shown = Array(trip.members.prefix(3))
        let extra = trip.members.count - shown.count
        return HStack(spacing: -9) {
            ForEach(shown) { member in
                AvatarView(
                    person: member,
                    imageData: member.id == store.currentUser.id ? store.profileImageData : nil,
                    size: 30
                )
                .overlay(Circle().strokeBorder(.black.opacity(0.35), lineWidth: 2))
            }
            if extra > 0 {
                Text(verbatim: "+\(extra)")
                    .font(.app(.caption2, .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(.white.opacity(0.3), in: .circle)
                    .overlay(Circle().strokeBorder(.black.opacity(0.35), lineWidth: 2))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(trip.members.count) traveler\(trip.members.count == 1 ? "" : "s")")
    }

    // MARK: Overview destinations

    private func tripPage(_ page: TripPage) -> some View {
        ScrollView {
            if let trip {
                VStack(spacing: Theme.Space.section) {
                    switch page {
                    case .history:
                        expensesCard(trip)
                        if !trip.deletedExpenses.isEmpty {
                            NavigationLink(value: TripPage.deleted) {
                                overviewLink("Recently deleted", icon: "trash", value: "\(trip.deletedExpenses.count)")
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("trip-deleted-expenses")
                        }
                    case .balances:
                        balancesCard(trip)
                    case .members:
                        membersCard(trip)
                    case .deleted:
                        if trip.deletedExpenses.isEmpty {
                            ContentUnavailableView("No deleted expenses", systemImage: "trash")
                        } else {
                            recentlyDeletedCard(trip)
                        }
                    }
                }
                .padding(Theme.Space.page)
            } else {
                ContentUnavailableView("Trip not found", systemImage: "suitcase")
            }
        }
        .background { AppBackground() }
        .navigationTitle(page.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }

    private func overviewLink(_ title: LocalizedStringKey, icon: String, value: String? = nil) -> some View {
        HStack(spacing: Theme.Space.content) {
            Label(title, systemImage: icon)
                .font(Theme.Typography.rowTitle)
            Spacer(minLength: Theme.Space.compact)
            if let value {
                Text(verbatim: value).font(Theme.Typography.metadata).foregroundStyle(Theme.textSecondary)
            }
            Image(systemName: "chevron.right").font(Theme.Typography.metadata)
        }
        .foregroundStyle(Theme.accent)
        .frame(minHeight: 44)
        .padding(.horizontal, Theme.Space.card)
        .padding(.vertical, Theme.Space.compact)
        .readableSurface()
    }

    private func recentExpensesCard(_ trip: Trip) -> some View {
        let recent = trip.expenses.sorted { $0.date > $1.date }.prefix(3)
        return TripCard(title: "Recent expenses", icon: "clock") {
            if recent.isEmpty {
                Text("No expenses yet").font(Theme.Typography.secondary).foregroundStyle(Theme.textSecondary)
            } else {
                ForEach(Array(recent.enumerated()), id: \.element.id) { index, expense in
                    if index > 0 { Divider() }
                    NavigationLink {
                        ExpenseDetailView(tripID: tripID, expense: expense)
                            .toolbar(.visible, for: .navigationBar)
                    } label: {
                        expenseRow(trip, expense)
                    }
                    .buttonStyle(.plain)
                }
            }
            NavigationLink(value: TripPage.history) {
                HStack {
                    Text("View all expenses")
                    Spacer()
                    Text(verbatim: "\(trip.expenses.count)").monospacedDigit()
                    Image(systemName: "chevron.right")
                }
                .font(Theme.Typography.rowTitle)
                .foregroundStyle(Theme.accent)
                .frame(minHeight: 44)
            }
            .accessibilityIdentifier("trip-expense-history")
        }
    }

    // MARK: Primary and secondary actions

    private func actionTiles(_ trip: Trip) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { tripActions }
            VStack(spacing: 10) { tripActions }
        }
    }

    @ViewBuilder
    private var tripActions: some View {
        Button { requireAuthentication(for: .addExpense) } label: {
            Label("Add expense", systemImage: "plus")
                .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(AppActionStyle())
        .accessibilityIdentifier("trip-add-expense")

        Button { scrollToSettle = true } label: {
            Label("Settle up", systemImage: "arrow.left.arrow.right")
                .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(AppActionStyle(primary: false))
    }

    // MARK: Detail tabs

    @ViewBuilder
    private var detailTabPicker: some View {
        (dynamicTypeSize.isAccessibilitySize
         ? AnyLayout(VStackLayout(spacing: Theme.Space.compact))
         : AnyLayout(HStackLayout(spacing: Theme.Space.compact))) {
            detailTabButton(.overview, title: "Overview", icon: "list.bullet.rectangle")
            detailTabButton(.feed, title: "Feed", icon: "photo.on.rectangle.angled")
        }
    }

    private func detailTabButton(_ tab: TripDetailTab, title: LocalizedStringKey, icon: String) -> some View {
        Button {
            withAnimation(.snappy) { detailTab = tab }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.app(.caption, .semibold))
                Text(title).font(Theme.Typography.rowTitle)
            }
            .foregroundStyle(detailTab == tab ? Theme.onAccent : .secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                detailTab == tab ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.fieldBackground),
                in: .capsule
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: Detail cards

    /// One budget metric; outstanding balances live in the next section.
    private func budgetOverviewCard(_ trip: Trip) -> some View {
        let me = store.currentUser.id
        let budget = trip.budget(for: me)
        let spent = trip.spent(for: me)
        let remaining = trip.remainingBudget(for: me)
        let over = budget > 0 && spent > budget
        let near = budget > 0 && spent / budget >= 0.8 && !over
        let statusColor = over ? Theme.negative : near ? Theme.warning : Theme.positive
        return TripCard(title: "Your budget", icon: "wallet.bifold") {
            Text(budget > 0 ? (over ? "Over budget" : "Remaining") : "Spent")
                .font(Theme.Typography.secondary)
                .foregroundStyle(Theme.textSecondary)
            Text(money(budget > 0 ? abs(remaining) : spent, trip.currencyCode))
                .font(Theme.Typography.heroAmount)
                .monospacedDigit()
                .foregroundStyle(over ? Theme.negative : Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            if budget > 0 {
                MeterBar(fraction: min(spent / budget, 1), colors: [statusColor], track: Theme.fieldBackground, height: 8)
                    .accessibilityLabel("Budget used")
                    .accessibilityValue(Text("\(money(spent, trip.currencyCode)) of \(money(budget, trip.currencyCode))"))
                ViewThatFits(in: .horizontal) {
                    HStack {
                        budgetCaption(spent: spent, budget: budget, currency: trip.currencyCode)
                            .fixedSize(horizontal: true, vertical: false)
                        Spacer()
                        budgetStatus(over: over, near: near, color: statusColor)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    VStack(alignment: .leading, spacing: Theme.Space.compact) {
                        budgetCaption(spent: spent, budget: budget, currency: trip.currencyCode)
                        budgetStatus(over: over, near: near, color: statusColor)
                    }
                }
            } else {
                Text("No budget set").font(Theme.Typography.metadata).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func budgetCaption(spent: Double, budget: Double, currency: String) -> some View {
        Text("\(money(spent, currency)) of \(money(budget, currency)) spent")
            .font(Theme.Typography.metadata)
            .foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func budgetStatus(over: Bool, near: Bool, color: Color) -> some View {
        Label(over ? "Over budget" : near ? "Running low" : "On track",
              systemImage: over ? "exclamationmark.circle" : near ? "gauge.with.needle" : "checkmark.circle")
            .font(Theme.Typography.metadata)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func requireAuthentication(for intent: ProtectedIntent) {
        guard auth.isAuthenticated else {
            protectedIntent = intent
            showSignInAlert = true
            return
        }
        switch intent {
        case .addExpense: showAddExpense = true
        case .editTrip: showEditTrip = true
        }
    }

    private func historyBinding(for settlement: Settlement) -> Binding<[SettlementRecord]> {
        Binding(
            get: { store.history(tripID: tripID, for: settlement) },
            set: { store.setHistory($0, tripID: tripID, for: settlement) }
        )
    }

    /// Personal "pay back" summary for the signed-in viewer: every settlement where
    /// they are the debtor, listed creditor-by-creditor so they can see at a glance
    /// whom to pay. Only account-backed members (the trip owner or invited users) can
    /// be `store.currentUser`, so the card never renders for manually added members —
    /// their `Person.ID` is a random UUID that no signed-in viewer matches.
    /// Every open transfer as one row: the other party's avatar, from→to dots, the
    /// amount coloured by your side of it, and one action — Pay when you owe, Paid
    /// (confirm) when you're owed. Your own transfers sort first. Confirmed-paid
    /// transfers drop out of here and reappear under History.
    private func balancesCard(_ trip: Trip, preview: Bool = false) -> some View {
        let me = store.currentUser.id
        let settlements = trip.settlements()
            .filter { !store.isFullySettled(tripID: tripID, $0) }
            .sorted { a, b in
                let aMine = a.from.id == me || a.to.id == me
                let bMine = b.from.id == me || b.to.id == me
                if aMine != bMine { return aMine }
                return (a.from.id == me) && !(b.from.id == me)
            }
        let personal = settlements.filter { $0.from.id == me || $0.to.id == me }
        let visible = preview ? Array(personal.prefix(3)) : settlements
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label {
                    Text(preview ? "Your balances" : "Balances")
                        .font(Theme.Typography.sectionTitle)
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "arrow.left.arrow.right.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                }
                Spacer()
                Button {
                    showSettleInfo = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("How payments are calculated"))
            }
            if visible.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.positive)
                    Text(preview && !settlements.isEmpty ? "No balances for you" : "All settled up").font(Theme.Typography.secondary).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, settlement in
                        if index > 0 { rowDivider }
                        balanceRow(trip, settlement)
                    }
                }
            }
            if preview && !settlements.isEmpty {
                NavigationLink(value: TripPage.balances) {
                    Label("View all balances", systemImage: "chevron.right")
                        .font(Theme.Typography.rowTitle)
                        .foregroundStyle(Theme.accent)
                        .frame(minHeight: 44)
                }
                .accessibilityIdentifier("trip-all-balances")
            }
        }
        .panelPadding(horizontal: Theme.Space.card, vertical: Theme.Space.card)
        .frame(maxWidth: .infinity, alignment: .leading)
        .homePanel(cornerRadius: Theme.cardRadius)
    }

    @ViewBuilder
    private var rowDivider: some View {
        Divider()
    }

    private func balanceRow(_ trip: Trip, _ settlement: Settlement) -> some View {
        let me = store.currentUser.id
        let iOwe = settlement.from.id == me
        let owedToMe = settlement.to.id == me
        let counterpart = iOwe ? settlement.to : settlement.from
        let amountColor: Color = iOwe ? Theme.negative : owedToMe ? Theme.positive : .primary
        let remaining = store.remaining(tripID: tripID, for: settlement)
        return (dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: Theme.Space.compact))
                : AnyLayout(HStackLayout(spacing: Theme.Space.content))) {
            AvatarView(
                person: counterpart,
                imageData: counterpart.id == me ? store.profileImageData : nil,
                size: 40
            )
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: counterpart.name)
                    .font(Theme.Typography.rowTitle)
                    .fixedSize(horizontal: false, vertical: true)
                Group {
                    if iOwe {
                        Text("You owe")
                    } else if owedToMe {
                        Text("Owes you")
                    } else {
                        Text("Owes \(settlement.to.name)")
                    }
                }
                .font(Theme.Typography.metadata)
                .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 8)
            Text(money(remaining, trip.currencyCode))
                .font(.app(.subheadline, .bold))
                .foregroundStyle(amountColor)
                .monospacedDigit()
            if iOwe {
                balanceAction("Pay", tint: Theme.accent, foreground: Theme.onAccent) {
                    activeSettlement = settlement
                }
            } else if owedToMe {
                // Only the creditor can confirm they were actually paid back.
                balanceAction("Confirm paid", tint: Theme.positive.opacity(0.14), foreground: Theme.positive) {
                    settlementToConfirm = settlement
                }
            } else {
                Image(systemName: "chevron.right")
                    .font(.app(.caption2, .bold)).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 10)
        .contentShape(.rect)
        .onTapGesture { activeSettlement = settlement }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "\(settlement.from.name) → \(settlement.to.name), \(money(remaining, trip.currencyCode))"))
    }

    private func balanceAction(_ title: LocalizedStringKey, tint: Color, foreground: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.app(.caption, .bold))
                .foregroundStyle(foreground)
                .padding(.horizontal, 12)
                .frame(minHeight: 32)
                .background(tint, in: AnyShape(Capsule()))
                .frame(minHeight: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private struct SettleMathInfoView: View {
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        step(number: 1, icon: "creditcard.fill",
                             title: "Add up what each person paid",
                             detail: "Every expense counts fully toward the person who fronted the money.")
                        step(number: 2, icon: "chart.pie.fill",
                             title: "Work out each person's share",
                             detail: "Each expense is divided using its own split settings — equally, by percentage, by exact amounts, or assigned to one person.")
                        step(number: 3, icon: "scalemass.fill",
                             title: "Net it out",
                             detail: "Balance = paid − share. A positive balance means the group owes you; a negative one means you owe the group.")
                        step(number: 4, icon: "arrow.triangle.swap",
                             title: "Settle with the fewest payments",
                             detail: "The biggest debtor pays the biggest creditor until both hit zero, then the next pair, and so on. You might pay someone who didn't cover your expense — but everyone ends up paid back exactly what they're owed.")
                    }
                    .padding(20)
                }
                .navigationTitle("How Settle Up works")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark")
                        }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }

        private func step(number: Int, icon: String, title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: icon)
                    .font(Theme.Typography.rowTitle)
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Theme.accent, in: .circle)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Step \(number)")
                        .font(.app(.caption, .bold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Text(title)
                        .font(Theme.Typography.rowTitle)
                    Text(detail)
                        .font(.app(.footnote))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func membersCard(_ trip: Trip) -> some View {
        TripCard(title: "Members", icon: "person.2.fill") {
            ForEach(trip.members) { member in
                HStack(spacing: Theme.Space.content) {
                    AvatarView(person: member,
                               imageData: member.id == store.currentUser.id ? store.profileImageData : nil,
                               size: 40)
                    VStack(alignment: .leading, spacing: Theme.Space.small) {
                        Text(member.id == store.currentUser.id ? String(localized: "You") : member.name)
                            .font(Theme.Typography.rowTitle)
                            .fixedSize(horizontal: false, vertical: true)
                        if member.id == trip.creatorID {
                            Label("Organizer", systemImage: "star")
                                .font(Theme.Typography.metadata)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    Spacer(minLength: Theme.Space.compact)
                    if store.isCreator(of: trip), member.id != trip.creatorID {
                        Menu {
                            Button(role: .destructive) { memberToRemove = member } label: {
                                Label("Remove Access", systemImage: "person.crop.circle.badge.minus")
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("Manage \(member.name)")
                    }
                }
                .frame(minHeight: 48)
            }

            if store.isCreator(of: trip) {
               Divider()
                VStack(spacing: 10) {
                    TripInvitationControls(tripID: trip.id, state: invitations) {
                        await loadPendingInvitations()
                    }

                    if !pendingInvitations.isEmpty {
                       Divider()
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Pending Invitations")
                                .font(Theme.Typography.rowTitle)
                            ForEach(pendingInvitations) { invitation in
                                HStack(spacing: 8) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(verbatim: invitation.email ?? "Share link")
                                            .font(.app(.caption, .semibold))
                                        Text("Expires \(invitation.expiresAt.formatted(.relative(presentation: .named)))")
                                            .font(.app(.caption2))
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button(role: .destructive) { invitationToRevoke = invitation } label: {
                                        Image(systemName: "xmark.circle")
                                            .frame(width: 36, height: 36)
                                            .contentShape(.rect)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Revoke invitation")
                                }
                            }
                        }
                    }
                }
            } else {
               Divider()
                Button(role: .destructive) { showLeaveTripConfirmation = true } label: {
                    Label("Leave Trip", systemImage: "rectangle.portrait.and.arrow.right")
                        .font(Theme.Typography.rowTitle)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .disabled(membershipActionBusy)
            }

            if let membershipMessage {
                ActionFeedbackView(feedback: membershipMessage)
            }
        }
        .task(id: trip.id) {
            if store.isCreator(of: trip) { await loadPendingInvitations() }
        }
    }

    private func removeMemberAccess(_ member: Person) {
        guard !membershipActionBusy else { return }
        membershipActionBusy = true
        membershipMessage = nil
        Task {
            do {
                try await store.removeMemberAccess(member.id, from: tripID)
                membershipMessage = .success(String(localized: "Access removed. Historical balances are unchanged."))
            } catch {
                membershipMessage = .failure((error as? AuthError)?.message ?? String(localized: "Member access could not be removed."))
            }
            membershipActionBusy = false
        }
    }

    private func leaveTrip() {
        guard !membershipActionBusy else { return }
        membershipActionBusy = true
        membershipMessage = nil
        Task {
            do {
                try await store.leaveTrip(tripID)
                dismiss()
            } catch {
                membershipMessage = .failure((error as? AuthError)?.message ?? String(localized: "The trip could not be left."))
                membershipActionBusy = false
            }
        }
    }

    private func loadPendingInvitations() async {
        do {
            pendingInvitations = try await store.pendingInvitations(for: tripID)
        } catch {
            // The core trip remains usable when this secondary owner-only list fails.
            BackendSecurity.log("Pending invitations could not be loaded", error: error)
        }
    }

    private func revokeInvitation(_ invitation: TripsRepository.PendingInvitation) {
        Task {
            do {
                try await store.revokeInvitation(invitation.id)
                pendingInvitations.removeAll { $0.id == invitation.id }
                membershipMessage = .success(String(localized: "Invitation revoked."))
            } catch {
                membershipMessage = .failure((error as? AuthError)?.message ?? String(localized: "The invitation could not be revoked."))
            }
        }
    }

    /// Entry point to the day-by-day planner (ItineraryFeature.swift): opens the plan
    /// when one exists, or seeds one from the trip's dates and budget so itineraries
    /// are reachable from the Trips side, not just Explore.
    @ViewBuilder
    private func itineraryCard(_ trip: Trip) -> some View {
        if let itinerary = trip.itinerary {
            let planned = itinerary.days.filter { !$0.stops.isEmpty }.count
            NavigationLink {
                ItineraryDetailView(tripID: trip.id, showsTripLink: false)
                    .toolbar(.visible, for: .navigationBar)
            } label: {
                TripCard(title: "Itinerary", icon: "map") {
                    HStack {
                        Text("\(planned) of \(itinerary.days.count) days planned")
                            .font(Theme.Typography.metadata)
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(Theme.accent)
                    }
                    if let dayIndex = itinerary.days.firstIndex(where: { !$0.stops.isEmpty }) {
                        Text("Day \(dayIndex + 1)")
                            .font(Theme.Typography.rowTitle)
                        ForEach(Array(itinerary.days[dayIndex].stops.prefix(2))) { stop in
                            Label(stop.name, systemImage: stop.kind.icon)
                                .font(Theme.Typography.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("trip-itinerary")
        } else {
            TripCard(title: "Itinerary", icon: "map") {
                Button { seedItinerary(trip) } label: {
                    Label("Plan itinerary", systemImage: "plus")
                }
                .buttonStyle(AppActionStyle(primary: false))
            }
        }
    }

    /// Creates an empty plan sized to the trip's date range (or 3 days without dates),
    /// budgeted with the signed-in user's trip budget.
    private func seedItinerary(_ trip: Trip) {
        let dayCount: Int
        if let start = trip.startDate, let end = trip.endDate {
            let cal = Calendar.current
            let span = cal.dateComponents([.day], from: cal.startOfDay(for: start), to: cal.startOfDay(for: end)).day ?? 0
            dayCount = min(max(span + 1, 1), 30)
        } else {
            dayCount = 3
        }
        let itinerary = Itinerary(
            totalBudget: trip.budget(for: store.currentUser.id),
            days: (0..<dayCount).map { _ in ItineraryDay() }
        )
        store.updateItinerary(itinerary, in: trip.id)
    }

    private func expensesCard(_ trip: Trip) -> some View {
        let settled = trip.settlements().filter { store.isFullySettled(tripID: tripID, $0) }
        let filtered = filteredExpenses(in: trip)
        return TripCard(title: "History", icon: "clock.arrow.circlepath") {
            if trip.expenses.isEmpty {
                Text("No expenses yet")
                    .font(Theme.Typography.secondary).italic()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                HStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search expenses", text: $expenseSearch)
                            .textInputAutocapitalization(.never)
                    }
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    // Card themes keep a true capsule here: this field grows with
                    // Dynamic Type, and a fixed radius would stop tracking its height.
                    .background(
                        Theme.fieldBackground,
                        in: AnyShape(Capsule())
                    )

                    Menu {
                        Section("Payer") {
                            Button("Anyone") { expensePayerID = nil }
                            ForEach(trip.members) { member in
                                Button(member.name) { expensePayerID = member.id }
                            }
                        }
                        Section("Participant") {
                            Button("Anyone") { expenseParticipantID = nil }
                            ForEach(trip.members) { member in
                                Button(member.name) { expenseParticipantID = member.id }
                            }
                        }
                        Picker("Date", selection: $expenseDateWindow) {
                            ForEach(ExpenseDateWindow.allCases) { window in
                                Text(LocalizedStringKey(window.rawValue)).tag(window)
                            }
                        }
                        Toggle("Has receipt", isOn: $expenseReceiptOnly)
                        Button("Clear filters") { clearExpenseFilters() }
                    } label: {
                        Image(systemName: isFilteringExpenses ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                            .font(.app(.title3))
                            .foregroundStyle(isFilteringExpenses ? Theme.accent : .secondary)
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Filter expenses")
                }

                Text("Expenses (\(filtered.count) of \(trip.expenses.count))")
                    .font(Theme.Typography.rowTitle).foregroundStyle(.secondary)
                // Eager (not Lazy) on purpose: a LazyVStack here re-measured rows as
                // they scrolled back into view, hitching the scroll-up out of this card.
                VStack(spacing: 8) {
                    ForEach(filtered) { expense in

                        let link = NavigationLink {
                            ExpenseDetailView(tripID: tripID, expense: expense)
                        } label: {
                            expenseRow(trip, expense)
                        }
                        .buttonStyle(.plain)

                        if canModify(trip, expense) {
                            SwipeToDeleteRow {
                                store.deleteExpense(expense.id, from: trip.id)
                            } content: {
                                link
                            }
                        } else {
                            link
                        }
                    }
                    if filtered.isEmpty {
                        ContentUnavailableView("No matching expenses", systemImage: "magnifyingglass")
                            .frame(minHeight: 120)
                    }
                }
            }

            if !settled.isEmpty {
                SectionDivider()
                Text("Settled payments")
                    .font(.app(.subheadline, .semibold))
                    .foregroundStyle(.secondary)
                ForEach(settled) { settlement in
                    Button {
                        activeSettlement = settlement
                    } label: {
                        settledPaymentRow(trip, settlement)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var isFilteringExpenses: Bool {
        !expenseSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || expensePayerID != nil || expenseParticipantID != nil
            || expenseReceiptOnly || expenseDateWindow != .all
    }

    private func filteredExpenses(in trip: Trip) -> [Expense] {
        let query = expenseSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        return trip.expenses.filter { expense in
            (query.isEmpty || expense.title.localizedCaseInsensitiveContains(query))
                && (expensePayerID == nil || expense.payerID == expensePayerID)
                && (expenseParticipantID == nil || expense.participantIDs.contains(expenseParticipantID!))
                && (!expenseReceiptOnly || expense.receiptURL?.isEmpty == false)
                && (expenseDateWindow.cutoff == nil || expense.date >= expenseDateWindow.cutoff!)
        }.sorted { $0.date > $1.date }
    }

    private func clearExpenseFilters() {
        expenseSearch = ""
        expensePayerID = nil
        expenseParticipantID = nil
        expenseReceiptOnly = false
        expenseDateWindow = .all
    }

    /// A confirmed-paid transfer, shown under History once the creditor marks it paid.
    private func settledPaymentRow(_ trip: Trip, _ settlement: Settlement) -> some View {
        let me = store.currentUser.id
        let fromLabel = settlement.from.id == me ? String(localized: "You") : settlement.from.name
        let toLabel = settlement.to.id == me ? String(localized: "you") : settlement.to.name
        let paidDate = store.history(tripID: tripID, for: settlement)
            .filter { $0.status == .confirmed }
            .map(\.date).max()
        return HStack(spacing: 8) {
            avatar(settlement.from, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(fromLabel) paid \(toLabel)")
                    .font(Theme.Typography.secondary).fontWeight(.semibold)
                if let paidDate {
                    Text(paidDate.formatted(date: .abbreviated, time: .omitted))
                        .font(Theme.Typography.metadata).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(money(settlement.amount, trip.currencyCode))
                .font(Theme.Typography.rowTitle)
                .foregroundStyle(.secondary)
            Label("Paid", systemImage: "checkmark.seal.fill")
                .font(.app(.caption, .semibold))
                .foregroundStyle(Theme.positive)
            Image(systemName: "chevron.right")
                .font(.app(.caption2, .bold)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
    }

    /// Whether the signed-in account may edit or delete an expense. The trip owner may
    /// edit everything; shared members can edit expenses they personally paid.
    private func canModify(_ trip: Trip, _ expense: Expense) -> Bool {
        store.isCreator(of: trip) || expense.payerID == store.currentUser.id
    }

    private func recentlyDeletedCard(_ trip: Trip) -> some View {
        TripCard(title: "Recently Deleted (\(trip.deletedExpenses.count))", icon: "trash") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Deleted expenses still count toward your budget. Restore one to add it back to the split.")
                    .font(.app(.footnote))
                    .foregroundStyle(.secondary)
                ForEach(trip.deletedExpenses) { expense in
                    deletedExpenseRow(trip, expense)
                }
            }
        }
    }

    private func deletedExpenseRow(_ trip: Trip, _ expense: Expense) -> some View {
        let payer = trip.members.first { $0.id == expense.payerID }
        let me = store.currentUser.id
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(expense.title)
                    .font(Theme.Typography.rowTitle)
                    .strikethrough(color: .secondary)
                    .foregroundStyle(.secondary)
                let payerText = payer.map { $0.id == me ? "you" : $0.name } ?? "—"
                let deletedText = expense.deletedAt.map { " • deleted \($0.formatted(date: .abbreviated, time: .omitted))" } ?? ""
                Text("Paid by \(payerText)\(deletedText)")
                    .font(Theme.Typography.metadata).foregroundStyle(.tertiary)
            }
            Spacer()
            Text(money(expense.amount, trip.currencyCode))
                .font(Theme.Typography.rowTitle)
                .foregroundStyle(.secondary)
            if canModify(trip, expense) {
                Button {
                    store.restoreExpense(expense.id, in: trip.id)
                } label: {
                    Text("Restore")
                        .font(.app(.caption, .semibold))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .pillTint(Theme.accent.opacity(0.16), horizontal: 12, vertical: 6)
                        .foregroundStyle(Theme.accent)
                        .frame(minHeight: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }

    private func expenseRow(_ trip: Trip, _ expense: Expense) -> some View {
        let payer = trip.members.first { $0.id == expense.payerID }
        let me = store.currentUser.id
        let yourShare = trip.share(for: me, in: expense)
        return (dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: Theme.Space.compact))
                : AnyLayout(HStackLayout(alignment: .top, spacing: Theme.Space.content))) {
            if let payer {
                AvatarView(
                    person: payer,
                    imageData: payer.id == me ? store.profileImageData : nil,
                    size: 34
                )
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(expense.title)
                    .font(Theme.Typography.rowTitle)
                    .fixedSize(horizontal: false, vertical: true)
                // Date plus receipt / comment glyphs; the payer is the avatar.
                HStack(spacing: 8) {
                    Text(verbatim: expense.date.formatted(date: .abbreviated, time: .omitted))
                    if expense.receiptURL != nil || !expense.items.isEmpty {
                        HStack(spacing: 3) {
                            Image(systemName: "doc.text")
                            if !expense.items.isEmpty {
                                Text(verbatim: "\(expense.items.count)")
                            }
                        }
                        .accessibilityLabel(expense.items.isEmpty ? "Receipt" : "Receipt, \(expense.items.count) items")
                    }
                    let commentCount = trip.comments[expense.id.uuidString]?.count ?? 0
                    if commentCount > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: "bubble.left")
                            Text(verbatim: "\(commentCount)")
                        }
                        .accessibilityLabel("\(commentCount) comments")
                    }
                }
                .font(Theme.Typography.metadata)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text(money(expense.amount, trip.currencyCode))
                    .font(.app(.subheadline, .bold))
                    .monospacedDigit()
                if expense.payerID == me || yourShare > 0 {
                    // This is the original expense allocation, not an outstanding balance.
                    // Settlements can cover several expenses, so avoid claiming money is still owed.
                    Text("Your share \(money(yourShare, trip.currencyCode))")
                        .font(Theme.Typography.metadata)
                        .foregroundStyle(Theme.textSecondary)
                        .monospacedDigit()
                        .multilineTextAlignment(.trailing)
                }
            }
            Image(systemName: "chevron.right")
                .font(.app(.caption2, .bold))
                .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text("Total \(money(expense.amount, trip.currencyCode)), \(trip.currencyCode). Paid by \(payer.map { $0.id == me ? String(localized: "you") : $0.name } ?? "—")"))
        .padding(.vertical, 12)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .background(Theme.surface)
    }

}
