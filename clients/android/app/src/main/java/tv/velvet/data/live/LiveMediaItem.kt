package tv.velvet.data.live

import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.util.UnstableApi

/** Protected playback stays inside Android's MediaDrm; Velvet never receives content keys. */
@OptIn(UnstableApi::class)
fun LiveSession.mediaItem(): MediaItem = MediaItem.Builder()
    .setMediaId(id)
    .setUri(playbackUrl)
    .setMimeType(mimeType)
    .apply {
        drm?.let { widevine ->
            setDrmConfiguration(MediaItem.DrmConfiguration.Builder(C.WIDEVINE_UUID)
                .setLicenseUri(widevine.licenseUrl)
                .setForceDefaultLicenseUri(true)
                .setMultiSession(widevine.multiSession)
                .build())
        }
    }
    .build()
