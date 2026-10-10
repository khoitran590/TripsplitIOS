import Foundation

/// Plain-text exports designed to stay readable in Messages, Mail, Notes, and other
/// share-sheet destinations. Values remain plain text rather than Markdown because many
/// receiving apps strip rich formatting.
enum TripExport {
    static func text(_ trip: Trip) -> String {
        let report = TripReport(trip: trip)
        let expenses = report.expenses
        let totalSpent = report.totalSpent
        let budgets = trip.members.filter { trip.budget(for: $0.id) > 0.005 }

        var lines = [String(localized: "TRIPSPLIT EXPENSE SUMMARY"), displayTripName(trip)]
        if let location = trip.location?.trimmingCharacters(in: .whitespacesAndNewlines),
           !location.isEmpty {
            lines.append("📍 \(location)")
        }
        if let dates = trip.dateRangeText {
            lines.append("📅 \(dates)")
        }

        appendSection(String(localized: "TRIP OVERVIEW"), to: &lines)
        lines.append(labeled("Total spent", money(totalSpent, trip.currencyCode)))
        lines.append(labeled("Travelers", String(trip.members.count)))
        lines.append(labeled("Expenses", String(expenses.count)))
        lines.append(labeled("Currency", trip.currencyCode))

        appendSection(String(localized: "SETTLE UP · WHO PAYS WHOM"), to: &lines)
        let openPayments = report.payments.filter { $0.remaining > 0.005 }
        if expenses.isEmpty {
            lines.append(String(localized: "No expenses recorded. No payments are needed."))
        } else if openPayments.isEmpty {
            lines.append(String(localized: "Everyone is settled up. No payments are needed."))
        } else {
            for payment in openPayments {
                let settlement = payment.settlement
                let direction = String(localized: "\(displayName(settlement.from)) owes \(displayName(settlement.to))")
                lines.append("• \(direction): \(report.money(payment.remaining))")
                if payment.paid > 0.005 {
                    lines.append("  \(String(localized: "Confirmed paid")): \(report.money(payment.paid)) · \(String(localized: "Original amount")): \(report.money(settlement.amount))")
                }
            }
        }
        lines.append(String(localized: "Suggested transfers simplify group debts. Only confirmed payments reduce the amounts due."))

        appendSection(String(localized: "BALANCES BY PERSON"), to: &lines)
        for person in report.people {
            lines.append("• \(displayName(person.person))")
            lines.append("  \(labeled("Paid for expenses", report.money(person.paid))) · \(labeled("Share of costs", report.money(person.share)))")
            lines.append("  \(report.balanceText(report.remainingBalance(for: person.person.id)))")
        }

        if !budgets.isEmpty {
            appendSection(String(localized: "BUDGETS"), to: &lines)
            for member in budgets {
                lines.append("• \(displayName(member)): \(money(trip.budget(for: member.id), trip.currencyCode))")
            }
        }

        appendSection(String(localized: "EXPENSES"), to: &lines)
        if expenses.isEmpty {
            lines.append(String(localized: "No expenses recorded"))
        } else {
            for (index, expense) in expenses.enumerated() {
                if index > 0 { lines.append("") }
                appendExpense(expense, number: index + 1, trip: trip, to: &lines)
            }
        }

        lines.append("")
        lines.append(String(localized: "Shared from TripSplit"))
        return lines.joined(separator: "\n")
    }

    static func settlementText(
        settlement: Settlement,
        remaining: Double,
        currencyCode: String,
        tripName: String?
    ) -> String {
        var lines = [String(localized: "TRIPSPLIT PAYMENT REQUEST")]
        if let tripName = tripName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !tripName.isEmpty {
            lines.append(tripName)
        }

        appendSection(String(localized: "PAYMENT"), to: &lines)
        lines.append(labeled("From", displayName(settlement.from)))
        lines.append(labeled("To", displayName(settlement.to)))

        if remaining > 0.005 {
            appendSection(String(localized: "AMOUNT DUE"), to: &lines)
            lines.append(money(remaining, currencyCode))
            lines.append("")
            lines.append(String(localized: "Remaining balance after confirmed payments."))
        } else {
            appendSection(String(localized: "STATUS"), to: &lines)
            lines.append("✓ \(String(localized: "PAID IN FULL"))")
        }

        lines.append("")
        lines.append(String(localized: "Shared from TripSplit"))
        return lines.joined(separator: "\n")
    }

    private static func appendExpense(
        _ expense: Expense,
        number: Int,
        trip: Trip,
        to lines: inout [String]
    ) {
        let title = expense.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let payer = trip.members.first { $0.id == expense.payerID }
        lines.append("\(number). \(title.isEmpty ? String(localized: "Expense") : title)")
        lines.append("   \(labeled("Total", money(expense.amount, trip.currencyCode)))")
        lines.append("   \(labeled("Paid by", payer.map(displayName) ?? String(localized: "Unknown")))")
        lines.append("   \(labeled("Date", expense.date.formatted(date: .abbreviated, time: .omitted)))")
        lines.append("   \(String(localized: "Split")):")

        for member in trip.members {
            let share = trip.share(for: member.id, in: expense)
            if share > 0.005 {
                lines.append("     • \(displayName(member)): \(money(share, trip.currencyCode))")
            }
        }
    }

    private static func appendSection(_ title: String, to lines: inout [String]) {
        lines.append("")
        lines.append(title)
    }

    private static func labeled(_ label: String.LocalizationValue, _ value: String) -> String {
        "\(String(localized: label)): \(value)"
    }

    private static func displayTripName(_ trip: Trip) -> String {
        let name = trip.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? String(localized: "Unnamed trip") : name
    }

    nonisolated private static func displayName(_ person: Person) -> String {
        let name = person.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? String(localized: "Tripmate") : name
    }
}
