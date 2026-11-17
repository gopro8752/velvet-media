import SwiftUI

/// tvOS owns text entry (including Siri Remote dictation); no microphone session
/// is opened just because this sheet appears.
struct TVCreateCategoryView: View {
    @ObservedObject var vm: HomeViewModel
    @EnvironmentObject private var profiles: ProfileStore
    @Environment(\.dismiss) private var dismiss
    @State private var prompt = ""
    @State private var submitted = false

    private let examples = ["Cartoon Network shows from 2009", "Christmas episodes of my favorite sitcoms", "Star Wars movies in story order"]

    var body: some View {
        ZStack {
            TVBackdrop()
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 18) {
                    Image(systemName: "sparkles").font(.system(size: 38)).foregroundStyle(VelvetColors.accent)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Make it your own").font(VelvetFont.display(44, .semibold))
                        Text("A collection for \(profiles.activeProfile?.name ?? "you")")
                            .font(VelvetFont.body(21)).foregroundStyle(VelvetColors.textSecondary)
                    }
                }
                Text("Describe movies, whole shows, or specific episodes. Add an era or a viewing order if you like.")
                    .font(VelvetFont.body(23)).foregroundStyle(VelvetColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("What would you like to watch?", text: $prompt)
                    .font(VelvetFont.body(25)).autocorrectionDisabled()
                    .disabled(vm.isGeneratingCategory)
                    .accessibilityIdentifier("category.prompt")
                Text("Select the field to type, or use dictation on the system keyboard.")
                    .font(VelvetFont.body(18)).foregroundStyle(VelvetColors.textTertiary)
                if prompt.isEmpty && !vm.isGeneratingCategory {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(examples, id: \.self) { example in
                            Button { prompt = example } label: {
                                Label(example, systemImage: "wand.and.stars").font(VelvetFont.body(19))
                            }.buttonStyle(TVGlassButtonStyle())
                        }
                    }
                }
                if let error = vm.categoryError {
                    Text(error).font(VelvetFont.body(20)).foregroundStyle(VelvetColors.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if prompt.count > 500 {
                    Text("Keep your description under 500 characters.").font(VelvetFont.body(20)).foregroundStyle(VelvetColors.danger)
                }
                HStack(spacing: 24) {
                    Button {
                        submitted = true
                        vm.createCategory(prompt: prompt)
                    } label: {
                        HStack(spacing: 14) {
                            if vm.isGeneratingCategory { ProgressView() }
                            Label(vm.isGeneratingCategory ? "Creating your collection…" : "Create collection", systemImage: "sparkles")
                        }
                    }
                    .buttonStyle(TVGlassButtonStyle(prominent: true))
                    .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || prompt.count > 500 || vm.isGeneratingCategory)
                    .accessibilityIdentifier("category.create")
                    Button("Close") { dismiss() }.buttonStyle(TVGlassButtonStyle())
                }
                Text("Your collection appears on Home. Play in order or shuffle, and remove it whenever you like.")
                    .font(VelvetFont.body(18)).foregroundStyle(VelvetColors.textTertiary)
            }
            .frame(maxWidth: 1100).padding(70)
        }
        .onAppear { vm.categoryError = nil }
        .onChange(of: vm.isGeneratingCategory) { wasGenerating, generating in
            if submitted && wasGenerating && !generating && vm.categoryError == nil { dismiss() }
        }
    }
}
