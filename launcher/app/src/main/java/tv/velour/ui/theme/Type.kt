@file:OptIn(ExperimentalTextApi::class)

package tv.velour.ui.theme

import androidx.compose.ui.text.ExperimentalTextApi
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontVariation
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp
import tv.velour.R

// Variable fonts: one FontFamily per weight, pinned via FontVariation.weight(N).
private val Outfit200 = FontFamily(
    Font(
        R.font.outfit_variable,
        weight = FontWeight(200),
        variationSettings = FontVariation.Settings(FontVariation.weight(200)),
    )
)
private val Outfit300 = FontFamily(
    Font(
        R.font.outfit_variable,
        weight = FontWeight(300),
        variationSettings = FontVariation.Settings(FontVariation.weight(300)),
    )
)
private val Inter400 = FontFamily(
    Font(
        R.font.inter_variable,
        weight = FontWeight(400),
        variationSettings = FontVariation.Settings(FontVariation.weight(400)),
    )
)
private val Inter500 = FontFamily(
    Font(
        R.font.inter_variable,
        weight = FontWeight(500),
        variationSettings = FontVariation.Settings(FontVariation.weight(500)),
    )
)
private val Inter600 = FontFamily(
    Font(
        R.font.inter_variable,
        weight = FontWeight(600),
        variationSettings = FontVariation.Settings(FontVariation.weight(600)),
    )
)
private val SpaceGrotesk500 = FontFamily(
    Font(
        R.font.space_grotesk_variable,
        weight = FontWeight(500),
        variationSettings = FontVariation.Settings(FontVariation.weight(500)),
    )
)

object VelourType {
    /** Space Grotesk 500, 13sp, +0.18em tracking. ALL CAPS is applied at call sites. */
    val eyebrow = TextStyle(
        fontFamily = SpaceGrotesk500,
        fontWeight = FontWeight(500),
        fontSize = 13.sp,
        letterSpacing = 0.18.em,
    )

    /** Outfit 200, 84sp, +0.01em, tabular digits for per-digit flips. */
    val clockHero = TextStyle(
        fontFamily = Outfit200,
        fontWeight = FontWeight(200),
        fontSize = 84.sp,
        letterSpacing = 0.01.em,
        fontFeatureSettings = "tnum",
    )

    /** Outfit 300, 24sp, tabular digits. */
    val clockMini = TextStyle(
        fontFamily = Outfit300,
        fontWeight = FontWeight(300),
        fontSize = 24.sp,
        fontFeatureSettings = "tnum",
    )

    /** Inter 400, 16sp. */
    val body = TextStyle(
        fontFamily = Inter400,
        fontWeight = FontWeight(400),
        fontSize = 16.sp,
    )

    /** Inter 400, 18sp — date + weather line. */
    val dateLine = TextStyle(
        fontFamily = Inter400,
        fontWeight = FontWeight(400),
        fontSize = 18.sp,
    )

    /** Inter 500, 18sp — long-press menu rows, settings rows. */
    val menuRow = TextStyle(
        fontFamily = Inter500,
        fontWeight = FontWeight(500),
        fontSize = 18.sp,
    )

    /** Inter 500, 22sp — settings nav column. */
    val settingsNav = TextStyle(
        fontFamily = Inter500,
        fontWeight = FontWeight(500),
        fontSize = 22.sp,
    )

    /** Inter 600, 16sp — focused card title under favorites. */
    val cardTitle = TextStyle(
        fontFamily = Inter600,
        fontWeight = FontWeight(600),
        fontSize = 16.sp,
    )

    /** Inter 600, 18sp — playbill card names at favorites size. */
    val playbillName = TextStyle(
        fontFamily = Inter600,
        fontWeight = FontWeight(600),
        fontSize = 18.sp,
    )

    /** Inter 600, 14sp — playbill card names at library tile size. */
    val playbillNameSmall = TextStyle(
        fontFamily = Inter600,
        fontWeight = FontWeight(600),
        fontSize = 14.sp,
    )
}
