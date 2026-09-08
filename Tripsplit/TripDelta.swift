import Foundation

/// Wire payload for sync_trip_delta_v1. Missing metadata means unchanged; missing
/// child IDs never imply deletion. Only explicit tombstones remove server records.
nonisolated struct TripDelta: Encodable {
    let metadata: Trip?
    let expenses: [Expense]
    let removedExpenses: [UUID]
    let settlements: [String: [SettlementRecord]]
    let removedSettlements: [UUID]
    let comments: [String: [ExpenseComment]]
    let removedComments: [UUID]

    var isEmpty: Bool {
        metadata == nil && expenses.isEmpty && removedExpenses.isEmpty
            && settlements.isEmpty && removedSettlements.isEmpty
            && comments.isEmpty && removedComments.isEmpty
    }

    init(current: Trip, previous: Trip?) {
        func metadataOnly(_ trip: Trip) -> Trip {
            var result = trip
            result.expenses = []
            result.deletedExpenses = []
            result.settlementRecords = [:]
            result.comments = [:]
            return result
        }
        let currentMetadata = metadataOnly(current)
        if let previous,
           currentMetadata == metadataOnly(previous) {
            metadata = nil
        } else { metadata = currentMetadata }

        let currentExpenses = current.expenses + current.deletedExpenses
        let oldExpenses = (previous?.expenses ?? []) + (previous?.deletedExpenses ?? [])
        let oldByID = Dictionary(oldExpenses.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        expenses = currentExpenses.filter { oldByID[$0.id] != $0 }
        removedExpenses = Array(Set(oldExpenses.map(\.id)).subtracting(currentExpenses.map(\.id)))

        func groupedDelta<T: Identifiable & Equatable>(
            _ current: [String: [T]], _ previous: [String: [T]]
        ) -> (changed: [String: [T]], removed: [UUID]) where T.ID == UUID {
            var changed: [String: [T]] = [:]
            for (key, records) in current {
                let old = Dictionary((previous[key] ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                let delta = records.filter { old[$0.id] != $0 }
                if !delta.isEmpty { changed[key] = delta }
            }
            let currentIDs = Set(current.values.flatMap { $0.map(\.id) })
            let removed = Set(previous.values.flatMap { $0.map(\.id) }).subtracting(currentIDs)
            return (changed, Array(removed))
        }
        (settlements, removedSettlements) = groupedDelta(current.settlementRecords, previous?.settlementRecords ?? [:])
        (comments, removedComments) = groupedDelta(current.comments, previous?.comments ?? [:])
    }
}
