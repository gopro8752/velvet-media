package tv.velvet.ui.player

import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class RollingDiagnosticLogWriterTest {
    @Test fun retainsRecentCompleteRecordsWithinDiskLimitAcrossRestarts() {
        val directory = Files.createTempDirectory("avsync-log-test").toFile()
        try {
            val first = RollingDiagnosticLogWriter(directory, maxFileBytes = 256, fileCount = 3)
            repeat(30) { first.append("event=$it " + "x".repeat(60)) }
            val restarted = RollingDiagnosticLogWriter(directory, maxFileBytes = 256, fileCount = 3)
            restarted.append("after_restart")
            val files = directory.listFiles()!!.sortedByDescending { it.name }
            assertTrue(files.size <= 3)
            assertTrue(files.all { it.length() <= 256 })
            assertTrue(files.sumOf { it.length() } <= 768)
            val lines = files.flatMap { it.readLines() }
            assertEquals("after_restart", lines.last())
            assertTrue(lines.any { it.startsWith("event=29 ") })
            assertTrue(lines.none { it.startsWith("event=0 ") })
            assertTrue(files.all { it.readText().endsWith("\n") })
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test fun oversizedAndMultilineRecordsCannotBreakRetentionOrForgeLines() {
        val directory = Files.createTempDirectory("avsync-log-test").toFile()
        try {
            val writer = RollingDiagnosticLogWriter(directory, maxFileBytes = 256, fileCount = 2)
            writer.append("x".repeat(2000))
            writer.append("first\nsecond\rthird")
            val lines = directory.resolve("avsync-0.log").readLines()
            assertTrue(lines.first().startsWith("diagnostic_record_oversize bytes="))
            assertEquals("first second third", lines.last())
            assertEquals(2, lines.size)
            assertTrue(directory.listFiles()!!.sumOf { it.length() } <= 512)
        } finally {
            directory.deleteRecursively()
        }
    }
}
