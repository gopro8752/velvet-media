package tv.velour.data.apps

import android.app.ActivityOptions
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.content.pm.ResolveInfo
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Rect
import android.graphics.drawable.Drawable
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.util.LruCache
import android.view.View
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.palette.graphics.Palette
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import tv.velour.core.AppEntry
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean

class AppRepository(private val context: Context) {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val started = AtomicBoolean(false)

    private val _apps = MutableStateFlow<List<AppEntry>>(emptyList())

    /** Alphabetical by label, all LEANBACK_LAUNCHER-resolvable apps, excluding tv.velour. */
    val apps: StateFlow<List<AppEntry>> = _apps.asStateFlow()

    /**
     * Banner ImageBitmaps keyed by package; BYTE-sized so the working set of one full
     * library screen plus prefetch always fits (an entry-counted cache of 32 was smaller
     * than the ~42 simultaneously visible tiles, so every scroll evicted live entries and
     * re-rendered ~230KB bitmaps). 16MB holds ~70 of the 320x180 ARGB_8888 banners.
     */
    private val bannerCache = object : LruCache<String, ImageBitmap>(BANNER_CACHE_BYTES) {
        override fun sizeOf(key: String, value: ImageBitmap): Int =
            value.width * value.height * 4
    }

    /** Packages known to have no banner, so we never re-resolve them per scroll. */
    private val bannerless = ConcurrentHashMap.newKeySet<String>()

    /** Palette dominant color per package; null results cached too (holder class). */
    private val whisperCache = ConcurrentHashMap<String, CachedWhisper>()

    private class CachedWhisper(val color: Color?)

    private val packageReceiver = object : BroadcastReceiver() {
        override fun onReceive(receiverContext: Context?, intent: Intent?) {
            // Drop any cached art for the changed package (REPLACED ships new banners/icons).
            intent?.data?.schemeSpecificPart?.let { changed ->
                bannerCache.remove(changed)
                bannerless.remove(changed)
                whisperCache.remove(changed)
            }
            scope.launch { refresh() }
        }
    }

