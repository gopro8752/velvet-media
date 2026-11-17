import SwiftUI

struct TVServiceConfiguration: Hashable {
    let sources: [StreamSourceConfig]
    let syncURL: String
    let token: String
    let profile: String

    @MainActor init(_ settings: SettingsStore) {
        sources = settings.streamSources
        syncURL = settings.syncUrl
        token = settings.syncToken
        profile = settings.activeProfileId ?? ProfileStore.defaultId
    }

    @MainActor var connection: LiveConnection? {
        LiveConnection(baseUrl: SettingsStore.normalizeBaseUrl(sources.first { $0.enabled }?.baseUrl ?? syncURL),
                       syncUrl: SettingsStore.normalizeBaseUrl(syncURL), token: token)
    }

    @MainActor var favoriteKey: String {
        LiveGuidePolicy.favoriteKey(backend: SettingsStore.normalizeBaseUrl(sources.first { $0.enabled }?.baseUrl ?? syncURL), profile: profile)
    }
}

@MainActor
private final class TVGuideModel: ObservableObject {
    @Published var channels: [LiveChannel] = []
    @Published var schedules: [String: LiveChannelSchedule] = [:]
    @Published var loading = false
    @Published var enabled = false
    @Published var error: String?
    @Published var message: String?
    @Published var guideUnavailable = false
    @Published var lastProgramEnd: Date?
    private let client: LiveTVServing
    private var generation = UUID()

    init(client: LiveTVServing) { self.client = client }

    func reload(reset: Bool = false) async {
        let current = UUID()
        generation = current
        loading = true
        error = nil
        if reset { channels = []; schedules = [:]; lastProgramEnd = nil }
        defer { if generation == current { loading = false } }
        async let guide = try? client.guide()
        do {
            let catalog = try await client.channels()
            guard !Task.isCancelled, generation == current else { return }
            enabled = catalog.enabled
            channels = catalog.enabled ? catalog.uniqueChannels : []
            message = catalog.message
        } catch is CancellationError { return }
        catch {
            guard !Task.isCancelled, generation == current else { return }
            self.error = error.localizedDescription
        }
        let schedule = await guide
        guard !Task.isCancelled, generation == current else { return }
        if let schedule {
            schedules = Dictionary(schedule.channels.map { ($0.channelId, $0) }, uniquingKeysWith: { first, _ in first })
            lastProgramEnd = schedule.channels.lazy.flatMap(\.programs).map(\.endTime).max()
        }
        guideUnavailable = schedule == nil
    }
}

struct TVLiveTVView: View {
    @EnvironmentObject private var container: AppContainer
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        TVGuideContent(client: container.liveTV, configuration: TVServiceConfiguration(settings))
    }
}

private struct TVGuideSelection: Identifiable {
    let id = UUID()
    let channel: LiveChannel
    let program: LiveProgram?
}

private struct TVGuideContent: View {
    @StateObject private var vm: TVGuideModel
    @State private var search = ""
    @State private var favorites = Set<String>()
    @State private var onlyFavorites = false
    @State private var browsingStart: Date?
    @State private var highlighted: TVGuideSelection?
    @State private var detail: TVGuideSelection?
    @State private var pendingPlayback: LiveChannel?
    @State private var playTarget: LivePlayTarget?
    let configuration: TVServiceConfiguration

