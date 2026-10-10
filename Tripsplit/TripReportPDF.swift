import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Shareable PDF expense report

/// A PDF expense report for people who don't have the app: who pays whom, each
/// person's balance, and the expense-by-expense breakdown behind those numbers.
/// The file is rendered only when a share destination asks for it, so placing a
/// `ShareLink` for it costs nothing until the user actually exports.
nonisolated struct TripReportPDF: Transferable {
    let trip: Trip

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .pdf) { report in
            SentTransferredFile(try await MainActor.run { try report.writeFile() })
        }
    }

    @MainActor
    static func fileName(for trip: Trip) -> String {
        let name = TripReport.displayTripName(trip)
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>"))
            .joined(separator: "-")
        return String(localized: "\(name) Expense Report") + ".pdf"
    }

    /// Writes the report into its own temporary folder so the shared file carries the
    /// trip's name and repeated exports never collide.
    @MainActor
    private func writeFile() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(Self.fileName(for: trip))
        try TripReportRenderer.data(for: TripReport(trip: trip)).write(to: url, options: .atomic)
        return url
    }
}

// MARK: - Report content

/// The numbers shown in the report, computed once from the trip so the drawing code
/// only lays out text. Balances come from the active expenses listed in the report,
/// so every row on the page can be checked against the breakdown beneath it.
struct TripReport {
    struct PersonSummary {
        let person: Person
        let paid: Double
        let share: Double
        var balance: Double { SplitEngine.roundToTwo(paid - share) }
        /// Expenses this person has a share in, with that share.
        let lines: [(expense: Expense, share: Double)]
    }

    struct Payment {
        let settlement: Settlement
        let paid: Double
        var remaining: Double { max(0, SplitEngine.roundToTwo(settlement.amount - paid)) }
    }

    let trip: Trip
    let generatedAt: Date
    let expenses: [Expense]
    let totalSpent: Double
    let people: [PersonSummary]
    let payments: [Payment]

    init(trip: Trip, generatedAt: Date = .now) {
        self.trip = trip
        self.generatedAt = generatedAt
        let expenses = trip.expenses.sorted {
            if $0.date != $1.date { return $0.date < $1.date }
            return $0.id.uuidString < $1.id.uuidString
        }
        self.expenses = expenses
        totalSpent = SplitEngine.roundToTwo(expenses.reduce(0) { $0 + $1.amount })
        people = trip.members.map { member in
            let lines = expenses.compactMap { expense -> (Expense, Double)? in
                let share = trip.share(for: member.id, in: expense)
                return share > 0.005 ? (expense, share) : nil
            }
            return PersonSummary(
                person: member,
                paid: SplitEngine.roundToTwo(trip.paid(by: member.id)),
                share: SplitEngine.roundToTwo(lines.reduce(0) { $0 + $1.1 }),
                lines: lines
            )
        }
        payments = trip.settlements().map { settlement in
            let confirmed = (trip.settlementRecords[settlement.id] ?? [])
                .filter { $0.status == .confirmed }
                .reduce(0.0) { $0 + $1.amount }
            return Payment(settlement: settlement, paid: SplitEngine.roundToTwo(confirmed))
        }
    }

    func money(_ value: Double) -> String { Tripsplit.money(value, trip.currencyCode) }

    func name(_ id: Person.ID) -> String {
        trip.members.first { $0.id == id }.map(Self.displayName) ?? String(localized: "Unknown")
    }

    func balanceText(_ balance: Double) -> String {
        if balance > 0.005 { return String(localized: "Gets back \(money(balance))") }
        if balance < -0.005 { return String(localized: "Owes \(money(-balance))") }
        return String(localized: "Settled")
    }

    static func displayName(_ person: Person) -> String {
        let name = person.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? String(localized: "Tripmate") : name
    }

    static func displayTripName(_ trip: Trip) -> String {
        let name = trip.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? String(localized: "Unnamed trip") : name
    }
}

// MARK: - Rendering

