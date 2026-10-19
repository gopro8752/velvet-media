import SwiftUI

@MainActor
final class LiveTVViewModel: ObservableObject {
    @Published private(set) var channels: [LiveChannel] = []
    @Published private(set) var loading = false
    @Published private(set) var enabled = false
    @Published private(set) var message: String?
    @Published private(set) var error: String?
    @Published private(set) var guide: LiveGuide?
    @Published private(set) var guideUnavailable = false
    @Published var search = ""
    @Published var selectedChannelID: String?
    private let client: LiveTVServing
    private var requestID = UUID()

    init(client: LiveTVServing) { self.client = client }

    var visibleChannels: [LiveChannel] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return channels.filter {
            (query.isEmpty
                || $0.name.localizedCaseInsensitiveContains(query)
                || ($0.number?.localizedCaseInsensitiveContains(query) == true)
                || ($0.group?.localizedCaseInsensitiveContains(query) == true))
        }
    }

    func reload() async {
        let id = UUID()
        requestID = id
        loading = true
        error = nil
        guide = nil
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
        guide = value
        guideUnavailable = value == nil
    }
}

struct LiveTVView: View {
    @EnvironmentObject private var container: AppContainer
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        LiveTVContent(client: container.liveTV, hardwareDecoding: settings.hardwareDecoding,
                      configurationKey: ConfigurationKey(sources: settings.streamSources,
                                                         syncURL: settings.syncUrl, token: settings.syncToken))
    }

    fileprivate struct ConfigurationKey: Hashable {
        let sources: [StreamSourceConfig]
        let syncURL: String
        let token: String
    }
}

private struct LiveTVContent: View {
    @EnvironmentObject private var settings: SettingsStore
    @StateObject private var vm: LiveTVViewModel
    @State private var playTarget: LivePlayTarget?
    @State private var scheduleChannel: LiveChannel?
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
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Spectrum channels")
                    .font(VelvetFont.body(13)).foregroundStyle(VelvetColors.textSecondary)
                if let error = vm.error {
                    statusCard(title: "Couldn't load Live TV", message: error, retry: true)
                } else if let message = vm.message, !message.isEmpty {
                    Text(message)
                        .font(VelvetFont.body(14))
                        .foregroundStyle(VelvetColors.textSecondary)
                }
                if let message = vm.guide?.message, !message.isEmpty {
                    Text(message).font(VelvetFont.body(13)).foregroundStyle(VelvetColors.textSecondary)
                } else if vm.guideUnavailable {
                    Text("Program schedules are unavailable right now. You can still watch channels.")
                        .font(VelvetFont.body(13)).foregroundStyle(VelvetColors.textSecondary)
                }
                if vm.loading && vm.channels.isEmpty {
                    ProgressView("Loading channels…")
                        .frame(maxWidth: .infinity, minHeight: 180)
                } else if vm.channels.isEmpty && vm.error == nil {
                    statusCard(title: vm.enabled ? "No channels available" : "Live TV isn't connected yet",
                               message: vm.enabled ? "Refresh after adding live channels to your server."
                                   : "Your live channels will appear here when the server is ready.", retry: true)
                } else if vm.visibleChannels.isEmpty {
                    statusCard(title: "No matching channels", message: "Try another name or channel number.", retry: false)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 16)], spacing: 16) {
                        ForEach(vm.visibleChannels) { channel in
                            VStack(spacing: 0) {
                                Button {
                                    vm.selectedChannelID = channel.id
                                    playTarget = LivePlayTarget(channel: channel)
                                } label: {
                                    LiveChannelCard(channel: channel, selected: vm.selectedChannelID == channel.id,
                                                    schedule: vm.guide?.channels.first { $0.channelId == channel.id })
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Watch \(channel.name) live")
                                .accessibilityIdentifier("live.channel.\(channel.id)")
                                if vm.guide?.channels.contains(where: { $0.channelId == channel.id && !$0.programs.isEmpty }) == true {
                                    Button { scheduleChannel = channel } label: {
                                        Label("View schedule", systemImage: "list.bullet.rectangle")
                                            .font(VelvetFont.body(13, .semibold))
                                            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                                    }.accessibilityIdentifier("live.schedule.\(channel.id)")
                                }
                            }
                            .background(RoundedRectangle(cornerRadius: 16).fill(VelvetColors.surface))
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 1600, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(VelvetColors.background.ignoresSafeArea())
        .navigationTitle("Live TV")
        .searchable(text: $vm.search, prompt: "Find a channel")
        .refreshable { await vm.reload() }
        .task(id: configurationKey) {
            await vm.reload()
            // A cold backend downloads the guide in the background. Refresh
            // only while this screen is visible, until real schedule data lands.
            while !Task.isCancelled, vm.guide?.enabled == true, vm.guide?.updatedAt == nil {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled else { return }
                await vm.reload()
            }
        }
        .sheet(item: $scheduleChannel) { channel in
            LiveScheduleView(channel: channel,
                             schedule: vm.guide?.channels.first { $0.channelId == channel.id })
        }
        .landscapePlayerPresenter(item: $playTarget) { target in
            LivePlayerView(channel: target.channel, channels: vm.channels, client: client,
                           hardwareDecoding: hardwareDecoding, settings: settings) { selected in
                vm.selectedChannelID = selected.id
            }
        }
    }

    private func statusCard(title: String, message: String, retry: Bool) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "tv")
                .font(.system(size: 34))
                .foregroundStyle(VelvetColors.accent)
            Text(title).font(VelvetFont.display(21, .semibold))
            Text(message)
                .font(VelvetFont.body(15))
                .foregroundStyle(VelvetColors.textSecondary)
                .multilineTextAlignment(.center)
            if retry {
                Button("Refresh") { Task { await vm.reload() } }
                    .buttonStyle(PlayerSecondaryButtonStyle())
                    .disabled(vm.loading)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, minHeight: 200)
        .background(RoundedRectangle(cornerRadius: 18).fill(VelvetColors.surface))
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

private struct LiveScheduleView: View {
    let channel: LiveChannel
    let schedule: LiveChannelSchedule?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach((schedule?.orderedPrograms ?? []).filter { $0.endTime > context.date }) { program in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(program.startTime, format: .dateTime.weekday(.abbreviated).hour().minute())
                                    Text("–")
                                    Text(program.endTime, format: .dateTime.hour().minute())
                                    Spacer()
                                    if program.startTime <= context.date { Text("NOW").foregroundStyle(VelvetColors.accent) }
                                }.font(VelvetFont.body(12, .semibold)).foregroundStyle(VelvetColors.textSecondary)
                                Text(program.title).font(VelvetFont.display(20, .semibold))
                                if let episode = program.episodeTitle, !episode.isEmpty {
                                    Text(episode).font(VelvetFont.body(15))
                                }
                                if let description = program.description, !description.isEmpty {
                                    Text(description).font(VelvetFont.body(14)).foregroundStyle(VelvetColors.textSecondary)
                                }
                            }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 14).fill(VelvetColors.surface))
                        }
                    }.padding(20)
                }
            }
            .background(VelvetColors.background).navigationTitle(channel.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }
}
