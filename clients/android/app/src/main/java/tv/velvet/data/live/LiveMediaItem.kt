package tv.velvet.data.live

import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.UnstableApi

/** Protected playback stays inside Android's MediaDrm; Velvet never receives content keys. */
@OptIn(UnstableApi::class)
fun LiveSession.mediaItem(): MediaItem = MediaItem.Builder()
    .setMediaId(id)
    .setUri(playbackUrl)
    .setMimeType(mimeType)
    .apply {
        if (drm != null && mimeType == MimeTypes.APPLICATION_MPD) {
            // Native broadcasts can expose only ~36 seconds of history. DASH's
            // 30-second fallback starts too close to the expiring edge of that
            // window. Keep enough headroom for brief stalls; Media3 still
            // derives and enforces the allowed offsets from the live manifest.
            setLiveConfiguration(nativeDashLiveConfiguration())
        }
        drm?.let { widevine ->
            setDrmConfiguration(MediaItem.DrmConfiguration.Builder(C.WIDEVINE_UUID)
                .setLicenseUri(widevine.licenseUrl)
                .setForceDefaultLicenseUri(true)
                .setMultiSession(widevine.multiSession)
                .build())
        }
    }
    .build()

internal fun nativeDashLiveConfiguration(): MediaItem.LiveConfiguration =
    MediaItem.LiveConfiguration.Builder().setTargetOffsetMs(10_000).build()
