// contractId: SC-warmup @1.0.0
// Warm-up ramp derivation — #16 §2 as a pure, port-fixed-point function (BR-001..BR-007).
// No GRDB, no Apple frameworks beyond Foundation: the Android port (#31) mirrors this
// file's math and must match outputs byte-for-byte.
//
// NOTE on nearestDown: SC-plate-calculator's code lands in the integration layer;
// the BR-003 greedy walk is duplicated here intentionally so MooreWarmup has no
// module dependency (SC-warmup §4). The algorithm below IS the BR-003 contract.

import Foundation

/// One derived warm-up row (absolute values, post-nearestDown).
public struct WarmupRow: Equatable, Codable, Sendable {
    public var weight: Double
    public var reps: Int

    public init(weight: Double, reps: Int) {
        self.weight = weight
        self.reps = reps
    }
}

public enum WarmupRamp {

    /// BR-003/BR-004/BR-005 rung tables. Rung 1 (bar×10) is unconditional when the
    /// gate passes; the percentage rungs follow the two-/three-rung tables.
    private static let twoRungPath: [(pct: Double, reps: Int)] = [(0.50, 5), (0.75, 3)]
    private static let threeRungPath: [(pct: Double, reps: Int)] = [(0.40, 5), (0.65, 3), (0.85, 2)]

    /// Reference per-side plate inventory (kg), one entry per single plate of each
    /// denomination (a pair contributes `plate * 2` toward the bar load). Warm-up
    /// derivation only ever needs the denominations, not the user's counts.
    public static let defaultPlateInventoryKg: [Double] = [25, 20, 15, 10, 5, 2.5, 1.25]

    /// Reference per-side plate inventory (lb).
    public static let defaultPlateInventoryLb: [Double] = [45, 35, 25, 10, 5, 2.5]

    // MARK: - nearestDown (SC-plate-calculator BR-003 mirror)

    /// Largest load ≤ `target` achievable as `barWeight + 2·(subset sum of
    /// plateInventory)`; nil when nothing below the bar itself is loadable.
    /// Greedy descent in used-plate space preserves the optimal ≤-target subset:
    /// every denomination of the canonical inventories divides the next, so a
    /// greedy take-largest-first walk from the target's used list can only shed
    /// load, never strand a better combination above.
    public static func nearestDown(
        _ target: Double,
        barWeight: Double,
        plateInventory: [Double]
    ) -> Double? {
        let inventory = plateInventory.filter { $0 > 0 }.sorted(by: >)
        guard !inventory.isEmpty else {
            return target >= barWeight ? barWeight : nil
        }
        if target < barWeight { return nil }
        // Per-side needed; greedy take in pairs (plates load symmetrically).
        guard var used = greedyPerSide((target - barWeight) / 2, inventory: inventory) else {
            return target >= barWeight ? barWeight : nil
        }
        var weight = barWeight + 2 * used.reduce(0, +)
        while weight > target + 1e-9 {
            guard let smallest = used.min(), let idx = used.lastIndex(of: smallest) else { break }
            used.remove(at: idx)   // removal always drops weight — a new best below target
            weight = barWeight + 2 * used.reduce(0, +)
        }
        return weight
    }

    /// Per-side greedy fill; nil when no plate combination (not even empty) applies.
    private static func greedyPerSide(_ perSide: Double, inventory: [Double]) -> [Double]? {
        guard perSide >= -1e-9 else { return nil }
        var remaining = perSide
        var used: [Double] = []
        for plate in inventory {
            while remaining >= plate - 1e-9 {
                used.append(plate)
                remaining -= plate
            }
        }
        return used
    }

    // MARK: - Ramp derivation (BR-001..BR-007)

    /// #16 §2 table. Returns [] exactly when the BR-002 gate fails
    /// (W nil, or W ≤ bar — the reps-metric and warmupEnabled checks happen
    /// upstream in `WarmupMaterialize`, which owns session shape).
    public static func derive(
        workingWeight: Double?,
        barWeight: Double,
        plateInventory: [Double]
    ) -> [WarmupRow] {
        guard let w = workingWeight, w > barWeight else { return [] }

        // BR-003: rung 1 is always the empty bar.
        var rows = [WarmupRow(weight: barWeight, reps: 10)]

        let heavy = w >= 5 * barWeight
        let path = heavy ? threeRungPath : twoRungPath

        var kept: [WarmupRow] = []
        for (i, rung) in path.enumerated() {
            let target = rung.pct * w
            let rounded = nearestDown(target, barWeight: barWeight, plateInventory: plateInventory)
            // BR-007.1: nothing loadable at/above the bar (nil when target < bar)
            // or a rung that rounds down to the bar itself — both are "dropped".
            if rounded == nil || rounded! <= barWeight {
                // BR-007.2: two-rung collapse — the first percentage rung at/below
                // bar (rounding and unreachability are equivalent here) kills every
                // percentage rung; bar×10 alone remains. (#16: "W = 25: 50% = 12.5
                // ≤ bar → collapse → 20×10 only.")
                if !heavy && i == 0 { return rows }
                continue
            }
            // BR-007.3: strictly increasing by rounded weight.
            if let last = kept.last, rounded! <= last.weight { continue }
            kept.append(WarmupRow(weight: rounded!, reps: rung.reps))
        }
        rows.append(contentsOf: kept)
        return rows
    }
}
