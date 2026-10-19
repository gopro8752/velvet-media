package tv.velvet.data.streams

import java.text.Normalizer
import java.util.Locale

/**
 * Episode-title cross-check for stream picking.
 *
 * Some usenet releases are numbered off-by-one: a request for S01E12 "Quagmire's Ire"
 * resolves to a file whose name actually carries episode 13's title. The numeric tag in
 * the release name agrees with the request (it's S01E12 — that's why the indexer returned
 * it), so only the human-readable episode title embedded in the filename can expose the
 * lie. [EpisodeMatch.classify] compares a stream's filename/display title against the
 * season's full episode list (numbers + titles, cached from TMDB by the player) and
 * returns one of three verdicts.
 *
 * The verdict is intentionally three-valued: title evidence is only trusted when it is
 * unambiguous (exactly one episode title of the season matches), and the numeric
 * SxxEyy / 1x12 parse is only consulted when title evidence is inconclusive — the
 * numbering being wrong is the whole bug, so title evidence outranks it. Anything
 * ambiguous is [EpisodeTitleVerdict.Unknown]: never guess, never demote on a hunch.
 *
 * Pure functions, zero dependencies beyond the JDK. Mirrored 1:1 by the iOS
 * EpisodeMatch.swift — any semantic change here must be made there too.
 */
sealed interface EpisodeTitleVerdict {

    /**
     * Sort key for stream ordering: CONFIRMED (0) first, UNKNOWN (1) middle so the
     * existing ordering is preserved within it, MISMATCH (2) last. Use with a stable
     * sort (Kotlin's sortedBy is stable) on an already-sorted list.
     */
    val sortRank: Int

    /** The filename carries the REQUESTED episode's title — confidence boost. */
    data object Confirmed : EpisodeTitleVerdict {
        override val sortRank: Int get() = 0
    }

    /** The filename carries a DIFFERENT episode's title (or an unambiguous different number). */
    data class Mismatch(val actualEpisode: Int) : EpisodeTitleVerdict {
        override val sortRank: Int get() = 2
    }

    /** No usable or unambiguous evidence either way — treat exactly like today. */
    data object Unknown : EpisodeTitleVerdict {
        override val sortRank: Int get() = 1
    }
}

object EpisodeMatch {

    /**
     * Minimal episode descriptor so this file depends on nothing but the JDK.
     * Call sites map from the model: `episodes.map { SeasonEpisodeRef(it.number, it.title) }`.
     */
    data class SeasonEpisodeRef(val number: Int, val title: String)

    /**
     * Classify one stream's filename (or display title) against the requested episode.
     *
     * Decision order (title evidence outranks the numeric parse):
     *  1. Every episode title of the season is tested against the filename. A title
     *     "matches" when its significant tokens appear, in order and contiguously, in
     *     the filename's significant tokens. Exactly one match => [EpisodeTitleVerdict.Confirmed]
     *     if it is the requested episode, [EpisodeTitleVerdict.Mismatch] with that episode
     *     otherwise. Zero or 2+ matches => title evidence is inconclusive (never guess).
     *  2. Only then the numeric SxxEyy / SxxEyyEzz / NxNN patterns are parsed. Exactly one
     *     distinct (season, episode) pair, same season, different episode =>
     *     [EpisodeTitleVerdict.Mismatch] with the parsed episode. Multi-episode files
     *     (S01E12E13) parse to 2+ pairs and stay Unknown; a pair from a different season
     *     stays Unknown (this season's episode list can't arbitrate it).
     *  3. Everything else => [EpisodeTitleVerdict.Unknown].
     *
     * @param filenameOrTitle release filename or the stream's display title line
     * @param seasonEpisodes  the FULL episode list of the requested season (numbers + titles)
     */
    fun classify(
        filenameOrTitle: String,
        requestedSeason: Int,
        requestedEpisode: Int,
        seasonEpisodes: List<SeasonEpisodeRef>,
    ): EpisodeTitleVerdict {
        val fileTokens = normalizeTokens(filenameOrTitle)
        val sigFile = significant(fileTokens)

        // Title evidence: which episode titles of the season appear in the filename?
        val matched = ArrayList<Int>()
        for (ep in seasonEpisodes) {
            val sigTitle = significant(normalizeTokens(ep.title))
            // Empty significant-token titles ("It", "A to Z") never match — a title that
            // normalizes to nothing would "appear" in every filename.
            if (sigTitle.isNotEmpty() && containsContiguous(sigFile, sigTitle)) {
                if (ep.number !in matched) matched.add(ep.number)
            }
        }
        if (matched.size == 1) {
            val actual = matched[0]
            return if (actual == requestedEpisode) {
                EpisodeTitleVerdict.Confirmed
            } else {
                EpisodeTitleVerdict.Mismatch(actual)
            }
        }

        // Numeric evidence, only when title evidence was inconclusive (0 or 2+ matches).
        val pairs = parseSeasonEpisodePairs(fileTokens.joinToString(" "))
        if (pairs.size == 1) {
            val (season, episode) = pairs.first()
            if (season == requestedSeason && episode != requestedEpisode) {
                return EpisodeTitleVerdict.Mismatch(episode)
            }
        }
        return EpisodeTitleVerdict.Unknown
    }

