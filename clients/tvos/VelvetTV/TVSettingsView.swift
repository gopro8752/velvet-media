import SwiftUI

struct TVSettingsView: View {
    @EnvironmentObject private var container: AppContainer
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var profiles: ProfileStore
    @State private var backendDraft = ""
    @State private var tokenDraft = ""
    @State private var connectionMessage: String?
    @State private var rowsPresented = false

    var body: some View {
        ZStack {
            TVBackdrop().ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 38) {
                    TVSectionHeader(title: "Settings", subtitle: "Your screen. Your way.")
                    HStack(alignment: .top, spacing: 42) {
                        VStack(alignment: .leading, spacing: 24) {
                            sectionTitle("Your Velvet server", icon: "externaldrive.connected.to.line.below")
                            Text("Connect once for discovery, playback, Live TV, sports, and your watch history. Metadata and AI credentials stay on your server.")
                                .font(VelvetFont.body(20)).foregroundStyle(VelvetColors.textSecondary)
                            TextField("https://backend.example.com", text: $backendDraft)
                                .autocorrectionDisabled().textInputAutocapitalization(.never)
                                .accessibilityIdentifier("settings.backendURL")
                            SecureField("Access token (optional)", text: $tokenDraft)
                                .autocorrectionDisabled().textInputAutocapitalization(.never)
                                .accessibilityIdentifier("settings.token")
                            HStack(spacing: 22) {
                                Button("Save connection") { saveConnection() }
                                    .buttonStyle(TVGlassButtonStyle(prominent: true))
                                    .accessibilityIdentifier("settings.saveConnection")
                                Button("Sync now") { container.sync.syncNow() }
                                    .buttonStyle(TVGlassButtonStyle())
                                    .disabled(settings.backendUrl.isEmpty)
                            }
                            if let connectionMessage {
                                Text(connectionMessage).font(VelvetFont.body(19)).foregroundStyle(VelvetColors.textSecondary)
                            }
                            if !settings.lastSyncStatus.isEmpty {
                                Text(settings.lastSyncStatus).font(VelvetFont.body(18)).foregroundStyle(VelvetColors.textSecondary)
                            }
                            Toggle("Sync watch history and profiles", isOn: $settings.syncEnabled)
                                .disabled(settings.backendUrl.isEmpty)
                        }.padding(34).frame(maxWidth: .infinity, alignment: .leading).background(panel)
                        VStack(alignment: .leading, spacing: 24) {
                            sectionTitle("Playback", icon: "play.rectangle")
                            Toggle("Autoplay next episode", isOn: $settings.autoplayNext)
                            Picker("Up Next countdown", selection: $settings.autoplayCountdownSecs) {
                                ForEach([5, 8, 10, 15], id: \.self) { Text("\($0) seconds").tag($0) }
                            }.disabled(!settings.autoplayNext)
                            Picker("Preferred quality", selection: $settings.preferredQuality) {
                                Text("4K · 2160p").tag("2160p")
                                Text("Full HD · 1080p").tag("1080p")
                                Text("HD · 720p").tag("720p")
                            }
                            Toggle("Hardware decoding", isOn: $settings.hardwareDecoding)
                            Text("Playback uses compatible sources for this Apple TV. Live channels use the quality supplied by your provider.")
                                .font(VelvetFont.body(18)).foregroundStyle(VelvetColors.textTertiary)
                        }.padding(34).frame(maxWidth: .infinity, alignment: .leading).background(panel)
                    }
                    HStack(alignment: .top, spacing: 42) {
                        VStack(alignment: .leading, spacing: 24) {
                            sectionTitle("Make yourself at home", icon: "rectangle.stack")
                            Button { rowsPresented = true } label: { Label("Choose Home rows", systemImage: "rectangle.grid.1x2") }
                                .buttonStyle(TVGlassButtonStyle())
                            Text("Show or hide discovery rows. Your Continue Watching, My List, and personal collections remain close at hand.")
                                .font(VelvetFont.body(20)).foregroundStyle(VelvetColors.textSecondary)
                        }.padding(34).frame(maxWidth: .infinity, alignment: .leading).background(panel)
                        VStack(alignment: .leading, spacing: 24) {
                            sectionTitle("Who's watching", icon: "person.crop.circle")
                            Text(profiles.activeProfile?.name ?? "Choose a profile").font(VelvetFont.display(30))
                            Button("Switch or manage profiles") { settings.profilePickerRequested = true }
                                .buttonStyle(TVGlassButtonStyle())
                            Text("Apple TV · \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")")
                                .font(VelvetFont.body(18)).foregroundStyle(VelvetColors.textTertiary)
                        }.padding(34).frame(maxWidth: .infinity, alignment: .leading).background(panel)
                    }
                }.padding(.horizontal, 80).padding(.vertical, 42).padding(.bottom, 60)
            }
        }
        .ignoresSafeArea(edges: .horizontal)
        .onAppear { backendDraft = settings.backendUrl; tokenDraft = settings.syncToken }
        .sheet(isPresented: $rowsPresented) { TVHomeRowsSettings() }
    }

    private var panel: some View {
        RoundedRectangle(cornerRadius: 30).fill(.ultraThinMaterial)
            .overlay(RoundedRectangle(cornerRadius: 30).stroke(.white.opacity(0.09), lineWidth: 1))
    }

    private func sectionTitle(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon).font(VelvetFont.display(28, .semibold))
    }

    private func saveConnection() {
        let value = SettingsStore.normalizeBaseUrl(backendDraft)
        guard value.isEmpty || (URL(string: value).map {
            ["https", "http"].contains($0.scheme?.lowercased() ?? "") && $0.host != nil && $0.user == nil && $0.password == nil && $0.query == nil && $0.fragment == nil
        } == true) else {
            connectionMessage = "Enter an http:// or https:// server address without embedded credentials, a query, or a fragment."
            return
        }
        settings.syncToken = tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.setBackendUrl(value)
        backendDraft = value
        connectionMessage = value.isEmpty ? "Server disconnected." : "Connection saved. Your library will refresh from this server."
        if !value.isEmpty { container.sync.syncNow() }
    }
}

