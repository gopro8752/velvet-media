import SwiftUI
import UIKit

private let countdownChoices = [5, 8, 10, 15]
private let qualityChoices = ["2160p", "1080p", "720p"]

/// One Home row as displayed in Settings: enabled rows first (in user order),
/// then disabled rows in default order — same shape as the Android HomeRowEntry.
private struct HomeRowEntry: Identifiable {
    let spec: RowSpec
    let enabled: Bool
    /// A seasonal row outside its active window: listed so it can be pinned,
    /// but never on Home and never enabled by default (spec §4f).
    let outOfSeason: Bool
    var id: String { spec.id }
}

/// Settings tab — Velvet-styled List, port of the Android SettingsScreen
/// (~/velvet/.../ui/settings/SettingsScreen.kt + SettingsViewModel.kt).
/// All bindings write straight onto SettingsStore @Published vars; the store
/// persists to UserDefaults automatically.
struct SettingsView: View {
    @EnvironmentObject private var container: AppContainer
    @EnvironmentObject private var settings: SettingsStore

    /// Edit mode for the List, toggled by the Home Rows "Reorder" button so the
    /// drag handles are discoverable (long-press drag works outside it too).
    @State private var rowsEditMode: EditMode = .inactive
    /// Local draft for the TMDB key field — committed on submit / focus loss,
    /// NOT per keystroke (TmdbClient reads the key at request time, so live
    /// partial prefixes would break in-flight Home/Search requests). A field
    /// cleared on commit removes the configured key.
    @State private var tmdbKeyDraft = ""
    @State private var tmdbKeyDraftLoaded = false
    @FocusState private var tmdbKeyFocused: Bool
    /// Local draft for the single backend URL — committed on submit / focus loss
    /// like the TMDB key: a live binding would fire the sync engine's URL-change
    /// full reconcile on every keystroke.
    @State private var backendUrlDraft = ""
    @State private var backendUrlDraftLoaded = false
    @FocusState private var backendUrlFocused: Bool