/// Lays the report out on US Letter pages with UIKit's PDF renderer. Text stays real
/// (selectable, searchable) rather than a rasterized SwiftUI snapshot.
enum TripReportRenderer {
    static func data(for report: TripReport) -> Data {
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextTitle as String: TripReportPDF.fileName(for: report.trip),
            kCGPDFContextCreator as String: "TripSplit",
        ]
        let renderer = UIGraphicsPDFRenderer(bounds: ReportCanvas.page, format: format)
        return renderer.pdfData { context in
            let canvas = ReportCanvas(
                context: context,
                footer: String(localized: "TripSplit expense report · \(TripReport.displayTripName(report.trip))")
            )
            canvas.beginPage()
            drawHeader(report, on: canvas)
            drawPayments(report, on: canvas)
            drawBalances(report, on: canvas)
            drawPersonBreakdowns(report, on: canvas)
            drawExpenses(report, on: canvas)
        }
    }

    private static func drawHeader(_ report: TripReport, on canvas: ReportCanvas) {
        let trip = report.trip
        canvas.paragraph(String(localized: "EXPENSE REPORT"), font: .systemFont(ofSize: 10, weight: .bold), color: .reportAccent, after: 4)
        canvas.paragraph(TripReport.displayTripName(trip), font: .systemFont(ofSize: 24, weight: .bold), after: 4)

        let details = [trip.location?.trimmingCharacters(in: .whitespacesAndNewlines), trip.dateRangeText]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        if !details.isEmpty {
            canvas.paragraph(details.joined(separator: " · "), font: .systemFont(ofSize: 12), color: .reportSecondary, after: 2)
        }
        let generated = report.generatedAt.formatted(date: .abbreviated, time: .shortened)
        canvas.paragraph(
            String(localized: "Generated \(generated) · All amounts in \(trip.currencyCode)"),
            font: .systemFont(ofSize: 10), color: .reportSecondary, after: 18
        )

        canvas.stats([
            (String(localized: "Total spent"), report.money(report.totalSpent)),
            (String(localized: "Travelers"), String(trip.members.count)),
            (String(localized: "Expenses"), String(report.expenses.count)),
        ])
    }

    private static func drawPayments(_ report: TripReport, on canvas: ReportCanvas) {
        canvas.section(String(localized: "Who pays whom"))
        guard !report.payments.isEmpty else {
            canvas.paragraph(String(localized: "Everyone is settled up. No payments are needed."), font: .systemFont(ofSize: 11), after: 8)
            return
        }
        canvas.paragraph(
            String(localized: "Balances are combined so the group settles up with as few payments as possible."),
            font: .systemFont(ofSize: 10), color: .reportSecondary, after: 8
        )
        canvas.table(
            columns: [
                .init(String(localized: "From"), 0.24),
                .init(String(localized: "To"), 0.24),
                .init(String(localized: "Amount"), 0.17, .right),
                .init(String(localized: "Paid so far"), 0.17, .right),
                .init(String(localized: "Still owed"), 0.18, .right),
            ],
            rows: report.payments.map { payment in
                [
                    TripReport.displayName(payment.settlement.from),
                    TripReport.displayName(payment.settlement.to),
                    report.money(payment.settlement.amount),
                    report.money(payment.paid),
                    payment.remaining > 0.005 ? report.money(payment.remaining) : String(localized: "Settled"),
                ]
            }
        )
    }

    private static func drawBalances(_ report: TripReport, on canvas: ReportCanvas) {
        canvas.section(String(localized: "Balances by person"))
        canvas.paragraph(
            String(localized: "Paid is what each person covered for the group; share is their part of the costs."),
            font: .systemFont(ofSize: 10), color: .reportSecondary, after: 8
        )
        canvas.table(
            columns: [
                .init(String(localized: "Person"), 0.31),
                .init(String(localized: "Paid"), 0.2, .right),
                .init(String(localized: "Share"), 0.2, .right),
                .init(String(localized: "Balance"), 0.29, .right),
            ],
            rows: report.people.map { summary in
                [
                    TripReport.displayName(summary.person),
                    report.money(summary.paid),
                    report.money(summary.share),
                    report.balanceText(summary.balance),
                ]
            },
            total: [
                String(localized: "Total"),
                report.money(report.totalSpent),
                report.money(SplitEngine.roundToTwo(report.people.reduce(0) { $0 + $1.share })),
                "",
            ]
        )
    }

    private static func drawPersonBreakdowns(_ report: TripReport, on canvas: ReportCanvas) {
        let people = report.people.filter { !$0.lines.isEmpty || $0.paid > 0.005 }
        guard !people.isEmpty else { return }
        canvas.section(String(localized: "Breakdown by person"))
        for summary in people {
            // Keep a person's heading with the start of their table.
            canvas.ensureSpace(80)
            canvas.paragraph(TripReport.displayName(summary.person), font: .systemFont(ofSize: 13, weight: .semibold), after: 2)
            let paid = report.money(summary.paid)
            let share = report.money(summary.share)
            canvas.paragraph(
                String(localized: "Paid \(paid) · Share \(share) · \(report.balanceText(summary.balance))"),
                font: .systemFont(ofSize: 10), color: .reportSecondary, after: 6
            )
            if summary.lines.isEmpty {
                canvas.paragraph(String(localized: "No share in any expense."), font: .systemFont(ofSize: 10), after: 14)
                continue
            }
            canvas.table(
                columns: [
                    .init(String(localized: "Date"), 0.17),
                    .init(String(localized: "Expense"), 0.35),
                    .init(String(localized: "Paid by"), 0.22),
                    .init(String(localized: "Their share"), 0.26, .right),
                ],
                rows: summary.lines.map { line in
                    [
                        line.expense.date.formatted(date: .abbreviated, time: .omitted),
                        expenseTitle(line.expense),
                        report.name(line.expense.payerID),
                        report.money(line.share),
                    ]
                },
                total: [String(localized: "Total"), "", "", report.money(summary.share)]
            )
        }
    }

    private static func drawExpenses(_ report: TripReport, on canvas: ReportCanvas) {
        canvas.section(String(localized: "All expenses"))
        guard !report.expenses.isEmpty else {
            canvas.paragraph(String(localized: "No expenses recorded"), font: .systemFont(ofSize: 11), after: 8)
            return
        }
        canvas.table(
            columns: [
                .init(String(localized: "Date"), 0.16),
                .init(String(localized: "Expense"), 0.20),
                .init(String(localized: "Paid by"), 0.16),
                .init(String(localized: "Amount"), 0.15, .right),
                .init(String(localized: "Split between"), 0.33),
            ],
            rows: report.expenses.map { expense in
                let split = report.trip.members.compactMap { member -> String? in
                    let share = report.trip.share(for: member.id, in: expense)
                    guard share > 0.005 else { return nil }
                    return "\(TripReport.displayName(member)) \(report.money(share))"
                }
                return [
                    expense.date.formatted(date: .abbreviated, time: .omitted),
                    expenseTitle(expense),
                    report.name(expense.payerID),
                    report.money(expense.amount),
                    split.joined(separator: "\n"),
                ]
            },
            total: [String(localized: "Total"), "", "", report.money(report.totalSpent), ""]
        )
    }

    private static func expenseTitle(_ expense: Expense) -> String {
        let title = expense.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? String(localized: "Expense") : title
    }
}

