package tv.velvet.ui.player

import android.content.Context
import android.os.Process
import android.util.Log
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.time.Instant
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import tv.velvet.BuildConfig

/** Private, bounded history survives process restarts; playback never waits for disk I/O. */
internal object PlaybackDiagnosticLog {
    private val dropped = AtomicLong()
    private val warned = AtomicBoolean()
    private var writer: RollingDiagnosticLogWriter? = null // Accessed only by the writer thread.
    private val executor = ThreadPoolExecutor(
        1, 1, 30, TimeUnit.SECONDS, ArrayBlockingQueue(128),
        { task -> Thread(task, "VelvetAvLog").apply { isDaemon = true; priority = Thread.MIN_PRIORITY } },
        { _, _ -> dropped.incrementAndGet() },
    ).apply { allowCoreThreadTimeOut(true) }

    fun append(context: Context, warning: Boolean, message: String) {
        val wallTimeMs = System.currentTimeMillis()
        val app = context.applicationContext
        executor.execute {
            var skipped = 0L
            try {
                val output = writer ?: RollingDiagnosticLogWriter(File(app.noBackupFilesDir, "diagnostics/avsync"))
                    .also { writer = it }
                val prefix = "${Instant.ofEpochMilli(wallTimeMs)} level=${if (warning) "W" else "I"}" +
                    " version=${BuildConfig.VERSION_NAME} versionCode=${BuildConfig.VERSION_CODE} pid=${Process.myPid()}"
                skipped = dropped.getAndSet(0)
                if (skipped > 0) output.append("$prefix diagnostic_events_dropped count=$skipped")
                output.append("$prefix $message")
                warned.set(false)
            } catch (error: IOException) {
                failed(skipped, error)
            } catch (error: SecurityException) {
                failed(skipped, error)
            }
        }
    }

    private fun failed(skipped: Long, error: Exception) {
        dropped.addAndGet(skipped + 1)
        if (warned.compareAndSet(false, true)) {
            Log.w("VelvetAVSync", "Persistent diagnostics unavailable type=${error.javaClass.simpleName}")
        }
    }
}

/** Single-writer rotation: avsync-0.log is current, avsync-3.log is oldest (3 MiB total). */
internal class RollingDiagnosticLogWriter(
    private val directory: File,
    private val maxFileBytes: Int = 768 * 1024,
    private val fileCount: Int = 4,
) {
    init {
        require(maxFileBytes >= 256 && fileCount >= 2)
    }

    fun append(line: String) {
        if (!directory.isDirectory && !directory.mkdirs()) throw IOException("Cannot create diagnostic directory")
        val bytes = (line.replace('\n', ' ').replace('\r', ' ') + "\n").toByteArray(Charsets.UTF_8)
        val record = if (bytes.size <= minOf(4096, maxFileBytes)) bytes else
            "diagnostic_record_oversize bytes=${bytes.size}\n".toByteArray(Charsets.UTF_8)
        val current = file(0)
        if (current.length() + record.size > maxFileBytes) {
            val oldest = file(fileCount - 1)
            if (oldest.exists() && !oldest.delete()) throw IOException("Cannot rotate diagnostic log")
            for (index in fileCount - 2 downTo 0) {
                val source = file(index)
                if (source.exists() && !source.renameTo(file(index + 1))) throw IOException("Cannot rotate diagnostic log")
            }
        }
        FileOutputStream(current, true).use { it.write(record) }
    }

    private fun file(index: Int) = File(directory, "avsync-$index.log")
}
