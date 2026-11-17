import SwiftUI

@MainActor
private final class TVSportsModel: ObservableObject {
    @Published var catalog: SportsCatalog?
    @Published var loading = false
    @Published var error: String?
    @Published var scope = SportsScope.live
    @Published var sportID = ""
    @Published var search = ""
    private let client: LiveSportsServing
    private var generation = UUID()

    init(client: LiveSportsServing) { self.client = client }

    var events: [SportsEvent] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Date()
        var seen = Set<String>()
        return (catalog?.events ?? []).filter {
            seen.insert($0.id).inserted && scope.includes($0, now: now)
                && (sportID.isEmpty || $0.sportId == sportID)
                && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)
                    || $0.sportName.localizedCaseInsensitiveContains(query)
                    || $0.homeTeam?.name.localizedCaseInsensitiveContains(query) == true
                    || $0.awayTeam?.name.localizedCaseInsensitiveContains(query) == true)
        }.sorted {
            if $0.isLive != $1.isLive { return $0.isLive }
            if $0.startTime != $1.startTime { return $0.startTime < $1.startTime }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    func reload(reset: Bool = false) async {
        let request = UUID()
        generation = request
        loading = true
        error = nil
        if reset { catalog = nil }
        defer { if request == generation { loading = false } }
        do {
            let result = try await client.events(scope: scope)
            guard !Task.isCancelled, request == generation else { return }
            catalog = result
            if !result.sports.contains(where: { $0.id == sportID }) { sportID = "" }
        } catch is CancellationError { return }
        catch {
            guard !Task.isCancelled, request == generation else { return }
            self.error = error.localizedDescription
        }
    }
}

struct TVSportsView: View {
    @EnvironmentObject private var container: AppContainer
    @EnvironmentObject private var settings: SettingsStore
    var body: some View {
        TVSportsContent(client: container.liveSports, releaseClient: container.liveTV, configuration: TVServiceConfiguration(settings))
    }
}

private struct TVSportsRequest: Hashable {
    let configuration: TVServiceConfiguration
    let scope: SportsScope
}

private struct TVSportsPlayback: Identifiable {
    let id = UUID()
    let channel: LiveChannel
    let client: TVNativeSportsClient
}

private struct TVSportsContent: View {
    @StateObject private var vm: TVSportsModel
    @State private var event: SportsEvent?
    @State private var pendingPlayback: TVSportsPlayback?
    @State private var playback: TVSportsPlayback?
    let client: LiveSportsServing
    let releaseClient: LiveTVServing
    let configuration: TVServiceConfiguration

    init(client: LiveSportsServing, releaseClient: LiveTVServing, configuration: TVServiceConfiguration) {
        _vm = StateObject(wrappedValue: TVSportsModel(client: client))
        self.client = client
        self.releaseClient = releaseClient
        self.configuration = configuration
    }

    var body: some View {
        ZStack {
            TVBackdrop().ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    TVSectionHeader(title: "Live Sports", subtitle: "The moment is everything.")
                    HStack(spacing: 25) {
                        ForEach(SportsScope.allCases) { scope in
                            Button(scope.title) { vm.scope = scope }
                                .buttonStyle(TVGlassButtonStyle(prominent: vm.scope == scope))
                        }
                        Spacer()
                        TextField("Find a team or event", text: $vm.search).frame(maxWidth: 480)
                            .font(VelvetFont.body(22)).autocorrectionDisabled()
                            .accessibilityIdentifier("sports.search")
                        Button { Task { await vm.reload() } } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(TVGlassButtonStyle()).disabled(vm.loading).accessibilityLabel("Refresh sports")
                    }
                    if !(vm.catalog?.sports.isEmpty ?? true) {
                        Picker("Sport", selection: $vm.sportID) {
                            Text("All sports").tag("")
                            ForEach(vm.catalog?.sports ?? []) { sport in Text(sport.name).tag(sport.id) }
                        }.frame(maxWidth: 550)
                    }
                    if let message = vm.catalog?.message, !message.isEmpty {
                        Text(message).font(VelvetFont.body(21)).foregroundStyle(VelvetColors.textSecondary)
                    }
                    if vm.loading && vm.catalog == nil {
                        ProgressView("Finding the action…").frame(maxWidth: .infinity, minHeight: 350)
                    } else if let error = vm.error {
                        TVServiceEmptyState(title: "Couldn't load events", message: error) { Task { await vm.reload() } }
                    } else if vm.catalog?.enabled == false {
                        TVServiceEmptyState(title: "Connect Live Sports", message: "Enable Live Sports on your Velvet server to browse events here.") { Task { await vm.reload() } }
                    } else if vm.events.isEmpty {
                        TVServiceEmptyState(title: "No matching events", message: vm.scope == .live ? "Try Today or Upcoming, or choose another sport." : "Try another team, sport, or day.") { Task { await vm.reload() } }
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 420), spacing: 32)], spacing: 32) {
                            ForEach(vm.events) { item in
                                TVSportsEventCard(event: item) { event = item }
                                    .accessibilityIdentifier("sports.event.\(item.id)")
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10).focusSection()
                    }
                    if let source = vm.catalog?.sourceName, !source.isEmpty {
                        Text("Events from \(source)").font(VelvetFont.body(17)).foregroundStyle(VelvetColors.textTertiary)
                    }
                }.padding(.horizontal, 80).padding(.top, 40).padding(.bottom, 100)
            }
        }
        .ignoresSafeArea(edges: .horizontal)
        .task(id: TVSportsRequest(configuration: configuration, scope: vm.scope)) {
            await vm.reload(reset: true)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 120_000_000_000)
                guard !Task.isCancelled else { return }
                await vm.reload()
            }
        }
        .sheet(item: $event, onDismiss: {
            playback = pendingPlayback
            pendingPlayback = nil
        }) { selected in
            TVSportsSources(event: selected, client: client) { stream in
                guard let connection = configuration.connection else { return }
                let native = TVNativeSportsClient(event: selected, stream: stream, connection: connection, releaseClient: releaseClient)
                pendingPlayback = TVSportsPlayback(channel: native.channel, client: native)
                event = nil
            }
        }
        .fullScreenCover(item: $playback) { item in
            TVLivePlayerView(channel: item.channel, client: item.client, telemetryKind: "live_sports")
        }
    }
}

