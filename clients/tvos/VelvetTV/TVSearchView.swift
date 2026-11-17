import SwiftUI

struct TVSearchView: View {
    @EnvironmentObject private var container: AppContainer
    @StateObject private var vm = SearchViewModel()
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 34, alignment: .top), count: 6)

    var body: some View {
        ZStack {
            TVBackdrop().ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 35) {
                    TVSectionHeader(title: "Find your next favorite", subtitle: "Search movies and series. Use Siri dictation or your iPhone keyboard.")
                    TextField("Search Velvet", text: $vm.query)
                        .font(VelvetFont.body(28)).textFieldStyle(.plain)
                        .padding(24).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
                        .submitLabel(.search).onSubmit { vm.commitSearch() }
                    if vm.searching {
                        HStack(spacing: 18) { ProgressView(); Text("Searching…").font(VelvetFont.body(23)) }
                    }
                    if !vm.results.isEmpty {
                        LazyVGrid(columns: columns, spacing: 38) {
                            ForEach(vm.results, id: \.self) { item in
                                NavigationLink(value: item) { TVMediaCard(item: item) }
                                    .buttonStyle(TVCardButtonStyle())
                            }
                        }.padding(.vertical, 15)
                    } else if !vm.searching && !vm.resultsFor.isEmpty {
                        TVEmptyState(symbol: "magnifyingglass", title: "No matches for “\(vm.resultsFor)”",
                                     message: "Try another title, or check your backend connection in Settings.")
                            .frame(height: 360)
                    } else if vm.trimmedQuery.count < 2 {
                        TVEmptyState(symbol: "sparkles.tv", title: "Something great is waiting",
                                     message: "Enter at least two letters to explore the catalog.")
                            .frame(height: 360)
                    }
                }
                .padding(.horizontal, TVLayout.edge).padding(.top, 40).padding(.bottom, 100)
            }.scrollIndicators(.hidden).scrollClipDisabled()
        }
        .navigationDestination(for: MediaItem.self) { TVDetailsView(item: $0) }
        .task { vm.configure(tmdb: container.tmdb) }
    }
}
