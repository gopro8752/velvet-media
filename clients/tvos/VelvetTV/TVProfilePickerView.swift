import SwiftUI

struct TVProfilePickerView: View {
    var onSelect: (() -> Void)? = nil
    @EnvironmentObject private var profiles: ProfileStore
    @EnvironmentObject private var settings: SettingsStore
    @State private var editor: ProfileEditor?
    @State private var deleting: Profile?
    @State private var editing = false

    private struct ProfileEditor: Identifiable {
        let id = UUID()
        var profile: Profile?
    }

    var body: some View {
        ZStack {
            TVBackdrop().ignoresSafeArea()
            VStack(spacing: 52) {
                Text("VELVET").font(VelvetFont.display(23, .semibold)).tracking(9)
                    .foregroundStyle(VelvetColors.textSecondary)
                VStack(spacing: 16) {
                    Text("Who's watching?").font(VelvetFont.display(56, .semibold))
                    Text("Your own favorites. Your own next episode.").font(VelvetFont.body(26))
                        .foregroundStyle(VelvetColors.textSecondary)
                }
                ScrollView(.horizontal) {
                    HStack(spacing: 38) {
                        ForEach(profiles.profiles) { profile in
                            Button {
                                if editing { editor = ProfileEditor(profile: profile) }
                                else { profiles.select(id: profile.id); onSelect?() }
                            } label: {
                                VStack(spacing: 24) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 32)
                                            .fill(LinearGradient(colors: [Color(hex: profile.color.profileColorHex), Color(hex: profile.color.profileColorHex).opacity(0.30)],
                                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                                        RoundedRectangle(cornerRadius: 32).strokeBorder(.white.opacity(0.25), lineWidth: 1)
                                        if editing {
                                            Image(systemName: "pencil").font(.system(size: 55, weight: .light)).foregroundStyle(.white)
                                        } else {
                                            Text(profile.initial).font(VelvetFont.display(76, .medium)).foregroundStyle(.white)
                                        }
                                    }.frame(width: 170, height: 170)
                                    Text(profile.name).font(VelvetFont.body(26, .semibold)).lineLimit(1)
                                        .foregroundStyle(VelvetColors.textPrimary)
                                }.frame(width: 190).padding(10)
                            }.buttonStyle(TVCardButtonStyle()).accessibilityIdentifier("profiles.\(profile.name)")
                            .contextMenu {
                                Button("Rename", systemImage: "pencil") { editor = ProfileEditor(profile: profile) }
                                Button("Delete", systemImage: "trash", role: .destructive) { deleting = profile }
                                    .disabled(!profiles.canDelete(id: profile.id))
                            }
                        }
                        Button { editor = ProfileEditor() } label: {
                            VStack(spacing: 24) {
                                Image(systemName: "plus").font(.system(size: 56, weight: .light))
                                    .foregroundStyle(VelvetColors.textSecondary)
                                    .frame(width: 170, height: 170)
                                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 32))
                                Text("Add profile").font(VelvetFont.body(26, .semibold)).foregroundStyle(VelvetColors.textSecondary)
                            }.frame(width: 190).padding(10)
                        }.buttonStyle(TVCardButtonStyle()).accessibilityIdentifier("profiles.add")
                    }.padding(35)
                }.scrollIndicators(.hidden).scrollClipDisabled().frame(maxWidth: 1500, maxHeight: 340).focusSection()
                HStack(spacing: 24) {
                    Button(editing ? "Done editing" : "Edit profiles") { editing.toggle() }
                        .buttonStyle(TVGlassButtonStyle())
                        .accessibilityIdentifier("profiles.edit")
                    if profiles.activeProfile != nil && settings.profileChosenThisLaunch {
                        Button("Close") { settings.profilePickerRequested = false; onSelect?() }
                            .buttonStyle(TVGlassButtonStyle())
                    }
                }.frame(maxWidth: .infinity).focusSection()
            }.padding(TVLayout.edge)
        }
        .sheet(item: $editor) { entry in
            TVProfileEditorView(profile: entry.profile) { id in
                if entry.profile == nil { profiles.select(id: id); onSelect?() }
            }
        }
        .confirmationDialog("Delete profile?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        ), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let profile = deleting { profiles.delete(id: profile.id) }
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: { Text("Other profiles and their watch history will stay unchanged.") }
    }
}

private struct TVProfileEditorView: View {
    let profile: Profile?
    let onSave: (String) -> Void
    @EnvironmentObject private var profiles: ProfileStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var error: String?
    @State private var confirmDelete = false

    var body: some View {
        ZStack {
            TVBackdrop().ignoresSafeArea()
            VStack(alignment: .leading, spacing: 28) {
                TVSectionHeader(title: profile == nil ? "Make yourself at home" : "Rename profile",
                                subtitle: "Keep your watch history, favorites, and categories personal.")
                TextField("Name", text: $name).font(VelvetFont.body(28))
                    .padding(22).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
                    .accessibilityIdentifier("profiles.name")
                if let error { Text(error).foregroundStyle(VelvetColors.danger).font(VelvetFont.body(23)) }
                HStack(spacing: 25) {
                    Button("Save") { save() }.buttonStyle(TVGlassButtonStyle(prominent: true))
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("profiles.save")
                    Button("Cancel") { dismiss() }.buttonStyle(TVGlassButtonStyle())
                    if let profile, profiles.canDelete(id: profile.id) {
                        Button("Delete profile", role: .destructive) { confirmDelete = true }
                            .buttonStyle(TVGlassButtonStyle()).accessibilityIdentifier("profiles.delete")
                    }
                }
            }.frame(maxWidth: 900).padding(70)
        }
        .onAppear { name = profile?.name ?? "" }
        .confirmationDialog("Delete this profile?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let profile { profiles.delete(id: profile.id) }
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Other profiles and their watch history will stay unchanged.") }
    }

    private func save() {
        if let profile {
            guard profiles.rename(id: profile.id, to: name) else { error = "That name is already in use."; return }
            onSave(profile.id)
        } else {
            guard let id = profiles.create(name: name) else { error = "That name is already in use."; return }
            onSave(id)
        }
        dismiss()
    }
}
