package tv.velour.ui.home

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.LruCache
import androidx.compose.runtime.Composable
import androidx.compose.runtime.RememberObserver
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import okhttp3.Cache
import okhttp3.Call
import okhttp3.Callback
import okhttp3.Dispatcher
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import tv.velour.R
import java.io.ByteArrayOutputStream
import java.io.Closeable
import java.io.File
import java.io.IOException
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.coroutines.resume
import kotlin.math.max
import kotlin.math.roundToInt

private const val MAX_ART_BYTES = 8 * 1024 * 1024
private const val BITMAP_CACHE_BYTES = 32 * 1024 * 1024

/**
 * Bounded artwork decoding. Requests are cancelled with their producer, including
 * during the body read, so fast remote navigation cannot fill the queue with old
 * artwork. Bitmap decoding and blur run off-main and never run during drawing.
 */
internal class HomeArtwork(context: Context) : Closeable {
    private val context = context.applicationContext
    private val closed = AtomicBoolean(false)
    private val client = OkHttpClient.Builder()
        .dispatcher(Dispatcher().apply { maxRequests = 3; maxRequestsPerHost = 3 })
        .cache(Cache(File(context.cacheDir, "launcher-art"), 32L * 1024 * 1024))
        .connectTimeout(6, TimeUnit.SECONDS).readTimeout(10, TimeUnit.SECONDS)
        .callTimeout(14, TimeUnit.SECONDS).build()
    private val permits = Semaphore(3)
    private val cache = object : LruCache<String, ImageBitmap>(BITMAP_CACHE_BYTES) {
        override fun sizeOf(key: String, value: ImageBitmap) = value.width * value.height * 4
    }

    suspend fun image(url: String?, maxSize: Int = 960, wallpaperResource: Int = R.drawable.velour_nocturne): ImageBitmap? = withContext(Dispatchers.IO) {
        ensureOpen()
        val edge = maxSize.coerceIn(64, 2048)
        val normalizedUrl = url?.takeUnless(String::isBlank)
        val key = "${normalizedUrl ?: "wallpaper:$wallpaperResource"}:$edge"
        cache.get(key)?.let { return@withContext it }
        permits.withPermit {
            currentCoroutineContext().ensureActive()
            ensureOpen()
            cache.get(key)?.let { return@withPermit it }
            val bitmap = try {
                if (normalizedUrl == null) {
                    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true; inScaled = false }
                    BitmapFactory.decodeResource(context.resources, wallpaperResource, bounds)
                    val options = decodeOptions(bounds, edge) ?: return@withPermit null
                    BitmapFactory.decodeResource(context.resources, wallpaperResource, options)
                } else {
                    val request = Request.Builder().url(normalizedUrl).build()
                    if (request.url.scheme != "http" && request.url.scheme != "https") return@withPermit null
                    val bytes = client.newCall(request).readArtwork() ?: return@withPermit null
                    currentCoroutineContext().ensureActive()
                    ensureOpen()
                    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                    BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
                    val options = decodeOptions(bounds, edge) ?: return@withPermit null
                    BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                null
            } ?: return@withPermit null
            try {
                currentCoroutineContext().ensureActive()
                ensureOpen()
            } catch (cancelled: CancellationException) {
                bitmap.recycle()
                throw cancelled
            }
            bitmap.asImageBitmap().also { cache.put(key, it) }
        }
    }

    private fun decodeOptions(bounds: BitmapFactory.Options, edge: Int): BitmapFactory.Options? {
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        var sample = 1
        // Power-of-two native sampling gives a hard decoded edge/pixel bound,
        // including very large images whose compressed body is deceptively small.
        while ((max(bounds.outWidth, bounds.outHeight).toLong() + sample - 1) / sample > edge) sample *= 2
        return BitmapFactory.Options().apply {
            inSampleSize = sample
            inScaled = false
            inPreferredConfig = Bitmap.Config.ARGB_8888
        }
    }

    private suspend fun Call.readArtwork(): ByteArray? = suspendCancellableCoroutine { continuation ->
        continuation.invokeOnCancellation { cancel() }
        enqueue(object : Callback {
            override fun onFailure(call: Call, error: IOException) {
                if (continuation.isActive) continuation.resume(null)
            }

            override fun onResponse(call: Call, response: Response) {
                val bytes = try {
                    response.use { current ->
                        if (!current.isSuccessful || !continuation.isActive) return@use null
                        val body = current.body ?: return@use null
                        if (body.contentLength() > MAX_ART_BYTES) return@use null
                        val out = ByteArrayOutputStream(32 * 1024)
                        val buffer = ByteArray(8192)
                        val stream = body.byteStream()
                        while (continuation.isActive) {
                            val read = stream.read(buffer)
                            if (read < 0) return@use out.toByteArray()
                            if (out.size() + read > MAX_ART_BYTES) return@use null
                            out.write(buffer, 0, read)
                        }
                        null
                    }
                } catch (_: Exception) {
                    null
                }
                if (continuation.isActive) continuation.resume(bytes)
            }
        })
    }

