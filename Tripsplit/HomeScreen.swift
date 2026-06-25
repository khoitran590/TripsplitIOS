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
    @State private var splitTrip: Trip?
    @State private var expenseTrip: Trip?
    @State private var tripToDelete: Trip?

    var body: some View {
        ZStack {
            // Screen background gradient — light pastel, deep "Arctic Depths" in dark mode.
            LinearGradient(
                colors: Theme.homeGradient,
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    syncBanner
                    BalanceCard()
                    CurrencyConverterCard()
                    quickActions
                    tripsSection
                    recentTransactions
                }
                .padding()
                .padding(.bottom, 90) // Clearance for the floating dock.
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
        .confirmationDialog("Choose a trip", isPresented: $showTripPicker, titleVisibility: .visible) {
            ForEach(store.myTrips) { trip in
                Button(trip.name) { choose(trip) }
            }
            Button("Cancel", role: .cancel) { pendingAction = nil }
        } message: {
            Text(pendingAction == .split ? "Split a bill within which trip?" : "Add an expense to which trip?")
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
            Text(tripToDelete.map { "“\($0.name)” and its expenses will be removed for everyone." } ?? "")
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

    /// Routes the pending quick action to the chosen trip.
    private func choose(_ trip: Trip) {
        switch pendingAction {
        case .split: splitTrip = trip
        case .addExpense: expenseTrip = trip
        case nil: break
        }
        pendingAction = nil
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
                Text("No trips yet. Tap Add Trip to create one.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
                    .glassEffect(.regular, in: .rect(cornerRadius: 20))
            } else {
                GlassEffectContainer(spacing: 12) {
                    VStack(spacing: 12) {
                        ForEach(store.myTrips) { trip in
                            Button { selectedTrip = trip } label: {
                                TripRow(trip: trip, currentUserID: store.currentUser.id)
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
                }
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

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("TRIP VITALS")
                    .font(.caption.weight(.semibold))
                    .tracking(1.5)
            }
            .foregroundStyle(.secondary)

            HStack(alignment: .center, spacing: 14) {
                Text("Hi, \(greetingName)")
                    .font(.system(size: 40, weight: .regular, design: .serif))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Spacer(minLength: 0)
                appearanceToggle
                ProfileAvatar(
                    imageData: store.profileImageData,
                    initials: store.currentUser.initials,
                    size: 56
                )
            }

            HStack(spacing: 12) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 40, height: 40)
                    .glassEffect(.regular, in: .circle)
                Text("Your itinerary is on track.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 24))
        }
    }

    /// A glass button that switches the app between System, Light, and Dark appearance.
    private var appearanceToggle: some View {
        Menu {
            Picker("Appearance", selection: $appearance) {
                ForEach(AppearancePreference.allCases) { option in
                    Label(option.label, systemImage: option.icon).tag(option)
                }
            }
        } label: {
            Image(systemName: appearance.icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .glassEffect(.regular.interactive(), in: .circle)
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
                    title: "Split", subtitle: "Divide a bill",
                    icon: "divide.circle.fill",
                    colors: [Color(hex: 0x818CF8), Color(hex: 0x4F46E5)]
                ) { startQuickAction(.split) }

                QuickActionButton(
                    title: "Add Expense", subtitle: "Log spending",
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
                        name: expense.title,
                        category: "\(trip.name) • Paid by \(payerLabel)",
                        date: expense.date.formatted(date: .abbreviated, time: .omitted),
                        amount: expense.amount,
                        currencyCode: trip.currencyCode,
                        color: payer?.color ?? Theme.accent,
                        sortDate: expense.date
                    )
                }
            }
            .sorted { $0.sortDate > $1.sortDate }
    }

    private var recentTransactions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent Transactions")
                .font(.headline)
                .padding(.leading, 4)

            let transactions = allTransactions
            if transactions.isEmpty {
                Text("No transactions yet. Add an expense to a trip to see it here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
                    .glassEffect(.regular, in: .rect(cornerRadius: 20))
            } else {
                GlassEffectContainer(spacing: 12) {
                    VStack(spacing: 12) {
                        ForEach(transactions) { transaction in
                            TransactionRow(transaction: transaction)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Balance Card

/// The gradient budget card. Totals are aggregated across every trip the user is part of.
struct BalanceCard: View {
    @Environment(TripStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("Budget Available", systemImage: "wallet.bifold.fill")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Image(systemName: "ellipsis")
            }
            .foregroundStyle(.white.opacity(0.95))

            Text(money(store.budgetAvailable, "USD"))
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            HStack {
                Label("Total spent", systemImage: "wallet.bifold")
                    .font(.footnote.weight(.medium))
                Text(money(store.totalSpent, "USD")).font(.footnote.weight(.semibold))
                Spacer()
                if !store.myTrips.isEmpty {
                    Text("Across \(store.myTrips.count) trip\(store.myTrips.count == 1 ? "" : "s")")
                        .font(.footnote)
                }
            }
            .foregroundStyle(.white.opacity(0.85))

            HStack(spacing: 12) {
                infoColumn(icon: "arrow.up.right", label: "You owe", value: money(store.totalYouOwe, "USD"))
                infoColumn(icon: "arrow.down.left", label: "People owe", value: money(store.totalOwedToYou, "USD"))
            }
        }
        .padding(20)
        .background(
            LinearGradient(
                colors: [Color(hex: 0xB8E6F5), Color(hex: 0x5B9BD5), Color(hex: 0x2E4A8B)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        )
        .clipShape(.rect(cornerRadius: 34))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
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

    // Budget health (per the signed-in user's own budget on this trip).
    private var budget: Double { trip.budget(for: currentUserID) }
    private var spent: Double { trip.spent(for: currentUserID) }
    private var remaining: Double { trip.remainingBudget(for: currentUserID) }
    private var hasBudget: Bool { budget > 0 }
    private var percent: Double { hasBudget ? (spent / budget) * 100 : 0 }
    private var isOver: Bool { hasBudget && spent > budget }
    private var isNear: Bool { hasBudget && !isOver && percent >= 80 }

    private var net: Double {
        SplitEngine.roundToTwo(trip.owed(to: currentUserID) - trip.owed(by: currentUserID))
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
        VStack(alignment: .leading, spacing: 14) {
            header
            budgetBoxes
            progress
            footer
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "suitcase.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Color(hex: 0x6366F1), in: .circle)

            VStack(alignment: .leading, spacing: 2) {
                Text(trip.name).font(.subheadline.weight(.bold)).lineLimit(1)
                Text("\(trip.expenses.count) expense\(trip.expenses.count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Spacer(minLength: 6)

            if isOver || isNear { healthBadge }
            memberBadge
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

    private var memberBadge: some View {
        HStack(spacing: 5) {
            Image(systemName: "person.2.fill").font(.system(size: 11))
            Text("\(trip.members.count)").font(.caption.weight(.semibold))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.primary.opacity(0.06), in: .capsule)
    }

    private var budgetBoxes: some View {
        HStack(spacing: 12) {
            statBox(
                label: "SPENT (YOU)",
                value: money(spent, trip.currencyCode),
                valueColor: Color(hex: 0x6366F1),
                background: Theme.fieldBackground
            )
            statBox(
                label: isOver ? "OVER BY (YOU)" : "REMAINING (YOU)",
                value: money(abs(remaining), trip.currencyCode),
                valueColor: accent,
                background: (isOver ? Color(hex: 0xDC2626) : Color(hex: 0x16A34A)).opacity(0.12)
            )
        }
    }

    private func statBox(label: String, value: String, valueColor: Color, background: Color) -> some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .semibold)).tracking(0.5)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.bold)).foregroundStyle(valueColor)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10).padding(.horizontal, 8)
        .background(background, in: .rect(cornerRadius: 10))
    }

    private var progress: some View {
        VStack(spacing: 6) {
            HStack {
                Text("Your Budget Usage").font(.caption).foregroundStyle(.secondary)
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

    @ViewBuilder
    private var footer: some View {
        HStack {
            if net == 0 {
                Label("Settled up", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(hex: 0x16A34A))
            } else {
                Text("\(net > 0 ? "You're owed" : "You owe") \(money(abs(net), trip.currencyCode))")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(net > 0 ? Color(hex: 0x16A34A) : Color(hex: 0xDC2626))
            }
            Spacer()
            HStack(spacing: 4) {
                Text("View trip").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Currency Converter

/// A live currency converter backed by the Exchange Rates API.
struct CurrencyConverterCard: View {
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
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
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

struct QuickActionButton: View {
    let title: String
    let subtitle: String
    let icon: String
    let colors: [Color]
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(
                        LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: .circle
                    )
                Text(title).font(.headline)
                HStack(spacing: 4) {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 28))
    }
}

// MARK: - Recent Transactions

struct Transaction: Identifiable {
    let id = UUID()
    let name: String
    let category: String
    let date: String
    let amount: Double
    let currencyCode: String
    let color: Color
    /// The underlying date, used to sort newest-first.
    let sortDate: Date

    var initials: String {
        let parts = name.split(separator: " ")
        return String(parts.prefix(2).compactMap(\.first)).uppercased()
    }
}

struct TransactionRow: View {
    let transaction: Transaction

    var body: some View {
        HStack(spacing: 12) {
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
    }
}

#Preview {
    HomeScreen()
        .environment(TripStore())
}
