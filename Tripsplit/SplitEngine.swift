import Foundation

// MARK: - Split Engine

/// The result of computing a split: each person's share, net balance, and validity.
struct SplitResult {
    /// Each person's share of the bill.
    var owed: [Person.ID: Double] = [:]
    /// Net balance per person: what they paid minus what they owe.
    /// Positive means the group owes them; negative means they owe the group.
    var net: [Person.ID: Double] = [:]
    var isValid: Bool = true
    var message: String?
}

/// Suggested transfer to settle up: `from` pays `to` the given `amount`.
struct Settlement: Identifiable {
    let id = UUID()
    let from: Person
    let to: Person
    let amount: Double
}

/// How a settlement payment was made, mirroring TripSplit's settlement payment methods.
enum PaymentMethod: String, CaseIterable, Identifiable, Codable {
    case cash = "Cash"
    case venmo = "Venmo"
    case paypal = "PayPal"
    case cashapp = "Cash App"

    var id: Self { self }

    var icon: String {
        switch self {
        case .cash: "banknote.fill"
        case .venmo: "v.circle.fill"
        case .paypal: "p.circle.fill"
        case .cashapp: "dollarsign.circle.fill"
        }
    }
}

/// The lifecycle of a settlement request, mirroring TripSplit's `status` field:
/// the debtor records a `pending` payment and the creditor confirms or declines it.
enum SettlementStatus: String, Codable {
    case pending, confirmed, rejected
}

/// A recorded settlement payment toward a debt between two people.
struct SettlementRecord: Identifiable, Codable {
    let id: UUID
    var amount: Double
    var method: PaymentMethod
    var note: String
    var status: SettlementStatus
    let date: Date

    init(
        id: UUID = UUID(), amount: Double, method: PaymentMethod, note: String,
        status: SettlementStatus, date: Date
    ) {
        self.id = id
        self.amount = amount
        self.method = method
        self.note = note
        self.status = status
        self.date = date
    }

    private enum CodingKeys: String, CodingKey { case id, amount, method, note, status, date }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        amount = try c.decodeIfPresent(Double.self, forKey: .amount) ?? 0
        method = try c.decodeIfPresent(PaymentMethod.self, forKey: .method) ?? .cash
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        status = try c.decodeIfPresent(SettlementStatus.self, forKey: .status) ?? .pending
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? Date()
    }
}

/// Pure split calculation, faithful to TripSplit's `calculateSplitPreview` +
/// `splitService` rounding, with exact-cent remainder distribution added so the
/// per-person shares always reconcile to the bill total.
enum SplitEngine {

    /// Rounds to two decimals using the same epsilon trick as `mathHelpers.roundToTwo`.
    static func roundToTwo(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return ((value + Double.ulpOfOne) * 100).rounded() / 100
    }

    /// Splits `total` across `count` people, distributing leftover cents to the
    /// first people so the parts sum exactly to `total` (largest-remainder method).
    static func equalShares(total: Double, count: Int) -> [Double] {
        guard count > 0 else { return [] }
        let totalCents = Int((total * 100).rounded())
        let base = totalCents / count
        let remainder = totalCents - base * count
        return (0..<count).map { index in
            Double(base + (index < remainder ? 1 : 0)) / 100.0
        }
    }

    /// Splits `amount` across people in proportion to `weights` (e.g. allocating tax/tip
    /// by each person's subtotal share), distributing leftover cents by largest remainder
    /// so the parts sum exactly to `amount`. Returns an empty map if there's no weight.
    static func allocateProportionally(_ amount: Double, weights: [Person.ID: Double]) -> [Person.ID: Double] {
        let totalWeight = weights.values.reduce(0, +)
        let cents = Int((amount * 100).rounded())
        guard totalWeight > 0, cents != 0 else { return [:] }

        let keys = Array(weights.keys)
        let exact = keys.map { Double(cents) * ((weights[$0] ?? 0) / totalWeight) }
        var base = exact.map { Int($0.rounded(.down)) }
        var leftover = cents - base.reduce(0, +)

        // Hand the remaining cents to the largest fractional remainders first.
        for index in (0..<keys.count).sorted(by: { (exact[$0] - Double(base[$0])) > (exact[$1] - Double(base[$1])) }) {
            guard leftover > 0 else { break }
            base[index] += 1
            leftover -= 1
        }

        return Dictionary(uniqueKeysWithValues: zip(keys, base.map { Double($0) / 100.0 }))
    }

