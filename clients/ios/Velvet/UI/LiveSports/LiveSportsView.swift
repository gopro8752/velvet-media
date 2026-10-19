import SwiftUI

@MainActor
final class LiveSportsViewModel: ObservableObject {
    @Published private(set) var catalog: SportsCatalog?
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published var scope = SportsScope.live
    @Published var sportID = ""
    @Published var search = ""
    private var requestID = UUID()
    private let client: LiveSportsServing

    init(client: LiveSportsServing) { self.client = client }

    var visibleEvents: [SportsEvent] {
        let now = Date()
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen = Set<String>()
        return (catalog?.events ?? []).filter { event in
            seen.insert(event.id).inserted && scope.includes(event, now: now)
                && (sportID.isEmpty || event.sportId == sportID)
                && (query.isEmpty || event.title.localizedCaseInsensitiveContains(query)
                    || event.sportName.localizedCaseInsensitiveContains(query)
                    || event.homeTeam?.name.localizedCaseInsensitiveContains(query) == true
                    || event.awayTeam?.name.localizedCaseInsensitiveContains(query) == true)
        }.sorted { a, b in
            if a.isLive != b.isLive { return a.isLive }
            if a.startTime != b.startTime { return a.startTime < b.startTime }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }

    func reload() async {
        let generation = UUID()
        requestID = generation
        loading = true
        error = nil
        defer { if requestID == generation { loading = false } }
        do {
            let value = try await client.events(scope: scope)
            guard !Task.isCancelled, requestID == generation else { return }
            catalog = value
            if !value.sports.contains(where: { $0.id == sportID }) { sportID = "" }
        } catch is CancellationError { return }
        catch {
            guard !Task.isCancelled, requestID == generation else { return }
            self.error = error.localizedDescription
        }
    }
}

struct LiveSportsView: View {
    @EnvironmentObject private var container: AppContainer
    @EnvironmentObject private var settings: SettingsStore
    var body: some View {
        LiveSportsContent(client: container.liveSports,
                          configuration: SportsConfiguration(sources: settings.streamSources,
                                                             syncURL: settings.syncUrl, token: settings.syncToken))
    }
}

private struct SportsConfiguration: Hashable {
    let sources: [StreamSourceConfig]
    let syncURL: String
    let token: String
}

private struct SportsRequestKey: Hashable {
    let configuration: SportsConfiguration
    let scope: SportsScope
}

private struct LiveSportsContent: View {
    @EnvironmentObject private var settings: SettingsStore
    @StateObject private var vm: LiveSportsViewModel
    @State private var selectedEvent: SportsEvent?
    @State private var playTarget: SportsPlayTarget?
    @State private var pendingPlayTarget: SportsPlayTarget?
    let client: LiveSportsServing
    let configuration: SportsConfiguration
    init(client: LiveSportsServing, configuration: SportsConfiguration) {
        self.client = client
        self.configuration = configuration
        _vm = StateObject(wrappedValue: LiveSportsViewModel(client: client))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) { scopePicker; sportPicker }
                    VStack(alignment: .leading, spacing: 12) { scopePicker; sportPicker }
                }
                Text("Events from Streamed")
                    .font(VelvetFont.body(13)).foregroundStyle(VelvetColors.textSecondary)
                if let message = vm.catalog?.message, !message.isEmpty {
                    Text(message).font(VelvetFont.body(14)).foregroundStyle(VelvetColors.textSecondary)
                }
                if let error = vm.error {
                    emptyState(title: "Couldn't load events", message: error)
                } else if vm.loading && vm.catalog == nil {
                    ProgressView("Loading events…").frame(maxWidth: .infinity, minHeight: 200)
                } else if vm.catalog?.enabled == false {
                    emptyState(title: "Live Sports isn't available yet", message: "Refresh when your server is ready.")
                } else if vm.visibleEvents.isEmpty {
                    emptyState(title: "No matching events", message: vm.scope == .live
                               ? "Try Today or Upcoming, or choose another sport."
                               : "Try another sport or search.")
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16)], spacing: 16) {
                        ForEach(vm.visibleEvents) { event in
                            Button { selectedEvent = event } label: { SportsEventCard(event: event) }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("sports.event.\(event.id)")
                                .accessibilityLabel("\(event.title), \(event.isLive ? "Live" : event.startTime.formatted(date: .abbreviated, time: .shortened))")
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 1600, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(VelvetColors.background.ignoresSafeArea())
        .navigationTitle("Live Sports")
        .searchable(text: $vm.search, prompt: "Find a team or event")
        .refreshable { await vm.reload() }
        .task(id: SportsRequestKey(configuration: configuration, scope: vm.scope)) { await vm.reload() }
        .sheet(item: $selectedEvent, onDismiss: {
            playTarget = pendingPlayTarget
            pendingPlayTarget = nil
        }) { event in
            SportsStreamPicker(event: event, client: client) { streams, selected in
                pendingPlayTarget = SportsPlayTarget(event: event, streams: streams, selectedID: selected.selectionID)
                selectedEvent = nil
            }
        }
        .landscapePlayerPresenter(item: $playTarget) { target in SportsPlayerView(target: target, settings: settings) }
    }

    private var scopePicker: some View {
        Picker("Events", selection: $vm.scope) {
            ForEach(SportsScope.allCases) { scope in Text(scope.title).tag(scope) }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 420)
        .accessibilityIdentifier("sports.scope")
    }

    private var sportPicker: some View {
        Menu {
            Picker("Sport", selection: $vm.sportID) {
                Text("All sports").tag("")
                ForEach(vm.catalog?.sports ?? []) { sport in Text(sport.name).tag(sport.id) }
            }
        } label: {
            Label(vm.catalog?.sports.first(where: { $0.id == vm.sportID })?.name ?? "All sports",
                  systemImage: "line.3.horizontal.decrease.circle")
                .font(VelvetFont.body(15, .semibold))
                .padding(.vertical, 9)
        }
        .accessibilityIdentifier("sports.sportFilter")
    }

    private func emptyState(title: String, message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "sportscourt").font(.system(size: 34)).foregroundStyle(VelvetColors.accent)
            Text(title).font(VelvetFont.display(22, .semibold))
            Text(message).font(VelvetFont.body(15)).foregroundStyle(VelvetColors.textSecondary)
                .multilineTextAlignment(.center)
            Button("Refresh") { Task { await vm.reload() } }.disabled(vm.loading)
        }
        .padding(28).frame(maxWidth: .infinity, minHeight: 220)
        .background(RoundedRectangle(cornerRadius: 18).fill(VelvetColors.surface))
    }
}

