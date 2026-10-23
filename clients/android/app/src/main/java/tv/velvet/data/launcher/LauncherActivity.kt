package tv.velvet.data.launcher

import tv.velvet.BuildConfig

import android.content.Intent
import android.os.Bundle
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout
import tv.velvet.MainActivity
import tv.velvet.VelvetApp

/** Android enforces the signature permission before creating this explicit-only entry point. */
class LauncherActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val source = intent
        val request = runCatching {
            if (source.action != "${BuildConfig.APPLICATION_ID}.action.LAUNCHER" || source.data != null) return@runCatching null
            LauncherRequest.validated(source.getStringExtra("destination"), source.getStringExtra("profile"),
                source.getIntExtra("mediaId", -1).takeIf { source.hasExtra("mediaId") }, source.getStringExtra("type"),
                source.getIntExtra("season", -1).takeIf { source.hasExtra("season") },
                source.getIntExtra("episode", -1).takeIf { source.hasExtra("episode") }, source.getStringExtra("category"),
                source.getBooleanExtra("shuffle", false), source.getStringExtra("game"))
        }.getOrNull()
        if (request == null) { finish(); return }
        lifecycleScope.launch {
            val active = runCatching { withTimeout(2_500) {
                (application as VelvetApp).container.settingsRepository.activeProfileId.first()
            } }.getOrNull()
            if (request.profileId != null && request.profileId != active) {
                Toast.makeText(this@LauncherActivity, "Your Velvet profile changed. Refresh the launcher and try again.", Toast.LENGTH_LONG).show()
            } else {
                android.util.Log.i("VelvetLauncher", "Open ${request.destination}")
                LauncherNavigation.submit(request)
                startActivity(Intent(this@LauncherActivity, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP))
            }
            finish()
        }
    }
}