    // ── normalization ────────────────────────────────────────────────────────

    /**
     * Tokens whose presence carries no identifying signal. "s" additionally absorbs
     * possessives when an apostrophe survives as a separator (belt and braces — the
     * apostrophe set below already glues "Quagmire's" into "quagmires").
     */
    private val STOPWORDS = setOf("the", "a", "an", "of", "and", "to", "in", "on", "at", "s")

    /**
     * Deleted (not space-replaced) so "Quagmire's" and a release's "Quagmires" normalize
     * to the same token: ASCII apostrophe, right single quote, modifier letter apostrophe,
     * backtick, acute accent.
     */
    private val APOSTROPHE_CODE_POINTS = setOf(0x27, 0x2019, 0x02BC, 0x60, 0xB4)

    /**
     * lowercase -> NFD -> drop combining marks (Mn) -> delete apostrophes -> keep
     * letters (Lu/Ll/Lt/Lm/Lo) and decimal digits (Nd), everything else becomes a
     * space -> split. "Café" and a release's "Cafe" tokenize identically. Applied to
     * BOTH the filename and the episode titles, so both sides play by the same rules.
     */
    private fun normalizeTokens(text: String): List<String> {
        val decomposed = Normalizer.normalize(text.lowercase(Locale.ROOT), Normalizer.Form.NFD)
        val sb = StringBuilder(decomposed.length)
        var i = 0
        while (i < decomposed.length) {
            val cp = decomposed.codePointAt(i)
            i += Character.charCount(cp)
            when {
                Character.getType(cp) == Character.NON_SPACING_MARK.toInt() -> Unit // é->e, ñ->n
                cp in APOSTROPHE_CODE_POINTS -> Unit
                isLetterOrDecimalDigit(cp) -> sb.appendCodePoint(cp)
                else -> sb.append(' ')
            }
        }
        return sb.toString().split(' ').filter { it.isNotEmpty() }
    }

    /** Lu/Ll/Lt/Lm/Lo + Nd — the exact category set the iOS port keeps. */
    private fun isLetterOrDecimalDigit(cp: Int): Boolean = when (Character.getType(cp)) {
        Character.UPPERCASE_LETTER.toInt(),
        Character.LOWERCASE_LETTER.toInt(),
        Character.TITLECASE_LETTER.toInt(),
        Character.MODIFIER_LETTER.toInt(),
        Character.OTHER_LETTER.toInt(),
        Character.DECIMAL_DIGIT_NUMBER.toInt(),
        -> true
        else -> false
    }

    /** Significant = length >= 3 and not a stopword; used on both sides of the match. */
    private fun significant(tokens: List<String>): List<String> =
        tokens.filter { it.length >= 3 && it !in STOPWORDS }

    /** True when [needle] occurs as a contiguous, in-order sublist of [haystack]. */
    private fun containsContiguous(haystack: List<String>, needle: List<String>): Boolean {
        if (needle.isEmpty() || needle.size > haystack.size) return false
        outer@ for (start in 0..haystack.size - needle.size) {
            for (offset in needle.indices) {
                if (haystack[start + offset] != needle[offset]) continue@outer
            }
            return true
        }
        return false
    }

    // ── numeric SxxEyy / 1x12 parsing ────────────────────────────────────────

    // Explicit [a-z0-9] lookarounds instead of \b: Java's default \b is ASCII-based
    // while ICU (iOS NSRegularExpression) is Unicode-aware — lookarounds behave
    // identically in both engines. Normalized text is lowercase with single spaces,
    // so [a-z0-9] covers every ASCII word character that can occur.
    private val SEASON_EP =
        Regex("(?<![a-z0-9])s([0-9]{1,2}) ?e([0-9]{1,3})((?: ?e[0-9]{1,3})*)(?![a-z0-9])")
    private val CROSS_EP =
        Regex("(?<![a-z0-9])([0-9]{1,2})x([0-9]{1,3})(?![a-z0-9])")
    private val EP_CONT = Regex("e([0-9]{1,3})")

    /**
     * All distinct (season, episode) pairs named by the text: "s01e12", "s01 e12",
     * "s1e13", multi-episode runs "s01e12e13" / "s01e12 e13" (each episode becomes a
     * pair), and the "1x12" form. "1920x1080" and "x264" never match (season is capped
     * at two digits and both ends are letter/digit-guarded). 2+ distinct pairs mean a
     * multi-episode file — numeric evidence is then deliberately inconclusive.
     */
    private fun parseSeasonEpisodePairs(normText: String): Set<Pair<Int, Int>> {
        val pairs = LinkedHashSet<Pair<Int, Int>>()
        for (match in SEASON_EP.findAll(normText)) {
            val season = match.groupValues[1].toIntOrNull() ?: continue
            match.groupValues[2].toIntOrNull()?.let { pairs.add(season to it) }
            for (cont in EP_CONT.findAll(match.groupValues[3])) {
                cont.groupValues[1].toIntOrNull()?.let { pairs.add(season to it) }
            }
        }
        for (match in CROSS_EP.findAll(normText)) {
            val season = match.groupValues[1].toIntOrNull() ?: continue
            val episode = match.groupValues[2].toIntOrNull() ?: continue
            pairs.add(season to episode)
        }
        return pairs
    }
}