    /** Initial scan + register ACTION_PACKAGE_{ADDED,REMOVED,REPLACED} receiver (scheme "package"). */
    fun start() {
        if (!started.compareAndSet(false, true)) return
        scope.launch { refresh() }
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_PACKAGE_ADDED)
            addAction(Intent.ACTION_PACKAGE_REMOVED)
            addAction(Intent.ACTION_PACKAGE_REPLACED)
            addDataScheme("package")
        }
        if (Build.VERSION.SDK_INT >= 33) {
            // Package broadcasts are protected system broadcasts; EXPORTED guarantees delivery
            // under targetSdk 34+'s mandatory receiver-export flag.
            context.registerReceiver(packageReceiver, filter, Context.RECEIVER_EXPORTED)
        } else {
            context.registerReceiver(packageReceiver, filter)
        }
    }

    // CONTRACT-NOTE: sourceBounds is android.graphics.Rect (window coordinates) because it feeds
    // ActivityOptions.makeScaleUpAnimation; callers convert from androidx.compose.ui.geometry.Rect.
    /** Leanback intent → fallback to launcher intent; makeScaleUpAnimation when bounds given. */
    fun launch(packageName: String, sourceBounds: Rect? = null) {
        val pm = context.packageManager
        val intent = pm.getLeanbackLaunchIntentForPackage(packageName)
            ?: pm.getLaunchIntentForPackage(packageName)
            ?: return
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED)
        var options: ActivityOptions? = null
        if (sourceBounds != null) {
            intent.sourceBounds = Rect(sourceBounds)
            // makeScaleUpAnimation resolves screen coordinates via the source view's location;
            // a detached View sits at (0, 0), so the card's window bounds pass through unchanged.
            options = ActivityOptions.makeScaleUpAnimation(
                View(context),
                sourceBounds.left,
                sourceBounds.top,
                sourceBounds.width(),
                sourceBounds.height(),
            )
        }
        runCatching { context.startActivity(intent, options?.toBundle()) }
    }

    /** ACTION_DELETE with package URI. */
    fun requestUninstall(packageName: String) {
        val intent = Intent(Intent.ACTION_DELETE, Uri.fromParts("package", packageName, null))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        runCatching { context.startActivity(intent) }
    }

    /** ACTION_APPLICATION_DETAILS_SETTINGS. */
    fun openAppInfo(packageName: String) {
        val intent = Intent(
            Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
            Uri.fromParts("package", packageName, null),
        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        runCatching { context.startActivity(intent) }
    }

    /** Banner drawable preferred (rendered ~320x180), null if none; LruCache'd. */
    suspend fun banner(packageName: String): ImageBitmap? {
        bannerCache.get(packageName)?.let { return it }
        if (packageName in bannerless) return null
        return withContext(Dispatchers.IO) {
            // Re-check after the dispatch; another caller may have rendered it meanwhile.
            bannerCache.get(packageName)?.let { return@withContext it }
            val image = runCatching {
                loadBannerDrawable(packageName)?.renderToBitmap(BANNER_W, BANNER_H)?.asImageBitmap()
            }.getOrNull()
            if (image == null) {
                bannerless.add(packageName)
            } else {
                bannerCache.put(packageName, image)
            }
            image
        }
    }

    /** Palette dominant color from icon, cached, null if unavailable. */
    suspend fun accentWhisper(packageName: String): Color? {
        whisperCache[packageName]?.let { return it.color }
        return withContext(Dispatchers.IO) {
            whisperCache[packageName]?.let { return@withContext it.color }
            val color = runCatching {
                val icon = context.packageManager.getApplicationIcon(packageName)
                val sample = icon.renderToBitmap(WHISPER_SAMPLE, WHISPER_SAMPLE)
                val swatch = Palette.from(sample)
                    .maximumColorCount(16)
                    .generate()
                    .dominantSwatch
                sample.recycle()
                swatch?.rgb?.let { Color(it) }
            }.getOrNull()
            whisperCache[packageName] = CachedWhisper(color)
            color
        }
    }

    // ---- internals -------------------------------------------------------------------------

    private suspend fun refresh() {
        withContext(Dispatchers.IO) { runCatching { scan() }.getOrNull() }
            ?.let { _apps.value = it }
    }

    private fun scan(): List<AppEntry> {
        val pm = context.packageManager
        return queryLeanback()
            .asSequence()
            .mapNotNull { it.activityInfo }
            .filter { it.packageName != context.packageName }
            .distinctBy { it.packageName }
            .map { activityInfo ->
                AppEntry(
                    packageName = activityInfo.packageName,
                    label = activityInfo.loadLabel(pm).toString()
                        .ifBlank { activityInfo.packageName },
                    isGame = activityInfo.applicationInfo.isGameApp(),
                )
            }
            .sortedWith(compareBy(String.CASE_INSENSITIVE_ORDER) { it.label })
            .toList()
    }

    private fun queryLeanback(packageName: String? = null): List<ResolveInfo> {
        val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LEANBACK_LAUNCHER)
        if (packageName != null) intent.setPackage(packageName)
        val pm = context.packageManager
        return if (Build.VERSION.SDK_INT >= 33) {
            pm.queryIntentActivities(intent, PackageManager.ResolveInfoFlags.of(0L))
        } else {
            @Suppress("DEPRECATION")
            pm.queryIntentActivities(intent, 0)
        }
    }

    /**
     * Activity banner first ([android.content.pm.PackageItemInfo.loadBanner] already falls back
     * to the application banner), then the application banner directly for safety.
     */
    private fun loadBannerDrawable(packageName: String): Drawable? {
        val pm = context.packageManager
        val activityInfo = queryLeanback(packageName).firstOrNull()?.activityInfo
        return runCatching { activityInfo?.loadBanner(pm) }.getOrNull()
            ?: runCatching { pm.getApplicationBanner(packageName) }.getOrNull()
    }

    @Suppress("DEPRECATION") // FLAG_IS_GAME: still the only signal set by many legacy games
    private fun ApplicationInfo.isGameApp(): Boolean =
        category == ApplicationInfo.CATEGORY_GAME || (flags and ApplicationInfo.FLAG_IS_GAME) != 0

    private fun Drawable.renderToBitmap(width: Int, height: Int): Bitmap {
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        setBounds(0, 0, width, height)
        draw(canvas)
        return bitmap
    }

    private companion object {
        const val BANNER_W = 320
        const val BANNER_H = 180
        const val BANNER_CACHE_BYTES = 16 * 1024 * 1024
        const val WHISPER_SAMPLE = 64
    }
}
