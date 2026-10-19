package tv.velvet.ui

/**
 * Migration for the persisted Home row order (SettingsRepository.rowOrder).
 *
 * Row ids are stable and user-visible (they encode his hand-tuned order), so a row
 * that gets rebuilt keeps its slot by RENAMING here rather than by disappearing:
 * v1.2.0 replaced the raw /trending movie row with the discover-backed, availability-
 * gated `popular_now`, so a stored `trending_movies` swaps in place. Applied on every
 * READ (Home + Settings) — the stored value re-persists itself on the next row edit.
 *
 * The other half of spec §4g is "new ids append": a stored order written by an older
 * build lists only the ids that build knew about, so mapping it 1:1 would make every row
 * added since INVISIBLE forever (v1.2.0's five holiday rows). [isAddedAfterV1] /
 * [migrateAndAppend] put those back on the end.
 */
object HomeRowOrder {

    private val RENAMED = mapOf(
        "trending_movies" to "popular_now",
    )

    /**
     * Every row id that existed in v1.1. A stored order can only have been written from
     * this set, so an id OUTSIDE it was introduced later and must be APPENDED to that
     * order rather than dropped. `trending_movies` is listed under its migrated name,
     * since [migrate] runs first.
     */
    private val KNOWN_IDS_V1 = setOf(
        "top10_today", "popular_now", "trending_shows", "new_to_stream", "new_shows",
        "bingeworthy", "acclaimed", "hidden_gems", "action", "comedy", "thrillers",
        "scifi_fantasy", "horror", "feel_good", "date_night", "animation_family", "docs",
        "anime", "modern_classics", "classics", "in_theaters", "coming_soon",
    )

    /**
     * Rewrite renamed ids in place, preserving order and dropping any duplicate that
     * the rename introduces (e.g. an order that already carried both ids).
     */
    fun migrate(order: List<String>): List<String> {
        if (order.isEmpty()) return order
        return order.map { RENAMED[it] ?: it }.distinct()
    }

    /** True when [rowId] post-dates v1.1's row set — such an id appends to a stored order. */
    fun isAddedAfterV1(rowId: String): Boolean = rowId !in KNOWN_IDS_V1

    /**
     * [migrate], then append every id in [allIds] that post-dates the stored order and
     * isn't in it already, keeping [allIds]' relative order. An EMPTY stored order is
     * returned untouched — it is the "no preference, use defaults" sentinel, and
     * fabricating a list here would silently turn it into a pinned one.
     */
    fun migrateAndAppend(order: List<String>, allIds: List<String>): List<String> {
        val migrated = migrate(order)
        if (migrated.isEmpty()) return migrated
        val present = migrated.toHashSet()
        return migrated + allIds.filter { it !in present && isAddedAfterV1(it) }
    }
}
