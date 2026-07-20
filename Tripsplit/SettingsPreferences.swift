import SwiftUI

struct PaymentPreferencesView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("defaultPaymentMethod") private var defaultMethod = PaymentMethod.cash.rawValue

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(PaymentMethod.allCases) { method in
                        Button { defaultMethod = method.rawValue } label: {
                            HStack {
                                Label(LocalizedStringKey(method.rawValue), systemImage: method.icon)
                                Spacer()
                                if defaultMethod == method.rawValue {
                                    Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Default payment method")
                } footer: {
                    Text("TripSplit records how a payment was made. It does not move money or connect to a payment account.")
                }
            }
            .navigationTitle("Payments")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

/// Typeface chooser. Each row previews itself in its own font, and the sample card
/// shows the selection at the sizes the app actually uses, so the readability of a
/// choice is visible before it is applied.
struct FontPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var fontManager = FontManager.shared

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(AppFontChoice.allCases) { choice in
                        Button {
                            withAnimation(.snappy) { fontManager.selection = choice }
                        } label: {
                            HStack(spacing: 14) {
                                VStack(alignment: .leading, spacing: 3) {
                                    // Typeface names are proper nouns — never localized.
                                    Text(verbatim: choice.label)
                                        .font(previewFont(choice, size: 17, weight: .semibold))
                                        .foregroundStyle(.primary)
                                    Text(choice.detail)
                                        .font(.app(.caption))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if choice == fontManager.selection {
                                    Image(systemName: "checkmark")
                                        .font(.app(.body, .semibold))
                                        .foregroundStyle(.tint)
                                }
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Font")
                } footer: {
                    Text("Applies across the app. Text still follows your device's Dynamic Type size, so larger text settings keep working.")
                }

                Section {
                    sample
                } header: {
                    Text("Preview")
                }
            }
            .navigationTitle("Change fonts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    /// A miniature of the real UI: a title, a total, a row subtitle, and a caption —
    /// the four sizes that carry most of the app's text.
    private var sample: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: "Tokyo Trip")
                .font(.app(.title2, .bold))
            Text(verbatim: "$1,284.50")
                .font(.app(.title3, .semibold))
                .foregroundStyle(Theme.accent)
            Text(verbatim: "Dinner at Ichiran — split 4 ways")
                .font(.app(.subheadline))
            Text(verbatim: "Paid by Alex · Jul 20")
                .font(.app(.caption))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }

    /// The font for a choice the user hasn't selected yet, so each row can render
    /// its own name in its own typeface.
    private func previewFont(_ choice: AppFontChoice, size: CGFloat, weight: Font.Weight) -> Font {
        guard let name = choice.previewFontName else {
            return .system(size: size, weight: weight)
        }
        return .custom(name, size: size)
    }
}

struct NotificationPreferencesView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("notifyExpenseActivity") private var expenseActivity = true
    @AppStorage("notifySettlementActivity") private var settlementActivity = true
    @AppStorage("notifyTripInvites") private var tripInvites = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Expenses and comments", isOn: $expenseActivity)
                    Toggle("Settlement updates", isOn: $settlementActivity)
                    Toggle("Trip invitations", isOn: $tripInvites)
                } footer: {
                    Text("These preferences are saved on this device. Push delivery will become available after TripSplit's notification service is enabled.")
                }
            }
            .navigationTitle("Notifications")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
