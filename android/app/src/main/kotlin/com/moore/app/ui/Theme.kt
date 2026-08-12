// Material You theme with the #17 steel surface rule + lime accent (#31 AC:
// lime.vivid #D4FF3F on opaque steel; rim-light gradients substituted with
// Material top-edge shadows + tint; opaque money screen kept as SurfaceVariant).
package com.moore.app.ui

import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.Surface
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp

/// Opaque steel surface (Material top-edge shadow + tint stands in for the iOS
/// rim-light gradient per #8's seam note).
val Steel = Color(0xFF1C1B1F)
val SteelVariant = Color(0xFF2A292E)   // money-screen SurfaceVariant (opaque, #17)
val LimeVivid = Color(0xFFD4FF3F)       // lime.vivid — accent only, ink foreground on it
val LimeInk = Color(0xFF0B0B0C)         // foreground-only on elevated lime surfaces

private val MooreColors = darkColorScheme(
    primary = LimeVivid,
    onPrimary = LimeInk,
    secondary = LimeVivid,
    onSecondary = LimeInk,
    tertiary = LimeVivid,
    background = Steel,
    onBackground = Color(0xFFE6E1E5),
    surface = Steel,
    onSurface = Color(0xFFE6E1E5),
    surfaceVariant = SteelVariant,
    onSurfaceVariant = Color(0xFFCAC4D0),
)

private val MooreShapes = Shapes(
    small = RoundedCornerShape(8.dp),
    medium = RoundedCornerShape(12.dp),
    large = RoundedCornerShape(16.dp),
)

@Composable
fun MooreTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = MooreColors,
        shapes = MooreShapes,
        content = content,
    )
}

@Composable
fun MooreSurface(content: @Composable () -> Unit) {
    Surface(color = MaterialTheme.colorScheme.background, content = content)
}