/// A cursor over paginated PDF pages: draws blocks top to bottom and starts a new
/// page (with footer) whenever the next block wouldn't fit.
private final class ReportCanvas {
    struct Column {
        let title: String
        let fraction: CGFloat
        let alignment: NSTextAlignment

        init(_ title: String, _ fraction: CGFloat, _ alignment: NSTextAlignment = .left) {
            self.title = title
            self.fraction = fraction
            self.alignment = alignment
        }
    }

    static let page = CGRect(x: 0, y: 0, width: 612, height: 792)
    private let margin: CGFloat = 48
    private let cellPadding = CGSize(width: 6, height: 5)
    private let context: UIGraphicsPDFRendererContext
    private let footer: String
    private var pageNumber = 0
    private var y: CGFloat = 0

    private var contentWidth: CGFloat { Self.page.width - margin * 2 }
    private var bottom: CGFloat { Self.page.height - margin - 20 }

    init(context: UIGraphicsPDFRendererContext, footer: String) {
        self.context = context
        self.footer = footer
    }

    func beginPage() {
        context.beginPage()
        pageNumber += 1
        y = margin
        let footerFont = UIFont.systemFont(ofSize: 8)
        let footerY = Self.page.height - margin + 4
        draw(footer, font: footerFont, color: .reportSecondary,
             in: CGRect(x: margin, y: footerY, width: contentWidth * 0.75, height: 12))
        draw(String(localized: "Page \(pageNumber)"), font: footerFont, color: .reportSecondary, alignment: .right,
             in: CGRect(x: margin, y: footerY, width: contentWidth, height: 12))
    }

    func ensureSpace(_ height: CGFloat) {
        if y + height > bottom { beginPage() }
    }

    func paragraph(_ text: String, font: UIFont, color: UIColor = .reportInk, after spacing: CGFloat) {
        let height = measure(text, font: font, width: contentWidth)
        ensureSpace(height)
        draw(text, font: font, color: color, in: CGRect(x: margin, y: y, width: contentWidth, height: height))
        y += height + spacing
    }

    func section(_ title: String) {
        // Never strand a heading at the bottom of a page.
        ensureSpace(90)
        y += 10
        draw(title.uppercased(), font: .systemFont(ofSize: 11, weight: .bold), color: .reportAccent,
             in: CGRect(x: margin, y: y, width: contentWidth, height: 16))
        y += 18
        fill(CGRect(x: margin, y: y, width: contentWidth, height: 1), .reportAccent)
        y += 10
    }