    var body: some View {
        ZStack {
            VelvetColors.background.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                Text("Settings")
                    .font(VelvetFont.display(30, .bold))
                    .foregroundStyle(VelvetColors.textPrimary)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                settingsList
            }
            // Native grouped controls keep their phone layout and a comfortable
            // reading width when the available iPad window is much wider.
            .frame(maxWidth: 860)
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            if !tmdbKeyDraftLoaded {
                tmdbKeyDraft = settings.tmdbApiKey
                tmdbKeyDraftLoaded = true
            }
            if !backendUrlDraftLoaded {
                backendUrlDraft = settings.backendUrl
                backendUrlDraftLoaded = true
            }
        }
    }

    private var settingsList: some View {
        List {
            backendSection
            homeRowsSection
            playbackSection
            tmdbSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .environment(\.editMode, $rowsEditMode)
    }

    // MARK: - Backend

    /// One URL drives everything: streaming resolution AND watch-state sync, since
    /// the monolith backend serves both on a single origin. Committing the field
    /// calls settings.setBackendUrl, which installs the sole stream source, sets
    /// the sync server, and enables sync in one write.
    private var backendSection: some View {
        Section {
            TextField("Backend URL", text: $backendUrlDraft)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(VelvetColors.textPrimary)
                .tint(VelvetColors.textPrimary)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .focused($backendUrlFocused)
                .onSubmit { commitBackendUrl() }
                .onChange(of: backendUrlFocused) { _, focused in
                    if !focused { commitBackendUrl() }
                }
                .listRowBackground(VelvetColors.surfaceElevated)

            TextField("Token (optional)", text: $settings.syncToken)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(VelvetColors.textPrimary)
                .tint(VelvetColors.textPrimary)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.asciiCapable)
                .listRowBackground(VelvetColors.surfaceElevated)

            Button {
                container.sync.syncNow()
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Label {
                        Text("Sync Now")
                            .font(VelvetFont.body(15, .semibold))
                    } icon: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    .foregroundStyle(backendReady ? VelvetColors.accent : VelvetColors.textTertiary)
                    Text(settings.lastSyncStatus.isEmpty ? "Not synced yet" : settings.lastSyncStatus)
                        .font(VelvetFont.body(12))
                        .foregroundStyle(VelvetColors.textTertiary)
                }
            }
            .disabled(!backendReady)
            .listRowBackground(VelvetColors.surfaceElevated)
        } header: {
            sectionHeader("Backend")
        } footer: {
            footerText("One URL for discovery, streaming and watch-state sync, e.g. https://backend.example.com. Leave the token empty unless your backend requires one.")
        }
    }

    private var backendReady: Bool {
        !SettingsStore.normalizeBaseUrl(settings.backendUrl).isEmpty
    }

    /// Commit on submit / focus loss only — setBackendUrl writes the sync URL,
    /// which fires the sync engine's URL-change reconcile; must not run per
    /// keystroke.
    private func commitBackendUrl() {
        let normalized = SettingsStore.normalizeBaseUrl(backendUrlDraft)
        backendUrlDraft = normalized
        if normalized != settings.backendUrl {
            settings.setBackendUrl(normalized)
        }
    }

    // MARK: - Home Rows

    private var homeRowsSection: some View {
        Section {
            ForEach(rowEntries) { entry in
                Button {
                    withAnimation { toggleRow(entry.id) }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: entry.enabled ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 20))
                            .foregroundStyle(entry.enabled ? VelvetColors.accent : VelvetColors.textTertiary)
                        Text(entry.spec.title)
                            .font(VelvetFont.body(15, .semibold))
                            .foregroundStyle(entry.enabled ? VelvetColors.textPrimary : VelvetColors.textTertiary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if entry.outOfSeason {
                            Text("Out of season")
                                .font(VelvetFont.body(12))
                                .foregroundStyle(VelvetColors.textTertiary)
                                .lineLimit(1)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .moveDisabled(!entry.enabled)
                .listRowBackground(VelvetColors.surfaceElevated)
            }
            .onMove(perform: moveRows)

            Button {
                withAnimation {
                    settings.disabledRowIds = []
                    settings.rowOrder = []
                }
            } label: {
                Label {
                    Text("Reset to default")
                        .font(VelvetFont.body(15, .semibold))
                } icon: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .foregroundStyle(VelvetColors.accent)
            }
            .listRowBackground(VelvetColors.surfaceElevated)
        } header: {
            HStack {
                sectionHeader("Home Rows")
                Spacer()
                Button(rowsEditMode.isEditing ? "Done" : "Reorder") {
                    withAnimation {
                        rowsEditMode = rowsEditMode.isEditing ? .inactive : .active
                    }
                }
                .font(VelvetFont.body(13, .semibold))
                .foregroundStyle(VelvetColors.accent)
            }
        } footer: {
            footerText("Rows appear on Home in this order. Tap to show or hide a row; drag to reorder. Holiday rows only appear during their season, and jump to the top while they're on.")
        }
    }

    private var allRows: [RowSpec] { container.tmdb.allRows }

    private var seasonalIds: Set<String> { Set(container.tmdb.seasonalRowIds()) }

    private func isOutOfSeason(_ rowId: String) -> Bool {
        seasonalIds.contains(rowId) && !container.tmdb.isSeasonalRowActive(rowId)
    }

    /// The default enabled set (no stored order): every row EXCEPT seasonal
    /// rows outside their window — those would be enabled-by-default noise
    /// (spec §4f). They stay listed below so they can still be pinned.
    private var defaultEnabledIds: [String] {
        let disabled = Set(settings.disabledRowIds)
        return allRows.map(\.id).filter { !isOutOfSeason($0) && !disabled.contains($0) }
    }

    /// rowOrder if non-empty (filtered to known ids), else the default enabled
    /// set in default order — the Android effectiveEnabledOrder() plus the
    /// seasonal-window rule.
    ///
    /// Seasonal rows missing from the stored order are appended once they come
    /// INTO season, unless explicitly disabled: the order is materialized from
    /// whatever was in season on the day it was written, so treating "absent"
    /// as "hidden" would bury every other holiday row forever (spec §4f). Same
    /// rule as HomeViewModel.resolveSpecs, so Settings and Home agree.
    private var effectiveOrder: [String] {
        let knownIds = Set(allRows.map(\.id))
        let order = settings.rowOrder.filter { knownIds.contains($0) }
        guard !order.isEmpty else { return defaultEnabledIds }
        let present = Set(order)
        let disabled = Set(settings.disabledRowIds)
        let seasonalExtras = allRows.map(\.id).filter {
            seasonalIds.contains($0) && !present.contains($0)
                && !disabled.contains($0) && !isOutOfSeason($0)
        }
        return order + seasonalExtras
    }

    private var rowEntries: [HomeRowEntry] {
        let byId = Dictionary(uniqueKeysWithValues: allRows.map { ($0.id, $0) })
        let enabledSpecs = effectiveOrder.compactMap { byId[$0] }
        let enabledIds = Set(enabledSpecs.map(\.id))
        let disabledSpecs = allRows.filter { !enabledIds.contains($0.id) }
        return enabledSpecs.map {
            HomeRowEntry(spec: $0, enabled: true, outOfSeason: isOutOfSeason($0.id))
        } + disabledSpecs.map {
            HomeRowEntry(spec: $0, enabled: false, outOfSeason: isOutOfSeason($0.id))
        }
    }

    /// Include/exclude a row. The first edit materializes the full default list
    /// (an empty persisted order means "all enabled"), then modifies it;
    /// re-enabled rows are appended to the end of the enabled list.
    ///
    /// A hide is ALSO recorded in `disabledRowIds`: for a seasonal row, dropping
    /// it from the order is indistinguishable from it merely being out of season
    /// when the order was written, so only the explicit set can keep it off.
    private func toggleRow(_ rowId: String) {
        var order = effectiveOrder
        var disabled = Set(settings.disabledRowIds)
        if let index = order.firstIndex(of: rowId) {
            // Never allow zero enabled rows: an empty persisted order means "all
            // enabled", so removing the last entry would re-enable everything.
            guard order.count > 1 else { return }
            order.remove(at: index)
            disabled.insert(rowId)
        } else {
            guard allRows.contains(where: { $0.id == rowId }) else { return }
            order.append(rowId)
            disabled.remove(rowId)
        }
        // Write the disable set FIRST: the rowOrder change is what Home
        // subscribes to, and it must re-resolve against the new membership.
        settings.disabledRowIds = allRows.map(\.id).filter { disabled.contains($0) }
        settings.rowOrder = order
    }

    /// Drag-to-reorder. Enabled entries occupy indices 0..<enabledCount of the
    /// displayed list (disabled rows are moveDisabled), so the offsets map 1:1
    /// onto the effective order; the drop position is clamped into that range.
    private func moveRows(from source: IndexSet, to destination: Int) {
        var order = effectiveOrder
        let enabledCount = order.count
        guard source.allSatisfy({ $0 < enabledCount }) else { return }
        order.move(fromOffsets: source, toOffset: min(destination, enabledCount))
        settings.rowOrder = order
    }

    // MARK: - Playback

    private var playbackSection: some View {
        Section {
            Toggle(isOn: $settings.autoplayNext) {
                VStack(alignment: .leading, spacing: 2) {
                    rowTitle("Autoplay next episode")
                    rowCaption("Start the next episode automatically with a countdown")
                }
            }
            .tint(VelvetColors.accent)
            .listRowBackground(VelvetColors.surfaceElevated)

            Picker(selection: $settings.autoplayCountdownSecs) {
                ForEach(countdownChoices, id: \.self) { secs in
                    Text("\(secs)s").tag(secs)
                }
            } label: {
                rowTitle("Up next countdown")
            }
            .pickerStyle(.menu)
            .listRowBackground(VelvetColors.surfaceElevated)

            Picker(selection: $settings.preferredQuality) {
                ForEach(qualityChoices, id: \.self) { quality in
                    Text(quality).tag(quality)
                }
            } label: {
                rowTitle("Preferred quality")
            }
            .pickerStyle(.menu)
            .listRowBackground(VelvetColors.surfaceElevated)

            Toggle(isOn: $settings.hardwareDecoding) {
                rowTitle("Hardware decoding")
            }
            .tint(VelvetColors.accent)
            .listRowBackground(VelvetColors.surfaceElevated)
        } header: {
            sectionHeader("Playback")
        } footer: {
            footerText("Turn off if video misbehaves.")
        }
    }

    // MARK: - TMDB

    private var tmdbSection: some View {
        Section {
            if !settings.backendUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Label("Managed by your backend", systemImage: "checkmark.shield")
                    .foregroundStyle(VelvetColors.textPrimary)
                    .listRowBackground(VelvetColors.surfaceElevated)
            } else {
                SecureField("TMDB API key (standalone)", text: $tmdbKeyDraft)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(VelvetColors.textPrimary)
                    .tint(VelvetColors.textPrimary)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.asciiCapable)
                    .focused($tmdbKeyFocused)
                    .onSubmit { commitTmdbKey() }
                    .onChange(of: tmdbKeyFocused) { _, focused in
                        if !focused { commitTmdbKey() }
                    }
                    .listRowBackground(VelvetColors.surfaceElevated)
            }
        } header: {
            sectionHeader("Discovery & artwork")
        } footer: {
            footerText(settings.backendUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                       ? "Connect a Velvet backend to use its metadata service, or enter your own TMDB key for standalone discovery."
                       : "Discovery and search use your backend’s TMDB connection. Its API key stays on the server; no key is needed on this device.")
        }
    }

    /// Commit on submit / focus loss only — never per keystroke. An empty
    /// commit removes the saved key. Public builds have no bundled fallback.
    private func commitTmdbKey() {
        guard settings.backendUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let trimmed = tmdbKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            settings.tmdbApiKey = SettingsStore.defaultTmdbKey
            tmdbKeyDraft = SettingsStore.defaultTmdbKey
        } else if trimmed != settings.tmdbApiKey {
            settings.tmdbApiKey = trimmed
        }
    }

    // MARK: - shared styling

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(VelvetFont.display(15, .semibold))
            .foregroundStyle(VelvetColors.textSecondary)
            .textCase(nil)
    }

    private func footerText(_ text: String) -> some View {
        Text(text)
            .font(VelvetFont.body(12))
            .foregroundStyle(VelvetColors.textTertiary)
    }

    private func rowTitle(_ text: String) -> some View {
        Text(text)
            .font(VelvetFont.body(15, .semibold))
            .foregroundStyle(VelvetColors.textPrimary)
    }

    private func rowCaption(_ text: String) -> some View {
        Text(text)
            .font(VelvetFont.body(12))
            .foregroundStyle(VelvetColors.textTertiary)
    }
}
