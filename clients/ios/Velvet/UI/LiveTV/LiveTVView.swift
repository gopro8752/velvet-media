import SwiftUI

@MainActor
final class LiveTVViewModel: ObservableObject {
    @Published private(set) var channels: [LiveChannel] = []
    @Published private(set) var loading = false
    @Published private(set) var enabled = false
    @Published private(set) var message: String?
    @Published private(set) var error: String?
    @Published private(set) var guide: LiveGuide?
    @Published private(set) var schedules: [String: LiveChannelSchedule] = [:]
    @Published private(set) var guideUnavailable = false
    @Published var search = ""
    @Published var selectedChannelID: String?
    private let client: LiveTVServing
    private var requestID = UUID()

    init(client: LiveTVServing) { self.client = client }

    func visibleChannels(at date: Date, favorites: Set<String>, onlyFavorites: Bool) -> [LiveChannel] {
        channels.filter {
            (!onlyFavorites || favorites.contains($0.id))
                && LiveGuidePolicy.matches(search, channel: $0, schedule: schedules[$0.id], at: date)
        }
    }

    func reload(reset: Bool = false) async {
        let id = UUID()
        requestID = id
        loading = true
        error = nil
        if reset {
            channels = []
            guide = nil
            schedules = [:]
        }
        guideUnavailable = false
        async let schedule = try? client.guide()
        defer { if requestID == id { loading = false } }
        do {
            let catalog = try await client.channels()
            guard !Task.isCancelled, requestID == id else { return }
            enabled = catalog.enabled
            channels = catalog.enabled ? catalog.uniqueChannels : []
            message = catalog.message
        } catch is CancellationError {
            return
        } catch {
            guard requestID == id else { return }
            self.error = error.localizedDescription
        }
        let value = await schedule
        guard !Task.isCancelled, requestID == id else { return }
        if let value {
            guide = value
            schedules = Dictionary(value.channels.map { ($0.channelId, $0) }, uniquingKeysWith: { first, _ in first })
        }
        guideUnavailable = value == nil
    }
}

struct LiveTVView: View {
    @EnvironmentObject private var container: AppContainer
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        LiveTVContent(client: container.liveTV, hardwareDecoding: settings.hardwareDecoding,
                      configurationKey: ConfigurationKey(sources: settings.streamSources,
                                                         syncURL: settings.syncUrl, token: settings.syncToken,
                                                         profile: settings.activeProfileId ?? ProfileStore.defaultId))
    }

    fileprivate struct ConfigurationKey: Hashable {
        let sources: [StreamSourceConfig]
        let syncURL: String
        let token: String
        let profile: String
        @MainActor var favoriteKey: String {
            LiveGuidePolicy.favoriteKey(backend: SettingsStore.normalizeBaseUrl(sources.first { $0.enabled }?.baseUrl ?? syncURL),
                                        profile: profile)
        }
    }
}

private enum GuideAppearance {
    static let ink = Color(hex: 0x0B0C14)
    static let plum = Color(hex: 0x252036)
    static let lavender = Color(hex: 0xD0C1FF)
    static let quiet = Color(hex: 0xA3A1B5)
    static let line = Color.white.opacity(0.07)
}

private struct GuideSelection: Identifiable {
    let id = UUID()
    let channel: LiveChannel
    let program: LiveProgram?
}

private struct LiveTVContent: View {
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var vm: LiveTVViewModel
    @State private var playTarget: LivePlayTarget?
    @State private var selection: GuideSelection?
    @State private var pendingPlayback: LiveChannel?
    @State private var favorites = Set<String>()
    @State private var onlyFavorites = false
    @State private var browsingStart: Date?
    let client: LiveTVServing
    let hardwareDecoding: Bool
    let configurationKey: LiveTVView.ConfigurationKey

