import Foundation

/// Episode-title cross-check for stream picking — 1:1 port of the Android
/// EpisodeMatch.kt (any semantic change there must be made here too).
///
/// Some usenet releases are numbered off-by-one: a request for S01E12
/// "Quagmire's Ire" resolves to a file whose name actually carries episode
/// 13's title. The numeric tag in the release name agrees with the request
/// (it's S01E12 — that's why the indexer returned it), so only the
/// human-readable episode title embedded in the filename can expose the lie.
/// `EpisodeMatch.classify` compares a stream's filename/display title against
/// the season's full episode list (numbers + titles, cached from TMDB by the
/// player) and returns one of three verdicts.
///
/// The verdict is intentionally three-valued: title evidence is only trusted
/// when it is unambiguous (exactly one episode title of the season matches),
/// and the numeric SxxEyy / 1x12 parse is only consulted when title evidence
/// is inconclusive — the numbering being wrong is the whole bug, so title
/// evidence outranks it. Anything ambiguous is `.unknown`: never guess,
/// never demote on a hunch.
enum EpisodeTitleVerdict: Equatable {
    /// The filename carries the REQUESTED episode's title — confidence boost.
    case confirmed
    /// The filename carries a DIFFERENT episode's title (or an unambiguous
    /// different number).
    case mismatch(actualEpisode: Int)
    /// No usable or unambiguous evidence either way — treat exactly like today.
    case unknown

    /// Sort key for stream ordering: confirmed (0) first, unknown (1) middle so
    /// the existing ordering is preserved within it, mismatch (2) last. Use with
    /// a stable sort on an already-sorted list (Swift's sort is not documented
    /// stable — sort `enumerated()` with the offset as the tiebreaker, exactly
    /// like StreamClient.sortStreams does).
    var sortRank: Int {
        switch self {
        case .confirmed: return 0
        case .unknown: return 1
        case .mismatch: return 2
        }
    }
}

enum EpisodeMatch {

    /// Minimal episode descriptor so this file depends on nothing but Foundation.
    /// Call sites map from the model: `episodes.map { SeasonEpisodeRef(number: $0.number, title: $0.title) }`.
    struct SeasonEpisodeRef {
        let number: Int
        let title: String

        init(number: Int, title: String) {
            self.number = number
            self.title = title
        }
    }

    /// Classify one stream's filename (or display title) against the requested episode.
    ///
    /// Decision order (title evidence outranks the numeric parse):
    ///  1. Every episode title of the season is tested against the filename. A
    ///     title "matches" when its significant tokens appear, in order and
    ///     contiguously, in the filename's significant tokens. Exactly one match
    ///     => `.confirmed` if it is the requested episode, `.mismatch` with that
    ///     episode otherwise. Zero or 2+ matches => title evidence is
    ///     inconclusive (never guess).
    ///  2. Only then the numeric SxxEyy / SxxEyyEzz / NxNN patterns are parsed.
    ///     Exactly one distinct (season, episode) pair, same season, different
    ///     episode => `.mismatch` with the parsed episode. Multi-episode files
    ///     (S01E12E13) parse to 2+ pairs and stay unknown; a pair from a
    ///     different season stays unknown (this season's episode list can't
    ///     arbitrate it).
    ///  3. Everything else => `.unknown`.
    ///
    /// - Parameters:
    ///   - filenameOrTitle: release filename or the stream's display title line
    ///   - seasonEpisodes: the FULL episode list of the requested season (numbers + titles)
    static func classify(
        filenameOrTitle: String,
        requestedSeason: Int,
        requestedEpisode: Int,
        seasonEpisodes: [SeasonEpisodeRef]
    ) -> EpisodeTitleVerdict {
        let fileTokens = normalizeTokens(filenameOrTitle)
        let sigFile = significant(fileTokens)

        // Title evidence: which episode titles of the season appear in the filename?
        var matched: [Int] = []
        for ep in seasonEpisodes {
            let sigTitle = significant(normalizeTokens(ep.title))
            // Empty significant-token titles ("It", "A to Z") never match — a title
            // that normalizes to nothing would "appear" in every filename.
            if !sigTitle.isEmpty, containsContiguous(haystack: sigFile, needle: sigTitle) {
                if !matched.contains(ep.number) { matched.append(ep.number) }
            }
        }
        if matched.count == 1 {
            let actual = matched[0]
            return actual == requestedEpisode ? .confirmed : .mismatch(actualEpisode: actual)
        }

        // Numeric evidence, only when title evidence was inconclusive (0 or 2+ matches).
        let pairs = parseSeasonEpisodePairs(fileTokens.joined(separator: " "))
        if pairs.count == 1, let pair = pairs.first {
            if pair.season == requestedSeason && pair.episode != requestedEpisode {
                return .mismatch(actualEpisode: pair.episode)
            }
        }
        return .unknown
    }

    // MARK: - normalization

    /// Tokens whose presence carries no identifying signal. "s" additionally
    /// absorbs possessives when an apostrophe survives as a separator (belt and
    /// braces — the apostrophe set below already glues "Quagmire's" into
    /// "quagmires").
    private static let stopwords: Set<String> =
        ["the", "a", "an", "of", "and", "to", "in", "on", "at", "s"]