private struct TVHomeRowsSettings: View {
    @EnvironmentObject private var container: AppContainer
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            TVBackdrop()
            VStack(alignment: .leading, spacing: 26) {
                TVSectionHeader(title: "Home rows", subtitle: "Choose what you want to discover.")
                ScrollView {
                    LazyVStack(spacing: 16) {
                        ForEach(container.tmdb.allRows, id: \.id) { row in
                            Button { toggle(row.id) } label: {
                                HStack {
                                    Text(row.title)
                                    Spacer()
                                    Image(systemName: enabledIDs.contains(row.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(VelvetColors.accent)
                                }.frame(maxWidth: .infinity).padding(8)
                            }.buttonStyle(TVGlassButtonStyle())
                        }
                    }.padding(16)
                }
                HStack(spacing: 24) {
                    Button("Reset to default") { settings.disabledRowIds = []; settings.rowOrder = [] }
                        .buttonStyle(TVGlassButtonStyle())
                    Button("Done") { dismiss() }.buttonStyle(TVGlassButtonStyle(prominent: true))
                }
            }.padding(70).frame(maxWidth: 1300)
        }
    }

    private func toggle(_ id: String) {
        var disabled = Set(settings.disabledRowIds)
        var order = enabledIDs
        if let index = order.firstIndex(of: id) {
            // Empty rowOrder means defaults, so keep at least one discovery row.
            guard order.count > 1 else { return }
            order.remove(at: index)
            disabled.insert(id)
        } else {
            order.append(id)
            disabled.remove(id)
        }
        settings.disabledRowIds = container.tmdb.allRows.map(\.id).filter { disabled.contains($0) }
        settings.rowOrder = order
    }

    private var enabledIDs: [String] {
        let all = container.tmdb.allRows.map(\.id)
        let disabled = Set(settings.disabledRowIds)
        guard !settings.rowOrder.isEmpty else { return all.filter { !disabled.contains($0) } }
        let known = Set(all)
        let seasonal = Set(container.tmdb.seasonalRowIds())
        let order = settings.rowOrder.filter { known.contains($0) && !disabled.contains($0) }
        return order + all.filter { seasonal.contains($0) && !order.contains($0) && !disabled.contains($0) }
    }
}