private struct SportsEventCard: View {
    let event: SportsEvent
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack {
                Rectangle().fill(VelvetColors.surfaceElevated)
                if let poster = event.posterUrl {
                    AsyncImage(url: poster) { image in image.resizable().scaledToFill() }
                        placeholder: { teamBadges }
                } else { teamBadges }
            }
            .frame(height: 142).clipped()
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text(event.sportName).foregroundStyle(VelvetColors.textSecondary)
                    Spacer()
                    if event.isLive {
                        Label("LIVE", systemImage: "circle.fill").foregroundStyle(.red)
                    } else if event.popular { Image(systemName: "star.fill").foregroundStyle(VelvetColors.accent) }
                }.font(VelvetFont.body(12, .semibold))
                Text(event.title).font(VelvetFont.display(19, .semibold)).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(event.startTime, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
                    .font(VelvetFont.body(13)).foregroundStyle(VelvetColors.textSecondary)
                Text(event.isLive ? "Choose stream" : "Event details")
                    .font(VelvetFont.body(13, .semibold)).foregroundStyle(VelvetColors.accent)
            }.padding([.horizontal, .bottom], 16)
        }
        .background(VelvetColors.surface).clipShape(RoundedRectangle(cornerRadius: 17))
    }

    private var teamBadges: some View {
        HStack(spacing: 28) {
            if let home = event.homeTeam, let away = event.awayTeam {
                badge(home); Text("VS").font(VelvetFont.body(14, .semibold)).foregroundStyle(VelvetColors.textTertiary); badge(away)
            } else { Image(systemName: "sportscourt.fill").font(.system(size: 44)).foregroundStyle(VelvetColors.accent) }
        }
    }
    private func badge(_ team: SportsTeam) -> some View {
        AsyncImage(url: team.badgeUrl) { image in image.resizable().scaledToFit() }
            placeholder: { Text(String(team.name.prefix(3))).font(VelvetFont.display(20, .bold)) }
            .frame(width: 72, height: 72)
    }
}

private struct SportsStreamPicker: View {
    let event: SportsEvent
    let client: LiveSportsServing
    let onPlay: ([SportsStream], SportsStream) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var response: SportsStreams?
    @State private var error: String?
    @State private var reloadID = UUID()
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(event.title).font(VelvetFont.display(25, .semibold))
                    Text(event.startTime, format: .dateTime.weekday().month().day().hour().minute())
                        .font(VelvetFont.body(15)).foregroundStyle(VelvetColors.textSecondary)
                    if let error {
                        Text(error).foregroundStyle(VelvetColors.textSecondary)
                        Button("Retry") { reloadID = UUID() }
                    } else if let response {
                        if let message = response.message { Text(message).foregroundStyle(VelvetColors.textSecondary) }
                        if response.streams.isEmpty {
                            Text("No streams are available yet. Check again closer to the event.")
                                .foregroundStyle(VelvetColors.textSecondary)
                            Button("Refresh") { reloadID = UUID() }
                        }
                        ForEach(response.streams, id: \.selectionID) { stream in
                            Button { onPlay(response.streams, stream) } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: "play.circle.fill").font(.system(size: 25))
                                    Text(stream.label).font(VelvetFont.body(16, .semibold))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }.padding(18).background(RoundedRectangle(cornerRadius: 14).fill(VelvetColors.surface))
                            }.buttonStyle(.plain).accessibilityIdentifier("sports.stream.\(stream.source).\(stream.streamNo)")
                        }
                    } else { ProgressView("Finding streams…").frame(maxWidth: .infinity, minHeight: 100) }
                }.padding(24)
            }
            .background(VelvetColors.background)
            .navigationTitle("Choose stream").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task(id: reloadID) {
                response = nil; error = nil
                do {
                    let value = try await client.streams(eventID: event.id)
                    guard !Task.isCancelled else { return }
                    response = value
                } catch is CancellationError { }
                catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            }
        }
        .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }
}