    func stats(_ items: [(label: String, value: String)]) {
        let gap: CGFloat = 10
        let width = (contentWidth - gap * CGFloat(items.count - 1)) / CGFloat(items.count)
        let height: CGFloat = 54
        ensureSpace(height)
        for (index, item) in items.enumerated() {
            let box = CGRect(x: margin + CGFloat(index) * (width + gap), y: y, width: width, height: height)
            UIColor.reportFill.setFill()
            UIBezierPath(roundedRect: box, cornerRadius: 8).fill()
            draw(item.label.uppercased(), font: .systemFont(ofSize: 8, weight: .semibold), color: .reportSecondary,
                 in: box.insetBy(dx: 10, dy: 9))
            draw(item.value, font: .systemFont(ofSize: 16, weight: .bold),
                 in: CGRect(x: box.minX + 10, y: box.minY + 23, width: box.width - 20, height: 22))
        }
        y += height + 6
    }

    func table(columns: [Column], rows: [[String]], total: [String]? = nil) {
        let headerFont = UIFont.systemFont(ofSize: 9, weight: .semibold)
        let bodyFont = UIFont.systemFont(ofSize: 10)
        let totalFont = UIFont.systemFont(ofSize: 10, weight: .semibold)
        let widths = columns.map { $0.fraction * contentWidth }

        func rowHeight(_ cells: [String], font: UIFont) -> CGFloat {
            zip(cells, widths)
                .map { measure($0, font: font, width: $1 - cellPadding.width * 2) }
                .max().map { $0 + cellPadding.height * 2 } ?? 0
        }

        func drawRow(_ cells: [String], font: UIFont, color: UIColor = .reportInk, height: CGFloat) {
            var x = margin
            for (index, cell) in cells.enumerated() where index < columns.count {
                draw(cell, font: font, color: color, alignment: columns[index].alignment,
                     in: CGRect(x: x, y: y, width: widths[index], height: height)
                        .insetBy(dx: cellPadding.width, dy: cellPadding.height))
                x += widths[index]
            }
        }

        func drawHeader() {
            let titles = columns.map { $0.title.uppercased() }
            let height = rowHeight(titles, font: headerFont)
            fill(CGRect(x: margin, y: y, width: contentWidth, height: height), .reportFill)
            drawRow(titles, font: headerFont, color: .reportSecondary, height: height)
            y += height
        }

        let header = rowHeight(columns.map { $0.title.uppercased() }, font: headerFont)
        ensureSpace(header + rowHeight(rows.first ?? [], font: bodyFont))
        drawHeader()
        for cells in rows {
            let height = rowHeight(cells, font: bodyFont)
            if y + height > bottom {
                beginPage()
                drawHeader()
            }
            drawRow(cells, font: bodyFont, height: height)
            y += height
            fill(CGRect(x: margin, y: y - 0.5, width: contentWidth, height: 0.5), .reportRule)
        }
        if let total {
            let height = rowHeight(total, font: totalFont)
            ensureSpace(height)
            fill(CGRect(x: margin, y: y, width: contentWidth, height: 1), .reportInk)
            drawRow(total, font: totalFont, height: height)
            y += height
        }
        y += 16
    }

    private func attributes(_ font: UIFont, _ color: UIColor, _ alignment: NSTextAlignment) -> [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineBreakMode = .byWordWrapping
        return [.font: font, .foregroundColor: color, .paragraphStyle: style]
    }

    private func measure(_ text: String, font: UIFont, width: CGFloat) -> CGFloat {
        guard !text.isEmpty else { return font.lineHeight.rounded(.up) }
        return (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes(font, .reportInk, .left),
            context: nil
        ).height.rounded(.up)
    }

    private func draw(
        _ text: String, font: UIFont, color: UIColor = .reportInk,
        alignment: NSTextAlignment = .left, in rect: CGRect
    ) {
        (text as NSString).draw(
            with: rect,
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes(font, color, alignment),
            context: nil
        )
    }

    private func fill(_ rect: CGRect, _ color: UIColor) {
        color.setFill()
        UIRectFill(rect)
    }
}

/// Fixed print colours: a shared PDF should look the same regardless of the sender's
/// app theme or dark mode.
private extension UIColor {
    static let reportInk = UIColor(red: 0.11, green: 0.12, blue: 0.14, alpha: 1)
    static let reportSecondary = UIColor(red: 0.40, green: 0.42, blue: 0.46, alpha: 1)
    static let reportAccent = UIColor(red: 0.16, green: 0.42, blue: 0.55, alpha: 1)
    static let reportFill = UIColor(red: 0.95, green: 0.95, blue: 0.96, alpha: 1)
    static let reportRule = UIColor(red: 0.86, green: 0.87, blue: 0.89, alpha: 1)
}
