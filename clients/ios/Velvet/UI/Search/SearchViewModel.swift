import Foundation

/// Search tab state — iOS port of the Android SearchViewModel
/// (~/velvet/.../ui/search/SearchViewModel.kt):
/// 350 ms debounce, minimum 2 trimmed characters, consecutive duplicate
/// queries skipped (distinctUntilChanged), results deduped by (type, id).
///
/// `query` is what the user typed, kept verbatim for the text field.
/// `resultsFor` is the trimmed query the current `results` belong to — empty
/// until the first search completes; drives the "No results for X" state.
@MainActor
final class SearchViewModel: ObservableObject {

    @Published var query: String = "" {
        didSet { scheduleSearch(debounced: true) }
    }
    @Published private(set) var results: [MediaItem] = []
    @Published private(set) var resultsFor: String = ""
    @Published private(set) var searching = false

    private var tmdb: TmdbRepository?
    private var searchTask: Task<Void, Never>?
    /// Last trimmed query a search completed for — duplicate-query guard.
    private var lastSearched: String?

    private static let debounceMs = 350
    private static let minQueryLength = 2

    var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Late dependency injection — the view calls this from `.task` because the
    /// EnvironmentObject container is not available in the view's init.
    func configure(tmdb: TmdbRepository) {
        guard self.tmdb == nil else { return }
        self.tmdb = tmdb
    }

    /// Keyboard "search" key: skip whatever is left of the debounce and run now.
    /// Forces a re-run even for the same query — tmdb.search returns [] on
    /// failure (repo contract), so "No results" can really mean "network error"
    /// and the Search key must work as a retry, not a dead-end.
    func commitSearch() {
        scheduleSearch(debounced: false, force: true)
    }

    private func scheduleSearch(debounced: Bool, force: Bool = false) {
        searchTask?.cancel()
        let trimmed = trimmedQuery
        guard trimmed.count >= Self.minQueryLength else {
            results = []
            resultsFor = ""
            searching = false
            lastSearched = nil
            return
        }
        // Same effective query as last time → keep the current results
        // (unless forced by the Search key).
        guard force || trimmed != lastSearched else {
            searching = false
            return
        }
        // Mark the search in flight NOW: the debounce window must read as
        // "Searching…" in the UI, not as the type-something prompt.
        searching = true
        searchTask = Task { [weak self] in
            if debounced {
                try? await Task.sleep(for: .milliseconds(Self.debounceMs))
            }
            guard !Task.isCancelled, let self else { return }
            await self.runSearch(trimmed)
        }
    }

    private func runSearch(_ trimmed: String) async {
        guard let tmdb else { return }
        searching = true
        let raw = await tmdb.search(query: trimmed) // [] on failure (repo contract)
        // A newer query superseded this one while the request was in flight.
        guard !Task.isCancelled else { return }
        // Guarantee unique (type, id) pairs — MediaItem.id alone (the TMDB id)
        // can collide between a movie and a show, and the pairs key the grid.
        var seen = Set<String>()
        var unique: [MediaItem] = []
        for item in raw where seen.insert("\(item.type.rawValue):\(item.id)").inserted {
            unique.append(item)
        }
        results = unique
        resultsFor = trimmed
        lastSearched = trimmed
        searching = false
    }
}
