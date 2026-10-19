package tv.velvet.ui.profile

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsFocusedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Edit
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import androidx.tv.material3.Border
import androidx.tv.material3.ClickableSurfaceDefaults
import androidx.tv.material3.Glow
import androidx.tv.material3.Icon
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.Surface
import androidx.tv.material3.Text
import tv.velvet.VelvetApp
import tv.velvet.data.local.ProfileEntity
import tv.velvet.data.profile.ProfileWriteResult
import tv.velvet.ui.components.MediaAction
import tv.velvet.ui.components.MediaActionsSheet
import tv.velvet.ui.components.longPressKeyGuard
import tv.velvet.ui.settings.DialogButtons
import tv.velvet.ui.settings.VelvetDialog
import tv.velvet.ui.settings.VelvetTextField
import tv.velvet.ui.theme.VelvetColors
import tv.velvet.ui.theme.VelvetFonts

private val AVATAR_SIZE = 116.dp
private val TILE_WIDTH = 150.dp

/**
 * "Who's watching?" — a centered grid of profile avatars (+ name labels) plus an Add
 * Profile tile. D-pad focusable, white focus ring, first tile auto-focused. Long-press
 * a profile to Rename / Delete (delete disabled for the last profile, press-again
 * confirm via the shared actions sheet). Selecting a tile chooses that profile.
 *
 * Shown by [ProfileGate] per the spec's gating logic; selecting routes back to Home.
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun ProfilePickerScreen(
    onProfileChosen: (String) -> Unit,
    onBack: (() -> Unit)? = null,
) {
    val app = LocalContext.current.applicationContext as VelvetApp
    val vm: ProfilesViewModel = viewModel(
        factory = viewModelFactory { initializer { ProfilesViewModel(app.container) } }
    )
    val state by vm.state.collectAsStateWithLifecycle()

    var showAdd by remember { mutableStateOf(false) }
    // The profile whose long-press actions sheet is open.
    var actionsFor by remember { mutableStateOf<ProfileEntity?>(null) }
    var renaming by remember { mutableStateOf<ProfileEntity?>(null) }
    // Inline validation copy for the open dialog (name collisions); cleared on edit.
    var addError by remember { mutableStateOf<String?>(null) }
    var renameError by remember { mutableStateOf<String?>(null) }

    // BACK re-opening from Home should be cancellable; the cold-start gate passes null.
    onBack?.let { BackHandler { it() } }

    // First tile auto-focus once profiles arrive (never re-grab on later recompositions).
    val firstTileFocus = remember { FocusRequester() }
    var focusPlaced by remember { mutableStateOf(false) }
    LaunchedEffect(state.profiles.isNotEmpty()) {
        if (state.profiles.isNotEmpty() && !focusPlaced) {
            if (runCatching { firstTileFocus.requestFocus() }.isSuccess) focusPlaced = true
        }
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(VelvetColors.Background)
            .padding(horizontal = 48.dp, vertical = 24.dp),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            modifier = Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState()),
        ) {
            Text(
                text = "Who's watching?",
                style = MaterialTheme.typography.headlineLarge.copy(fontFamily = VelvetFonts.Display),
                color = VelvetColors.TextPrimary,
            )
            Spacer(Modifier.height(28.dp))
            FlowRow(
                horizontalArrangement = Arrangement.spacedBy(20.dp, Alignment.CenterHorizontally),
                verticalArrangement = Arrangement.spacedBy(20.dp),
                modifier = Modifier.fillMaxWidth(),
            ) {
                state.profiles.forEachIndexed { index, profile ->
                    ProfileTile(
                        profile = profile,
                        active = profile.id == state.activeProfileId,
                        onClick = { onProfileChosen(profile.id) },
                        onLongClick = { actionsFor = profile },
                        modifier = if (index == 0) Modifier.focusRequester(firstTileFocus) else Modifier,
                    )
                }
                AddProfileTile(onClick = { showAdd = true })
            }
        }
    }

    if (showAdd) {
        AddProfileDialog(
            errorMessage = addError,
            onNameEdited = { addError = null },
            onSave = { name ->
                // createProfile selects the new profile; chosen-this-launch is set by the
                // gate when activeProfileId flips, so route to Home explicitly too.
                // A duplicate name keeps the dialog open with the error shown.
                vm.createProfile(name) { result ->
                    when (result) {
                        is ProfileWriteResult.Success -> {
                            addError = null
                            showAdd = false
                        }
                        is ProfileWriteResult.NameTaken ->
                            addError = "A profile named '${result.name}' already exists."
                        ProfileWriteResult.InvalidName -> addError = "Enter a name."
                    }
                }
            },
            onDismiss = {
                addError = null
                showAdd = false
            },
        )
    }

    actionsFor?.let { profile ->
        ProfileActionsSheet(
            profile = profile,
            canDelete = state.canDelete,
            onRename = {
                actionsFor = null
                renameError = null
                renaming = profile
            },
            onDelete = {
                actionsFor = null
                vm.deleteProfile(profile.id)
            },
            onDismiss = { actionsFor = null },
        )
    }

    renaming?.let { profile ->
        RenameProfileDialog(
            initialName = profile.name,
            errorMessage = renameError,
            onNameEdited = { renameError = null },
            onSave = { name ->
                vm.renameProfile(profile.id, name) { result ->
                    when (result) {
                        is ProfileWriteResult.Success -> {
                            renameError = null
                            renaming = null
                        }
                        is ProfileWriteResult.NameTaken ->
                            renameError = "A profile named '${result.name}' already exists."
                        ProfileWriteResult.InvalidName -> renameError = "Enter a name."
                    }
                }
            },
            onDismiss = {
                renameError = null
                renaming = null
            },
        )
    }
}

/** Inline validation line under a dialog's text field (name collisions). */
@Composable
private fun DialogErrorText(message: String) {
    Spacer(Modifier.height(8.dp))
    Text(
        text = message,
        style = MaterialTheme.typography.labelMedium,
        color = VelvetColors.Danger,
    )
}

