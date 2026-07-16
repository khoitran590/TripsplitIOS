import SwiftUI
import Observation
import Combine
import ImageIO
import PhotosUI
import UIKit
import VisionKit
import MapKit

// MARK: - Expense Detail

struct ExpenseDetailView: View {
    @Environment(TripStore.self) private var store
    let tripID: Trip.ID
    let expense: Expense

    @State private var commentText = ""
    @State private var editingExpense: Expense?
    @FocusState private var commentFieldFocused: Bool

    private var trip: Trip? { store.trip(tripID) }

    private var currentExpense: Expense? {
        trip?.expenses.first { $0.id == expense.id }
    }

    private var comments: [ExpenseComment] {
        trip?.comments[expense.id.uuidString] ?? []
    }

    private var canModify: Bool {
        guard let trip else { return false }
        return store.isCreator(of: trip) || expense.payerID == store.currentUser.id
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: Theme.sheetGradient,
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 18) {
                    summaryCard
                    receiptItemsCard
                    if let trip { participantsCard(trip) }
                    commentsCard
                }
                .padding()
                .padding(.bottom, 24)
            }
        }
        .navigationTitle(expense.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if canModify {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Edit") { editingExpense = currentExpense ?? expense }
                }
            }
        }
        .sheet(item: $editingExpense) { exp in
            AddExpenseView(tripID: tripID, editing: exp)
        }
    }

    private var summaryCard: some View {
        let exp = currentExpense ?? expense
        let payer = trip?.members.first { $0.id == exp.payerID }
        let me = store.currentUser.id

        return TripCard(title: "Details", icon: "info.circle.fill") {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(money(exp.amount, trip?.currencyCode ?? "USD"))
                        .font(.system(size: 28, weight: .bold))
                    Text(exp.date.formatted(date: .long, time: .omitted))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider()

            HStack(spacing: 10) {
                if let payer {
                    avatar(payer, size: 30)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Paid by").font(.caption).foregroundStyle(.secondary)
                    Text(LocalizedStringKey(payer.map { $0.id == me ? "You" : $0.name } ?? "—"))
                        .font(.subheadline.weight(.semibold))
                }
                Spacer()
            }

            if exp.receiptURL != nil || !exp.items.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text.viewfinder")
                    Text(exp.items.isEmpty ? "Receipt attached" : "Receipt • \(exp.items.count) item\(exp.items.count == 1 ? "" : "s")")
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            }
        }
    }

    /// The scanned/entered line items with their prices, plus tax/tip and a total, so the
    /// breakdown behind an itemized expense is visible instead of just an item count.
    @ViewBuilder
    private var receiptItemsCard: some View {
        let exp = currentExpense ?? expense
        let currency = trip?.currencyCode ?? "USD"
        if !exp.items.isEmpty {
            TripCard(title: "Receipt Items", icon: "list.bullet.rectangle.fill") {
                ForEach(exp.items) { item in
                    HStack(spacing: 10) {
                        Text(item.name)
                            .font(.subheadline)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(money(item.price, currency))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }

                if exp.tax > 0 || exp.tip > 0 {
                    Divider()
                    if exp.tax > 0 { receiptTotalRow(label: "Tax", value: money(exp.tax, currency)) }
                    if exp.tip > 0 { receiptTotalRow(label: "Tip", value: money(exp.tip, currency)) }
                }

                Divider()
                receiptTotalRow(label: "Total", value: money(exp.amount, currency), emphasized: true)
            }
        }
    }

    private func receiptTotalRow(label: LocalizedStringKey, value: String, emphasized: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(emphasized ? .subheadline.weight(.semibold) : .subheadline)
                .foregroundStyle(emphasized ? .primary : .secondary)
            Spacer()
            Text(value)
                .font(emphasized ? .subheadline.weight(.bold) : .subheadline.weight(.medium))
                .foregroundStyle(emphasized ? .primary : .secondary)
                .monospacedDigit()
        }
    }

    private func participantsCard(_ trip: Trip) -> some View {
        let exp = currentExpense ?? expense
        let me = store.currentUser.id

        return TripCard(title: "Split", icon: "person.2.fill") {
            ForEach(trip.members) { member in
                let share = trip.share(for: member.id, in: exp)
                if share > 0.005 {
                    HStack(spacing: 10) {
                        avatar(member, size: 30)
                        Text(LocalizedStringKey(member.id == me ? "You" : member.name))
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        Text(money(share, trip.currencyCode))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var commentsCard: some View {
        TripCard(title: "Comments (\(comments.count))", icon: "bubble.left.and.bubble.right.fill") {
            if comments.isEmpty {
                Text("No comments yet")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                ForEach(comments) { comment in
                    commentRow(comment)
                    if comment.id != comments.last?.id {
                        Divider()
                    }
                }
            }

            Divider()

            HStack(spacing: 10) {
                TextField("Add a comment…", text: $commentText, axis: .vertical)
                    .lineLimit(1...4)
                    .font(.subheadline)
                    .focused($commentFieldFocused)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Theme.fieldBackground, in: .rect(cornerRadius: 12))

                Button {
                    addComment()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .disabled(commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.4 : 1)
            }
        }
    }

    private func commentRow(_ comment: ExpenseComment) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                let member = trip?.members.first { $0.id == comment.authorID }
                if let member {
                    avatar(member, size: 24)
                }
                Text(LocalizedStringKey(comment.authorID == store.currentUser.id ? "You" : comment.authorName))
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(comment.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                if comment.authorID == store.currentUser.id || (trip.map { store.isCreator(of: $0) } ?? false) {
                    Button {
                        store.deleteComment(comment.id, from: expense.id, in: tripID)
                    } label: {
                        Image(systemName: "trash")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            Text(comment.text)
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
    }

    private func addComment() {
        let text = commentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        store.addComment(text, to: expense.id, in: tripID)
        commentText = ""
        commentFieldFocused = false
    }
}
