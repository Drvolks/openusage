import Foundation

/// Builds the Session and Weekly meters from MiniMax's `/v1/token_plan/remains` payload.
///
/// The quota lives in `model_remains`, one entry per model pool (`general` for chat/coding, `video`,
/// and so on). OpenUsage meters the chat pool — the one a coding agent spends — and ignores the rest.
///
/// Within an entry, counts (`current_interval_total_count` / `current_interval_usage_count`) are
/// authoritative when the plan provisions them; several plans leave them at zero and report only a
/// remaining percentage, which is the fallback, inverted because MiniMax reports what's *left* while
/// the meters show what's *used*.
enum MiniMaxUsageMapper {
    static let sessionPeriodMs = 5 * 60 * 60 * 1000
    static let weeklyPeriodMs = 7 * 24 * 60 * 60 * 1000

    /// MiniMax's business-level success code. Anything else in `base_resp` is a real failure, even on
    /// an HTTP 200.
    static let successStatusCode = 0
    /// Authentication failure (invalid key, or a pay-as-you-go key on this Token Plan endpoint).
    static let authStatusCode = 1004
    /// The chat/coding model pool, the one the meters track.
    static let chatModelName = "general"

    /// One window's parsed quota, before it becomes a metric line.
    struct Window: Equatable {
        var usedPercent: Double
        var resetsAt: Date?
        var periodDurationMs: Int?
    }

    static func map(remainsBody: Data) throws -> [MetricLine] {
        guard let root = ProviderParse.jsonObject(remainsBody) else {
            throw MiniMaxUsageError.invalidResponse
        }
        if let error = apiError(in: root) { throw error }

        var lines: [MetricLine] = []
        if let quota = chatQuota(in: root) {
            if let session = window(
                in: quota, prefix: "current_interval",
                startKey: "start_time", endKey: "end_time", fallbackPeriodMs: sessionPeriodMs
            ) {
                lines.append(.progress(
                    label: "Session",
                    used: session.usedPercent,
                    limit: 100,
                    format: .percent,
                    resetsAt: session.resetsAt,
                    periodDurationMs: session.periodDurationMs
                ))
            }
            if let weekly = window(
                in: quota, prefix: "current_weekly",
                startKey: "weekly_start_time", endKey: "weekly_end_time", fallbackPeriodMs: weeklyPeriodMs
            ) {
                lines.append(.progress(
                    label: "Weekly",
                    used: weekly.usedPercent,
                    limit: 100,
                    format: .percent,
                    resetsAt: weekly.resetsAt,
                    periodDurationMs: weekly.periodDurationMs
                ))
            }
        }

        MetricLine.appendNoDataIfNeeded(&lines)
        return lines
    }

    /// The chat pool's quota object: the `model_remains` entry named `general`, or the first entry when
    /// the plan names its pools differently. Older/wrapped shapes that put the fields directly on the
    /// payload (or under `data`) are still accepted, so a response shape change degrades to the fields
    /// it can still find instead of an empty card.
    static func chatQuota(in root: [String: Any]) -> [String: Any]? {
        let container = (root["data"] as? [String: Any]) ?? root
        if let entries = container["model_remains"] as? [[String: Any]], !entries.isEmpty {
            return entries.first { ($0["model_name"] as? String) == chatModelName } ?? entries[0]
        }
        return container
    }

    /// The business-level failure in `base_resp`, if any. MiniMax answers 200 with a status code in the
    /// body for most errors, so this is where an invalid key actually surfaces.
    static func apiError(in root: [String: Any]) -> MiniMaxUsageError? {
        guard let base = root["base_resp"] as? [String: Any],
              let code = ProviderParse.number(base["status_code"]).map({ Int($0) }),
              code != successStatusCode
        else { return nil }

        return .apiError(code: code, message: base["status_msg"] as? String)
    }

    /// Whether a business-level code means "the key was rejected", so the provider can report an auth
    /// error instead of a generic failure.
    static func isAuthFailure(_ error: MiniMaxUsageError) -> Bool {
        if case .apiError(let code, _) = error { return code == authStatusCode }
        return false
    }

    /// One window's usage. `prefix` is `current_interval` (the rolling session window) or
    /// `current_weekly`; `startKey`/`endKey` are that window's boundary timestamps. Returns `nil` when
    /// the plan provisions neither counts nor a percentage, so an absent window reads as "No data"
    /// rather than a full or empty bar.
    static func window(
        in quota: [String: Any],
        prefix: String,
        startKey: String,
        endKey: String,
        fallbackPeriodMs: Int
    ) -> Window? {
        let resetsAt = date(quota[endKey])
        // The payload carries the real window boundaries; only fall back to the documented cadence
        // when it doesn't, so the meter's pace line follows the plan rather than an assumption.
        let periodMs = duration(from: quota[startKey], to: quota[endKey]) ?? fallbackPeriodMs

        let total = ProviderParse.number(quota["\(prefix)_total_count"])
        let used = ProviderParse.number(quota["\(prefix)_usage_count"])
        if let total, let used, total > 0 {
            return Window(
                usedPercent: ProviderParse.clampPercent(used / total * 100),
                resetsAt: resetsAt,
                periodDurationMs: periodMs
            )
        }

        // Fallback: MiniMax reports how much is left, the meters show how much is used.
        if let remaining = ProviderParse.number(quota["\(prefix)_remaining_percent"]) {
            return Window(
                usedPercent: ProviderParse.clampPercent(100 - remaining),
                resetsAt: resetsAt,
                periodDurationMs: periodMs
            )
        }
        return nil
    }

    /// Reset instants come back as an epoch number whose unit isn't documented and, on some plans, as an
    /// ISO-8601 string. Numbers past the year-2100 mark in seconds are milliseconds.
    private static func date(_ value: Any?) -> Date? {
        if let text = value as? String, let parsed = OpenUsageISO8601.date(from: text) {
            return parsed
        }
        guard let number = ProviderParse.number(value), number > 0 else { return nil }
        return Date(timeIntervalSince1970: epochSeconds(number))
    }

    /// The window's length in milliseconds, when both boundaries are present as epoch numbers.
    private static func duration(from start: Any?, to end: Any?) -> Int? {
        guard let start = ProviderParse.number(start), start > 0,
              let end = ProviderParse.number(end), end > start
        else { return nil }
        return Int((epochSeconds(end) - epochSeconds(start)) * 1000)
    }

    private static func epochSeconds(_ number: Double) -> Double {
        number > 4_102_444_800 ? number / 1000 : number
    }
}