    init(client: LiveTVServing, hardwareDecoding: Bool, configurationKey: LiveTVView.ConfigurationKey) {
        self.client = client
        self.hardwareDecoding = hardwareDecoding
        self.configurationKey = configurationKey
        _vm = StateObject(wrappedValue: LiveTVViewModel(client: client))
    }

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let wide = geometry.size.width >= 650
                let now = context.date
                let start = browsingStart ?? LiveGuidePolicy.windowStart(at: now)
                let channels = vm.visibleChannels(at: now, favorites: favorites, onlyFavorites: onlyFavorites)
                VStack(spacing: 0) {
                    header(now: now, wide: wide, count: channels.count)
                    controls(now: now, start: start, wide: wide)
                    ScrollView {
                        LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                            if vm.loading && vm.channels.isEmpty {
                                ProgressView("Loading your guide…").tint(GuideAppearance.lavender)
                                    .frame(maxWidth: .infinity, minHeight: 240)
                            } else if vm.channels.isEmpty {
                                statusCard(title: vm.error != nil ? "Couldn't load Live TV" : vm.enabled ? "No channels available" : "Live TV isn't connected yet",
                                           message: vm.error ?? vm.message ?? "Your channels will appear when the server is ready.", retry: true)
                            } else if channels.isEmpty {
                                statusCard(title: onlyFavorites && favorites.isEmpty ? "Your favorites belong here" : "Nothing found",
                                           message: onlyFavorites && favorites.isEmpty ? "Tap a channel's star to keep it close." : "Try a channel, a program title, or an episode name.", retry: false)
                            } else {
                                Section {
                                    ForEach(channels) { channel in
                                        let schedule = vm.schedules[channel.id]
                                        if wide && vm.search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                            timelineRow(channel: channel, schedule: schedule, now: now, start: start,
                                                        width: max(200, geometry.size.width - 48 - 142))
                                        } else {
                                            compactRow(channel: channel, schedule: schedule, now: now, wide: wide)
                                        }
                                    }
                                } header: {
                                    ruler(start: start, now: now, wide: wide && vm.search.isEmpty)
                                }
                            }
                        }
                        .padding(.horizontal, wide ? 24 : 16)
                        .padding(.bottom, 110)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .refreshable { await vm.reload() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background {
            ZStack(alignment: .topTrailing) {
                GuideAppearance.ink
                RadialGradient(colors: [GuideAppearance.plum.opacity(0.9), .clear],
                               center: .topTrailing, startRadius: 30, endRadius: 640)
            }.ignoresSafeArea()
        }
        .navigationTitle("Live TV")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .task(id: configurationKey) {
            favorites = Set(UserDefaults.standard.stringArray(forKey: configurationKey.favoriteKey) ?? [])
            browsingStart = nil
            await vm.reload(reset: true)
            // Refresh the guide quietly, keeping its rows and scroll position.
            while !Task.isCancelled {
                let delay: UInt64 = vm.guide?.enabled == true && vm.guide?.updatedAt == nil
                    ? 30_000_000_000 : 300_000_000_000
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else { return }
                await vm.reload()
            }
        }
        .sheet(item: $selection, onDismiss: {
            if let channel = pendingPlayback {
                pendingPlayback = nil
                watch(channel)
            }
        }) { selected in
            LiveProgramSheet(selection: selected, schedule: vm.schedules[selected.channel.id],
                             favorite: favorites.contains(selected.channel.id),
                             toggleFavorite: { toggleFavorite(selected.channel) },
                             watch: { pendingPlayback = selected.channel; selection = nil })
        }
        .landscapePlayerPresenter(item: $playTarget) { target in
            LivePlayerView(channel: target.channel, channels: vm.channels, client: client,
                           hardwareDecoding: hardwareDecoding, settings: settings) { selected in
                vm.selectedChannelID = selected.id
            }
        }
    }

