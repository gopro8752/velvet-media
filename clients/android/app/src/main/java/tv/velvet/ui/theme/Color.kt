package tv.velvet.ui.theme

import androidx.compose.ui.graphics.Color

/**
 * Velvet palette — dark cinematic. Near-black blue base, white-glow focus,
 * iris-violet accent, gold for ratings, green for match/progress.
 */
object VelvetColors {
    val Background = Color(0xFF0A0C12)
    val Surface = Color(0xFF11141C)
    val SurfaceElevated = Color(0xFF181C26)
    val SurfaceHighlight = Color(0xFF222736)

    val TextPrimary = Color(0xFFF2F4F8)
    val TextSecondary = Color(0xFF9BA3B4)
    val TextTertiary = Color(0xFF5F6878)

    val Accent = Color(0xFF8B7CF6)          // iris violet
    val AccentDeep = Color(0xFF5B47D6)
    val Gold = Color(0xFFF5C76B)            // ratings
    val Match = Color(0xFF46D369)           // match %, progress bars
    val Danger = Color(0xFFE0506A)

    val FocusRing = Color(0xFFFFFFFF)       // white focus glow (Apple TV style)
    val Scrim = Color(0xCC0A0C12)
    val CardPlaceholder = Color(0xFF161A24)
}
