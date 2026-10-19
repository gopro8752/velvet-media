package tv.velvet.ui.profile

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.tv.material3.Text
import tv.velvet.data.local.ProfileEntity
import tv.velvet.ui.theme.VelvetColors
import tv.velvet.ui.theme.VelvetFonts
import java.util.Locale

/**
 * Velvet profile avatar — a rounded square filled with the profile's color, with the
 * name's first initial in TextPrimary (DESIGN.md/spec: rounded square on Android, no
 * image upload in v1). Shared by the picker grid and the Home top-bar.
 */
@Composable
fun ProfileAvatar(
    profile: ProfileEntity,
    size: Dp,
    modifier: Modifier = Modifier,
) {
    val color = remember(profile.color) { parseHexColor(profile.color) }
    val initial = remember(profile.name) {
        profile.name.trim().firstOrNull()?.uppercaseChar()?.toString() ?: "?"
    }
    Box(
        modifier = modifier
            .size(size)
            .clip(RoundedCornerShape(size * 0.22f))
            .background(color),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = initial,
            fontFamily = VelvetFonts.Display,
            fontWeight = FontWeight.SemiBold,
            // ~44% of the tile reads well across 36dp top-bar and 116dp picker sizes.
            fontSize = (size.value * 0.44f).sp,
            color = VelvetColors.TextPrimary,
        )
    }
}

/** "#8B7CF6" → Color; falls back to the accent violet on a malformed/blank hex. */
fun parseHexColor(hex: String): Color = runCatching {
    val cleaned = hex.trim().removePrefix("#")
    val value = cleaned.toLong(16)
    when (cleaned.length) {
        6 -> Color(0xFF000000L or value)   // pad opaque alpha
        8 -> Color(value)
        else -> VelvetColors.Accent
    }
}.getOrDefault(VelvetColors.Accent)