    private func header(now: Date, wide: Bool, count: Int) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Live TV").font(VelvetFont.display(wide ? 38 : 32, .semibold)).tracking(-0.8)
                Text(now, format: .dateTime.weekday(.wide).month(.abbreviated).day())
                    .font(VelvetFont.body(12)).foregroundStyle(GuideAppearance.quiet)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 7) {
                Text(now, format: .dateTime.hour().minute())
                    .font(VelvetFont.body(wide ? 21 : 17, .medium)).monospacedDigit()
                HStack(spacing: 5) {
                    Circle().fill(GuideAppearance.lavender).frame(width: 4, height: 4)
                    Text("\(count) channels").font(VelvetFont.body(10, .medium))
                }.foregroundStyle(GuideAppearance.quiet)
            }
        }
        .padding(.horizontal, wide ? 28 : 20).padding(.top, 12).padding(.bottom, 22)
        .accessibilityElement(children: .combine)
    }

    private func controls(now: Date, start: Date, wide: Bool) -> some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(GuideAppearance.quiet)
                TextField("Channels, shows, and more", text: $vm.search)
                    .font(VelvetFont.body(14)).autocorrectionDisabled().textInputAutocapitalization(.never)
                    .accessibilityIdentifier("live.guide.search")
                if !vm.search.isEmpty {
                    Button { vm.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .foregroundStyle(GuideAppearance.quiet).accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 16).frame(height: 46)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.white.opacity(0.09)))
            HStack(spacing: 8) {
                filterButton("All channels", systemImage: "rectangle.grid.1x2", selected: !onlyFavorites) { onlyFavorites = false }
                filterButton("Favorites", systemImage: "star", selected: onlyFavorites) { onlyFavorites = true }
                Spacer(minLength: 0)
                if wide {
                    Button { shiftTime(-1, now: now) } label: { Image(systemName: "chevron.left").frame(width: 34, height: 38) }
                        .disabled(start <= LiveGuidePolicy.windowStart(at: now))
                        .accessibilityLabel("Previous two hours")
                    Button {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { browsingStart = nil }
                    } label: {
                        Text("Now").font(VelvetFont.body(13, .semibold)).frame(height: 38)
                    }.accessibilityIdentifier("live.guide.now")
                    Button { shiftTime(1, now: now) } label: { Image(systemName: "chevron.right").frame(width: 34, height: 38) }
                        .disabled(start >= lastGuideWindow(now: now))
                        .accessibilityLabel("Next two hours")
                }
            }.foregroundStyle(GuideAppearance.lavender)
            if let error = vm.error, !vm.channels.isEmpty {
                notice(error)
            } else if vm.guideUnavailable {
                notice("Schedule unavailable. Tap any channel to watch live.")
            } else if let message = vm.guide?.message ?? vm.message, !message.isEmpty {
                notice(message)
            }
        }.padding(.horizontal, wide ? 24 : 16).padding(.bottom, 18)
    }

    private func filterButton(_ title: String, systemImage: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage).font(VelvetFont.body(12, .semibold))
                .padding(.horizontal, 13).frame(height: 36)
                .foregroundStyle(selected ? GuideAppearance.lavender : GuideAppearance.quiet)
                .background(selected ? GuideAppearance.lavender.opacity(0.13) : Color.white.opacity(0.03), in: Capsule())
                .overlay(Capsule().strokeBorder(selected ? GuideAppearance.lavender.opacity(0.2) : .clear))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func notice(_ text: String) -> some View {
        Text(text).font(VelvetFont.body(12)).foregroundStyle(GuideAppearance.quiet)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func ruler(start: Date, now: Date, wide: Bool) -> some View {
        HStack(spacing: 0) {
            Text(wide && !Calendar.current.isDateInToday(start)
                 ? start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()).uppercased() : "CHANNEL")
                .frame(width: wide ? 142 : 94, alignment: .leading)
            if wide {
                ForEach(0..<4) { slot in
                    let time = start.addingTimeInterval(Double(slot) * LiveGuidePolicy.slotDuration)
                    Text(time, format: .dateTime.hour().minute())
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                HStack(spacing: 7) {
                    Circle().fill(GuideAppearance.lavender).frame(width: 4, height: 4)
                    Text(vm.search.isEmpty ? "ON NOW & UP NEXT" : "MATCHING CHANNELS & PROGRAMS")
                }
            }
        }
        .font(VelvetFont.body(10, .semibold)).tracking(1)
        .foregroundStyle(GuideAppearance.quiet)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GuideAppearance.ink.opacity(0.98))
        .overlay(alignment: .bottom) { Rectangle().fill(GuideAppearance.line).frame(height: 1) }
    }

    private func channelRail(_ channel: LiveChannel, wide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { watch(channel) } label: {
                VStack(alignment: .leading, spacing: 7) {
                    GuideChannelLogo(channel: channel).frame(width: wide ? 60 : 50, height: 34)
                    Text(channel.name).font(VelvetFont.body(wide ? 12 : 11, .semibold))
                        .foregroundStyle(VelvetColors.textPrimary).lineLimit(2).multilineTextAlignment(.leading)
                    if let number = channel.number, !number.isEmpty {
                        Text(number).font(VelvetFont.body(10)).foregroundStyle(GuideAppearance.quiet)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("Watch \(channel.name) live")
                .accessibilityIdentifier("live.channel.\(channel.id)")
            HStack(spacing: 0) {
                Button { toggleFavorite(channel) } label: {
                    Image(systemName: favorites.contains(channel.id) ? "star.fill" : "star")
                        .font(.system(size: 12)).frame(width: 40, height: 44)
                }.accessibilityLabel(favorites.contains(channel.id) ? "Remove \(channel.name) from favorites" : "Favorite \(channel.name)")
                    .accessibilityIdentifier("live.favorite.\(channel.id)")
                Button { selection = GuideSelection(channel: channel, program: vm.schedules[channel.id]?.now(at: .now)) } label: {
                    Image(systemName: "calendar").font(.system(size: 12)).frame(width: 40, height: 44)
                }.accessibilityLabel("View \(channel.name) schedule")
                    .accessibilityIdentifier("live.schedule.\(channel.id)")
            }.foregroundStyle(GuideAppearance.lavender.opacity(0.85)).buttonStyle(.plain)
        }
        .frame(width: wide ? 126 : 80, alignment: .leading)
        .padding(.trailing, wide ? 16 : 14)
        .padding(.vertical, 15)
    }

    private func compactRow(channel: LiveChannel, schedule: LiveChannelSchedule?, now: Date, wide: Bool) -> some View {
        let matches = LiveGuidePolicy.matchingPrograms(vm.search, schedule: schedule, at: now)
        return HStack(alignment: .top, spacing: 0) {
            channelRail(channel, wide: false)
            VStack(alignment: .leading, spacing: 10) {
                if !matches.isEmpty {
                    ForEach(matches.prefix(3)) { program in compactProgram(program, channel: channel, now: now) }
                } else {
                    if let current = schedule?.now(at: now) {
                        compactProgram(current, channel: channel, now: now)
                    } else {
                        Button { watch(channel) } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                Text("Watch live").font(VelvetFont.display(17, .medium))
                                Text("Schedule unavailable").font(VelvetFont.body(11)).foregroundStyle(GuideAppearance.quiet)
                            }.frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
                        }.buttonStyle(.plain)
                    }
                    if let next = schedule?.next(at: now) { compactProgram(next, channel: channel, now: now) }
                }
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 17).fill(Color.white.opacity(0.035)))
                .overlay(RoundedRectangle(cornerRadius: 17).strokeBorder(GuideAppearance.line))
                .padding(.vertical, 12)
        }.overlay(alignment: .bottom) { Rectangle().fill(GuideAppearance.line).frame(height: 1) }
    }

    private func compactProgram(_ program: LiveProgram, channel: LiveChannel, now: Date) -> some View {
        let live = LiveGuidePolicy.isLive(program, at: now)
        return Button { selection = GuideSelection(channel: channel, program: program) } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    if live { Circle().fill(GuideAppearance.lavender).frame(width: 4, height: 4) }
                    Text(live ? "ON NOW" : program.startTime.formatted(.dateTime.hour().minute()))
                        .foregroundStyle(live ? GuideAppearance.lavender : GuideAppearance.quiet)
                    if live {
                        Spacer()
                        Text("\(max(1, Int(ceil(program.endTime.timeIntervalSince(now) / 60))))m left").foregroundStyle(GuideAppearance.quiet)
                    }
                }.font(VelvetFont.body(10, .medium))
                Text(program.title).font(VelvetFont.display(live ? 18 : 15, live ? .semibold : .medium))
                    .foregroundStyle(live ? VelvetColors.textPrimary : GuideAppearance.quiet).lineLimit(2)
                if let episode = program.episodeTitle, !episode.isEmpty {
                    Text(episode).font(VelvetFont.body(11)).foregroundStyle(GuideAppearance.quiet).lineLimit(1)
                }
                if live {
                    GeometryReader { geometry in
                        Capsule().fill(Color.white.opacity(0.07))
                            .overlay(alignment: .leading) {
                                Capsule().fill(GuideAppearance.lavender.opacity(0.75))
                                    .frame(width: geometry.size.width * LiveGuidePolicy.progress(program, at: now))
                            }
                    }.frame(height: 2).padding(.top, 5).padding(.bottom, 5)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("live.program.\(channel.id).\(program.id)")
    }

    private func timelineRow(channel: LiveChannel, schedule: LiveChannelSchedule?, now: Date, start: Date, width: CGFloat) -> some View {
        let end = start.addingTimeInterval(LiveGuidePolicy.windowDuration)
        let segments = LiveGuidePolicy.segments(schedule: schedule, from: start, to: end)
        return HStack(spacing: 0) {
            channelRail(channel, wide: true)
            HStack(spacing: 0) {
                ForEach(segments) { segment in
                    let cellWidth = width * segment.end.timeIntervalSince(segment.start) / LiveGuidePolicy.windowDuration
                    Button {
                        if let program = segment.program { selection = GuideSelection(channel: channel, program: program) }
                        else { watch(channel) }
                    } label: {
                        timelineCell(segment: segment, now: now, width: cellWidth)
                    }.buttonStyle(.plain)
                        .accessibilityLabel(segment.program.map { "\($0.title), \($0.startTime.formatted(date: .omitted, time: .shortened)), \(channel.name)" } ?? "Watch \(channel.name) live, schedule unavailable")
                        .accessibilityIdentifier("live.program.\(channel.id).\(segment.program?.id ?? "gap")")
                }
            }.frame(width: width, height: 124)
                .overlay(alignment: .leading) {
                    if now >= start && now < end {
                        Rectangle().fill(GuideAppearance.lavender.opacity(0.65)).frame(width: 1)
                            .offset(x: width * now.timeIntervalSince(start) / LiveGuidePolicy.windowDuration)
                            .allowsHitTesting(false)
                    }
                }
        }
        .frame(minHeight: 146)
        .overlay(alignment: .bottom) { Rectangle().fill(GuideAppearance.line).frame(height: 1) }
    }

    private func timelineCell(segment: LiveGuidePolicy.Segment, now: Date, width: CGFloat) -> some View {
        let live = segment.program.map { LiveGuidePolicy.isLive($0, at: now) } ?? false
        return VStack(alignment: .leading, spacing: 7) {
            if let program = segment.program {
                if width > 72 {
                    Text(live ? "ON NOW" : program.startTime.formatted(.dateTime.hour().minute()))
                        .font(VelvetFont.body(9, .semibold)).foregroundStyle(live ? GuideAppearance.lavender : GuideAppearance.quiet)
                }
                Text(program.title).font(VelvetFont.display(16, .medium)).lineLimit(2)
                    .foregroundStyle(live ? VelvetColors.textPrimary : VelvetColors.textPrimary.opacity(0.8))
                if width > 110, let episode = program.episodeTitle, !episode.isEmpty {
                    Text(episode).font(VelvetFont.body(11)).foregroundStyle(GuideAppearance.quiet).lineLimit(1)
                }
            } else if width > 100 {
                Text("Watch live").font(VelvetFont.display(15, .medium))
                Text("Schedule unavailable").font(VelvetFont.body(11)).foregroundStyle(GuideAppearance.quiet)
            }
            Spacer(minLength: 0)
        }
        .padding(width > 72 ? 13 : 4)
        .frame(width: max(0, width - 5), height: 120, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14).fill(live ? GuideAppearance.lavender.opacity(0.11) : Color.white.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(live ? GuideAppearance.lavender.opacity(0.22) : GuideAppearance.line))
        .clipped()
        .frame(width: width, alignment: .leading)
    }

    private func lastGuideWindow(now: Date) -> Date {
        let last = vm.schedules.values.compactMap { $0.orderedPrograms.last?.endTime }.max() ?? now
        return LiveGuidePolicy.lastWindowStart(lastProgramEnd: last, now: now)
    }

    private func shiftTime(_ direction: Double, now: Date) {
        let start = browsingStart ?? LiveGuidePolicy.windowStart(at: now)
        browsingStart = min(lastGuideWindow(now: now), max(LiveGuidePolicy.windowStart(at: now), start.addingTimeInterval(direction * LiveGuidePolicy.windowDuration)))
    }

    private func watch(_ channel: LiveChannel) {
        vm.selectedChannelID = channel.id
        playTarget = LivePlayTarget(channel: channel)
    }

    private func toggleFavorite(_ channel: LiveChannel) {
        if favorites.contains(channel.id) { favorites.remove(channel.id) } else { favorites.insert(channel.id) }
        UserDefaults.standard.set(favorites.sorted(), forKey: configurationKey.favoriteKey)
    }

    private func statusCard(title: String, message: String, retry: Bool) -> some View {
        VStack(spacing: 14) {
            Image(systemName: onlyFavorites ? "star" : "tv").font(.system(size: 32, weight: .light)).foregroundStyle(GuideAppearance.lavender)
            Text(title).font(VelvetFont.display(23, .medium))
            Text(message).font(VelvetFont.body(14)).foregroundStyle(GuideAppearance.quiet).multilineTextAlignment(.center)
            if retry { Button("Refresh") { Task { await vm.reload() } }.buttonStyle(PlayerSecondaryButtonStyle()).disabled(vm.loading) }
        }.padding(28).frame(maxWidth: .infinity, minHeight: 240)
    }
}

