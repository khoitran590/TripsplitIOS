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
    @State private var expandedCreditors: Set<Person.ID> = []
    @State private var showSettleInfo = false
    @State private var manualMemberName = ""
    @State private var inviteEmail = ""
    @State private var inviteMessage: String?
    @State private var inviteLink: URL?
    @State private var isInviting = false
    @State private var isGeneratingLink = false
    @State private var memberToRemove: Person?
    @State private var showLeaveTripConfirmation = false
    @State private var membershipMessage: String?
    @State private var membershipActionBusy = false
    @State private var pendingInvitations: [TripsRepository.PendingInvitation] = []
    @State private var invitationToRevoke: TripsRepository.PendingInvitation?
    @State private var detailTab: TripDetailTab = .overview
    @State private var expenseSearch = ""
    @State private var expensePayerID: Person.ID?
    @State private var expenseParticipantID: Person.ID?
    @State private var expenseReceiptOnly = false
    @State private var expenseDateWindow: ExpenseDateWindow = .all
    /// Ruled hero numeral. Fixed point sizes don't scale with Dynamic Type, so it is
    /// tied to `.largeTitle` rather than hard-coded at 56.
    @ScaledMetric(relativeTo: .largeTitle) private var ruledHeroSize: CGFloat = 56
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

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
                                // Ruled themes take their rhythm from each section's
                                // own rule, so the stack stops adding gaps between them.
                                VStack(spacing: Theme.isRuled ? 0 : 18) {
                                    detailTabPicker
                                    switch detailTab {
                                    case .overview:
                                        tripDetailsCard(trip)
                                        itineraryCard(trip)
                                        budgetOverviewCard(trip)
                                        if trip.members.count >= 2 && !trip.expenses.isEmpty {
                                            OneTimeTipBanner(
                                                key: "tipSettleUpDismissed",
                                                icon: "arrow.left.arrow.right.circle.fill",
                                                message: "TripSplit works out who owes whom below — tap a payment to record it once it's settled."
                                            )
                                        }
                                        yourDebtsCard(trip)
                                        settleCard(trip).id("settle")
                                        membersCard(trip)
                                        expensesCard(trip)
                                        if !trip.deletedExpenses.isEmpty {
                                            recentlyDeletedCard(trip)
                                        }
                                    case .feed:
                                        TripFeedView(tripID: tripID)
                                    }
                                }
                                .padding(.horizontal, Theme.contentInset)
                                .padding(.top, Theme.isRuled ? 4 : 34)
                                .padding(.bottom, 40)
                                .background {
                                    // The ruled hero is typographic, not a photo, so
                                    // there is no cover edge for a card to tuck under.
                                    if !Theme.isRuled {
                                        LinearGradient(
                                            colors: Theme.sheetGradient,
                                            startPoint: .top, endPoint: .bottom
                                        )
                                        .clipShape(.rect(topLeadingRadius: 28, topTrailingRadius: 28))
                                    }
                                }
                                // Pull the content sheet up over the photo's bottom so the
                                // cover fades under a rounded card edge instead of a hard cut.
                                .padding(.top, Theme.isRuled ? 0 : -28)
                            }
                        }
                        .ignoresSafeArea(edges: Theme.isRuled ? [] : .top)
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
        if Theme.isRuled {
            ruledHeader(trip)
        } else {
            photoHeroHeader(trip)
        }
    }

    /// The ruled hero: the cover as a plain full-bleed plate, then the eyebrow, the
    /// Display title and the screen's one near-black rule. No scrim, no glass chrome —
    /// the actions are tracked-caps labels under the rule.
    private func ruledHeader(_ trip: Trip) -> some View {
        let eyebrow = [trip.location, trip.dateRangeText]
            .compactMap { ($0?.isEmpty == false) ? $0 : nil }
            .joined(separator: " · ")
        return VStack(alignment: .leading, spacing: 12) {
            TripCoverView(trip: trip)
                .frame(height: 220)
                .frame(maxWidth: .infinity)
                .clipped()

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Group {
                    if eyebrow.isEmpty {
                        Text("NOW EXPLORING")
                    } else {
                        Text(verbatim: eyebrow)
                    }
                }
                .inscription()
                .foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 0)
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.app(.subheadline, .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
            .padding(.horizontal, Theme.ruledInset)

            VStack(alignment: .leading, spacing: 8) {
                Text(trip.name)
                    .font(.app(size: 36, weight: .medium))
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                Text("\(trip.members.count) traveler\(trip.members.count == 1 ? "" : "s")")
                    .inscription()
                    .foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.ruledInset)

            // The one near-black rule on the screen; it closes the title block.
            Rectangle()
                .fill(Color.primary)
                .frame(height: Theme.ruleWidth(colorSchemeContrast))

            ruledHeroActions(trip)
                .padding(.horizontal, Theme.ruledInset)
        }
        .padding(.top, 8)
    }

    private func ruledHeroActions(_ trip: Trip) -> some View {
        HStack(spacing: 12) {
            ruledHeroButton("Add Expense") { requireAuthentication(for: .addExpense) }
            if store.isCreator(of: trip) {
                ruledHeroButton("Edit Trip") { requireAuthentication(for: .editTrip) }
            }
            ruledHeroButton("Record Payment") { scrollToSettle = true }
            ShareLink(item: TripExport.text(trip)) {
                Image(systemName: "square.and.arrow.up")
                    .font(.app(.caption, .semibold))
                    .frame(width: 44, height: 46)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Share trip summary")
        }
    }

    private func ruledHeroButton(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .inscription()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(minHeight: 46)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func photoHeroHeader(_ trip: Trip) -> some View {
        ZStack(alignment: .bottomLeading) {
            TripCoverView(trip: trip)
                .frame(height: 440)
                .frame(maxWidth: .infinity)
                .clipped()
                .overlay {
                    LinearGradient(
                        colors: [.black.opacity(0.35), .clear, .clear, .black.opacity(0.7)],
                        startPoint: .top, endPoint: .bottom
                    )
                }

            VStack(alignment: .leading, spacing: 12) {
                Text("NOW EXPLORING")
                    .font(.app(.caption, .bold)).tracking(2)
                    .foregroundStyle(.white.opacity(0.85))
                Text(trip.name)
                    .font(.app(size: 36, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                if let location = trip.location, !location.isEmpty {
                    Text(location)
                        .font(.app(.title3))
                        .foregroundStyle(.white.opacity(0.9))
                } else if let range = trip.dateRangeText {
                    Text(range)
                        .font(.app(.title3))
                        .foregroundStyle(.white.opacity(0.9))
                }
                travelersRow(trip)
                heroActions(trip)
            }
            .padding(20)
            .padding(.bottom, 40)
        }
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.app(.subheadline, .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.black.opacity(0.35), in: .circle)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .padding(.top, 60)
            .padding(.trailing, 20)
        }
    }

    private func travelersRow(_ trip: Trip) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: -8) {
                ForEach(trip.members.prefix(3)) { member in
                    Text(member.initials)
                        .font(.app(.caption2, .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(member.color, in: .circle)
                        .overlay(Circle().strokeBorder(.white.opacity(0.7), lineWidth: 1.5))
                }
            }
            Text("\(trip.members.count) traveler\(trip.members.count == 1 ? "" : "s")")
                .font(.app(.subheadline, .medium))
                .foregroundStyle(.white)
        }
    }

    private func heroActions(_ trip: Trip) -> some View {
        HStack(spacing: 10) {
            heroButton("Add Expense", icon: "plus") {
                requireAuthentication(for: .addExpense)
            }
            if store.isCreator(of: trip) {
                heroButton("Edit Trip", icon: "calendar") {
                    requireAuthentication(for: .editTrip)
                }
            }
            heroButton("Record Payment", icon: "person.2.fill") { scrollToSettle = true }
            ShareLink(item: TripExport.text(trip)) {
                Image(systemName: "square.and.arrow.up")
                    .font(.app(.caption, .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel("Share trip summary")
        }
        .padding(.top, 4)
    }

    private func heroButton(_ title: LocalizedStringKey, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.app(.caption, .semibold))
                Text(title).font(.app(.caption, .semibold)).lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    // MARK: Detail tabs

    @ViewBuilder
    private var detailTabPicker: some View {
        if Theme.isRuled {
            // Not a segmented control on ruled themes: labels on a ruled row, the
            // active one underlined. Same tabs, same binding.
            RuledSegmentedRow(items: TripDetailTab.allCases, selection: $detailTab) { $0.title }
        } else {
            HStack(spacing: 8) {
                detailTabButton(.overview, title: "Overview", icon: "list.bullet.rectangle")
                detailTabButton(.feed, title: "Feed", icon: "photo.on.rectangle.angled")
            }
        }
    }

    private func detailTabButton(_ tab: TripDetailTab, title: LocalizedStringKey, icon: String) -> some View {
        Button {
            withAnimation(.snappy) { detailTab = tab }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.app(.caption, .semibold))
                Text(title).font(.app(.subheadline, .semibold))
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

    private func tripDetailsCard(_ trip: Trip) -> some View {
        TripCard(title: "Trip Details", icon: "calendar") {
            HStack(spacing: 12) {
                detailTile(
                    icon: "calendar",
                    label: "Date",
                    value: trip.dateRangeText ?? "Not set"
                )
                detailTile(
                    icon: "mappin.and.ellipse",
                    label: "Location",
                    value: trip.location?.isEmpty == false ? trip.location! : "Not set"
                )
            }
        }
    }

    private func detailTile(icon: String, label: LocalizedStringKey, value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.app(.subheadline))
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.app(.caption)).foregroundStyle(.secondary)
                Text(value).font(.app(.subheadline, .semibold))
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.fieldBackground, in: .rect(cornerRadius: 12))
    }

    private func budgetOverviewCard(_ trip: Trip) -> some View {
        let me = store.currentUser.id
        let budget = trip.budget(for: me)
        let spent = trip.spent(for: me)
        let remaining = trip.remainingBudget(for: me)
        let overBudget = budget > 0 && spent > budget
        // A $0 budget has no separate "over budget" state, so retain the negative
        // balance to make spending against it visible in the Remaining tile.
        let displayedRemaining = budget == 0 ? remaining : abs(remaining)
        let usedFraction = budget > 0 ? spent / budget : 0
        let nearBudget = budget > 0 && usedFraction >= 0.8 && !overBudget
        let barColor = overBudget ? Theme.negative : (nearBudget ? Theme.warning : Theme.positive)
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                if Theme.isRuled {
                    Text("Budget Overview").inscription().foregroundStyle(Theme.textSecondary)
                } else {
                    Label("Budget Overview", systemImage: "wallet.bifold.fill").font(.app(.headline))
                }
                Spacer()
                if store.isCreator(of: trip) {
                    Button {
                        requireAuthentication(for: .editTrip)
                    } label: {
                        Text("Edit Budget")
                            .font(.app(.caption, .semibold))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(.secondary.opacity(0.14), in: .capsule)
                            .frame(minHeight: 44)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }

            VStack(alignment: .leading, spacing: Theme.isRuled ? 6 : 2) {
                if Theme.isRuled {
                    // Hero numeral first on ruled themes: one thin, large figure, then
                    // the accent bar, then the label — the mockup's reading order.
                    Text(money(budget, trip.currencyCode))
                        .font(.app(size: ruledHeroSize, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    Rectangle()
                        .fill(Theme.accent)
                        .frame(width: 44, height: 2)
                    Text("Total Budget").inscription().foregroundStyle(Theme.textSecondary)
                } else {
                    Text("Total Budget").font(.app(.caption)).foregroundStyle(.secondary)
                    Text(money(budget, trip.currencyCode))
                        .font(.app(size: 30, weight: .bold))
                }
            }

            if budget > 0 {
                let fraction = min(usedFraction, 1)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.fieldBackground)
                        Capsule()
                            .fill(barColor)
                            .frame(width: max(0, geo.size.width * fraction))
                    }
                }
                .frame(height: 8)

                if nearBudget || overBudget {
                    HStack(spacing: 8) {
                        Image(systemName: overBudget ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .font(.app(.subheadline, .semibold))
                        Text(overBudget
                            ? "You've gone over budget."
                            : "Heads up — you've used \(Int((usedFraction * 100).rounded()))% of your budget.")
                            .font(.app(.footnote, .medium))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(barColor)
                    .padding(.vertical, 8).padding(.horizontal, 12)
                    .background(barColor.opacity(0.12), in: .rect(cornerRadius: 12))
                }
            }

            HStack(spacing: 12) {
                budgetTile("Spent So Far", money(spent, trip.currencyCode), Theme.accent)
                budgetTile(
                    overBudget ? "Over Budget" : "Remaining",
                    money(displayedRemaining, trip.currencyCode),
                    barColor
                )
            }

            SectionDivider()

            let owed = trip.remainingOwed(for: me)
            HStack {
                statColumn("You owe", money(owed.by, trip.currencyCode), Theme.negative)
                Spacer()
                statColumn("You're owed", money(owed.to, trip.currencyCode), Theme.positive)
            }
        }
        .panelPadding(horizontal: 18, vertical: 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .homePanel(cornerRadius: Theme.cardRadius)
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

    private func budgetTile(_ label: LocalizedStringKey, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // The inner `textCase` wins over the one `inscription()` sets, so card
            // themes keep the caps they already had and ruled themes gain the tracking.
            Text(label)
                .textCase(.uppercase)
                .inscription()
                .foregroundStyle(.secondary)
            Text(value)
                .font(.app(.subheadline, .bold)).foregroundStyle(color)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
        // Ruled tiles carry no fill, so they take no padding of their own either.
        .padding(.horizontal, Theme.isRuled ? 0 : 12)
        .background {
            if !Theme.isRuled {
                RoundedRectangle(cornerRadius: 12).fill(color.opacity(0.10))
            }
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
    private func yourDebtsCard(_ trip: Trip) -> some View {
        let me = store.currentUser.id
        let myDebts = trip.settlements().filter { $0.from.id == me }
        return Group {
            if trip.members.contains(where: { $0.id == me }), !myDebts.isEmpty {
                TripCard(title: "You Need to Pay Back", icon: "arrow.up.right.circle.fill") {
                    ForEach(myDebts) { settlement in
                        Button {
                            activeSettlement = settlement
                        } label: {
                            yourDebtRow(trip, settlement)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func yourDebtRow(_ trip: Trip, _ settlement: Settlement) -> some View {
        let settled = store.isFullySettled(tripID: tripID, settlement)
        return HStack(spacing: 8) {
            avatar(settlement.to, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: settlement.to.name)
                    .font(.app(.subheadline)).fontWeight(.semibold)
                if settled {
                    Text("Settled").font(.app(.caption)).foregroundStyle(Color(hex: 0x10B981))
                } else {
                    Text("Tap to record a payment")
                        .font(.app(.caption))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if settled {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(Color(hex: 0x10B981))
            } else {
                Text(money(store.remaining(tripID: tripID, for: settlement), trip.currencyCode))
                    .font(.app(.subheadline, .semibold))
                    .foregroundStyle(Theme.negative)
            }
            Image(systemName: "chevron.right")
                .font(.app(.caption2, .bold)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
    }

    private func settleCard(_ trip: Trip) -> some View {
        // Confirmed-paid transfers drop out of this card and reappear under History.
        let settlements = trip.settlements().filter { !store.isFullySettled(tripID: tripID, $0) }
        return TripCard(title: "Record Payments", icon: "arrow.left.arrow.right.circle.fill") {
            if settlements.isEmpty {
                Text("All settled up — no transfers needed.")
                    .font(.app(.subheadline))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                HStack(spacing: 6) {
                    Text("Tap a person to see who owes them.")
                        .font(.app(.footnote))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        showSettleInfo = true
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.app(.subheadline))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("How payments are calculated"))
                }
                let groups = creditorGroups(settlements)
                ForEach(groups, id: \.creditor.id) { group in
                    creditorRow(trip, group)
                    if expandedCreditors.contains(group.creditor.id) {
                        ForEach(group.settlements) { settlement in
                            Button {
                                activeSettlement = settlement
                            } label: {
                                settleRow(trip, settlement)
                            }
                            .buttonStyle(.plain)
                            .padding(.leading, 24)
                        }
                    }
                }
            }
        }
    }

    private func creditorGroups(_ settlements: [Settlement]) -> [(creditor: Person, settlements: [Settlement])] {
        var order: [Person.ID] = []
        var byCreditor: [Person.ID: (creditor: Person, settlements: [Settlement])] = [:]
        for settlement in settlements {
            if byCreditor[settlement.to.id] == nil {
                order.append(settlement.to.id)
                byCreditor[settlement.to.id] = (settlement.to, [])
            }
            byCreditor[settlement.to.id]?.settlements.append(settlement)
        }
        return order.compactMap { byCreditor[$0] }
    }

    private func creditorRow(_ trip: Trip, _ group: (creditor: Person, settlements: [Settlement])) -> some View {
        let me = store.currentUser.id
        let name = group.creditor.id == me ? "You" : group.creditor.name
        let totalRemaining = group.settlements.reduce(0) { $0 + store.remaining(tripID: tripID, for: $1) }
        let isExpanded = expandedCreditors.contains(group.creditor.id)
        return Button {
            withAnimation(.snappy) {
                if isExpanded {
                    expandedCreditors.remove(group.creditor.id)
                } else {
                    expandedCreditors.insert(group.creditor.id)
                }
            }
        } label: {
            HStack(spacing: 8) {
                avatar(group.creditor, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey(name))
                        .font(.app(.subheadline)).fontWeight(.semibold)
                    Text("Owed by \(group.settlements.count) \(group.settlements.count == 1 ? "person" : "people")")
                        .font(.app(.caption))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if totalRemaining <= 0 {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(Color(hex: 0x10B981))
                } else {
                    Text(money(totalRemaining, trip.currencyCode))
                        .font(.app(.subheadline, .semibold))
                        .foregroundStyle(Color(hex: 0x10B981))
                }
                Image(systemName: "chevron.right")
                    .font(.app(.caption2, .bold)).foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            // Padding before contentShape so the whole padded row hit-tests,
            // not just the inner rect.
            .padding(.vertical, 4)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func settleRow(_ trip: Trip, _ settlement: Settlement) -> some View {
        let me = store.currentUser.id
        let fromLabel = settlement.from.id == me ? "You" : settlement.from.name
        return HStack(spacing: 8) {
            avatar(settlement.from, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(fromLabel))
                    .font(.app(.subheadline)).fontWeight(.semibold)
                if store.isFullySettled(tripID: tripID, settlement) {
                    Text("Settled").font(.app(.caption)).foregroundStyle(Color(hex: 0x10B981))
                }
            }
            Spacer()
            if store.isFullySettled(tripID: tripID, settlement) {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(Color(hex: 0x10B981))
            } else {
                Text(money(store.remaining(tripID: tripID, for: settlement), trip.currencyCode))
                    .font(.app(.subheadline, .semibold))
                    .foregroundStyle(Color(hex: 0x10B981))
                // Only the creditor can confirm they were actually paid back.
                if settlement.to.id == me {
                    Button {
                        settlementToConfirm = settlement
                    } label: {
                        Text("Mark Paid")
                            .font(.app(.caption, .semibold))
                            .foregroundStyle(Color(hex: 0x10B981))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Color(hex: 0x10B981).opacity(0.15), in: .capsule)
                            .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                }
            }
            Image(systemName: "chevron.right")
                .font(.app(.caption2, .bold)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
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
                    .font(.app(.subheadline, .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Theme.accent, in: .circle)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Step \(number)")
                        .font(.app(.caption, .bold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Text(title)
                        .font(.app(.subheadline, .semibold))
                    Text(detail)
                        .font(.app(.footnote))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func membersCard(_ trip: Trip) -> some View {
        TripCard(title: "Members (\(trip.members.count))", icon: "person.2.fill") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(trip.members) { member in
                        VStack(spacing: 6) {
                            AvatarView(
                                person: member,
                                imageData: member.id == store.currentUser.id ? store.profileImageData : nil,
                                size: 40
                            )
                            Text(LocalizedStringKey(member.id == store.currentUser.id ? "You" : member.name))
                                .font(.app(.caption))
                                .lineLimit(1)
                            if member.id == trip.creatorID {
                                Text("Organizer")
                                    .font(.app(.caption2, .semibold))
                                    .foregroundStyle(Theme.accent)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Theme.accent.opacity(0.14), in: .capsule)
                            }
                        }
                        .frame(width: 74)
                        .contextMenu {
                            if store.isCreator(of: trip), member.id != trip.creatorID {
                                Button(role: .destructive) { memberToRemove = member } label: {
                                    Label("Remove Access", systemImage: "person.crop.circle.badge.minus")
                                }
                            }
                        }
                    }
                }
            }

            if store.isCreator(of: trip) {
                Divider()
                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        TextField("Add manual member", text: $manualMemberName)
                            .font(.app(.subheadline))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Theme.fieldBackground, in: .rect(cornerRadius: 12))
                        Button { addManualMember(trip) } label: {
                            Image(systemName: "plus")
                                .font(.app(.subheadline, .bold))
                                .foregroundStyle(Theme.onAccent)
                                .frame(width: 40, height: 40)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.tint(Theme.accent).interactive(), in: .circle)
                        .disabled(manualMemberName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    TextField("Invite by email", text: $inviteEmail)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                        .autocorrectionDisabled()
                        .font(.app(.subheadline))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Theme.fieldBackground, in: .rect(cornerRadius: 12))

                    Button { invite(trip) } label: {
                        HStack(spacing: 8) {
                            if isInviting { ProgressView().tint(.white) }
                            Label("Invite Member", systemImage: "person.badge.plus")
                        }
                        .font(.app(.subheadline, .semibold))
                        .foregroundStyle(Theme.onAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.tint(Theme.accent).interactive(), in: .capsule)
                    .disabled(inviteEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isInviting)
                    .opacity(inviteEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isInviting ? 0.55 : 1)

                    if let inviteMessage {
                        Text(inviteMessage)
                            .font(.app(.caption))
                            .foregroundStyle(inviteMessage.localizedCaseInsensitiveContains("invited") || inviteMessage.localizedCaseInsensitiveContains("copied") ? Theme.positive : Theme.negative)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Divider()

                    Button { generateInviteLink(trip) } label: {
                        HStack(spacing: 8) {
                            if isGeneratingLink { ProgressView().tint(.white) }
                            Label("Generate Invitation Link", systemImage: "link")
                        }
                        .font(.app(.subheadline, .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.tint(Color(hex: 0x10B981)).interactive(), in: .capsule)
                    .disabled(isGeneratingLink)

                    if let inviteLink {
                        HStack(spacing: 8) {
                            Text(inviteLink.absoluteString)
                                .font(.app(.caption))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button {
                                UIPasteboard.general.string = inviteLink.absoluteString
                                inviteMessage = String(localized: "Invitation link copied.")
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.app(.caption, .bold))
                                    .frame(width: 38, height: 38)
                                    .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            ShareLink(item: inviteLink) {
                                Image(systemName: "square.and.arrow.up")
                                    .font(.app(.caption, .bold))
                                    .frame(width: 38, height: 38)
                                    .contentShape(.rect)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Theme.fieldBackground, in: .rect(cornerRadius: 12))
                    }

                    if !pendingInvitations.isEmpty {
                        Divider()
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Pending Invitations")
                                .font(.app(.subheadline, .semibold))
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
                        .font(.app(.subheadline, .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .disabled(membershipActionBusy)
            }

            if let membershipMessage {
                Text(verbatim: membershipMessage)
                    .font(.app(.caption))
                    .foregroundStyle(
                        membershipMessage.localizedCaseInsensitiveContains("removed")
                        || membershipMessage.localizedCaseInsensitiveContains("revoked")
                            ? Theme.positive : Theme.negative
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
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
                membershipMessage = "Access removed. Historical balances are unchanged."
            } catch {
                membershipMessage = (error as? AuthError)?.message ?? "Member access could not be removed."
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
                membershipMessage = (error as? AuthError)?.message ?? "The trip could not be left."
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
                membershipMessage = "Invitation revoked."
            } catch {
                membershipMessage = (error as? AuthError)?.message ?? "The invitation could not be revoked."
            }
        }
    }

    private func addManualMember(_ trip: Trip) {
        store.addManualMember(name: manualMemberName, to: trip.id)
        manualMemberName = ""
    }

    private func invite(_ trip: Trip) {
        inviteMessage = nil
        isInviting = true
        let email = inviteEmail
        Task {
            do {
                try await store.inviteMember(email: email, displayName: "", to: trip.id)
                inviteEmail = ""
                inviteMessage = String(localized: "Invitation pending. Membership starts only after the recipient accepts.")
                await loadPendingInvitations()
            } catch {
                inviteMessage = (error as? AuthError)?.message ?? error.localizedDescription
            }
            isInviting = false
        }
    }

    private func generateInviteLink(_ trip: Trip) {
        inviteMessage = nil
        isGeneratingLink = true
        Task {
            do {
                inviteLink = try await store.createInvitationLink(for: trip.id)
                inviteMessage = String(localized: "Invitation link ready to share.")
                await loadPendingInvitations()
            } catch {
                inviteMessage = (error as? AuthError)?.message ?? error.localizedDescription
            }
            isGeneratingLink = false
        }
    }

    /// Entry point to the day-by-day planner (ItineraryFeature.swift): opens the plan
    /// when one exists, or seeds one from the trip's dates and budget so itineraries
    /// are reachable from the Trips side, not just Explore.
    @ViewBuilder
    private func itineraryCard(_ trip: Trip) -> some View {
        TripCard(title: "Itinerary", icon: "map.fill") {
            if let itinerary = trip.itinerary {
                let stopCount = itinerary.days.reduce(0) { $0 + $1.stops.count }
                NavigationLink {
                    ItineraryDetailView(tripID: trip.id, showsTripLink: false)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "calendar.day.timeline.left")
                            .font(.app(.title3))
                            .foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Day-by-day plan")
                                .font(.app(.subheadline, .semibold))
                                .foregroundStyle(.primary)
                            Text("\(itinerary.days.count) day\(itinerary.days.count == 1 ? "" : "s") · \(stopCount) stop\(stopCount == 1 ? "" : "s") planned")
                                .font(.app(.caption))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.app(.footnote, .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(12)
                    .background(Theme.fieldBackground, in: .rect(cornerRadius: 14))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            } else {
                Text("Plan each day of this trip: places to go, things to do, and where to eat.")
                    .font(.app(.footnote))
                    .foregroundStyle(.secondary)
                Button {
                    seedItinerary(trip)
                } label: {
                    Label("Plan day-by-day itinerary", systemImage: "map.fill")
                        .font(.app(.subheadline, .semibold))
                        .foregroundStyle(Theme.onAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.tint(Theme.accent).interactive(), in: .capsule)
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
                Text("No expenses yet. Tap Add Expense to log one.")
                    .font(.app(.subheadline)).italic()
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
                    .background(Theme.fieldBackground, in: .capsule)

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
                    .font(.app(.subheadline, .semibold)).foregroundStyle(.secondary)
                // Eager (not Lazy) on purpose: a LazyVStack here re-measured rows as
                // they scrolled back into view, hitching the scroll-up out of this card.
                VStack(spacing: Theme.isRuled ? 0 : 8) {
                    ForEach(filtered) { expense in
                        if Theme.isRuled { RuledDivider() }
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
                    .inscription(orFont: .app(.subheadline, .semibold))
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
        }
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
                    .font(.app(.subheadline)).fontWeight(.semibold)
                if let paidDate {
                    Text(paidDate.formatted(date: .abbreviated, time: .omitted))
                        .font(.app(.caption)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(money(settlement.amount, trip.currencyCode))
                .font(.app(.subheadline, .semibold))
                .foregroundStyle(.secondary)
            Label("Paid", systemImage: "checkmark.seal.fill")
                .font(.app(.caption, .semibold))
                .foregroundStyle(Color(hex: 0x10B981))
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
                    .font(.app(.subheadline, .semibold))
                    .strikethrough(color: .secondary)
                    .foregroundStyle(.secondary)
                let payerText = payer.map { $0.id == me ? "you" : $0.name } ?? "—"
                let deletedText = expense.deletedAt.map { " • deleted \($0.formatted(date: .abbreviated, time: .omitted))" } ?? ""
                Text("Paid by \(payerText)\(deletedText)")
                    .font(.app(.caption)).foregroundStyle(.tertiary)
            }
            Spacer()
            Text(money(expense.amount, trip.currencyCode))
                .font(.app(.subheadline, .semibold))
                .foregroundStyle(.secondary)
            if canModify(trip, expense) {
                Button {
                    store.restoreExpense(expense.id, in: trip.id)
                } label: {
                    Text("Restore")
                        .font(.app(.caption, .semibold))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Theme.accent.opacity(0.16), in: .capsule)
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
        return HStack(alignment: .top, spacing: 12) {
            if let payer {
                if Theme.isRuled {
                    // A monogram, not a disc: the ruled style has no filled shapes
                    // besides the primary action.
                    Text(payer.initials)
                        .font(.app(size: 13, weight: .semibold))
                        .foregroundStyle(payer.id == me ? Theme.accent : Theme.accentSecondary)
                        .frame(width: 24, height: 24)
                } else {
                    AvatarView(
                        person: payer,
                        imageData: payer.id == me ? store.profileImageData : nil,
                        size: 34
                    )
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(expense.title).font(.app(.subheadline, .semibold))
                        Text("Paid by \(payer.map { $0.id == me ? "you" : $0.name } ?? "—") • \(expense.date.formatted(date: .abbreviated, time: .omitted))")
                            .font(.app(.caption)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(money(expense.amount, trip.currencyCode))
                        .font(.app(.subheadline, .semibold))
                    Image(systemName: "chevron.right")
                        .font(.app(.caption2, .bold))
                        .foregroundStyle(.tertiary)
                }
                if expense.participantIDs.contains(me) {
                    Text("Your share: \(money(yourShare, trip.currencyCode))")
                        .font(.app(.caption))
                        .foregroundStyle(expense.payerID == me ? Theme.positive : Theme.negative)
                }
                HStack(spacing: 10) {
                    if expense.receiptURL != nil || !expense.items.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.text.viewfinder")
                            Text(expense.items.isEmpty ? "Receipt" : "Receipt • \(expense.items.count) item\(expense.items.count == 1 ? "" : "s")")
                        }
                        .font(.app(.caption2, .medium))
                        .foregroundStyle(.secondary)
                    }
                    let commentCount = trip.comments[expense.id.uuidString]?.count ?? 0
                    if commentCount > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "bubble.left.fill")
                            Text("\(commentCount)")
                        }
                        .font(.app(.caption2, .medium))
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, Theme.isRuled ? 0 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .background {
            if !Theme.isRuled {
                RoundedRectangle(cornerRadius: 12).fill(Theme.fieldBackground)
            }
        }
    }

    private func statColumn(_ title: LocalizedStringKey, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .inscription(orFont: .app(.caption))
                .foregroundStyle(.secondary)
            Text(value).font(.app(.subheadline, .bold)).foregroundStyle(color)
        }
    }
}
