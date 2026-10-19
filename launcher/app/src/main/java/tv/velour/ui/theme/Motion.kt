package tv.velour.ui.theme

import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.Easing
import androidx.compose.animation.core.SpringSpec
import androidx.compose.animation.core.spring

object VelourMotion {
    /** All focus transforms. */
    val Spotlight: Easing = CubicBezierEasing(0.2f, 0.9f, 0.25f, 1.0f)

    /** Scrolls and panels. */
    val Decelerate: Easing = CubicBezierEasing(0.05f, 0.7f, 0.1f, 1.0f)

    /** Wallpaper room-lean. */
    val Lean: Easing = CubicBezierEasing(0.33f, 0f, 0.1f, 1f)

    /** Reorder swaps only. */
    val ReorderSpring: SpringSpec<Float> = spring(dampingRatio = 0.78f, stiffness = 380f)

    const val FocusEnterMs = 260
    const val FocusExitMs = 200
    const val GlowIgniteMs = 220
    const val EmberDecayMs = 350
    const val SweepMs = 600
    const val SweepDelayMs = 80
    const val DimMs = 200
    const val LeanMs = 600
    const val RowScrollMs = 320
    const val SpineMs = 420
    const val ClockFlipMs = 300
    const val IrisMs = 250
    const val MenuDimMs = 180
    const val MenuRowMs = 150
    const val RelightMs = 150
}
