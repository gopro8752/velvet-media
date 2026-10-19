package tv.velvet.ui.theme

import androidx.compose.runtime.Composable
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.Typography
import androidx.tv.material3.darkColorScheme

private val VelvetColorScheme = darkColorScheme(
    primary = VelvetColors.Accent,
    onPrimary = VelvetColors.TextPrimary,
    secondary = VelvetColors.AccentDeep,
    background = VelvetColors.Background,
    onBackground = VelvetColors.TextPrimary,
    surface = VelvetColors.Surface,
    onSurface = VelvetColors.TextPrimary,
    surfaceVariant = VelvetColors.SurfaceElevated,
    onSurfaceVariant = VelvetColors.TextSecondary,
    border = VelvetColors.FocusRing,
)

private val VelvetTypography = Typography(
    displayLarge = TextStyle(fontFamily = VelvetFonts.Display, fontWeight = FontWeight.Bold, fontSize = 52.sp, lineHeight = 56.sp),
    displayMedium = TextStyle(fontFamily = VelvetFonts.Display, fontWeight = FontWeight.Bold, fontSize = 40.sp, lineHeight = 46.sp),
    displaySmall = TextStyle(fontFamily = VelvetFonts.Display, fontWeight = FontWeight.SemiBold, fontSize = 30.sp, lineHeight = 36.sp),
    headlineLarge = TextStyle(fontFamily = VelvetFonts.Display, fontWeight = FontWeight.SemiBold, fontSize = 26.sp, lineHeight = 32.sp),
    headlineMedium = TextStyle(fontFamily = VelvetFonts.Display, fontWeight = FontWeight.SemiBold, fontSize = 22.sp, lineHeight = 28.sp),
    headlineSmall = TextStyle(fontFamily = VelvetFonts.Display, fontWeight = FontWeight.Medium, fontSize = 18.sp, lineHeight = 24.sp),
    titleLarge = TextStyle(fontFamily = VelvetFonts.Display, fontWeight = FontWeight.SemiBold, fontSize = 20.sp, lineHeight = 26.sp),
    titleMedium = TextStyle(fontFamily = VelvetFonts.Body, fontWeight = FontWeight.SemiBold, fontSize = 16.sp, lineHeight = 22.sp),
    titleSmall = TextStyle(fontFamily = VelvetFonts.Body, fontWeight = FontWeight.Medium, fontSize = 14.sp, lineHeight = 20.sp),
    bodyLarge = TextStyle(fontFamily = VelvetFonts.Body, fontWeight = FontWeight.Normal, fontSize = 16.sp, lineHeight = 24.sp),
    bodyMedium = TextStyle(fontFamily = VelvetFonts.Body, fontWeight = FontWeight.Normal, fontSize = 14.sp, lineHeight = 20.sp),
    bodySmall = TextStyle(fontFamily = VelvetFonts.Body, fontWeight = FontWeight.Normal, fontSize = 12.sp, lineHeight = 16.sp),
    labelLarge = TextStyle(fontFamily = VelvetFonts.Body, fontWeight = FontWeight.SemiBold, fontSize = 14.sp, lineHeight = 18.sp),
    labelMedium = TextStyle(fontFamily = VelvetFonts.Body, fontWeight = FontWeight.Medium, fontSize = 12.sp, lineHeight = 16.sp),
    labelSmall = TextStyle(fontFamily = VelvetFonts.Body, fontWeight = FontWeight.Medium, fontSize = 11.sp, lineHeight = 14.sp),
)

@Composable
fun VelvetTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = VelvetColorScheme,
        typography = VelvetTypography,
        content = content,
    )
}
