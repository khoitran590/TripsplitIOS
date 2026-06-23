import SwiftUI

/// The TripSplit-style main dashboard: greeting, balance card, quick actions,
/// and recent transactions.
struct HomeScreen: View {
    @State private var showSplit = false

    var body: some View {
        ZStack {
            // Screen background gradient (TripSplit light palette).
            LinearGradient(
                colors: [Color(hex: 0xCCE0FF), Color(hex: 0xCCF0F5), Color(hex: 0xEBD0F0), Color(hex: 0xFAD0DE)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    BalanceCard()
                    CurrencyConverterCard()
                    quickActions
                    recentTransactions
                }
                .padding()
                .padding(.bottom, 90) // Clearance for the floating dock.
            }
        }
        .sheet(isPresented: $showSplit) {
            SplitView()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("TRIP VITALS")
                    .font(.caption.weight(.semibold))
                    .tracking(1.5)
                Circle().frame(width: 4, height: 4)
                Text("98")
                    .font(.caption.weight(.bold))
            }
            .foregroundStyle(.secondary)

            Text("Hi, Benjamin")
                .font(.system(size: 40, weight: .regular, design: .serif))

            HStack(spacing: 12) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 40, height: 40)
                    .glassEffect(.regular, in: .circle)
                Text("Your itinerary is on track. 3 places scheduled for today.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 24))
        }
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
                ) { showSplit = true }

                QuickActionButton(
                    title: "Add Expense", subtitle: "Log spending",
                    icon: "plus.circle.fill",
                    colors: [Color(hex: 0x34D399), Color(hex: 0x059669)]
                ) {}
            }
        }
    }

    private var recentTransactions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent Transactions")
                .font(.headline)
                .padding(.leading, 4)

            GlassEffectContainer(spacing: 12) {
                VStack(spacing: 12) {
                    ForEach(Transaction.samples) { transaction in
                        TransactionRow(transaction: transaction)
                    }
                }
            }
        }
    }
}

// MARK: - Balance Card

/// The gradient budget card with a daily-spending bar chart.
struct BalanceCard: View {
    private let dailySpending: [(label: String, amount: Double)] = [
        ("2", 45), ("3", 62), ("4", 30), ("5", 88), ("6", 54), ("7", 70), ("8", 40),
        ("9", 95), ("10", 60), ("11", 48), ("12", 80), ("13", 35), ("14", 66), ("15", 52),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("Budget Available", systemImage: "wallet.bifold.fill")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Image(systemName: "ellipsis")
            }
            .foregroundStyle(.white.opacity(0.95))

            Text("$2,500.00")
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            HStack {
                Label("Total spent", systemImage: "wallet.bifold")
                    .font(.footnote.weight(.medium))
                Text("$1,250.00").font(.footnote.weight(.semibold))
                Spacer()
                Text("Combined from 2 currencies").font(.footnote)
            }
            .foregroundStyle(.white.opacity(0.85))

            // Daily spending bar chart
            let maxAmount = dailySpending.map(\.amount).max() ?? 1
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(Array(dailySpending.enumerated()), id: \.offset) { _, day in
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(.white.opacity(0.85))
                            .frame(height: max(6, 110 * (day.amount / maxAmount)))
                        Text(day.label)
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 140, alignment: .bottom)

            HStack(spacing: 12) {
                infoColumn(icon: "arrow.up.right", label: "You owe", value: "$150.00")
                infoColumn(icon: "arrow.down.left", label: "People owe", value: "$300.00")
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
    let color: Color

    var initials: String {
        let parts = name.split(separator: " ")
        return String(parts.prefix(2).compactMap(\.first)).uppercased()
    }

    static let samples: [Transaction] = [
        Transaction(name: "Ramen Dinner", category: "Food", date: "Nov 5", amount: 45.00, color: Color(hex: 0xEC4899)),
        Transaction(name: "Shinkansen Tickets", category: "Transport", date: "Nov 4", amount: 220.50, color: Color(hex: 0x6366F1)),
        Transaction(name: "Hotel Kyoto", category: "Lodging", date: "Nov 3", amount: 480.00, color: Color(hex: 0x10B981)),
        Transaction(name: "Museum Passes", category: "Activities", date: "Nov 3", amount: 36.00, color: Color(hex: 0xF59E0B)),
    ]
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
            Text(String(format: "$%.2f", transaction.amount))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color(hex: 0x10B981))
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }
}

#Preview {
    HomeScreen()
}