    init(client: LiveTVServing, configuration: TVServiceConfiguration) {
        _vm = StateObject(wrappedValue: TVGuideModel(client: client))
        self.configuration = configuration
    }

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.periodic(from: .now, by: 30)) { clock in
                let now = clock.date
                let start = browsingStart ?? LiveGuidePolicy.windowStart(at: now)
                let channelWidth: CGFloat = 242
                let timelineWidth = max(480, geometry.size.width - 160 - channelWidth - 72)
                VStack(alignment: .leading, spacing: 18) {
                    header(now)
                    preview(now)
                    controls(now: now, start: start)
                    if vm.guideUnavailable && !vm.channels.isEmpty {
                        Text("Program listings are temporarily unavailable. You can still tune any channel.")
                            .font(VelvetFont.body(18)).foregroundStyle(VelvetColors.textSecondary)
                    }
                    if vm.loading && vm.channels.isEmpty {
                        ProgressView("Loading your guide…").frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if vm.channels.isEmpty {
                        TVServiceEmptyState(title: vm.error == nil ? "Connect your Live TV" : "Couldn't load Live TV",
                                            message: vm.error ?? vm.message ?? "Enable Live TV on your Velvet server to see your channels here.") {
                            Task { await vm.reload() }
                        }
                    } else {
                        guide(now: now, start: start, channelWidth: channelWidth, timelineWidth: timelineWidth)
                    }
                }.padding(.horizontal, 80).padding(.top, 30).padding(.bottom, 20)
            }
        }
        .background { TVBackdrop().ignoresSafeArea() }
        .ignoresSafeArea(edges: .horizontal)
        .task(id: configuration) {
            favorites = Set(UserDefaults.standard.stringArray(forKey: configuration.favoriteKey) ?? [])
            browsingStart = nil
            highlighted = nil
            await vm.reload(reset: true)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000_000)
                guard !Task.isCancelled else { return }
                await vm.reload()
            }
        }
        .sheet(item: $detail, onDismiss: {
            if let channel = pendingPlayback {
                pendingPlayback = nil
                playTarget = LivePlayTarget(channel: channel)
            }
        }) { selected in
            TVGuideProgramSheet(selection: selected, favorite: favorites.contains(selected.channel.id),
                                toggleFavorite: { toggleFavorite(selected.channel) },
                                watch: { pendingPlayback = selected.channel; detail = nil })
        }
        .fullScreenCover(item: $playTarget) { target in
            TVLivePlayerView(channel: target.channel, channels: vm.channels)
        }
    }

    private func header(_ now: Date) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Live TV").font(VelvetFont.display(46, .semibold))
            Text(now, format: .dateTime.weekday(.wide).month(.abbreviated).day())
                .font(VelvetFont.body(21)).foregroundStyle(VelvetColors.textSecondary)
            Spacer()
            Text(now, format: .dateTime.hour().minute()).font(VelvetFont.body(25, .medium)).monospacedDigit()
        }
    }

    private func preview(_ now: Date) -> some View {
        let channel = highlighted?.channel ?? vm.channels.first
        let program = highlighted?.program ?? channel.flatMap { vm.schedules[$0.id]?.now(at: now) }
        return HStack(spacing: 30) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 14) {
                    if let channel { Text(channel.name).foregroundStyle(VelvetColors.accent) }
                    if let program {
                        if LiveGuidePolicy.isLive(program, at: now) { Label("ON NOW", systemImage: "circle.fill").foregroundStyle(VelvetColors.match) }
                        Text("\(program.startTime.formatted(date: .omitted, time: .shortened)) – \(program.endTime.formatted(date: .omitted, time: .shortened))")
                            .foregroundStyle(VelvetColors.textSecondary)
                    }
                }.font(VelvetFont.body(17, .semibold))
                Text(program?.title ?? "Find your next favorite moment").font(VelvetFont.display(34, .semibold)).lineLimit(1)
                Text(program?.description ?? "Browse channels and upcoming programs. Select what's on now to watch; select a future program for details.")
                    .font(VelvetFont.body(21)).foregroundStyle(VelvetColors.textSecondary).lineLimit(2)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if let url = program?.imageUrl ?? channel?.logoUrl {
                AsyncImage(url: url) { image in image.resizable().scaledToFit() } placeholder: { Color.clear }
                    .frame(width: 230, height: 120).clipShape(RoundedRectangle(cornerRadius: 18))
            }
        }.frame(height: 155, alignment: .topLeading)
    }

    private func controls(now: Date, start: Date) -> some View {
        HStack(spacing: 22) {
            TextField("Search channels or programs", text: $search)
                .font(VelvetFont.body(21)).autocorrectionDisabled().frame(maxWidth: 460)
                .accessibilityIdentifier("live.guide.search")
            Button { onlyFavorites.toggle() } label: {
                Label(onlyFavorites ? "Favorites" : "All channels", systemImage: onlyFavorites ? "star.fill" : "rectangle.grid.1x2")
            }.buttonStyle(TVGlassButtonStyle()).accessibilityIdentifier("live.guide.filter")
            Spacer(minLength: 10)
            Button { browsingStart = start.addingTimeInterval(-LiveGuidePolicy.windowDuration) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(TVGlassButtonStyle()).disabled(start <= LiveGuidePolicy.windowStart(at: now))
                .accessibilityLabel("Previous two hours")
            Button("Now") { browsingStart = nil }.buttonStyle(TVGlassButtonStyle())
            Button { browsingStart = start.addingTimeInterval(LiveGuidePolicy.windowDuration) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(TVGlassButtonStyle()).disabled(start >= lastWindow(now: now))
                .accessibilityLabel("Next two hours")
            Button { Task { await vm.reload() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(TVGlassButtonStyle()).disabled(vm.loading).accessibilityLabel("Refresh guide")
        }.font(VelvetFont.body(20, .medium)).padding(.bottom, 8)
    }

    private func guide(now: Date, start: Date, channelWidth: CGFloat, timelineWidth: CGFloat) -> some View {
        let channels = vm.channels.filter {
            (!onlyFavorites || favorites.contains($0.id)) && LiveGuidePolicy.matches(search, channel: $0, schedule: vm.schedules[$0.id], at: now)
        }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 0) {
                Text("\(channels.count) channels").frame(width: channelWidth + 72, alignment: .leading)
                ForEach(0..<4) { slot in
                    Text(start.addingTimeInterval(Double(slot) * LiveGuidePolicy.slotDuration), format: .dateTime.hour().minute())
                        .frame(width: timelineWidth / 4, alignment: .leading)
                }
            }.font(VelvetFont.body(18, .medium)).foregroundStyle(VelvetColors.textSecondary).padding(.vertical, 10)
            if channels.isEmpty {
                TVServiceEmptyState(title: "Nothing here yet", message: onlyFavorites ? "Star a channel to add it to your favorites, or switch to All channels." : "Try a different channel or program name.", retry: nil)
            } else {
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(channels) { channel in
                            HStack(spacing: 0) {
                                TVGuideCell {
                                    playTarget = LivePlayTarget(channel: channel)
                                } focused: {
                                    highlighted = TVGuideSelection(channel: channel, program: vm.schedules[channel.id]?.now(at: now))
                                } label: {
                                    HStack(spacing: 14) {
                                        if let url = channel.logoUrl {
                                            AsyncImage(url: url) { image in image.resizable().scaledToFit() } placeholder: { Image(systemName: "tv") }
                                                .frame(width: 45, height: 45)
                                        }
                                        VStack(alignment: .leading, spacing: 5) {
                                            if let number = channel.number { Text(number).font(VelvetFont.body(17)).foregroundStyle(VelvetColors.textSecondary) }
                                            Text(channel.name).font(VelvetFont.body(19, .semibold)).lineLimit(2)
                                        }
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }.frame(width: channelWidth - 12).accessibilityIdentifier("live.channel.\(channel.id)")
                                Button { toggleFavorite(channel) } label: {
                                    Image(systemName: favorites.contains(channel.id) ? "star.fill" : "star")
                                        .foregroundStyle(favorites.contains(channel.id) ? VelvetColors.gold : VelvetColors.textTertiary)
                                }.buttonStyle(TVGlassButtonStyle()).frame(width: 84)
                                    .accessibilityLabel(favorites.contains(channel.id) ? "Remove \(channel.name) from favorites" : "Favorite \(channel.name)")
                                    .accessibilityIdentifier("live.favorite.\(channel.id)")
                                    .accessibilityValue(favorites.contains(channel.id) ? "Favorite" : "Not favorite")
                                if search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    timeline(channel: channel, now: now, start: start, width: timelineWidth)
                                } else {
                                    searchResult(channel: channel, now: now).frame(width: timelineWidth)
                                }
                            }.frame(height: 98).focusSection()
                        }
                    }.padding(.horizontal, 12).padding(.vertical, 20).padding(.bottom, 35)
                }.padding(.horizontal, -12)
            }
        }
    }

    private func timeline(channel: LiveChannel, now: Date, start: Date, width: CGFloat) -> some View {
        let segments = LiveGuidePolicy.segments(schedule: vm.schedules[channel.id], from: start, to: start.addingTimeInterval(LiveGuidePolicy.windowDuration))
        return HStack(spacing: 0) {
            ForEach(segments) { segment in
                let cellWidth = width * segment.end.timeIntervalSince(segment.start) / LiveGuidePolicy.windowDuration
                TVGuideCell {
                    select(channel: channel, program: segment.program, now: now)
                } focused: {
                    highlighted = TVGuideSelection(channel: channel, program: segment.program)
                } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        if cellWidth > 100 {
                            Text(segment.program?.title ?? "No listing available").font(VelvetFont.body(19, .semibold)).lineLimit(2)
                            if let program = segment.program, LiveGuidePolicy.isLive(program, at: now) {
                                ProgressView(value: LiveGuidePolicy.progress(program, at: now)).tint(VelvetColors.accent)
                            }
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }
                .frame(width: max(1, cellWidth - 8)).padding(.trailing, 8)
                .accessibilityLabel("\(channel.name), \(segment.program?.title ?? "No program listing")")
                .accessibilityIdentifier("live.program.\(channel.id).\(segment.program?.id ?? "gap")")
            }
        }
    }

    private func searchResult(channel: LiveChannel, now: Date) -> some View {
        let schedule = vm.schedules[channel.id]
        let program = LiveGuidePolicy.matchingPrograms(search, schedule: schedule, at: now).first ?? schedule?.now(at: now)
        return TVGuideCell { select(channel: channel, program: program, now: now) } focused: {
            highlighted = TVGuideSelection(channel: channel, program: program)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(program?.title ?? "Watch \(channel.name)").font(VelvetFont.body(22, .semibold))
                if let program {
                    Text(program.startTime, format: .dateTime.weekday(.abbreviated).hour().minute())
                        .font(VelvetFont.body(17)).foregroundStyle(VelvetColors.textSecondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func select(channel: LiveChannel, program: LiveProgram?, now: Date) {
        if let program, !LiveGuidePolicy.isLive(program, at: now) { detail = TVGuideSelection(channel: channel, program: program) }
        else { playTarget = LivePlayTarget(channel: channel) }
    }

    private func lastWindow(now: Date) -> Date {
        LiveGuidePolicy.lastWindowStart(lastProgramEnd: vm.lastProgramEnd ?? now, now: now)
    }

    private func toggleFavorite(_ channel: LiveChannel) {
        if favorites.contains(channel.id) { favorites.remove(channel.id) } else { favorites.insert(channel.id) }
        UserDefaults.standard.set(favorites.sorted(), forKey: configuration.favoriteKey)
    }
}

private struct TVGuideCell<Content: View>: View {
    let action: () -> Void
    let focused: () -> Void
    @ViewBuilder let label: () -> Content
    @FocusState private var hasFocus: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Button(action: action) { label().padding(15).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading) }
            .buttonStyle(TVServiceCardButtonStyle()).focused($hasFocus)
            .background(hasFocus ? VelvetColors.accent.opacity(0.24) : Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(hasFocus ? Color.white.opacity(0.95) : Color.white.opacity(0.07), lineWidth: hasFocus ? 3 : 1))
            .shadow(color: hasFocus ? VelvetColors.accent.opacity(0.28) : .clear, radius: 16)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hasFocus)
            .onChange(of: hasFocus) { _, value in if value { focused() } }
    }
}