    suspend fun softened(source: ImageBitmap): ImageBitmap = withContext(Dispatchers.Default) {
        val jobContext = currentCoroutineContext()
        jobContext.ensureActive()
        ensureOpen()
        // Both axes are bounded. A portrait/poster response must not inflate the
        // glass blur into a tall unbounded texture.
        val scale = 240f / max(source.width, source.height)
        val width = (source.width * scale).roundToInt().coerceIn(1, 240)
        val height = (source.height * scale).roundToInt().coerceIn(1, 240)
        val original = source.asAndroidBitmap()
        val scaled = Bitmap.createScaledBitmap(original, width, height, true)
        val bitmap = scaled.copy(Bitmap.Config.ARGB_8888, true)
        if (scaled !== original) scaled.recycle()
        var published = false
        try {
            var pixels = IntArray(width * height)
            var scratch = IntArray(pixels.size)
            bitmap.getPixels(pixels, 0, width, 0, 0, width, height)
            // Three separable box passes approximate a Gaussian on <=57,600 pixels.
            repeat(3) {
                for (y in 0 until height) {
                    jobContext.ensureActive()
                    ensureOpen()
                    for (x in 0 until width) {
                        var r = 0; var g = 0; var b = 0
                        for (d in -5..5) {
                            val c = pixels[y * width + (x + d).coerceIn(0, width - 1)]
                            r += (c ushr 16) and 255; g += (c ushr 8) and 255; b += c and 255
                        }
                        scratch[y * width + x] = (255 shl 24) or ((r / 11) shl 16) or ((g / 11) shl 8) or (b / 11)
                    }
                }
                val swap = pixels; pixels = scratch; scratch = swap
                for (y in 0 until height) {
                    jobContext.ensureActive()
                    ensureOpen()
                    for (x in 0 until width) {
                        var r = 0; var g = 0; var b = 0
                        for (d in -5..5) {
                            val c = pixels[(y + d).coerceIn(0, height - 1) * width + x]
                            r += (c ushr 16) and 255; g += (c ushr 8) and 255; b += c and 255
                        }
                        scratch[y * width + x] = (255 shl 24) or ((r / 11) shl 16) or ((g / 11) shl 8) or (b / 11)
                    }
                }
                val swap2 = pixels; pixels = scratch; scratch = swap2
            }
            jobContext.ensureActive()
            ensureOpen()
            bitmap.setPixels(pixels, 0, width, 0, 0, width, height)
            bitmap.asImageBitmap().also { published = true }
        } finally {
            if (!published) bitmap.recycle()
        }
    }

    private fun ensureOpen() {
        if (closed.get()) throw CancellationException("Artwork owner disposed")
    }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        client.dispatcher.cancelAll()
        client.connectionPool.evictAll()
        client.dispatcher.executorService.shutdown()
        runCatching { client.cache?.close() }
        // Existing composables may still hold an image during disposal; drop cache
        // ownership without recycling images that a RenderNode might still draw.
        cache.evictAll()
    }
}

/** One disk-cache owner, even during overlapping Activity recreation. */
private object HomeArtworkOwners {
    private var loader: HomeArtwork? = null
    private var owners = 0

    @Synchronized fun acquire(context: Context): HomeArtwork {
        val instance = loader ?: HomeArtwork(context).also { loader = it }
        owners++
        return instance
    }

    @Synchronized fun release(instance: HomeArtwork) {
        if (loader !== instance) return
        owners--
        if (owners == 0) {
            instance.close()
            loader = null
        }
    }
}

/** RememberObserver also releases an acquired owner if composition is abandoned. */
private class HomeArtworkLease(context: Context) : RememberObserver {
    val loader = HomeArtworkOwners.acquire(context)
    private var released = false
    override fun onRemembered() = Unit
    override fun onForgotten() = release()
    override fun onAbandoned() = release()
    private fun release() {
        if (!released) {
            released = true
            HomeArtworkOwners.release(loader)
        }
    }
}

@Composable
internal fun rememberHomeArtwork(): HomeArtwork {
    val context = LocalContext.current.applicationContext
    return remember(context) { HomeArtworkLease(context) }.loader
}

@Composable
internal fun rememberArtwork(loader: HomeArtwork, url: String?, size: Int = 960,
    wallpaperResource: Int = R.drawable.velour_nocturne): ImageBitmap? {
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    return produceState<ImageBitmap?>(null, loader, url, size, wallpaperResource, lifecycle) {
        lifecycle.repeatOnLifecycle(Lifecycle.State.RESUMED) {
            value = loader.image(url, size, wallpaperResource)
        }
    }.value
}
