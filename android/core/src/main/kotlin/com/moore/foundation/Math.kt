// Closed-form rounding parity helpers (ticket #31).
// Swift `.rounded(.toNearestOrAwayFromZero)` / `.rounded(.awayFromZero)` round
// half cases AWAY from zero; kotlin.math.round rounds ties toward zero. These
// helpers keep the ported engines byte-identical with the Swift originals.
package com.moore.foundation

import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.floor

/// Nearest integer, half cases away from zero (Swift toNearestOrAwayFromZero).
fun roundAwayFromZero(x: Double): Double {
    val sign = if (x < 0) -1.0 else 1.0
    return sign * floor(abs(x) + 0.5)
}
