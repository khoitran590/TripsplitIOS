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

/// A summary row for one trip on the home screen, showing the user's net balance.
struct TripRow: View {
    let trip: Trip
    let currentUserID: Person.ID

    private var net: Double {
        SplitEngine.roundToTwo(trip.owed(to: currentUserID) - trip.owed(by: currentUserID))
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "suitcase.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Color(hex: 0x6366F1), in: .circle)

            VStack(alignment: .leading, spacing: 2) {
                Text(trip.name).font(.subheadline.weight(.semibold))
                Text("\(trip.members.count) member\(trip.members.count == 1 ? "" : "s") • \(trip.expenses.count) expense\(trip.expenses.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(net == 0 ? "Settled" : (net > 0 ? "You're owed" : "You owe"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if net != 0 {
                    Text(money(abs(net), trip.currencyCode))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(net > 0 ? Color(hex: 0x10B981) : Color(hex: 0xEF4444))
                }
            }
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
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