private struct TVSportsEventCard: View {
    let event: SportsEvent
    let action: () -> Void
    @FocusState private var focused: Bool
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 17) {
                ZStack(alignment: .bottomLeading) {
                    RoundedRectangle(cornerRadius: 21).fill(VelvetColors.surfaceHighlight)
                    if let poster = event.posterUrl {
                        AsyncImage(url: poster) { image in image.resizable().scaledToFill() } placeholder: { badges }
                    } else { badges }
                    LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .center, endPoint: .bottom)
                    HStack {
                        Text(event.sportName.uppercased()).font(VelvetFont.body(15, .semibold)).tracking(1)
                        Spacer()
                        if event.isLive { Label("LIVE", systemImage: "circle.fill").font(VelvetFont.body(15, .bold)).foregroundStyle(VelvetColors.match) }
                    }.padding(20)
                }.frame(height: 230).clipped().clipShape(RoundedRectangle(cornerRadius: 21))
                Text(event.title).font(VelvetFont.display(25, .semibold)).lineLimit(2).frame(height: 68, alignment: .topLeading)
                HStack {
                    Text(event.startTime, format: .dateTime.weekday(.abbreviated).hour().minute())
                    Spacer()
                    Text(event.sourceCount == 1 ? "1 source" : "\(event.sourceCount) sources")
                }.font(VelvetFont.body(17)).foregroundStyle(VelvetColors.textSecondary)
            }.padding(18).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 30))
        }
        .buttonStyle(TVServiceCardButtonStyle()).focused($focused)
        .overlay(RoundedRectangle(cornerRadius: 30).strokeBorder(focused ? Color.white : .white.opacity(0.08), lineWidth: focused ? 3 : 1))
        .scaleEffect(focused ? 1.025 : 1).shadow(color: focused ? VelvetColors.accent.opacity(0.3) : .clear, radius: 24)
        .animation(.easeOut(duration: 0.18), value: focused)
    }

    private var badges: some View {
        HStack(spacing: 28) {
            badge(event.awayTeam?.badgeUrl)
            Text("VS").font(VelvetFont.display(25, .semibold)).foregroundStyle(VelvetColors.textTertiary)
            badge(event.homeTeam?.badgeUrl)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func badge(_ url: URL?) -> some View {
        AsyncImage(url: url) { image in image.resizable().scaledToFit() } placeholder: {
            Image(systemName: "sportscourt").resizable().scaledToFit().foregroundStyle(VelvetColors.accent.opacity(0.6))
        }.frame(width: 80, height: 80)
    }
}

private struct TVSportsSources: View {
    let event: SportsEvent
    let client: LiveSportsServing
    let play: (SportsStream) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var result: SportsStreams?
    @State private var loading = true
    @State private var error: String?
    var body: some View {
        ZStack {
            TVBackdrop(url: event.posterUrl)
            VStack(alignment: .leading, spacing: 30) {
                Text(event.sportName).font(VelvetFont.body(22, .semibold)).foregroundStyle(VelvetColors.accent)
                Text(event.title).font(VelvetFont.display(46, .semibold))
                if loading { ProgressView("Finding sources…") }
                else if let error {
                    Text(error).font(VelvetFont.body(23)).foregroundStyle(VelvetColors.textSecondary)
                    Button("Try again") { Task { await load() } }.buttonStyle(TVGlassButtonStyle())
                } else if result?.streams.isEmpty ?? true {
                    Text(result?.message ?? "No streams are available for this event yet. Try again closer to its start time.")
                        .font(VelvetFont.body(23)).foregroundStyle(VelvetColors.textSecondary)
                    Button("Refresh sources") { Task { await load() } }.buttonStyle(TVGlassButtonStyle())
                } else {
                    ScrollView {
                        VStack(spacing: 20) {
                            ForEach(result?.streams ?? [], id: \.selectionID) { stream in
                                Button { play(stream) } label: {
                                    HStack {
                                        Image(systemName: "play.fill")
                                        Text(stream.label)
                                        Spacer()
                                        if stream.hd { Text("HD").foregroundStyle(VelvetColors.accent) }
                                    }.frame(maxWidth: .infinity).padding(8)
                                }.buttonStyle(TVGlassButtonStyle()).accessibilityIdentifier("sports.source.\(stream.id).\(stream.streamNo)")
                            }
                        }.padding(20)
                    }.frame(maxHeight: 450)
                }
                Button("Close") { dismiss() }.buttonStyle(TVGlassButtonStyle())
            }.frame(maxWidth: 1120, alignment: .leading).padding(70)
        }.task { await load() }
    }

    private func load() async {
        loading = true
        error = nil
        defer { loading = false }
        do { result = try await client.streams(eventID: event.id) }
        catch is CancellationError { return }
        catch { self.error = error.localizedDescription }
    }
}

/// The backend validates catalog identifiers and returns the same revocable HLS
/// lease as Live TV. tvOS never loads the provider's browser embed or accepts a
/// provider URL from a tune response.
private final class TVSportsRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

@MainActor
final class TVNativeSportsClient: LiveTVServing {
    let channel: LiveChannel
    private let event: SportsEvent
    private let stream: SportsStream
    private let connection: LiveConnection
    private let releaseClient: LiveTVServing
    private let session: URLSession
    private static let networkSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration, delegate: TVSportsRedirectPolicy(), delegateQueue: nil)
    }()

    init(event: SportsEvent, stream: SportsStream, connection: LiveConnection, releaseClient: LiveTVServing,
         session: URLSession? = nil) {
        self.event = event
        self.stream = stream
        self.connection = connection
        self.releaseClient = releaseClient
        self.session = session ?? Self.networkSession
        channel = LiveChannel(id: event.id, name: event.title, number: nil, logoUrl: event.posterUrl, group: "Live Sports")
    }

    func channels() async throws -> LiveChannelCatalog {
        LiveChannelCatalog(enabled: true, sourceName: "Live Sports", channels: [channel], message: nil)
    }

    func guide() async throws -> LiveGuide {
        LiveGuide(enabled: false, sourceName: "Live Sports", updatedAt: nil, channels: [], message: nil)
    }

    func tune(channelID: String) async throws -> LiveSession {
        guard channelID == event.id else { throw LiveTVError.invalidResponse }
        struct TuneRequest: Encodable {
            let eventId: String
            let streamId: String
            let source: String
            let streamNo: Int
        }
        var request = URLRequest(url: connection.endpoint("sports/tune"))
        request.httpMethod = "POST"
        request.timeoutInterval = 85
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("tvos", forHTTPHeaderField: "X-Velvet-Client")
        request.setValue("hls-clear", forHTTPHeaderField: "X-Velvet-Playback-Capabilities")
        if !connection.token.isEmpty { request.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONEncoder().encode(TuneRequest(eventId: event.id, streamId: stream.id, source: stream.source, streamNo: stream.streamNo))
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw LiveTVError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            struct Failure: Decodable { let error: String }
            let message = (try? JSONDecoder().decode(Failure.self, from: data))?.error
            throw SportsError.message(message.map { String($0.prefix(300)) }
                ?? "This event couldn't start. Choose another source or try again.")
        }
        struct Allocation: Decodable { let sessionId: String }
        guard let allocation = try? JSONDecoder().decode(Allocation.self, from: data),
              LiveFairPlayConfiguration.safeReference(allocation.sessionId),
              let allocatedURL = connection.playbackURL("/live/streams/\(allocation.sessionId)/index.m3u8") else {
            throw LiveTVError.invalidResponse
        }
        let provisional = LiveSession(id: allocation.sessionId, channel: channel, playbackURL: allocatedURL, connection: connection)
        guard let tune = try? JSONDecoder().decode(LiveTuneResponse.self, from: data), tune.channel.id == event.id,
              tune.mimeType == "application/vnd.apple.mpegurl", tune.drm == nil,
              tune.playbackPath == "/live/streams/\(allocation.sessionId)/index.m3u8",
              let playbackURL = connection.playbackURL(tune.playbackPath), !Task.isCancelled else {
            await releaseClient.release(provisional)
            if Task.isCancelled { throw CancellationError() }
            throw LiveTVError.invalidResponse
        }
        return LiveSession(id: tune.sessionId, channel: tune.channel, playbackURL: playbackURL, connection: connection)
    }

    func release(_ session: LiveSession) async { await releaseClient.release(session) }
}
