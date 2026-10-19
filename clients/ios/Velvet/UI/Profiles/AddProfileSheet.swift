import SwiftUI

/// "Add Profile" sheet — a single name field; the color is auto-assigned (next
/// unused palette entry). Save creates the profile and selects it (→ Home).
/// Styling: header row, surfaceElevated field, medium detent, drag indicator.
struct AddProfileSheet: View {
    @EnvironmentObject private var profiles: ProfileStore
    @Environment(\.dismiss) private var dismiss

    /// Called with the new profile id after Save, so the presenter can select it
    /// and dismiss the picker to Home.
    var onCreated: (String) -> Void

    @State private var name = ""
    /// Inline rejection text (spec §1a) — set when Save hits a name collision;
    /// cleared on the next keystroke so the field never nags while retyping.
    @State private var errorText: String?
    @FocusState private var focused: Bool

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var canSave: Bool { !trimmedName.isEmpty }

    /// The color this profile will get — previewed in the avatar swatch.
    private var previewColor: Color {
        Color(hex: profiles.nextColor().profileColorHex)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 20)

            HStack(spacing: 14) {
                // Avatar preview: the auto color + the first initial as you type.
                Circle()
                    .fill(previewColor)
                    .overlay(
                        Text(trimmedName.first.map { String($0).uppercased() } ?? "?")
                            .font(VelvetFont.display(24, .semibold))
                            .foregroundStyle(VelvetColors.textPrimary)
                    )
                    .frame(width: 56, height: 56)
                nameField
            }
            .padding(.horizontal, 16)

            if let errorText {
                Text(errorText)
                    .font(VelvetFont.body(12, .semibold))
                    .foregroundStyle(VelvetColors.danger)
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .transition(.opacity)
            } else {
                Text("A color is assigned automatically. You can rename or remove a profile later.")
                    .font(VelvetFont.body(12))
                    .foregroundStyle(VelvetColors.textTertiary)
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
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

    private var header: some View {
        HStack {
            Button("Cancel") { dismiss() }
                .font(VelvetFont.body(15))
                .foregroundStyle(VelvetColors.textSecondary)
            Spacer()
            Text("Add Profile")
                .font(VelvetFont.display(16, .semibold))
                .foregroundStyle(VelvetColors.textPrimary)
            Spacer()
            Button("Save") { save() }
                .font(VelvetFont.body(15, .semibold))
                .foregroundStyle(canSave ? VelvetColors.accent : VelvetColors.textTertiary)
                .disabled(!canSave)
        }
    }

    private var nameField: some View {
        ZStack(alignment: .leading) {
            if name.isEmpty {
                Text("Name (e.g. Sarah)")
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
                    if errorText != nil { withAnimation(.easeInOut(duration: 0.15)) { errorText = nil } }
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

    /// Spec §1a: a duplicate name is REJECTED — the sheet stays open, shows the
    /// error inline, and nothing is created.
    private func save() {
        guard canSave else { return }
        guard let id = profiles.create(name: trimmedName) else {
            withAnimation(.easeInOut(duration: 0.15)) {
                errorText = "A profile named '\(trimmedName)' already exists."
            }
            return
        }
        dismiss()
        onCreated(id)
    }
}
