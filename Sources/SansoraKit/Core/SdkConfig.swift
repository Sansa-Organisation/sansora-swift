import Foundation
import CryptoKit

/// `sansora.config/1` (packages/core/src/sdk-config.ts): active campaigns and
/// the approved paywall versions they show.
public struct SdkConfig: Codable, Equatable, Sendable {
    public static let schemaId = "sansora.config/1"
    public var schema: String
    public var appId: String
    public var generatedAt: Int64
    public var paywalls: [ConfigPaywall]
    public var campaigns: [ConfigCampaign]

    public struct ConfigPaywall: Codable, Equatable, Sendable {
        public var versionId: String
        public var paywallId: String
        public var version: Int
        public var variant: String
        public var definition: PaywallDefinition
    }

    public struct Variant: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        /// nil: a holdout arm.
        public var paywallVersionId: String?
        public var allocationBps: Int
    }

    public struct Experiment: Codable, Equatable, Sendable {
        public var id: String
        public var variants: [Variant]
    }

    public struct ConfigCampaign: Codable, Equatable, Sendable {
        public var id: String
        public var placement: String
        public var audience: Audience
        public var frequency: String
        public var priority: Int
        public var holdoutBps: Int
        public var paywallVersionId: String
        public var experiment: Experiment?
    }

    /// Parses a downloaded or bundled config; nil unless the schema is `sansora.config/1`.
    public static func parse(_ data: Data) -> SdkConfig? {
        guard let c = try? JSONDecoder().decode(SdkConfig.self, from: data), c.schema == schemaId else { return nil }
        return c
    }

    public func paywall(versionId: String) -> ConfigPaywall? { paywalls.first { $0.versionId == versionId } }
}

/// Display history: `paywall_shown` times per campaign and the campaigns shown this session.
public struct DisplayHistory: Codable, Equatable, Sendable {
    public var shown: [String: [Int64]]
    public var session: [String]
    public init(shown: [String: [Int64]] = [:], session: [String] = []) { self.shown = shown; self.session = session }

    /// Records a display, keeping the latest 50 times per campaign.
    public mutating func record(campaignId: String, at now: Int64) {
        var times = shown[campaignId] ?? []
        times.append(now)
        if times.count > 50 { times.removeFirst(times.count - 50) }
        shown[campaignId] = times
        if !session.contains(campaignId) { session.append(campaignId) }
    }
}

public enum NoCampaignReason: String, Codable, Sendable {
    case noCampaignForPlacement = "no_campaign_for_placement"
    case noAudienceMatch = "no_audience_match"
    case frequencyCapped = "frequency_capped"
}

/// What `resolvePlacement` decided.
public enum Resolution: Equatable, Sendable {
    case paywall(campaignId: String, versionId: String, paywallId: String, variant: String, experimentId: String?, experimentVariantId: String?)
    case holdout(campaignId: String, experimentId: String?, experimentVariantId: String?)
    case noCampaign(NoCampaignReason)

    public var json: JSONValue {
        let s: (String?) -> JSONValue = { $0.map(JSONValue.string) ?? .null }
        switch self {
        case let .paywall(c, v, p, variant, e, ev):
            return .object(["kind": .string("paywall"), "campaignId": .string(c), "versionId": .string(v), "paywallId": .string(p),
                            "variant": .string(variant), "experimentId": s(e), "experimentVariantId": s(ev)])
        case let .holdout(c, e, ev):
            return .object(["kind": .string("holdout"), "campaignId": .string(c), "experimentId": s(e), "experimentVariantId": s(ev)])
        case let .noCampaign(r):
            return .object(["kind": .string("no_campaign"), "reason": .string(r.rawValue)])
        }
    }
}

public enum Assignment {
    /// SHA-256 of the UTF-8 seed: first 4 bytes big-endian unsigned, mod 10000.
    public static func bucket(_ seed: String) -> Int {
        let d = Array(SHA256.hash(data: Data(seed.utf8)))
        let n = (UInt32(d[0]) << 24) | (UInt32(d[1]) << 16) | (UInt32(d[2]) << 8) | UInt32(d[3])
        return Int(n % 10000)
    }

    public static func sha256Hex(_ seed: String) -> String {
        SHA256.hash(data: Data(seed.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func holdoutSeed(_ campaignId: String, _ appUserId: String) -> String { "holdout:\(campaignId):\(appUserId)" }
    public static func experimentSeed(_ experimentId: String, _ appUserId: String) -> String { "experiment:\(experimentId):\(appUserId)" }

    static func assignVariant(_ variants: [SdkConfig.Variant], _ b: Int) -> SdkConfig.Variant {
        var sum = 0
        for v in variants { sum += v.allocationBps; if b < sum { return v } }
        return variants[variants.count - 1]
    }

    static let day: Int64 = 86_400_000

    public static func frequencyAllows(_ f: String, times: [Int64], inSession: Bool, now: Int64) -> Bool {
        switch f {
        case "once_per_session": return !inSession
        case "once_per_day": return !times.contains { now - $0 < day }
        case "once_per_week": return !times.contains { now - $0 < 7 * day }
        case "once_ever": return times.isEmpty
        default: return true
        }
    }

    /// Exactly `resolvePlacement` in sdk-config.ts.
    public static func resolvePlacement(_ config: SdkConfig, placement: String, appUserId: String, user: UserAttributes,
                                        history: DisplayHistory, now: Int64) -> Resolution {
        let list = config.campaigns.filter { $0.placement == placement }.sorted {
            $0.priority != $1.priority ? $0.priority < $1.priority : Array($0.id.utf16).lexicographicallyPrecedes(Array($1.id.utf16))
        }
        if list.isEmpty { return .noCampaign(.noCampaignForPlacement) }
        var matched = false
        for c in list {
            if !AudienceEvaluator.matches(c.audience, user) { continue }
            matched = true
            if !frequencyAllows(c.frequency, times: history.shown[c.id] ?? [], inSession: history.session.contains(c.id), now: now) { continue }
            if c.holdoutBps > 0 && bucket(holdoutSeed(c.id, appUserId)) < c.holdoutBps {
                return .holdout(campaignId: c.id, experimentId: nil, experimentVariantId: nil)
            }
            if let exp = c.experiment, !exp.variants.isEmpty {
                let v = assignVariant(exp.variants, bucket(experimentSeed(exp.id, appUserId)))
                guard let vid = v.paywallVersionId else {
                    return .holdout(campaignId: c.id, experimentId: exp.id, experimentVariantId: v.id)
                }
                guard let p = config.paywall(versionId: vid) else { continue }
                let arm = v.name == "A" || v.name == "B" ? v.name : p.variant
                return .paywall(campaignId: c.id, versionId: p.versionId, paywallId: p.paywallId, variant: arm, experimentId: exp.id, experimentVariantId: v.id)
            }
            guard let p = config.paywall(versionId: c.paywallVersionId) else { continue }
            return .paywall(campaignId: c.id, versionId: p.versionId, paywallId: p.paywallId, variant: p.variant, experimentId: nil, experimentVariantId: nil)
        }
        return .noCampaign(matched ? .frequencyCapped : .noAudienceMatch)
    }
}