private struct GuideChannelLogo: View {
    let channel: LiveChannel
    var body: some View {
        AsyncImage(url: channel.logoUrl) { phase in
            if let image = phase.image { image.resizable().scaledToFit() }
            else { Image(systemName: "tv").font(.system(size: 22, weight: .light)).foregroundStyle(GuideAppearance.ink.opacity(0.65)) }
        }
        .padding(5)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.9)))
        .accessibilityHidden(true)
    }
}

private struct LiveProgramSheet: View {
    let selection: GuideSelection
    let schedule: LiveChannelSchedule?
    let favorite: Bool
    let toggleFavorite: () -> Void
    let watch: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var localFavorite = false
    @State private var chosenProgram: LiveProgram?

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let selectedProgram = chosenProgram ?? selection.program
                ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        HStack(spacing: 14) {
                            GuideChannelLogo(channel: selection.channel).frame(width: 62, height: 42)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(selection.channel.name).font(VelvetFont.display(20))
                                if let number = selection.channel.number { Text("Channel \(number)").font(VelvetFont.body(12)).foregroundStyle(GuideAppearance.quiet) }
                            }
                            Spacer()
                            Button { localFavorite.toggle(); toggleFavorite() } label: {
                                Image(systemName: localFavorite ? "star.fill" : "star").frame(width: 44, height: 44)
                            }.foregroundStyle(GuideAppearance.lavender).accessibilityLabel(localFavorite ? "Remove favorite" : "Add favorite")
                        }.id("program-top")
                        if let program = selectedProgram {
                            if let artwork = program.imageUrl {
                                AsyncImage(url: artwork) { phase in
                                    if let image = phase.image {
                                        image.resizable().scaledToFill().frame(height: 180).clipped()
                                            .overlay(alignment: .bottom) {
                                                LinearGradient(colors: [.clear, GuideAppearance.ink.opacity(0.5)], startPoint: .top, endPoint: .bottom)
                                            }
                                            .clipShape(RoundedRectangle(cornerRadius: 20))
                                    }
                                }.accessibilityHidden(true)
                            }
                            VStack(alignment: .leading, spacing: 12) {
                                let live = LiveGuidePolicy.isLive(program, at: context.date)
                                Text(live ? "ON NOW" : program.startTime > context.date ? "UPCOMING" : "PREVIOUSLY AIRED")
                                    .font(VelvetFont.body(10, .semibold)).tracking(1.5).foregroundStyle(GuideAppearance.lavender)
                                Text(program.title).font(VelvetFont.display(30, .semibold))
                                Text(program.startTime.formatted(.dateTime.weekday(.abbreviated).hour().minute()) + " – " + program.endTime.formatted(.dateTime.hour().minute()))
                                    .font(VelvetFont.body(13)).foregroundStyle(GuideAppearance.quiet)
                                let metadata = [program.rating, program.genres?.prefix(2).joined(separator: " · "), program.isNew == true ? "New" : nil].compactMap { $0 }.filter { !$0.isEmpty }
                                if !metadata.isEmpty {
                                    Text(metadata.joined(separator: " · ")).font(VelvetFont.body(12)).foregroundStyle(GuideAppearance.quiet)
                                }
                                if let episode = program.episodeTitle, !episode.isEmpty { Text(episode).font(VelvetFont.body(16, .medium)) }
                                if let description = program.description, !description.isEmpty {
                                    Text(description).font(VelvetFont.body(15)).foregroundStyle(GuideAppearance.quiet).lineSpacing(5)
                                }
                                if !live {
                                    Text(program.startTime > context.date ? "This program hasn't started. Watching this channel opens what's on live now." : "This program has ended. Watching this channel opens what's on live now.")
                                        .font(VelvetFont.body(12)).foregroundStyle(GuideAppearance.quiet)
                                }
                            }
                        } else {
                            Text("The schedule isn't available for this channel. You can still watch live.")
                                .font(VelvetFont.body(15)).foregroundStyle(GuideAppearance.quiet)
                        }
                        Button(action: watch) {
                            Label(selectedProgram.map { LiveGuidePolicy.isLive($0, at: context.date) } == true ? "Watch live" : "Watch channel live", systemImage: "play.fill")
                                .font(VelvetFont.body(15, .semibold)).frame(maxWidth: .infinity).padding(17)
                                .foregroundStyle(GuideAppearance.ink).background(GuideAppearance.lavender, in: Capsule())
                        }.buttonStyle(.plain).accessibilityIdentifier("live.program.watch")
                        let programs = (schedule?.orderedPrograms ?? []).filter { $0.endTime > context.date && $0.id != selectedProgram?.id }
                        if !programs.isEmpty {
                            Text("Channel schedule").font(VelvetFont.display(22, .medium)).padding(.top, 8)
                            ForEach(programs) { program in
                                Button {
                                    chosenProgram = program
                                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
                                        proxy.scrollTo("program-top", anchor: .top)
                                    }
                                } label: {
                                HStack(alignment: .top, spacing: 16) {
                                    Text(program.startTime, format: .dateTime.weekday(.abbreviated).hour().minute())
                                        .font(VelvetFont.body(12, .medium)).foregroundStyle(GuideAppearance.quiet).frame(width: 90, alignment: .leading)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(program.title).font(VelvetFont.display(17, .medium))
                                        if let episode = program.episodeTitle, !episode.isEmpty { Text(episode).font(VelvetFont.body(12)).foregroundStyle(GuideAppearance.quiet) }
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(GuideAppearance.quiet)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                        }
                    }.padding(24)
                }
                }
            }
            .background(GuideAppearance.ink).navigationTitle("Program details").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear { localFavorite = favorite }
        }.presentationDetents([.large]).presentationDragIndicator(.visible)
    }
}

