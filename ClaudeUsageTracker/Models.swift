import Foundation
import SwiftUI

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

    var allWindows: [(String, UsageWindow)] {
        var result: [(String, UsageWindow)] = []
        if let w = fiveHour { result.append(("5-Hour Window", w)) }
        if let w = sevenDay { result.append(("7-Day Window", w)) }
        return result
    }
}

struct UsageWindow: Codable {
    let utilization: Double
    let resetsAt: String

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }

    var resetsAtDate: Date? {
        Self.formatterWithFractional.date(from: resetsAt)
            ?? Self.formatterWithout.date(from: resetsAt)
    }

    var utilizationFraction: Double {
        min(utilization / 100.0, 1.0)
    }

    var utilizationColor: Color {
        if utilization >= 80 { return .red }
        if utilization >= 50 { return .orange }
        return .green
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

struct Organization: Codable {
    let uuid: String
    let name: String
}

struct AccountInfo: Codable {
    let fullName: String?
    let emailAddress: String
    let memberships: [AccountMembership]?

    enum CodingKeys: String, CodingKey {
        case fullName = "full_name"
        case emailAddress = "email_address"
        case memberships
    }

    var displayName: String { fullName ?? emailAddress }

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

struct AccountOrganization: Codable {
    let capabilities: [String]?
    let rateLimitTier: String?

    enum CodingKeys: String, CodingKey {
        case capabilities
        case rateLimitTier = "rate_limit_tier"
    }
}

// MARK: - Menu Bar Display Option

enum MenuBarWindow: String, CaseIterable, Identifiable {
    case fiveHour = "five_hour"
    case sevenDay = "seven_day"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fiveHour: return "5-Hour Window"
        case .sevenDay: return "7-Day Window"
        }
    }
}
