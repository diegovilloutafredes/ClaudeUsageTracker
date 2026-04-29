import Foundation
import SwiftUI

/// Maps a normalized urgency (0 = calm, 1 = critical) to a SwiftUI Color.
/// Hue interpolates continuously: green (0) → yellow → orange → red (1).
func urgencyColor(_ urgency: Double) -> Color {
    let t = max(0, min(1, urgency))
    return Color(hue: 0.33 * (1 - t), saturation: 0.85, brightness: 0.9)
}

/// Returns true when `remote` is a higher semantic version than `current`.
/// Uses `.numeric` comparison so "1.10.0" > "1.9.0".
func isNewerVersion(_ remote: String, than current: String) -> Bool {
    remote.compare(current, options: .numeric) == .orderedDescending
}

/// Computes consumption rate and projected time-to-full from a utilization history.
///
/// Requires at least 30 seconds of elapsed history between the first and last entry.
/// Returns `nil` when the rate is negligible (≤ 0.1 %/hr) or data is insufficient.
func computePace(history: [(Date, Double)]) -> (rate: Double, projectedHours: Double?)? {
    guard history.count >= 2 else { return nil }
    let oldest = history.first!
    let newest = history.last!
    let elapsed = newest.0.timeIntervalSince(oldest.0) / 3600.0
    guard elapsed >= (30.0 / 3600.0) else { return nil }
    let rate = (newest.1 - oldest.1) / elapsed
    guard rate > 0.1 else { return nil }
    let remaining = 100.0 - newest.1
    let projectedHours: Double? = remaining > 0 ? remaining / rate : nil
    return (rate, projectedHours)
}

/// Response payload from the `/api/organizations/{id}/usage` endpoint.
struct UsageResponse: Codable {
    let fiveHour: UsageWindow?
    let sevenDay: UsageWindow?
    let sevenDayOpus: UsageWindow?
    let sevenDaySonnet: UsageWindow?
    let extraUsage: ExtraUsage?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
        case extraUsage = "extra_usage"
    }

    /// The windows shown in the UI, in display order.
    ///
    /// The Opus and Sonnet sub-windows are omitted — they are informational breakdowns
    /// of the 7-day total and do not represent independent rate limits the user can act on.
    var allWindows: [(MenuBarWindow, UsageWindow)] {
        var result: [(MenuBarWindow, UsageWindow)] = []
        if let w = fiveHour { result.append((.fiveHour, w)) }
        if let w = sevenDay { result.append((.sevenDay, w)) }
        return result
    }
}

/// A single rate-limit window returned by the usage API.
struct UsageWindow: Codable {
    /// Utilization as a percentage (0–100+; may slightly exceed 100 when overages are permitted).
    let utilization: Double
    /// ISO 8601 timestamp of the next reset, as returned by the API.
    let resetsAt: String

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }

    /// Parses `resetsAt` into a `Date`.
    ///
    /// The API returns timestamps both with and without fractional seconds depending on the
    /// server — two formatters are tried in order to handle both forms.
    var resetsAtDate: Date? {
        Self.formatterWithFractional.date(from: resetsAt)
            ?? Self.formatterWithout.date(from: resetsAt)
    }

    /// Utilization clamped to `[0, 1]` for use with `ProgressView`.
    var utilizationFraction: Double {
        min(utilization / 100.0, 1.0)
    }

    /// Continuous urgency gradient: green (low) → yellow → orange → red (high).
    var utilizationColor: Color {
        urgencyColor(utilization / 100.0)
    }

    private static let formatterWithFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let formatterWithout: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}

/// Pay-as-you-go credit usage, present when the account has extra usage enabled.
struct ExtraUsage: Codable {
    let isEnabled: Bool
    let monthlyLimit: Double?
    let usedCredits: Double?
    let utilization: Double?

    enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
        case monthlyLimit = "monthly_limit"
        case usedCredits = "used_credits"
        case utilization
    }
}

/// A claude.ai organization, used only to extract the UUID for usage API calls.
struct Organization: Codable {
    let uuid: String
    let name: String
}

/// Account profile returned by `/api/account`.
struct AccountInfo: Codable {
    let fullName: String?
    let emailAddress: String
    /// Organization memberships; only the first entry is used to determine subscription tier.
    let memberships: [AccountMembership]?

    enum CodingKeys: String, CodingKey {
        case fullName = "full_name"
        case emailAddress = "email_address"
        case memberships
    }

    var displayName: String { fullName ?? emailAddress }

    /// Human-readable plan label derived from `capabilities` and `rate_limit_tier`.
    ///
    /// The API exposes no dedicated tier field. The tier is inferred by combining
    /// the capability set (e.g. `"claude_max"`) with the tier slug string
    /// (e.g. `"default_claude_max_5x"`). Returns `nil` for unrecognised or free accounts.
    var subscriptionLabel: String? {
        guard let org = memberships?.first?.organization else { return nil }
        let caps = Set(org.capabilities ?? [])
        let tier = org.rateLimitTier ?? ""
        if caps.contains("claude_max") {
            if tier.contains("20x") { return "Max 20×" }
            if tier.contains("5x")  { return "Max 5×" }
            return "Max"
        }
        if caps.contains("claude_pro") || tier.contains("_pro") { return "Pro" }
        if caps.contains("claude_team")       { return "Team" }
        if caps.contains("claude_enterprise") { return "Enterprise" }
        return nil
    }
}

struct AccountMembership: Codable {
    let organization: AccountOrganization
}

/// Organization-level fields used to infer subscription tier.
struct AccountOrganization: Codable {
    let capabilities: [String]?
    let rateLimitTier: String?

    enum CodingKeys: String, CodingKey {
        case capabilities
        case rateLimitTier = "rate_limit_tier"
    }
}

// MARK: - Usage History

/// A single timestamped utilization snapshot, stored persistently for the charts tab.
///
/// Sampled at most once every 5 minutes regardless of poll rate, so a 2016-entry cap
/// covers exactly 7 days — the full 7-day window at this resolution.
struct UsageDataPoint: Codable, Identifiable {
    let timestamp: Date
    let fiveHour: Double?
    let sevenDay: Double?
    /// Consumption rate in %/hr at snapshot time; nil when history was insufficient.
    let fiveHourPace: Double?
    let sevenDayPace: Double?
    var id: Date { timestamp }
}

// MARK: - Menu Bar Display Option

/// The rate-limit window whose utilization the menu bar label tracks.
enum MenuBarWindow: String, CaseIterable, Identifiable {
    case fiveHour = "five_hour"
    case sevenDay = "seven_day"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fiveHour: return String(localized: "5-Hour Window")
        case .sevenDay: return String(localized: "7-Day Window")
        }
    }
}

/// A newer version discovered via the GitHub Releases API.
struct UpdateInfo {
    let version: String
    let releaseURL: URL
    /// Direct ZIP download URL from the GitHub release assets, if present.
    let downloadURL: URL?
}
