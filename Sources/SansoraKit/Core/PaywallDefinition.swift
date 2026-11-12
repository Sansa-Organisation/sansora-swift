import Foundation

/// `sansora.paywall/1` (packages/core/src/paywall.ts).
public struct PaywallDefinition: Codable, Equatable, Sendable {
    public static let schemaId = "sansora.paywall/1"
    public var schema: String
    public var name: String
    public var locale: String
    public var theme: Theme
    public var palette: Palette
    public var products: [Product]
    public var blocks: [Block]
    /// Consecutive runs of `blocks`, adding up to all of them. nil means one page.
    public var pages: [Page]?
    /// Translated text, keyed by source text.
    public var translations: [Translation]?

    public struct Page: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var blockCount: Int
        public var nextLabel: String
    }

    public struct Translation: Codable, Equatable, Sendable {
        public struct Entry: Codable, Equatable, Sendable {
            public var source: String
            public var text: String
            public var origin: String
        }
        public var locale: String
        public var strings: [Entry]
    }

    public enum Theme: String, Codable, Sendable { case light, dark }

    public struct Palette: Codable, Equatable, Sendable {
        public var background: String
        public var surface: String
        public var text: String
        public var muted: String
        public var accent: String
        public var hero: String
    }

    public enum Period: String, Codable, Sendable { case week, month, year, lifetime }

    public struct Product: Codable, Equatable, Sendable {
        public var id: String
        public var storeProductId: String
        public var label: String
        public var period: Period
        public var trialDays: Int
        /// Typed in the editor for the preview only; the app always shows the store price.
        public var previewPrice: Double?
        public var currency: String

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            storeProductId = try c.decode(String.self, forKey: .storeProductId)
            label = try c.decode(String.self, forKey: .label)
            period = try c.decode(Period.self, forKey: .period)
            trialDays = try c.decode(Int.self, forKey: .trialDays)
            previewPrice = try c.decodeIfPresent(Double.self, forKey: .previewPrice)
            currency = try c.decode(String.self, forKey: .currency)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(storeProductId, forKey: .storeProductId)
            try c.encode(label, forKey: .label)
            try c.encode(period, forKey: .period)
            try c.encode(trialDays, forKey: .trialDays)
            try c.encode(previewPrice, forKey: .previewPrice)
            try c.encode(currency, forKey: .currency)
        }

        enum CodingKeys: String, CodingKey { case id, storeProductId, label, period, trialDays, previewPrice, currency }
    }

    public enum Position: String, Codable, Sendable { case left, right }

    public struct Badge: Codable, Equatable, Sendable { public var productId: String; public var text: String }
    public struct Quote: Codable, Equatable, Sendable { public var quote: String; public var author: String }
    public struct Question: Codable, Equatable, Sendable { public var question: String; public var answer: String }
    public struct ComparisonRow: Codable, Equatable, Sendable { public var feature: String; public var free: Bool; public var pro: Bool }

    /// The 11 block types. Unknown types (a newer editor) decode to `.unknown` and are not drawn.
    public enum Block: Codable, Equatable, Sendable {
        case close(position: Position, delaySeconds: Int)
        case hero(height: Int, imageUrl: String)
        case headline(text: String, subtext: String)
        case benefits(items: [String])
        case plans(productIds: [String], selected: String, badge: Badge?, showPerMonth: Bool)
        case trialTimeline(reminderDay: Int)
        case testimonials(items: [Quote])
        case faq(items: [Question])
        case comparison(rows: [ComparisonRow])
        case cta(label: String)
        case legal(termsUrl: String, privacyUrl: String, restore: Bool, text: String)
        case unknown(type: String)

        enum K: String, CodingKey {
            case type, position, delaySeconds, height, imageUrl, text, subtext, items, productIds, selected, badge, showPerMonth
            case reminderDay, rows, label, termsUrl, privacyUrl, restore
        }

        public var type: String {
            switch self {
            case .close: return "close"
            case .hero: return "hero"
            case .headline: return "headline"
            case .benefits: return "benefits"
            case .plans: return "plans"
            case .trialTimeline: return "trial_timeline"
            case .testimonials: return "testimonials"
            case .faq: return "faq"
            case .comparison: return "comparison"
            case .cta: return "cta"
            case .legal: return "legal"
            case .unknown(let t): return t
            }
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: K.self)
            let type = try c.decode(String.self, forKey: .type)
            switch type {
            case "close": self = .close(position: try c.decode(Position.self, forKey: .position), delaySeconds: try c.decode(Int.self, forKey: .delaySeconds))
            case "hero": self = .hero(height: try c.decode(Int.self, forKey: .height), imageUrl: try c.decode(String.self, forKey: .imageUrl))
            case "headline": self = .headline(text: try c.decode(String.self, forKey: .text), subtext: try c.decode(String.self, forKey: .subtext))
            case "benefits": self = .benefits(items: try c.decode([String].self, forKey: .items))
            case "plans":
                self = .plans(productIds: try c.decode([String].self, forKey: .productIds), selected: try c.decode(String.self, forKey: .selected),
                              badge: try c.decodeIfPresent(Badge.self, forKey: .badge), showPerMonth: try c.decode(Bool.self, forKey: .showPerMonth))
            case "trial_timeline": self = .trialTimeline(reminderDay: try c.decode(Int.self, forKey: .reminderDay))
            case "testimonials": self = .testimonials(items: try c.decode([Quote].self, forKey: .items))
            case "faq": self = .faq(items: try c.decode([Question].self, forKey: .items))
            case "comparison": self = .comparison(rows: try c.decode([ComparisonRow].self, forKey: .rows))
            case "cta": self = .cta(label: try c.decode(String.self, forKey: .label))
            case "legal":
                self = .legal(termsUrl: try c.decode(String.self, forKey: .termsUrl), privacyUrl: try c.decode(String.self, forKey: .privacyUrl),
                              restore: try c.decode(Bool.self, forKey: .restore), text: try c.decode(String.self, forKey: .text))
            default: self = .unknown(type: type)
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: K.self)
            try c.encode(type, forKey: .type)
            switch self {
            case let .close(position, delay): try c.encode(position, forKey: .position); try c.encode(delay, forKey: .delaySeconds)
            case let .hero(height, url): try c.encode(height, forKey: .height); try c.encode(url, forKey: .imageUrl)
            case let .headline(text, sub): try c.encode(text, forKey: .text); try c.encode(sub, forKey: .subtext)
            case let .benefits(items): try c.encode(items, forKey: .items)
            case let .plans(ids, selected, badge, perMonth):
                try c.encode(ids, forKey: .productIds); try c.encode(selected, forKey: .selected)
                try c.encode(badge, forKey: .badge); try c.encode(perMonth, forKey: .showPerMonth)
            case let .trialTimeline(day): try c.encode(day, forKey: .reminderDay)
            case let .testimonials(items): try c.encode(items, forKey: .items)
            case let .faq(items): try c.encode(items, forKey: .items)
            case let .comparison(rows): try c.encode(rows, forKey: .rows)
            case let .cta(label): try c.encode(label, forKey: .label)
            case let .legal(terms, privacy, restore, text):
                try c.encode(terms, forKey: .termsUrl); try c.encode(privacy, forKey: .privacyUrl)
                try c.encode(restore, forKey: .restore); try c.encode(text, forKey: .text)
            case .unknown: break
            }
        }
    }
}