/**
 * One focusable profile tile: avatar + name. White focus ring + glow + slight scale,
 * matching the card system. A subtle accent underline marks the currently-active one.
 */
@Composable
private fun ProfileTile(
    profile: ProfileEntity,
    active: Boolean,
    onClick: () -> Unit,
    onLongClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val interactionSource = remember { MutableInteractionSource() }
    val focused by interactionSource.collectIsFocusedAsState()
    val shape = RoundedCornerShape(AVATAR_SIZE * 0.22f)
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = modifier.width(TILE_WIDTH).longPressKeyGuard(onLongClick),
    ) {
        Surface(
            onClick = onClick,
            interactionSource = interactionSource,
            shape = ClickableSurfaceDefaults.shape(shape),
            colors = ClickableSurfaceDefaults.colors(
                containerColor = VelvetColors.Background,
                focusedContainerColor = VelvetColors.Background,
                pressedContainerColor = VelvetColors.Background,
            ),
            border = ClickableSurfaceDefaults.border(
                focusedBorder = Border(
                    border = BorderStroke(2.5.dp, VelvetColors.FocusRing),
                    shape = shape,
                ),
            ),
            glow = ClickableSurfaceDefaults.glow(
                focusedGlow = Glow(
                    elevationColor = VelvetColors.FocusRing.copy(alpha = 0.35f),
                    elevation = 16.dp,
                ),
            ),
            scale = ClickableSurfaceDefaults.scale(focusedScale = 1.08f),
            modifier = Modifier.size(AVATAR_SIZE),
        ) {
            ProfileAvatar(profile = profile, size = AVATAR_SIZE)
        }
        Spacer(Modifier.height(10.dp))
        Text(
            text = profile.name,
            style = MaterialTheme.typography.titleSmall,
            color = when {
                focused -> VelvetColors.TextPrimary
                active -> VelvetColors.Accent
                else -> VelvetColors.TextSecondary
            },
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            textAlign = TextAlign.Center,
            modifier = Modifier.width(TILE_WIDTH),
        )
    }
}