    /// Deleted (not space-replaced) so "Quagmire's" and a release's "Quagmires"
    /// normalize to the same token: ASCII apostrophe, right single quote,
    /// modifier letter apostrophe, backtick, acute accent.
    private static let apostrophes: Set<Unicode.Scalar> =
        ["\u{27}", "\u{2019}", "\u{02BC}", "\u{60}", "\u{B4}"]

    /// lowercase -> NFD -> drop combining marks (Mn) -> delete apostrophes ->
    /// keep letters (Lu/Ll/Lt/Lm/Lo) and decimal digits (Nd), everything else
    /// becomes a space -> split. "Café" and a release's "Cafe" tokenize
    /// identically. Applied to BOTH the filename and the episode titles, so
    /// both sides play by the same rules.
    private static func normalizeTokens(_ text: String) -> [String] {
        let decomposed = text.lowercased().decomposedStringWithCanonicalMapping
        var scalars = String.UnicodeScalarView()
        for scalar in decomposed.unicodeScalars {
            if scalar.properties.generalCategory == .nonspacingMark { continue } // é->e, ñ->n
            if apostrophes.contains(scalar) { continue }
            if isLetterOrDecimalDigit(scalar) {
                scalars.append(scalar)
            } else {
                scalars.append(" ")
            }
        }
        return String(scalars).split(separator: " ").map(String.init)
    }

    /// Lu/Ll/Lt/Lm/Lo + Nd — the exact category set the Android port keeps.
    private static func isLetterOrDecimalDigit(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter,
             .modifierLetter, .otherLetter, .decimalNumber:
            return true
        default:
            return false
        }
    }

    /// Significant = length >= 3 and not a stopword; used on both sides of the match.
    private static func significant(_ tokens: [String]) -> [String] {
        tokens.filter { $0.count >= 3 && !stopwords.contains($0) }
    }

    /// True when `needle` occurs as a contiguous, in-order sublist of `haystack`.
    private static func containsContiguous(haystack: [String], needle: [String]) -> Bool {
        if needle.isEmpty || needle.count > haystack.count { return false }
        outer: for start in 0...(haystack.count - needle.count) {
            for offset in needle.indices where haystack[start + offset] != needle[offset] {
                continue outer
            }
            return true
        }
        return false
    }

    // MARK: - numeric SxxEyy / 1x12 parsing

    private struct SeasonEpisodePair: Hashable {
        let season: Int
        let episode: Int
    }

    // Explicit [a-z0-9] lookarounds instead of \b: ICU's \b is Unicode-aware
    // while Java's default \b (Android port) is ASCII-based — lookarounds behave
    // identically in both engines. Normalized text is lowercase with single
    // spaces, so [a-z0-9] covers every ASCII word character that can occur.
    // NSRegularExpression is immutable and documented thread-safe.
    private static let seasonEp = try! NSRegularExpression(
        pattern: "(?<![a-z0-9])s([0-9]{1,2}) ?e([0-9]{1,3})((?: ?e[0-9]{1,3})*)(?![a-z0-9])")
    private static let crossEp = try! NSRegularExpression(
        pattern: "(?<![a-z0-9])([0-9]{1,2})x([0-9]{1,3})(?![a-z0-9])")
    private static let epCont = try! NSRegularExpression(pattern: "e([0-9]{1,3})")

    /// All distinct (season, episode) pairs named by the text: "s01e12",
    /// "s01 e12", "s1e13", multi-episode runs "s01e12e13" / "s01e12 e13" (each
    /// episode becomes a pair), and the "1x12" form. "1920x1080" and "x264"
    /// never match (season is capped at two digits and both ends are
    /// letter/digit-guarded). 2+ distinct pairs mean a multi-episode file —
    /// numeric evidence is then deliberately inconclusive.
    private static func parseSeasonEpisodePairs(_ normText: String) -> Set<SeasonEpisodePair> {
        var pairs = Set<SeasonEpisodePair>()
        let fullRange = NSRange(normText.startIndex..., in: normText)
        for match in seasonEp.matches(in: normText, range: fullRange) {
            guard let season = groupInt(match, 1, in: normText) else { continue }
            if let episode = groupInt(match, 2, in: normText) {
                pairs.insert(SeasonEpisodePair(season: season, episode: episode))
            }
            let continuation = groupString(match, 3, in: normText) ?? ""
            let contRange = NSRange(continuation.startIndex..., in: continuation)
            for cont in epCont.matches(in: continuation, range: contRange) {
                if let episode = groupInt(cont, 1, in: continuation) {
                    pairs.insert(SeasonEpisodePair(season: season, episode: episode))
                }
            }
        }
        for match in crossEp.matches(in: normText, range: fullRange) {
            guard let season = groupInt(match, 1, in: normText),
                  let episode = groupInt(match, 2, in: normText) else { continue }
            pairs.insert(SeasonEpisodePair(season: season, episode: episode))
        }
        return pairs
    }

    private static func groupString(_ match: NSTextCheckingResult, _ index: Int, in text: String) -> String? {
        guard index < match.numberOfRanges,
              let range = Range(match.range(at: index), in: text) else { return nil }
        return String(text[range])
    }

    private static func groupInt(_ match: NSTextCheckingResult, _ index: Int, in text: String) -> Int? {
        groupString(match, index, in: text).flatMap(Int.init)
    }
}
