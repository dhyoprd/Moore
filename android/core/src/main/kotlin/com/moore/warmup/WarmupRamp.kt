// contractId: SC-warmup @1.0.0
// Warm-up ramp derivation — #16 §2 as a pure, port-fixed-point function (BR-001..BR-007).
// Mechanical Kotlin port of Sources/MooreWarmup/WarmupRamp.swift; must match
// outputs byte-for-byte across platforms.
package com.moore.warmup

import kotlin.math.min

/// One derived warm-up row (absolute values, post-nearestDown).
data class WarmupRow(
    var weight: Double,
    var reps: Int,
)

object WarmupRamp {

    /// BR-003/BR-004/BR-005 rung tables. Rung 1 (bar×10) is unconditional when the
    /// gate passes; the percentage rungs follow the two-/three-rung tables.
    private val twoRungPath: List<Pair<Double, Int>> = listOf(0.50 to 5, 0.75 to 3)
    private val threeRungPath: List<Pair<Double, Int>> = listOf(0.40 to 5, 0.65 to 3, 0.85 to 2)

    /// Reference per-side plate inventory (kg), one entry per single plate of each
    /// denomination (a pair contributes plate * 2 toward the bar load).
    val defaultPlateInventoryKg: List<Double> = listOf(25.0, 20.0, 15.0, 10.0, 5.0, 2.5, 1.25)

    /// Reference per-side plate inventory (lb).
    val defaultPlateInventoryLb: List<Double> = listOf(45.0, 35.0, 25.0, 10.0, 5.0, 2.5)

    // MARK: - nearestDown (SC-plate-calculator BR-003 mirror)

    /// Largest load ≤ target achievable as barWeight + 2·(subset sum of
    /// plateInventory); null when nothing below the bar itself is loadable.
    /// Greedy descent in used-plate space preserves the optimal ≤-target subset.
    fun nearestDown(
        target: Double,
        barWeight: Double,
        plateInventory: List<Double>,
    ): Double? {
        val inventory = plateInventory.filter { it > 0 }.sortedDescending()
        if (inventory.isEmpty()) {
            return if (target >= barWeight) barWeight else null
        }
        if (target < barWeight) return null
        // Per-side needed; greedy take in pairs (plates load symmetrically).
        val used = greedyPerSide((target - barWeight) / 2, inventory)
            ?: return if (target >= barWeight) barWeight else null
        var weight = barWeight + 2 * used.sum()
        while (weight > target + 1e-9) {
            val smallest = used.minOrNull() ?: break
            val idx = used.lastIndexOf(smallest)
            if (idx < 0) break
            used.removeAt(idx)   // removal always drops weight — a new best below target
            weight = barWeight + 2 * used.sum()
        }
        return weight
    }

    /// Per-side greedy fill; null when no plate combination (not even empty) applies.
    private fun greedyPerSide(perSide: Double, inventory: List<Double>): MutableList<Double>? {
        if (perSide < -1e-9) return null
        var remaining = perSide
        val used = mutableListOf<Double>()
        for (plate in inventory) {
            while (remaining >= plate - 1e-9) {
                used.add(plate)
                remaining -= plate
            }
        }
        return used
    }

    // MARK: - Ramp derivation (BR-001..BR-007)

    /// #16 §2 table. Returns [] exactly when the BR-002 gate fails
    /// (W null, or W ≤ bar — the reps-metric and warmupEnabled checks happen
    /// upstream in WarmupMaterialize, which owns session shape).
    fun derive(
        workingWeight: Double?,
        barWeight: Double,
        plateInventory: List<Double>,
    ): List<WarmupRow> {
        val w = workingWeight
        if (w == null || w <= barWeight) return emptyList()

        // BR-003: rung 1 is always the empty bar.
        val rows = mutableListOf(WarmupRow(barWeight, 10))

        val heavy = w >= 5 * barWeight
        val path = if (heavy) threeRungPath else twoRungPath

        val kept = mutableListOf<WarmupRow>()
        for ((i, rung) in path.withIndex()) {
            val target = rung.first * w
            val rounded = nearestDown(target, barWeight, plateInventory)
            // BR-007.1: nothing loadable at/above the bar (null when target < bar)
            // or a rung that rounds down to the bar itself — both are "dropped".
            if (rounded == null || rounded <= barWeight) {
                // BR-007.2: two-rung collapse — the first percentage rung at/below
                // bar kills every percentage rung; bar×10 alone remains.
                if (!heavy && i == 0) return rows
                continue
            }
            // BR-007.3: strictly increasing by rounded weight.
            val last = kept.lastOrNull()
            if (last != null && rounded <= last.weight) continue
            kept.add(WarmupRow(rounded, rung.second))
        }
        rows.addAll(kept)
        return rows
    }
}
