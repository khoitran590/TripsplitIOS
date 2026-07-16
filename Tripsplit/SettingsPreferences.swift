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