struct LiveChannelCard: View {
    let channel: LiveChannel
    var selected = false
    var schedule: LiveChannelSchedule?

    var body: some View {
        HStack(spacing: 14) {
            AsyncImage(url: channel.logoUrl) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                Image(systemName: "tv.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(VelvetColors.textSecondary)
            }
            .frame(width: 64, height: 64)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 12).fill(VelvetColors.surfaceElevated))

            VStack(alignment: .leading, spacing: 5) {
                Text(channel.name)
                    .font(VelvetFont.display(17, .semibold))
                    .foregroundStyle(VelvetColors.textPrimary)
                    .lineLimit(2)
                if let number = channel.number, !number.isEmpty {
                    Text("Channel \(number)")
                        .font(VelvetFont.body(12))
                        .foregroundStyle(VelvetColors.textSecondary)
                }
                if let group = channel.group, !group.isEmpty {
                    Text(group)
                        .font(VelvetFont.body(12))
                        .foregroundStyle(VelvetColors.textTertiary)
                        .lineLimit(1)
                }
                HStack(spacing: 5) {
                    Circle().fill(Color.red).frame(width: 5, height: 5)
                    Text("LIVE").font(VelvetFont.body(10, .semibold))
                }
                .foregroundStyle(VelvetColors.textSecondary)
                if let schedule {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        VStack(alignment: .leading, spacing: 4) {
                            if let current = schedule.now(at: context.date) {
                                Text("Now · \(current.title)").foregroundStyle(VelvetColors.textPrimary)
                            }
                            if let next = schedule.next(at: context.date) {
                                Text("Next · \(next.title)").foregroundStyle(VelvetColors.textSecondary)
                            }
                        }.font(VelvetFont.body(12)).lineLimit(2)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if selected {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(VelvetColors.accent)
            } else {
                Image(systemName: "play.fill").foregroundStyle(VelvetColors.accent)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 124, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(VelvetColors.surface))
        .overlay(RoundedRectangle(cornerRadius: 16)
            .strokeBorder(selected ? VelvetColors.accent : .clear, lineWidth: 1.5))
        .contentShape(RoundedRectangle(cornerRadius: 16))
    }
}