/** The dashed-feel "Add Profile" tile: a + glyph in a muted square, same focus treatment. */
@Composable
private fun AddProfileTile(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val interactionSource = remember { MutableInteractionSource() }
    val focused by interactionSource.collectIsFocusedAsState()
    val shape = RoundedCornerShape(AVATAR_SIZE * 0.22f)
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = modifier.width(TILE_WIDTH),
    ) {
        Surface(
            onClick = onClick,
            interactionSource = interactionSource,
            shape = ClickableSurfaceDefaults.shape(shape),
            colors = ClickableSurfaceDefaults.colors(
                containerColor = VelvetColors.Surface,
                focusedContainerColor = VelvetColors.SurfaceHighlight,
                pressedContainerColor = VelvetColors.SurfaceHighlight,
            ),
            border = ClickableSurfaceDefaults.border(
                focusedBorder = Border(
                    border = BorderStroke(2.5.dp, VelvetColors.FocusRing),
                    shape = shape,
                ),
            ),
            glow = ClickableSurfaceDefaults.glow(
                focusedGlow = Glow(
                    elevationColor = VelvetColors.FocusRing.copy(alpha = 0.35f),
                    elevation = 16.dp,
                ),
            ),
            scale = ClickableSurfaceDefaults.scale(focusedScale = 1.08f),
            modifier = Modifier.size(AVATAR_SIZE),
        ) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Icon(
                    imageVector = Icons.Filled.Add,
                    contentDescription = "Add Profile",
                    tint = if (focused) VelvetColors.TextPrimary else VelvetColors.TextSecondary,
                    modifier = Modifier.size(40.dp),
                )
            }
        }
        Spacer(Modifier.height(10.dp))
        Text(
            text = "Add Profile",
            style = MaterialTheme.typography.titleSmall,
            color = if (focused) VelvetColors.TextPrimary else VelvetColors.TextSecondary,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            textAlign = TextAlign.Center,
            modifier = Modifier.width(TILE_WIDTH),
        )
    }
}

/** Rename / Delete sheet for a long-pressed profile (reuses the media actions sheet). */
@Composable
private fun ProfileActionsSheet(
    profile: ProfileEntity,
    canDelete: Boolean,
    onRename: () -> Unit,
    onDelete: () -> Unit,
    onDismiss: () -> Unit,
) {
    val actions = buildList {
        add(MediaAction(icon = Icons.Filled.Edit, label = "Rename") { onRename() })
        if (canDelete) {
            add(
                MediaAction(
                    icon = Icons.Filled.Delete,
                    label = "Delete profile",
                    destructive = true,
                ) { onDelete() }
            )
        }
    }
    MediaActionsSheet(
        title = profile.name,
        subtitle = if (canDelete) null else "The only profile can't be deleted",
        actions = actions,
        onDismiss = onDismiss,
    )
}

@Composable
private fun AddProfileDialog(
    errorMessage: String?,
    onNameEdited: () -> Unit,
    onSave: (String) -> Unit,
    onDismiss: () -> Unit,
) {
    var name by remember { mutableStateOf("") }
    val nameFocus = remember { FocusRequester() }

    VelvetDialog(title = "Add Profile", onDismiss = onDismiss) {
        VelvetTextField(
            value = name,
            onValueChange = {
                name = it
                onNameEdited()
            },
            hint = "Name (e.g. Sarah)",
            focusRequester = nameFocus,
        )
        if (errorMessage != null) {
            DialogErrorText(errorMessage)
        } else {
            Spacer(Modifier.height(8.dp))
            Text(
                text = "A color is assigned automatically. You can rename it any time.",
                style = MaterialTheme.typography.labelMedium,
                color = VelvetColors.TextTertiary,
            )
        }
        Spacer(Modifier.height(20.dp))
        DialogButtons(
            confirmLabel = "Save",
            onConfirm = { onSave(name) },
            onCancel = onDismiss,
            confirmEnabled = name.isNotBlank(),
        )
        LaunchedEffect(Unit) { nameFocus.requestFocus() }
    }
}

@Composable
private fun RenameProfileDialog(
    initialName: String,
    errorMessage: String?,
    onNameEdited: () -> Unit,
    onSave: (String) -> Unit,
    onDismiss: () -> Unit,
) {
    var name by remember { mutableStateOf(initialName) }
    val nameFocus = remember { FocusRequester() }

    VelvetDialog(title = "Rename Profile", onDismiss = onDismiss) {
        VelvetTextField(
            value = name,
            onValueChange = {
                name = it
                onNameEdited()
            },
            hint = "Name",
            focusRequester = nameFocus,
        )
        if (errorMessage != null) DialogErrorText(errorMessage)
        Spacer(Modifier.height(20.dp))
        DialogButtons(
            confirmLabel = "Save",
            onConfirm = { onSave(name) },
            onCancel = onDismiss,
            confirmEnabled = name.isNotBlank(),
        )
        LaunchedEffect(Unit) { nameFocus.requestFocus() }
    }
}
