package tv.velvet.ui.player

import android.content.Context
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.isActive
import kotlinx.coroutines.withContext
import tv.velvet.VelvetApp
import tv.velvet.data.companion.HandoffLease
import tv.velvet.data.companion.ReceiverPresence
import tv.velvet.data.model.MediaType
import tv.velvet.data.model.PlayTarget

/** Advertise only a resumed, focused app on an interactive display. Never wake a TV. */
@Composable
fun HandoffReceiver(onPlay: (PlayTarget) -> Unit) {
    val context = LocalContext.current
    val container = (context.applicationContext as VelvetApp).container
    val view = LocalView.current
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val play = rememberUpdatedState(onPlay)
    LaunchedEffect(container, lifecycle, view) {
        val power = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        val settings = container.settingsRepository
        val api = container.tvHandoffApi
        val sessions = container.tvHandoffSession
        sessions.visible = { power.isInteractive && view.hasWindowFocus() &&
            lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED) }
        val name = Settings.Global.getString(context.contentResolver, "device_name")
            ?.takeIf { it.isNotBlank() } ?: Build.MODEL
        lifecycle.repeatOnLifecycle(Lifecycle.State.RESUMED) {
            var presence: ReceiverPresence? = null
            var heartbeatAt = 0L
            suspend fun offline() {
                val old = presence ?: return
                sessions.sessionId = null
                presence = null
                withContext(NonCancellable) {
                    try {
                        val (_, sequence) = settings.nextHandoffPresence()
                        api.presence(old.copy(available = false, sequence = sequence))
                    } catch (_: Exception) { /* Server also expires a missed heartbeat. */ }
                }
            }
            try {
                while (isActive) {
                    try {
                        val cfg = settings.settings.first()
                        val profile = settings.activeProfileId.first()
                        if (!power.isInteractive || !view.hasWindowFocus() || !cfg.syncEnabled || profile == null) {
                            offline()
                            delay(500)
                            continue
                        }
                        val now = android.os.SystemClock.elapsedRealtime()
                        if (presence == null || now >= heartbeatAt) {
                            val (device, sequence) = settings.nextHandoffPresence()
                            val current = ReceiverPresence(device, presence?.sessionId ?: UUID.randomUUID().toString(), name,
                                profile, sequence, available = true)
                            if (!api.presence(current)) { offline(); delay(500); continue }
                            presence = current
                            sessions.sessionId = current.sessionId
                            heartbeatAt = now + 3_000
                        }
                        val current = requireNotNull(presence)
                        val handoff = api.claim(current.deviceId, current.sessionId)
                        if (handoff != null) {
                            val lease = HandoffLease(handoff, current.deviceId, current.sessionId)
                            // Recheck after the network await: focus can change while a claim is in flight.
                            if (!power.isInteractive || !view.hasWindowFocus() ||
                                !lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)) {
                                api.ack(lease, "failed", "TV is no longer active")
                            } else if (api.status(handoff.id).state == "claimed") {
                                if (sessions.isEligible(lease)) {
                                    sessions.register(lease)
                                    play.value(PlayTarget(handoff.mediaId, MediaType.fromKey(handoff.type),
                                        handoff.season, handoff.episode, handoffId = handoff.id))
                                } else api.ack(lease, "failed", "TV is no longer active")
                            }
                        }
                    } catch (cancelled: CancellationException) { throw cancelled
                    } catch (_: Exception) { /* Bounded retries; no fallback to legacy broadcast claims. */ }
                    delay(1_000)
                }
            } finally { offline() }
        }
    }
}
