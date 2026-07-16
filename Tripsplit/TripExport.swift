import Foundation

enum TripExport {
    static func text(_ trip: Trip) -> String {
        var lines = [trip.name]
        if let location = trip.location, !location.isEmpty { lines.append(location) }
        if let dates = trip.dateRangeText { lines.append(dates) }
        lines.append("")
        lines.append("Members")
        for member in trip.members {
            lines.append("• \(member.name): budget \(money(trip.budget(for: member.id), trip.currencyCode))")
        }
        lines.append("")
        lines.append("Expenses")
        if trip.expenses.isEmpty {
            lines.append("No expenses")
        } else {
            for expense in trip.expenses.sorted(by: { $0.date < $1.date }) {
                let payer = trip.members.first(where: { $0.id == expense.payerID })?.name ?? "Unknown"
                lines.append("• \(expense.date.formatted(date: .abbreviated, time: .omitted)) — \(expense.title): \(money(expense.amount, trip.currencyCode)) (paid by \(payer))")
            }
        }
        lines.append("")
        lines.append("Open settlements")
        let settlements = trip.settlements().filter { settlement in
            let key = "\(settlement.from.id.uuidString)->\(settlement.to.id.uuidString)"
            let confirmed = (trip.settlementRecords[key] ?? []).filter { $0.status == .confirmed }.reduce(0) { $0 + $1.amount }
            return settlement.amount - confirmed > 0.005
        }
        if settlements.isEmpty {
            lines.append("Everyone is settled up")
        } else {
            for settlement in settlements {
                let key = "\(settlement.from.id.uuidString)->\(settlement.to.id.uuidString)"
                let confirmed = (trip.settlementRecords[key] ?? []).filter { $0.status == .confirmed }.reduce(0) { $0 + $1.amount }
                lines.append("• \(settlement.from.name) pays \(settlement.to.name) \(money(max(0, settlement.amount - confirmed), trip.currencyCode))")
            }
        }
        return lines.joined(separator: "\n")
    }
}
