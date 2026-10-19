package tv.velour.ui.theme

import androidx.compose.ui.graphics.Color
import tv.velour.core.AccentChoice

object VelourColors {
    val Void = Color(0xFF060709)
    val Surface = Color(0xFF101216)
    val SurfaceRaised = Color(0xFF181B21)
    val InkPrimary = Color(0xFFF4F1EA)
    val InkSecondary = Color(0xFFA8ADB8)
    val InkTertiary = Color(0xFF5C616C)
    val Danger = Color(0xFFE5484D)

    fun accent(choice: AccentChoice): Color = when (choice) {
        AccentChoice.TUNGSTEN -> Color(0xFFF2A93B)
        AccentChoice.ION -> Color(0xFF4FD8DB)
        AccentChoice.SIGNAL -> Color(0xFFE03131)
        AccentChoice.BIAS -> Color(0xFF9D7BFF)
    }

    fun accentDeep(choice: AccentChoice): Color = when (choice) {
        AccentChoice.TUNGSTEN -> Color(0xFF3A2810)
        AccentChoice.ION -> Color(0xFF103638)
        AccentChoice.SIGNAL -> Color(0xFF3A0F10)
        AccentChoice.BIAS -> Color(0xFF251A47)
    }
}