/// A custom style avoids tvOS's oversized automatic white focus platter. The
/// guide and sports cards draw their own precise focus outline and glow.
struct TVServiceCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(VelvetColors.textPrimary)
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

private struct TVGuideProgramSheet: View {
    let selection: TVGuideSelection
    @State var favorite: Bool
    let toggleFavorite: () -> Void
    let watch: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        ZStack {
            TVBackdrop(url: selection.program?.imageUrl)
            VStack(alignment: .leading, spacing: 26) {
                Text(selection.channel.name).font(VelvetFont.body(24, .semibold)).foregroundStyle(VelvetColors.accent)
                Text(selection.program?.title ?? selection.channel.name).font(VelvetFont.display(48, .semibold))
                if let program = selection.program {
                    Text(program.startTime, format: .dateTime.weekday(.wide).month(.abbreviated).day().hour().minute())
                        .font(VelvetFont.body(22)).foregroundStyle(VelvetColors.textSecondary)
                    Text(program.description ?? program.episodeTitle ?? "No description available.")
                        .font(VelvetFont.body(25)).fixedSize(horizontal: false, vertical: true)
                    Text("Upcoming programs are listings. Watch channel opens the live broadcast.")
                        .font(VelvetFont.body(19)).foregroundStyle(VelvetColors.textSecondary)
                }
                HStack(spacing: 24) {
                    Button("Watch channel", action: watch).buttonStyle(TVGlassButtonStyle(prominent: true))
                    Button(favorite ? "Remove favorite" : "Favorite channel") { toggleFavorite(); favorite.toggle() }.buttonStyle(TVGlassButtonStyle())
                    Button("Close") { dismiss() }.buttonStyle(TVGlassButtonStyle())
                }
            }.frame(maxWidth: 1200, alignment: .leading).padding(80)
        }
    }
}

struct TVServiceEmptyState: View {
    let title: String
    let message: String
    var retry: (() -> Void)?
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "sparkles.tv").font(.system(size: 45)).foregroundStyle(VelvetColors.accent)
            Text(title).font(VelvetFont.display(32, .semibold))
            Text(message).font(VelvetFont.body(22)).foregroundStyle(VelvetColors.textSecondary).multilineTextAlignment(.center).frame(maxWidth: 1000)
            if let retry { Button("Try again", action: retry).buttonStyle(TVGlassButtonStyle()) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(35)
    }
}