    /// Computes the per-person shares and net balances for the given configuration.
    static func calculate(
        total: Double,
        method: SplitMethod,
        people: [Person],
        payer: Person.ID,
        selected: Set<Person.ID>,
        noSplitAssignee: Person.ID?,
        percentages: [Person.ID: Double],
        amounts: [Person.ID: Double]
    ) -> SplitResult {
        var result = SplitResult()
        var owed: [Person.ID: Double] = [:]
        people.forEach { owed[$0.id] = 0 }

        switch method {
        case .equalAll:
            let shares = equalShares(total: total, count: people.count)
            for (person, share) in zip(people, shares) { owed[person.id] = share }

        case .equalSelected:
            let chosen = people.filter { selected.contains($0.id) }
            guard !chosen.isEmpty else {
                result.isValid = false
                result.message = "Select at least one person to split between."
                result.owed = owed
                return result
            }
            let shares = equalShares(total: total, count: chosen.count)
            for (person, share) in zip(chosen, shares) { owed[person.id] = share }

        case .noSplit:
            guard let assignee = noSplitAssignee else {
                result.isValid = false
                result.message = "Choose who this expense belongs to."
                result.owed = owed
                return result
            }
            owed[assignee] = roundToTwo(total)

        case .percentage:
            let sum = people.reduce(0) { $0 + (percentages[$1.id] ?? 0) }
            for person in people {
                owed[person.id] = roundToTwo(total * (percentages[person.id] ?? 0) / 100.0)
            }
            if abs(sum - 100) > 0.01 {
                result.isValid = false
                result.message = String(format: "Percentages must add up to 100%% (now %.1f%%).", sum)
            }

        case .amount:
            let sum = people.reduce(0) { $0 + (amounts[$1.id] ?? 0) }
            for person in people {
                owed[person.id] = roundToTwo(amounts[person.id] ?? 0)
            }
            if abs(sum - total) > 0.01 {
                result.isValid = false
                result.message = String(format: "Amounts must add up to %.2f (now %.2f).", total, sum)
            }
        }

        // Net balance: the payer fronted the whole bill, everyone owes their share.
        var net: [Person.ID: Double] = [:]
        for person in people {
            let paid = person.id == payer ? total : 0
            net[person.id] = roundToTwo(paid - (owed[person.id] ?? 0))
        }

        result.owed = owed
        result.net = net
        return result
    }

    /// Greedy debt simplification: produces the minimum-ish set of transfers that
    /// settles every net balance. (TripSplit settles manually; this is a helper.)
    static func settleUp(net: [Person.ID: Double], people: [Person]) -> [Settlement] {
        let lookup = Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0) })
        // Walk in `people` order (not dictionary order) and tie-break equal amounts by
        // that order, so the same balances always produce the same transfer pairs —
        // recorded payments are keyed by pair and must survive relaunches.
        let ordered = people.enumerated().compactMap { index, person in
            net[person.id].map { (id: person.id, amount: $0, order: index) }
        }
        var creditors = ordered.filter { $0.amount > 0.005 }
            .sorted { $0.amount != $1.amount ? $0.amount > $1.amount : $0.order < $1.order }
        var debtors = ordered.filter { $0.amount < -0.005 }
            .map { (id: $0.id, amount: -$0.amount, order: $0.order) }
            .sorted { $0.amount != $1.amount ? $0.amount > $1.amount : $0.order < $1.order }

        var settlements: [Settlement] = []
        var ci = 0, di = 0
        while ci < creditors.count && di < debtors.count {
            let pay = min(creditors[ci].amount, debtors[di].amount)
            if let from = lookup[debtors[di].id], let to = lookup[creditors[ci].id] {
                settlements.append(Settlement(from: from, to: to, amount: roundToTwo(pay)))
            }
            creditors[ci].amount -= pay
            debtors[di].amount -= pay
            if creditors[ci].amount <= 0.005 { ci += 1 }
            if debtors[di].amount <= 0.005 { di += 1 }
        }
        return settlements
    }
}
