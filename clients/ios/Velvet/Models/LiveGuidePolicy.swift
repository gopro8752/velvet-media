import Foundation
import CryptoKit

/// Shared by both guide layouts. Times stay absolute so daylight-saving changes
/// cannot create duplicate or missing half-hour columns.
enum LiveGuidePolicy {
    static let slotDuration: TimeInterval = 30 * 60
    static let windowDuration: TimeInterval = 2 * 60 * 60

    static func windowStart(at date: Date) -> Date {
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 / slotDuration) * slotDuration)
    }

    static func lastWindowStart(lastProgramEnd: Date, now: Date) -> Date {
        let start = windowStart(at: now)
        let pages = max(0, floor((lastProgramEnd.timeIntervalSince(start) - 1) / windowDuration))
        return start.addingTimeInterval(pages * windowDuration)
    }

    static func matches(_ query: String, channel: LiveChannel, schedule: LiveChannelSchedule?, at date: Date) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || [channel.name, channel.number ?? "", channel.group ?? ""].contains {
            $0.localizedCaseInsensitiveContains(query)
        } || matchingPrograms(query, schedule: schedule, at: date).isEmpty == false
    }

    static func matchingPrograms(_ query: String, schedule: LiveChannelSchedule?, at date: Date) -> [LiveProgram] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return (schedule?.orderedPrograms ?? []).filter {
            $0.endTime > date && ($0.title.localizedCaseInsensitiveContains(query)
                || $0.episodeTitle?.localizedCaseInsensitiveContains(query) == true)
        }
    }

    static func progress(_ program: LiveProgram, at date: Date) -> Double {
        guard program.endTime > program.startTime else { return 0 }
        return min(1, max(0, date.timeIntervalSince(program.startTime) / program.endTime.timeIntervalSince(program.startTime)))
    }

    static func isLive(_ program: LiveProgram, at date: Date) -> Bool {
        program.startTime <= date && date < program.endTime
    }

    struct Segment: Identifiable {
        let start: Date
        let end: Date
        let program: LiveProgram?
        var id: String { "\(start.timeIntervalSince1970)-\(program?.id ?? "gap")" }
    }

    /// Explicit gaps are real missing schedule data, never invented programs.
    /// Clipping also prevents malformed overlapping upstream entries from
    /// shifting every channel out of alignment with the time ruler.
    static func segments(schedule: LiveChannelSchedule?, from start: Date, to end: Date) -> [Segment] {
        guard end > start else { return [] }
        var cursor = start
        var result: [Segment] = []
        for program in schedule?.orderedPrograms ?? [] where program.endTime > start && program.startTime < end {
            let left = max(cursor, program.startTime)
            let right = min(end, program.endTime)
            guard right > left else { continue }
            if left > cursor { result.append(Segment(start: cursor, end: left, program: nil)) }
            result.append(Segment(start: left, end: right, program: program))
            cursor = right
        }
        if cursor < end { result.append(Segment(start: cursor, end: end, program: nil)) }
        return result
    }

    static func favoriteKey(backend: String, profile: String) -> String {
        var components = URLComponents(string: backend.trimmingCharacters(in: .whitespacesAndNewlines))
        let host = components?.host?.lowercased()
        let scheme = components?.scheme?.lowercased()
        components?.host = host
        components?.scheme = scheme
        components?.user = nil
        components?.password = nil
        components?.query = nil
        components?.fragment = nil
        if (components?.scheme == "https" && components?.port == 443)
            || (components?.scheme == "http" && components?.port == 80) { components?.port = nil }
        let origin = (components?.string ?? backend).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let digest = SHA256.hash(data: Data((origin + "\n" + profile).utf8)).map { String(format: "%02x", $0) }.joined()
        return "live.guide.favorites." + digest
    }
}
