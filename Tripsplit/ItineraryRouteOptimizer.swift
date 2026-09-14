import Foundation
import CoreLocation

/// Optimizes geographic distance without moving bookings or jumping over missing pins.
/// Keeps the original path whenever a heuristic would make it longer.
nonisolated enum ItineraryRouteOptimizer {
    static func applying(_ ids: [UUID], to stops: [ItineraryStop]) -> [ItineraryStop] {
        guard ids.count == stops.count, Set(ids).count == ids.count,
              Set(ids) == Set(stops.map(\.id)) else { return stops }
        let byID = Dictionary(uniqueKeysWithValues: stops.map { ($0.id, $0) })
        return ids.compactMap { byID[$0] }
    }

    static func optimize(_ stops: [ItineraryStop]) -> [ItineraryStop] {
        guard stops.count > 3 else { return stops }
        var result = stops
        let locked = stops.indices.filter {
            $0 == 0 || $0 == stops.count - 1 || stops[$0].time != nil || stops[$0].coordinate == nil
        }
        for (left, right) in zip(locked, locked.dropFirst()) where right - left > 2 {
            // Missing anchors divide the day; never invent a connection through them.
            guard stops[left].coordinate != nil, stops[right].coordinate != nil else { continue }
            let original = Array(stops[left...right])
            var remaining = Array(original.dropFirst().dropLast())
            var greedy = [original[0]]
            while !remaining.isEmpty {
                let last = greedy.last!
                let next = remaining.indices.min {
                    distance(last, remaining[$0]) < distance(last, remaining[$1])
                }!
                greedy.append(remaining.remove(at: next))
            }
            greedy.append(original.last!)
            // Improve both seeds; nearest-neighbor alone can strand a distant stop.
            let candidates = [twoOpt(original), twoOpt(greedy)]
            let best = candidates.min { length($0) < length($1) }!
            if length(best) + 0.01 < length(original) {
                result.replaceSubrange(left...right, with: best)
            }
        }
        return result
    }

    static func length(_ stops: [ItineraryStop]) -> Double {
        zip(stops, stops.dropFirst()).reduce(0) { $0 + distance($1.0, $1.1) }
    }

    private static func distance(_ a: ItineraryStop, _ b: ItineraryStop) -> Double {
        guard let a = a.coordinate, let b = b.coordinate else { return 0 }
        return CLLocation(latitude: a.latitude, longitude: a.longitude).distance(
            from: CLLocation(latitude: b.latitude, longitude: b.longitude)
        )
    }

    private static func twoOpt(_ stops: [ItineraryStop]) -> [ItineraryStop] {
        guard stops.count > 3 else { return stops }
        var best = stops
        // Bounded work even for unusually large imported days.
        for _ in 0..<min(stops.count, 50) {
            var improved = false
            for i in 1..<(best.count - 2) {
                for j in (i + 1)..<(best.count - 1) {
                    let old = distance(best[i - 1], best[i]) + distance(best[j], best[j + 1])
                    let new = distance(best[i - 1], best[j]) + distance(best[i], best[j + 1])
                    if new + 0.01 < old {
                        best.replaceSubrange(i...j, with: Array(best[i...j].reversed()))
                        improved = true
                    }
                }
            }
            if !improved { break }
        }
        return best
    }
}
