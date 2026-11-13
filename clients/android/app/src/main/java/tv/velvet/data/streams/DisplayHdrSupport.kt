package tv.velvet.data.streams

import android.content.Context
import android.hardware.display.DisplayManager
import android.os.Build
import android.view.Display

/** Read anew before selection: HDMI/display settings may change while Velvet is open. */
class DisplayHdrSupport(context: Context) {
    private val displays = context.getSystemService(DisplayManager::class.java)

    @Suppress("DEPRECATION")
    fun current(): DisplayHdrPolicy {
        val types = runCatching {
            val display = displays?.getDisplay(Display.DEFAULT_DISPLAY) ?: return@runCatching emptySet<Int>()
            // Mode-specific reporting supersedes HdrCapabilities on Android 14+.
            if (Build.VERSION.SDK_INT >= 34) display.mode.supportedHdrTypes.toSet()
            else display.hdrCapabilities?.supportedHdrTypes?.toSet().orEmpty()
        }.getOrDefault(emptySet())
        return DisplayHdrPolicy(
            dolbyVision = Display.HdrCapabilities.HDR_TYPE_DOLBY_VISION in types,
            hdr10 = Display.HdrCapabilities.HDR_TYPE_HDR10 in types,
            hdr10Plus = Display.HdrCapabilities.HDR_TYPE_HDR10_PLUS in types,
            hlg = Display.HdrCapabilities.HDR_TYPE_HLG in types,
        )
    }
}
