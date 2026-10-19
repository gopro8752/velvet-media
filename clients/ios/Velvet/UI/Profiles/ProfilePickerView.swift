import SwiftUI

/// "Who's watching?" — the profile picker. A centered grid of circular avatars
/// with name labels plus an "Add Profile" tile. Tap a profile → select it and
/// dismiss to Home (selecting sets profileChosenThisLaunch, which flips the
/// RootGate binding closed). Edit mode (or a context menu) exposes Rename /
/// Delete; Delete is disabled for the last remaining profile and uses a
/// role:.destructive confirm consistent with the app's pattern.
struct ProfilePickerView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var profiles: ProfileStore

    /// One sheet channel (a single `.sheet(item:)` avoids the SwiftUI bug where
    /// two `.sheet` modifiers on one view fight over presentation).
    private enum ActiveSheet: Identifiable {
        case add
        case rename(Profile)
        var id: String {
            switch self {
            case .add: return "add"
            case .rename(let p): return "rename:\(p.id)"
            }
        }
    }

    @State private var editing = false
    @State private var activeSheet: ActiveSheet?
    /// Profile pending delete confirmation.
    @State private var deleteTarget: Profile?

    private static let columns = [
        GridItem(.adaptive(minimum: 96, maximum: 130), spacing: 28, alignment: .top)
    ]

    var body: some View {
        ZStack {
            VelvetColors.background.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                Text("Who's watching?")
                    .font(VelvetFont.display(28, .bold))
                    .foregroundStyle(VelvetColors.textPrimary)
                    .padding(.bottom, 36)
                grid
                Spacer(minLength: 0)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .add:
                AddProfileSheet { id in
                    // New profile is selected immediately → dismiss to Home.
                    profiles.select(id: id)
                }
            case .rename(let profile):
                RenameProfileSheet(profile: profile)
            }
        }
        .confirmationDialog(
            "Delete this profile?",
            isPresented: Binding(get: { deleteTarget != nil },
                                 set: { if !$0 { deleteTarget = nil } }),
            titleVisibility: .visible,
            presenting: deleteTarget
        ) { profile in
            Button("Delete \(profile.name)", role: .destructive) {
                profiles.delete(id: profile.id)
                deleteTarget = nil
                if profiles.enabledCount <= 1 { editing = false }
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: { profile in
            Text("\(profile.name)'s watch history stays synced but won't clutter anyone else's lists.")
        }
    }

    // MARK: top bar (Edit toggle)

    /// The picker can be dismissed without choosing only when a valid active
    /// profile already exists (an on-demand re-open). The cold-launch gate has
    /// no escape — a profile MUST be chosen.
    private var canCancel: Bool {
        guard let id = settings.activeProfileId else { return false }
        return profiles.profiles.contains { $0.id == id }
    }

    private var topBar: some View {
        HStack {
            if canCancel {
                Button("Close") {
                    settings.profilePickerRequested = false
                    settings.profileChosenThisLaunch = true
                }
                .font(VelvetFont.body(15, .semibold))
                .foregroundStyle(VelvetColors.textSecondary)
            } else {
                Text("VELVET")
                    .font(VelvetFont.display(15, .bold))
                    .tracking(4)
                    .foregroundStyle(VelvetColors.textSecondary)
            }
            Spacer()
            Button(editing ? "Done" : "Edit") {
                withAnimation(.easeInOut(duration: 0.18)) { editing.toggle() }
            }
            .font(VelvetFont.body(15, .semibold))
            .foregroundStyle(VelvetColors.accent)
        }
        .padding(.top, 20)
    }

    // MARK: grid

    private var grid: some View {
        LazyVGrid(columns: Self.columns, spacing: 28) {
            ForEach(profiles.profiles) { profile in
                profileTile(profile)
            }
            addTile
        }
        .frame(maxWidth: 460)
    }

    private func profileTile(_ profile: Profile) -> some View {
        let isActive = profile.id == settings.activeProfileId
        return VStack(spacing: 10) {
            ZStack(alignment: .topTrailing) {
                ProfileAvatar(profile: profile, diameter: 84, selected: isActive && !editing)
                    .opacity(editing ? 0.85 : 1)
                if editing {
                    // Edit badge — tap to rename; the whole tile long-presses for
                    // the full menu, but the pencil makes rename discoverable.
                    Image(systemName: "pencil.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(VelvetColors.textPrimary, VelvetColors.surfaceHighlight)
                        .offset(x: 4, y: -4)
                }
            }
            Text(profile.name)
                .font(VelvetFont.body(14, .semibold))
                .foregroundStyle(isActive ? VelvetColors.textPrimary : VelvetColors.textSecondary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if editing {
                activeSheet = .rename(profile)
            } else {
                profiles.select(id: profile.id)
            }
        }
        .contextMenu {
            Button {
                activeSheet = .rename(profile)
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button(role: .destructive) {
                deleteTarget = profile
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(!profiles.canDelete(id: profile.id))
        }
    }

    private var addTile: some View {
        VStack(spacing: 10) {
            Circle()
                .strokeBorder(VelvetColors.surfaceHighlight, style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
                .background(Circle().fill(VelvetColors.surface))
                .overlay(
                    Image(systemName: "plus")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(VelvetColors.textSecondary)
                )
                .frame(width: 84, height: 84)
            Text("Add Profile")
                .font(VelvetFont.body(14, .semibold))
                .foregroundStyle(VelvetColors.textSecondary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .onTapGesture { activeSheet = .add }
    }
}

/// Rename sheet — mirrors AddProfileSheet styling; prefilled name, Save commits.
private struct RenameProfileSheet: View {
    @EnvironmentObject private var profiles: ProfileStore
    @Environment(\.dismiss) private var dismiss

    let profile: Profile

    @State private var name: String
    /// Inline rejection text (spec §1a), same contract as AddProfileSheet.
    @State private var errorText: String?
    @FocusState private var focused: Bool

    init(profile: Profile) {
        self.profile = profile
        _name = State(initialValue: profile.name)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var canSave: Bool { !trimmedName.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button("Cancel") { dismiss() }
                    .font(VelvetFont.body(15))
                    .foregroundStyle(VelvetColors.textSecondary)
                Spacer()
                Text("Rename Profile")
                    .font(VelvetFont.display(16, .semibold))
                    .foregroundStyle(VelvetColors.textPrimary)
                Spacer()
                Button("Save") { save() }
                    .font(VelvetFont.body(15, .semibold))
                    .foregroundStyle(canSave ? VelvetColors.accent : VelvetColors.textTertiary)
                    .disabled(!canSave)
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 20)

            HStack(spacing: 14) {
                ProfileAvatar(profile: profile, diameter: 56)
                ZStack(alignment: .leading) {
                    if name.isEmpty {
                        Text("Name")
                            .font(VelvetFont.body(15))
                            .foregroundStyle(VelvetColors.textTertiary)
                            .allowsHitTesting(false)
                    }
                    TextField("", text: $name)
                        .font(VelvetFont.body(15))
                        .foregroundStyle(VelvetColors.textPrimary)
                        .tint(VelvetColors.textPrimary)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                        .focused($focused)
                        .onSubmit { if canSave { save() } }
                        .onChange(of: name) { _, _ in
                            if errorText != nil {
                                withAnimation(.easeInOut(duration: 0.15)) { errorText = nil }
                            }
                        }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(VelvetColors.surfaceElevated)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(VelvetColors.danger, lineWidth: errorText == nil ? 0 : 1)
                        )
                )
            }
            .padding(.horizontal, 16)

            if let errorText {
                Text(errorText)
                    .font(VelvetFont.body(12, .semibold))
                    .foregroundStyle(VelvetColors.danger)
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .transition(.opacity)
            }

            Spacer(minLength: 0)
        }
        .background(VelvetColors.background)
        .presentationBackground(VelvetColors.background)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .task {
            try? await Task.sleep(for: .milliseconds(400))
            focused = true
        }
    }

    /// Spec §1a: renaming onto another live profile's name is REJECTED — inline
    /// error, sheet stays open, nothing written.
    private func save() {
        guard canSave else { return }
        guard profiles.rename(id: profile.id, to: trimmedName) else {
            withAnimation(.easeInOut(duration: 0.15)) {
                errorText = "A profile named '\(trimmedName)' already exists."
            }
            return
        }
        dismiss()
    }
}
