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
    /// Where the content sits when it is shorter than the screen (0.3.0); nil means `top`. A page may set its own.
    public var align: Align?
    /// Translated text, keyed by source text.
    public var translations: [Translation]?

    enum CodingKeys: String, CodingKey { case schema, name, locale, theme, palette, products, blocks, pages, align, translations }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decode(String.self, forKey: .schema)
        name = try c.decode(String.self, forKey: .name)
        locale = try c.decode(String.self, forKey: .locale)
        theme = try c.decode(Theme.self, forKey: .theme)
        palette = try c.decode(Palette.self, forKey: .palette)
        products = try c.decode([Product].self, forKey: .products)
        blocks = try c.decode([Block].self, forKey: .blocks)
        pages = try c.decodeIfPresent([Page].self, forKey: .pages)
        align = c.layoutValue(Align.self, forKey: .align)
        translations = try c.decodeIfPresent([Translation].self, forKey: .translations)
    }

    public struct Page: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var blockCount: Int
        public var nextLabel: String
        /// Where this page's content sits when it is shorter than the screen (0.3.0); nil means the paywall's `align`.
        public var align: Align?

        enum CodingKeys: String, CodingKey { case id, name, blockCount, nextLabel, align }

        public init(id: String, name: String, blockCount: Int, nextLabel: String, align: Align? = nil) {
            self.id = id; self.name = name; self.blockCount = blockCount; self.nextLabel = nextLabel; self.align = align
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            name = try c.decode(String.self, forKey: .name)
            blockCount = try c.decode(Int.self, forKey: .blockCount)
            nextLabel = try c.decode(String.self, forKey: .nextLabel)
            align = c.layoutValue(Align.self, forKey: .align)
        }
    }

    // MARK: Layout (0.3.0, docs/PAYWALLS.md § Layout)
    //
    // Optional fields on existing blocks and pages. A value this SDK does not know (a newer editor) reads as left
    // out, so the default applies and the paywall still shows; known values are written back as they were read.

    /// Where the content sits when it is shorter than the screen.
    public enum Align: String, Codable, Sendable { case top, center, bottom }

    /// `bottom` keeps a block in the area pinned to the bottom of the screen; `unpinned` (JSON `none`) keeps it in the
    /// content. Left out, a purchase button and legal footer that end a page are pinned.
    public enum Pin: String, Codable, Sendable { case bottom, unpinned = "none" }

    /// `overlay`: a ✕ floating in the top corner (the default). `bar`: a top bar with the close button on its side and
    /// other items in the free slots. `row`: the close button in its own row in the content, as before 0.3.0.
    public enum CloseStyle: String, Codable, Sendable { case overlay, bar, row }

    /// The layout of a block other than close: `pin` and `spaceBefore` (extra points above the block). nil is left out.
    public struct Placement: Equatable, Sendable {
        public var pin: Pin?
        public var spaceBefore: Int?
        public init(pin: Pin? = nil, spaceBefore: Int? = nil) { self.pin = pin; self.spaceBefore = spaceBefore }
    }

    /// What can sit in the top bar beside the close button.
    public enum BarItem: Codable, Equatable, Sendable {
        case back
        case restore
        case text(String)
        case progress
        case image(imageUrl: String, height: Int)
        /// A kind from a newer editor: not drawn.
        case unknown(kind: String)

        enum K: String, CodingKey { case kind, text, imageUrl, height }

        public var kind: String {
            switch self {
            case .back: return "back"
            case .restore: return "restore"
            case .text: return "text"
            case .progress: return "progress"
            case .image: return "image"
            case .unknown(let k): return k
            }
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: K.self)
            let kind = try c.decode(String.self, forKey: .kind)
            switch kind {
            case "back": self = .back
            case "restore": self = .restore
            case "text": self = .text(try c.decode(String.self, forKey: .text))
            case "progress": self = .progress
            case "image": self = .image(imageUrl: try c.decode(String.self, forKey: .imageUrl), height: try c.decode(Int.self, forKey: .height))
            default: self = .unknown(kind: kind)
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: K.self)
            try c.encode(kind, forKey: .kind)
            switch self {
            case let .text(text): try c.encode(text, forKey: .text)
            case let .image(url, height): try c.encode(url, forKey: .imageUrl); try c.encode(height, forKey: .height)
            case .back, .restore, .progress, .unknown: break
            }
        }
    }

    /// The top bar's other slots (`style` `bar`). The close button takes the slot on its `position` side. nil is empty;
    /// a slot written as `null` is written back as `null`, one left out stays left out.
    public struct Bar: Codable, Equatable, Sendable {
        public var leading: BarItem?
        public var center: BarItem?
        public var trailing: BarItem?
        /// Slots that were `null` rather than left out.
        var nullSlots: Set<String> = []

        enum CodingKeys: String, CodingKey, CaseIterable { case leading, center, trailing }

        public init(leading: BarItem? = nil, center: BarItem? = nil, trailing: BarItem? = nil) {
            self.leading = leading; self.center = center; self.trailing = trailing
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            var nulls: Set<String> = []
            func slot(_ k: CodingKeys) throws -> BarItem? {
                guard c.contains(k) else { return nil }
                if try c.decodeNil(forKey: k) { nulls.insert(k.rawValue); return nil }
                return try c.decode(BarItem.self, forKey: k)
            }
            leading = try slot(.leading); center = try slot(.center); trailing = try slot(.trailing)
            nullSlots = nulls
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            for (k, item) in [(CodingKeys.leading, leading), (.center, center), (.trailing, trailing)] {
                if let item { try c.encode(item, forKey: k) } else if nullSlots.contains(k.rawValue) { try c.encodeNil(forKey: k) }
            }
        }

        /// Null and left out mean the same: empty.
        public static func == (a: Bar, b: Bar) -> Bool { a.leading == b.leading && a.center == b.center && a.trailing == b.trailing }
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
    /// 0.3.0: close has `style`, `label` and `bar`; every other block ends with its `placement` (`pin`, `spaceBefore`).
    /// All default to left out, so existing constructions still compile; a `switch` binds one more value.
    public enum Block: Codable, Equatable, Sendable {
        /// `label` (bar and row only) is text instead of the ✕; `bar` fills the top bar's other slots (style `bar`).
        case close(position: Position, delaySeconds: Int, style: CloseStyle? = nil, label: String? = nil, bar: Bar? = nil)
        case hero(height: Int, imageUrl: String, placement: Placement = .init())
        case headline(text: String, subtext: String, placement: Placement = .init())
        case benefits(items: [String], placement: Placement = .init())
        case plans(productIds: [String], selected: String, badge: Badge?, showPerMonth: Bool, placement: Placement = .init())
        case trialTimeline(reminderDay: Int, placement: Placement = .init())
        case testimonials(items: [Quote], placement: Placement = .init())
        case faq(items: [Question], placement: Placement = .init())
        case comparison(rows: [ComparisonRow], placement: Placement = .init())
        case cta(label: String, placement: Placement = .init())
        /// `textGooglePlay` (0.2.1): the Google Play version of `text`, for Android. iOS and macOS always show `text`.
        case legal(termsUrl: String, privacyUrl: String, restore: Bool, text: String, textGooglePlay: String? = nil, placement: Placement = .init())
        case unknown(type: String)

        enum K: String, CodingKey {
            case type, position, delaySeconds, height, imageUrl, text, subtext, items, productIds, selected, badge, showPerMonth
            case reminderDay, rows, label, termsUrl, privacyUrl, restore, textGooglePlay, style, bar, pin, spaceBefore
        }

        /// `pin` and `spaceBefore`; nil for close and unknown blocks.
        public var placement: Placement? {
            switch self {
            case .close, .unknown: return nil
            case let .hero(_, _, p), let .headline(_, _, p), let .benefits(_, p), let .plans(_, _, _, _, p), let .trialTimeline(_, p),
                 let .testimonials(_, p), let .faq(_, p), let .comparison(_, p), let .cta(_, p), let .legal(_, _, _, _, _, p):
                return p
            }
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
            let place = { () throws -> Placement in
                Placement(pin: c.layoutValue(Pin.self, forKey: .pin), spaceBefore: try c.decodeIfPresent(Int.self, forKey: .spaceBefore))
            }
            switch type {
            case "close":
                self = .close(position: try c.decode(Position.self, forKey: .position), delaySeconds: try c.decode(Int.self, forKey: .delaySeconds),
                              style: c.layoutValue(CloseStyle.self, forKey: .style), label: try c.decodeIfPresent(String.self, forKey: .label),
                              bar: try c.decodeIfPresent(Bar.self, forKey: .bar))
            case "hero": self = .hero(height: try c.decode(Int.self, forKey: .height), imageUrl: try c.decode(String.self, forKey: .imageUrl), placement: try place())
            case "headline": self = .headline(text: try c.decode(String.self, forKey: .text), subtext: try c.decode(String.self, forKey: .subtext), placement: try place())
            case "benefits": self = .benefits(items: try c.decode([String].self, forKey: .items), placement: try place())
            case "plans":
                self = .plans(productIds: try c.decode([String].self, forKey: .productIds), selected: try c.decode(String.self, forKey: .selected),
                              badge: try c.decodeIfPresent(Badge.self, forKey: .badge), showPerMonth: try c.decode(Bool.self, forKey: .showPerMonth),
                              placement: try place())
            case "trial_timeline": self = .trialTimeline(reminderDay: try c.decode(Int.self, forKey: .reminderDay), placement: try place())
            case "testimonials": self = .testimonials(items: try c.decode([Quote].self, forKey: .items), placement: try place())
            case "faq": self = .faq(items: try c.decode([Question].self, forKey: .items), placement: try place())
            case "comparison": self = .comparison(rows: try c.decode([ComparisonRow].self, forKey: .rows), placement: try place())
            case "cta": self = .cta(label: try c.decode(String.self, forKey: .label), placement: try place())
            case "legal":
                self = .legal(termsUrl: try c.decode(String.self, forKey: .termsUrl), privacyUrl: try c.decode(String.self, forKey: .privacyUrl),
                              restore: try c.decode(Bool.self, forKey: .restore), text: try c.decode(String.self, forKey: .text),
                              textGooglePlay: try c.decodeIfPresent(String.self, forKey: .textGooglePlay), placement: try place())
            default: self = .unknown(type: type)
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: K.self)
            try c.encode(type, forKey: .type)
            switch self {
            case let .close(position, delay, style, label, bar):
                try c.encode(position, forKey: .position); try c.encode(delay, forKey: .delaySeconds)
                try c.encodeIfPresent(style, forKey: .style); try c.encodeIfPresent(label, forKey: .label); try c.encodeIfPresent(bar, forKey: .bar)
            case let .hero(height, url, _): try c.encode(height, forKey: .height); try c.encode(url, forKey: .imageUrl)
            case let .headline(text, sub, _): try c.encode(text, forKey: .text); try c.encode(sub, forKey: .subtext)
            case let .benefits(items, _): try c.encode(items, forKey: .items)
            case let .plans(ids, selected, badge, perMonth, _):
                try c.encode(ids, forKey: .productIds); try c.encode(selected, forKey: .selected)
                try c.encode(badge, forKey: .badge); try c.encode(perMonth, forKey: .showPerMonth)
            case let .trialTimeline(day, _): try c.encode(day, forKey: .reminderDay)
            case let .testimonials(items, _): try c.encode(items, forKey: .items)
            case let .faq(items, _): try c.encode(items, forKey: .items)
            case let .comparison(rows, _): try c.encode(rows, forKey: .rows)
            case let .cta(label, _): try c.encode(label, forKey: .label)
            case let .legal(terms, privacy, restore, text, textGooglePlay, _):
                try c.encode(terms, forKey: .termsUrl); try c.encode(privacy, forKey: .privacyUrl)
                try c.encode(restore, forKey: .restore); try c.encode(text, forKey: .text)
                try c.encodeIfPresent(textGooglePlay, forKey: .textGooglePlay)
            case .unknown: break
            }
            if let p = placement {
                try c.encodeIfPresent(p.pin, forKey: .pin); try c.encodeIfPresent(p.spaceBefore, forKey: .spaceBefore)
            }
        }
    }
}

extension KeyedDecodingContainer {
    /// A layout value (0.3.0) this SDK knows, or nil when it is left out or unknown (a newer editor): the default applies.
    func layoutValue<T: RawRepresentable>(_ type: T.Type, forKey key: Key) -> T? where T.RawValue == String {
        (try? decodeIfPresent(String.self, forKey: key)).flatMap { $0 }.flatMap(T.init(rawValue:))
    }
}
