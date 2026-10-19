package tv.velvet.ui.home

import android.Manifest
import android.content.pm.PackageManager
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Mic
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.withFrameNanos
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.tv.material3.Button
import androidx.tv.material3.Icon
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.Text
import tv.velvet.ui.components.velvetButtonColors
import tv.velvet.ui.theme.VelvetColors

@OptIn(ExperimentalComposeUiApi::class)
@Composable
fun CreateCategoryDialog(busy: Boolean, error: String?, onCreate: (String) -> Unit, onDismiss: () -> Unit) {
    var prompt by rememberSaveable { mutableStateOf("") }
    var voiceError by remember { mutableStateOf<String?>(null) }
    var voiceState by remember { mutableStateOf(CategorySpeechState()) }
    var pendingVoiceStart by remember { mutableStateOf(false) }
    var permissionInFlight by remember { mutableStateOf(false) }
    var autoStartAttempted by rememberSaveable { mutableStateOf(false) }
    var typing by remember { mutableStateOf(false) }
    val micFocus = remember { FocusRequester() }
    val textFocus = remember { FocusRequester() }
    val typeFocus = remember { FocusRequester() }
    val createFocus = remember { FocusRequester() }
    val closeFocus = remember { FocusRequester() }
    val keyboard = LocalSoftwareKeyboardController.current
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val lifecycleState by lifecycleOwner.lifecycle.currentStateFlow.collectAsState()
    val currentOnCreate by rememberUpdatedState(onCreate)
    val currentBusy by rememberUpdatedState(busy)
    val speech = remember(context, lifecycleOwner) {
        CategorySpeechInput(context,
            onState = { voiceState = it },
            onResult = { recognized ->
                prompt = recognized
                voiceError = null
                if (!currentBusy) currentOnCreate(recognized)
            })
    }
    val microphonePermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        permissionInFlight = false
        pendingVoiceStart = granted
        voiceError = if (granted) null else "Microphone access is off. Allow it in Android's app permissions to speak, or type your category."
    }
    val requestSpeech: () -> Unit = {
        voiceError = null
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
            pendingVoiceStart = true
        } else if (!permissionInFlight) {
            permissionInFlight = true
            microphonePermission.launch(Manifest.permission.RECORD_AUDIO)
        }
    }
    val cancelSpeech: () -> Unit = {
        pendingVoiceStart = false
        speech.cancel()
    }
    val dismiss: () -> Unit = { cancelSpeech(); keyboard?.hide(); onDismiss() }
    val voiceActive = pendingVoiceStart || permissionInFlight || voiceState.phase != CategorySpeechPhase.IDLE

    // Permission results can arrive before resume. Only start recording once our
    // own dialog is visible again, and invalidate callbacks when leaving it.
    LaunchedEffect(speech, pendingVoiceStart, lifecycleState, busy) {
        if (pendingVoiceStart && lifecycleState == Lifecycle.State.RESUMED && !busy) {
            pendingVoiceStart = false
            speech.start()
        }
    }
    DisposableEffect(speech, lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_STOP) {
                if (!permissionInFlight) pendingVoiceStart = false
                speech.cancel()
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose {
            lifecycleOwner.lifecycle.removeObserver(observer)
            speech.close()
        }
    }
    Dialog(onDismissRequest = {
        if (typing) {
            typing = false
            keyboard?.hide()
        } else dismiss()
    }, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        val focusManager = LocalFocusManager.current
        val keyboard = LocalSoftwareKeyboardController.current
        val leaveTyping: () -> Unit = {
            typing = false
            focusManager.clearFocus(force = true)
            keyboard?.hide()
        }
        val startSpeech: () -> Unit = {
            leaveTyping()
            micFocus.requestFocus()
            requestSpeech()
        }
        val canCreate = !busy && !voiceActive && prompt.trim().length >= 3
        val submit: () -> Unit = {
            if (canCreate) {
                leaveTyping()
                onCreate(prompt.trim())
            }
        }
        BackHandler(enabled = typing) { leaveTyping() }
        LaunchedEffect(typing, busy) {
            withFrameNanos { }
            if (typing && !busy) {
                textFocus.requestFocus()
                keyboard?.show()
            } else {
                focusManager.clearFocus(force = true)
                keyboard?.hide()
                if (busy) closeFocus.requestFocus() else micFocus.requestFocus()
            }
        }
        LaunchedEffect(Unit) {
            withFrameNanos { }
            if (!autoStartAttempted && !busy) {
                autoStartAttempted = true
                startSpeech()
            }
        }
        Column(Modifier.width(620.dp).background(VelvetColors.SurfaceElevated, RoundedCornerShape(18.dp))
            .padding(28.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Text("Create a category", style = MaterialTheme.typography.headlineSmall, color = VelvetColors.TextPrimary)
            Text("Try “Cartoon Network shows”, “Disney Halloween episodes”, or “Star Wars movies in story order”. Year or era is optional.",
                style = MaterialTheme.typography.bodyMedium, color = VelvetColors.TextSecondary)
            // No editor exists in voice mode, so d-pad focus cannot open the IME.
            if (typing) {
                BasicTextField(value = prompt, onValueChange = { prompt = it.take(500) }, enabled = !busy && !voiceActive, singleLine = true,
                    textStyle = MaterialTheme.typography.bodyLarge.copy(color = VelvetColors.TextPrimary),
                    cursorBrush = SolidColor(VelvetColors.FocusRing),
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                    keyboardActions = KeyboardActions(onDone = { submit() }),
                    modifier = Modifier.fillMaxWidth().focusRequester(textFocus).focusProperties { down = micFocus }
                        .border(1.dp, VelvetColors.TextTertiary, RoundedCornerShape(8.dp)).padding(14.dp),
                    decorationBox = { inner -> Box { if (prompt.isBlank()) Text("Type a category…", color = VelvetColors.TextTertiary); inner() } })
            } else {
                Text(prompt.ifBlank { "Your category will appear here." },
                    style = MaterialTheme.typography.bodyLarge,
                    color = if (prompt.isBlank()) VelvetColors.TextTertiary else VelvetColors.TextPrimary,
                    maxLines = 3,
                    modifier = Modifier.fillMaxWidth()
                        .border(1.dp, VelvetColors.TextTertiary, RoundedCornerShape(8.dp)).padding(14.dp))
            }
            val voiceStatus = when (voiceState.phase) {
                CategorySpeechPhase.STARTING -> "Starting microphone…"
                CategorySpeechPhase.LISTENING -> "Listening… describe your category."
                CategorySpeechPhase.PROCESSING -> "Finishing voice input…"
                CategorySpeechPhase.IDLE -> null
            }
            voiceStatus?.let { Text(it, color = VelvetColors.TextPrimary) }
            if (voiceState.partial.isNotBlank()) Text(voiceState.partial, color = VelvetColors.TextSecondary, maxLines = 2)
            (voiceError ?: voiceState.error ?: error)?.let { Text(it, style = MaterialTheme.typography.bodyMedium, color = VelvetColors.TextSecondary) }
            if (busy) Text("Finding matches for your category…", color = VelvetColors.TextSecondary)
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Button(onClick = { if (voiceActive) cancelSpeech() else startSpeech() }, enabled = !busy && !permissionInFlight,
                    colors = velvetButtonColors(), modifier = Modifier.focusRequester(micFocus).focusProperties {
                        up = if (typing) textFocus else FocusRequester.Cancel
                        left = FocusRequester.Cancel
                        right = typeFocus
                        down = if (canCreate) createFocus else closeFocus
                    }) {
                    Icon(Icons.Filled.Mic, contentDescription = null)
                    Text(if (voiceActive) "Cancel listening" else "Speak")
                }
                Button(onClick = {
                    if (typing) leaveTyping() else {
                        cancelSpeech()
                        voiceError = null
                        typing = true
                    }
                }, enabled = !busy && !permissionInFlight,
                    colors = velvetButtonColors(), modifier = Modifier.focusRequester(typeFocus).focusProperties {
                        left = micFocus
                        right = FocusRequester.Cancel
                        up = if (typing) textFocus else FocusRequester.Cancel
                        down = if (canCreate) createFocus else closeFocus
                    }) { Text(if (typing) "Done typing" else if (prompt.isBlank()) "Type instead" else "Edit text") }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Button(onClick = submit, enabled = canCreate,
                    colors = velvetButtonColors(), modifier = Modifier.focusRequester(createFocus).focusProperties {
                        left = FocusRequester.Cancel
                        right = closeFocus
                        up = micFocus
                        down = FocusRequester.Cancel
                    }) { Text("Create") }
                Button(onClick = { leaveTyping(); dismiss() }, colors = velvetButtonColors(), modifier = Modifier.focusRequester(closeFocus).focusProperties {
                    left = if (canCreate) createFocus else FocusRequester.Cancel
                    right = FocusRequester.Cancel
                    up = if (!busy && !permissionInFlight) typeFocus else FocusRequester.Cancel
                    down = FocusRequester.Cancel
                }) { Text("Close") }
            }
        }
    }
}


@Composable
fun QueuePreparationDialog(preparing: Boolean, error: String?, onDismiss: () -> Unit) {
    Dialog(onDismissRequest = onDismiss) {
        Column(Modifier.width(560.dp).background(VelvetColors.SurfaceElevated, RoundedCornerShape(18.dp))
            .padding(28.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Text(if (preparing) "Preparing your channel…" else "Couldn't start this category",
                style = MaterialTheme.typography.headlineSmall, color = VelvetColors.TextPrimary)
            Text(if (preparing) "Gathering your selections. Playback will continue through the whole category."
                else error.orEmpty(), color = VelvetColors.TextSecondary)
            val focus = remember { FocusRequester() }
            LaunchedEffect(Unit) { runCatching { focus.requestFocus() } }
            Button(onClick = onDismiss, colors = velvetButtonColors(), modifier = Modifier.focusRequester(focus)) {
                Text(if (preparing) "Cancel" else "Close")
            }
        }
    }
}
