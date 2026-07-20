import SwiftUI
import Observation
import Combine
import ImageIO
import PhotosUI
import UIKit
import VisionKit
import MapKit

// MARK: - Per-item split configuration

/// Configures how a single receipt item is split (equal/all, equal/selected,
/// single-payer, percentage, or by amount). Edits write straight back into the bound
/// `ReceiptItem`; the parent aggregates each item's shares into the expense total.
struct ItemSplitConfigView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var item: ReceiptItem
    let members: [Person]
    let payer: Person.ID
    let currencyCode: String
    let currentUserID: Person.ID

    private var outcome: SplitResult {
        SplitEngine.calculate(
            total: item.price,
            method: item.splitMethod,
            people: members,
            payer: payer,
            selected: item.participantIDs,
            noSplitAssignee: item.soloPayerID ?? payer,
            percentages: item.percentages,
            amounts: item.amounts
        )
    }

    private func name(_ member: Person) -> String { member.id == currentUserID ? "You" : member.name }

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(colors: Theme.sheetGradient, startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 18) {
                        TripCard(title: LocalizedStringKey(item.name), icon: "tag.fill") {
                            HStack {
                                Text("Item total").font(.app(.subheadline)).foregroundStyle(.secondary)
                                Spacer()
                                Text(money(item.price, currencyCode)).font(.app(.subheadline, .bold))
                            }
                        }
                        methodCard
                    }
                    .padding()
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("Split item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.disabled(!outcome.isValid)
                }
            }
        }
    }

    private var methodCard: some View {
        TripCard(title: "Split", icon: "divide.circle.fill") {
            Menu {
                ForEach(SplitMethod.allCases) { option in
                    Button {
                        item.splitMethod = option
                        if option == .equalSelected && item.participantIDs.isEmpty {
                            item.participantIDs = Set(members.map(\.id))
                        }
                        if option == .noSplit && item.soloPayerID == nil {
                            item.soloPayerID = payer
                        }
                    } label: {
                        Label(LocalizedStringKey(option.rawValue), systemImage: option.icon)
                    }
                }
            } label: {
                HStack {
                    Image(systemName: item.splitMethod.icon)
                    Text(LocalizedStringKey(item.splitMethod.rawValue)).font(.app(.subheadline, .semibold))
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down").font(.app(.caption)).foregroundStyle(.secondary)
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(Theme.fieldBackground, in: .rect(cornerRadius: 12))
            }

            switch item.splitMethod {
            case .equalAll:
                Text("Split equally across all \(members.count) member\(members.count == 1 ? "" : "s").")
                    .font(.app(.caption)).foregroundStyle(.secondary)
            case .equalSelected:
                ForEach(members) { member in
                    Button {
                        if item.participantIDs.contains(member.id) { item.participantIDs.remove(member.id) }
                        else { item.participantIDs.insert(member.id) }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: item.participantIDs.contains(member.id) ? "checkmark.square.fill" : "square")
                                .foregroundStyle(Theme.accent)
                            avatar(member, size: 30)
                            Text(LocalizedStringKey(name(member))).font(.app(.subheadline, .medium))
                            Spacer()
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            case .noSplit:
                ForEach(members) { member in
                    Button { item.soloPayerID = member.id } label: {
                        HStack(spacing: 12) {
                            Image(systemName: (item.soloPayerID ?? payer) == member.id ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(Theme.accent)
                            avatar(member, size: 30)
                            Text(LocalizedStringKey(name(member))).font(.app(.subheadline, .medium))
                            Spacer()
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            case .percentage:
                valueFields(unit: "%", values: $item.percentages)
            case .amount:
                valueFields(unit: currencySymbol(currencyCode), values: $item.amounts)
            }

            if let message = outcome.message, !outcome.isValid {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.app(.caption, .medium)).foregroundStyle(Theme.negative)
            }

            ForEach(members) { member in
                let owed = outcome.owed[member.id] ?? 0
                if owed > 0.005 {
                    HStack {
                        Text(LocalizedStringKey(name(member))).font(.app(.caption)).foregroundStyle(.secondary)
                        Spacer()
                        Text(money(owed, currencyCode)).font(.app(.caption, .semibold))
                    }
                }
            }
        }
    }

    private func valueFields(unit: String, values: Binding<[Person.ID: Double]>) -> some View {
        ForEach(members) { member in
            HStack(spacing: 10) {
                avatar(member, size: 30)
                Text(LocalizedStringKey(name(member))).font(.app(.subheadline, .medium))
                Spacer()
                TextField("0", value: Binding(
                    get: { values.wrappedValue[member.id] ?? 0 },
                    set: { values.wrappedValue[member.id] = $0 }
                ), format: .number)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 64)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(Theme.fieldBackground, in: .rect(cornerRadius: 10))
                Text(unit).font(.app(.subheadline)).foregroundStyle(.secondary)
            }
        }
    }
}
