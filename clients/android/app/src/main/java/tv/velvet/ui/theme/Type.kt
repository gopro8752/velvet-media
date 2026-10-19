@file:OptIn(androidx.compose.ui.text.ExperimentalTextApi::class)

package tv.velvet.ui.theme

import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.font.FontVariation
import tv.velvet.R

/**
 * Outfit (variable) for display/titles, Inter (variable) for body/meta.
 * Use [Display] for hero titles, section headers, buttons.
 * Use [Body] for overviews, card titles, metadata lines.
 */
object VelvetFonts {
    val Display = FontFamily(
        Font(R.font.outfit, weight = FontWeight.Normal, variationSettings = FontVariation.Settings(FontVariation.weight(400))),
        Font(R.font.outfit, weight = FontWeight.Medium, variationSettings = FontVariation.Settings(FontVariation.weight(500))),
        Font(R.font.outfit, weight = FontWeight.SemiBold, variationSettings = FontVariation.Settings(FontVariation.weight(600))),
        Font(R.font.outfit, weight = FontWeight.Bold, variationSettings = FontVariation.Settings(FontVariation.weight(700))),
    )
    val Body = FontFamily(
        Font(R.font.inter, weight = FontWeight.Normal, variationSettings = FontVariation.Settings(FontVariation.weight(400))),
        Font(R.font.inter, weight = FontWeight.Medium, variationSettings = FontVariation.Settings(FontVariation.weight(500))),
        Font(R.font.inter, weight = FontWeight.SemiBold, variationSettings = FontVariation.Settings(FontVariation.weight(600))),
    )
}
