// SC-cues@1.0.0 haptic delivery seam (#31 / #29 port).
// Apple Taptic patterns → HapticFeedbackConstants mapping (ticket #31):
//   success     → CONFIRM
//   nudge       → CLOCK_TICK
//   alert       → LONG_PRESS
//   celebration → CONTEXT_CLICK × 3 sequence
// API 31+ carries the standard constants; older APIs degrade gracefully
// (performHapticFeedback is a no-op for unknown constants).
package com.moore.app.haptics

import android.os.Build
import android.view.HapticFeedbackConstants
import android.view.View
import com.moore.cues.HapticClass

object MooreHaptics {

    /// Map one #10 haptic class onto the platform constant(s).
    fun constantsFor(hapticClass: HapticClass): IntArray = when (hapticClass) {
        HapticClass.SUCCESS -> intArray(HapticFeedbackConstants.CONFIRM)
        HapticClass.NUDGE -> intArray(HapticFeedbackConstants.CLOCK_TICK)
        HapticClass.ALERT -> intArray(HapticFeedbackConstants.LONG_PRESS)
        HapticClass.CELEBRATION -> intArrayOf(
            HapticFeedbackConstants.CONTEXT_CLICK,
            HapticFeedbackConstants.CONTEXT_CLICK,
            HapticFeedbackConstants.CONTEXT_CLICK,
        )
    }

    /// Perform the class on a view host. nil haptic (BR-002) performs nothing.
    fun perform(host: View, hapticClass: HapticClass?) {
        if (hapticClass == null) return
        val constants = constantsFor(hapticClass)
        for ((index, constant) in constants.withIndex()) {
            if (index > 0) {
                // Distinct multi-stage pattern: space the celebration ticks.
                host.postDelayed({ performSafely(host, constant) }, 90L * index)
            } else {
                performSafely(host, constant)
            }
        }
    }

    private fun performSafely(host: View, constant: Int) {
        try {
            host.performHapticFeedback(constant)
        } catch (_: Throwable) {
            // Graceful no-op on devices/versions without the constant.
        }
    }

    private fun intArray(value: Int): IntArray = intArrayOf(value)

    /// True when the device runs API 31+ (the standard-constants floor).
    val standardConstantsAvailable: Boolean
        get() = Build.VERSION.SDK_INT >= 31
}
