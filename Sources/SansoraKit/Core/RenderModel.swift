import Foundation

/// One product as the store reports it for this user. `trialDays` is the free
/// trial this user is eligible for (0 when none or not eligible).
public struct StorePrice: Codable, Equatable, Sendable {
    public var priceMicros: Int64
    public var currency: String
    public var displayPrice: String
    public var trialDays: Int
    public init(priceMicros: Int64, currency: String, displayPrice: String, trialDays: Int) {
        self.priceMicros = priceMicros; self.currency = currency; self.displayPrice = displayPrice; self.trialDays = trialDays
    }
}

/// `sansora.render/1` (packages/core/src/sdk-render.ts): what the native views draw.
public struct RenderModel: Equatable, Sendable {
    public static let schemaId = "sansora.render/1"
    public typealias Align = PaywallDefinition.Align
    public typealias CloseStyle = PaywallDefinition.CloseStyle
    public var name: String
    public var locale: String
    public var theme: PaywallDefinition.Theme
    public var palette: PaywallDefinition.Palette
    public var selectedProductId: String?
    /// The selected plan has a store price, so the purchase button works.
    public var purchasable: Bool
    public var blocks: [Block]
    /// Where the content sits when it is shorter than the screen (0.3.0); with `pages`, each page has its own.
    public var align: Align = .top
    /// Only for a paged definition. Each page holds its share of `blocks`.
    public var pages: [Page]?
    /// `rtl` only for a translated right-to-left view.
    public var direction: String?
    /// Only for a translated view: the words the views draw themselves.
    public var labels: Labels?

    public struct Page: Equatable, Sendable {
        public var id: String
        /// nil on the last page.
        public var nextLabel: String?
        /// This page's `align`, else the paywall's (0.3.0).
        public var align: Align = .top
        public var blocks: [Block]
    }

    public struct Labels: Equatable, Sendable {
        public var terms: String
        public var privacy: String
        public var restore: String
        public var close: String
        public var unavailablePrice: String
    }

    public struct Plan: Equatable, Sendable {
        public var productId: String
        public var storeProductId: String
        public var period: PaywallDefinition.Period
        public var title: String
        public var priceLine: String?
        public var badge: String?
        public var selected: Bool
    }

    public struct Step: Equatable, Sendable { public var label: String; public var text: String }

    /// Layout of a block other than close (0.3.0): `pinned` blocks are drawn in the area pinned to the bottom of the
    /// screen, in order; `spaceBefore` is extra space above the block in points.
    public struct Placement: Equatable, Sendable {
        public var pinned: Bool
        public var spaceBefore: Int
        public init(pinned: Bool = false, spaceBefore: Int = 0) { self.pinned = pinned; self.spaceBefore = spaceBefore }
    }

    /// A top bar item resolved for its page: words translated, back left out on the first page and page dots on a
    /// paywall with one page.
    public enum BarItem: Equatable, Sendable {
        case back(label: String)
        case restore(label: String)
        case text(String)
        /// `index` is 0-based.
        case progress(index: Int, count: Int, label: String)
        case image(imageUrl: String, height: Int)
    }

    /// The top bar's other slots; nil is empty.
    public struct Bar: Equatable, Sendable {
        public var leading: BarItem?
        public var center: BarItem?
        public var trailing: BarItem?
        public init(leading: BarItem? = nil, center: BarItem? = nil, trailing: BarItem? = nil) {
            self.leading = leading; self.center = center; self.trailing = trailing
        }
    }

    public enum Block: Equatable, Sendable {
        /// `label`: text instead of the ✕ (bar and row only, else nil). `bar`: only for `style` `bar`.
        case close(position: PaywallDefinition.Position, delaySeconds: Int, style: CloseStyle = .overlay, label: String? = nil, bar: Bar? = nil)
        /// Only with an image (0.3.0).
        case hero(height: Int, imageUrl: String, placement: Placement = .init())
        case headline(text: String, subtext: String?, placement: Placement = .init())
        case benefits(items: [String], placement: Placement = .init())
        case plans([Plan], placement: Placement = .init())
        case trialTimeline(steps: [Step], placement: Placement = .init())
        case testimonials(items: [PaywallDefinition.Quote], placement: Placement = .init())
        case faq(items: [PaywallDefinition.Question], placement: Placement = .init())
        case comparison(columns: [String], rows: [PaywallDefinition.ComparisonRow], placement: Placement = .init())
        case cta(label: String, enabled: Bool, placement: Placement = .init())
        case legal(text: String, termsUrl: String?, privacyUrl: String?, restore: Bool, placement: Placement = .init())

        /// `pinned` and `spaceBefore`; nil for close.
        public var placement: Placement? {
            switch self {
            case .close: return nil
            case let .hero(_, _, p), let .headline(_, _, p), let .benefits(_, p), let .plans(_, p), let .trialTimeline(_, p),
                 let .testimonials(_, p), let .faq(_, p), let .comparison(_, _, p), let .cta(_, _, p), let .legal(_, _, _, _, p):
                return p
            }
        }
    }

    public static let unavailablePrice = "Price unavailable"

    public var json: JSONValue {
        let s: (String?) -> JSONValue = { $0.map(JSONValue.string) ?? .null }
        let n: (Int) -> JSONValue = { .number(Double($0)) }
        let item: (BarItem?) -> JSONValue = { i in
            switch i {
            case nil: return .null
            case let .back(label)?: return .object(["kind": "back", "label": .string(label)])
            case let .restore(label)?: return .object(["kind": "restore", "label": .string(label)])
            case let .text(text)?: return .object(["kind": "text", "text": .string(text)])
            case let .progress(index, count, label)?: return .object(["kind": "progress", "index": n(index), "count": n(count), "label": .string(label)])
            case let .image(url, height)?: return .object(["kind": "image", "imageUrl": .string(url), "height": n(height)])
            }
        }
        let encode: (Block) -> JSONValue = { b in
            var o: [String: JSONValue]
            switch b {
            case let .close(p, d, style, label, bar):
                o = ["type": "close", "position": .string(p.rawValue), "delaySeconds": n(d), "style": .string(style.rawValue), "label": s(label),
                     "bar": bar.map { .object(["leading": item($0.leading), "center": item($0.center), "trailing": item($0.trailing)]) } ?? .null]
            case let .hero(h, u, _): o = ["type": "hero", "height": n(h), "imageUrl": .string(u)]
            case let .headline(t, sub, _): o = ["type": "headline", "text": .string(t), "subtext": s(sub)]
            case let .benefits(items, _): o = ["type": "benefits", "items": .array(items.map(JSONValue.string))]
            case let .plans(plans, _):
                o = ["type": "plans", "plans": .array(plans.map { p in
                    .object(["productId": .string(p.productId), "storeProductId": .string(p.storeProductId), "period": .string(p.period.rawValue),
                             "title": .string(p.title), "priceLine": s(p.priceLine), "badge": s(p.badge), "selected": .bool(p.selected)])
                })]
            case let .trialTimeline(steps, _):
                o = ["type": "trial_timeline", "steps": .array(steps.map { .object(["label": .string($0.label), "text": .string($0.text)]) })]
            case let .testimonials(items, _):
                o = ["type": "testimonials", "items": .array(items.map { .object(["quote": .string($0.quote), "author": .string($0.author)]) })]
            case let .faq(items, _):
                o = ["type": "faq", "items": .array(items.map { .object(["question": .string($0.question), "answer": .string($0.answer)]) })]
            case let .comparison(cols, rows, _):
                o = ["type": "comparison", "columns": .array(cols.map(JSONValue.string)),
                     "rows": .array(rows.map { .object(["feature": .string($0.feature), "free": .bool($0.free), "pro": .bool($0.pro)]) })]
            case let .cta(label, enabled, _): o = ["type": "cta", "label": .string(label), "enabled": .bool(enabled)]
            case let .legal(text, terms, privacy, restore, _):
                o = ["type": "legal", "text": .string(text), "termsUrl": s(terms), "privacyUrl": s(privacy), "restore": .bool(restore)]
            }
            if let p = b.placement { o["pinned"] = .bool(p.pinned); o["spaceBefore"] = n(p.spaceBefore) }
            return .object(o)
        }
        let p = palette
        var out: [String: JSONValue] = [
            "schema": .string(Self.schemaId), "name": .string(name), "locale": .string(locale), "theme": .string(theme.rawValue),
            "palette": .object(["background": .string(p.background), "surface": .string(p.surface), "text": .string(p.text),
                                "muted": .string(p.muted), "accent": .string(p.accent), "hero": .string(p.hero)]),
            "selectedProductId": s(selectedProductId), "purchasable": .bool(purchasable), "blocks": .array(blocks.map(encode)),
            "align": .string(align.rawValue),
        ]
        if let pages {
            out["pages"] = .array(pages.map {
                .object(["id": .string($0.id), "nextLabel": s($0.nextLabel), "align": .string($0.align.rawValue), "blocks": .array($0.blocks.map(encode))])
            })
        }
        if let direction { out["direction"] = .string(direction) }
        if let l = labels {
            out["labels"] = .object(["terms": .string(l.terms), "privacy": .string(l.privacy), "restore": .string(l.restore),
                                     "close": .string(l.close), "unavailablePrice": .string(l.unavailablePrice)])
        }
        return .object(out)
    }
}

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

/// Prices and the render model, with integer math only (no platform number formatter).
public enum Render {
    static let zeroDecimals: Set<String> = ["BIF", "CLP", "DJF", "GNF", "ISK", "JPY", "KMF", "KRW", "PYG", "RWF", "UGX", "VND", "VUV", "XAF", "XOF", "XPF"]
    static let threeDecimals: Set<String> = ["BHD", "IQD", "JOD", "KWD", "LYD", "OMR", "TND"]

    public static func currencyDigits(_ c: String) -> Int { zeroDecimals.contains(c) ? 0 : threeDecimals.contains(c) ? 3 : 2 }

    static func pow10(_ n: Int) -> Int64 { var r: Int64 = 1; for _ in 0..<max(0, n) { r *= 10 }; return r }

    /// Integer half-up rounding of priceMicros×num/den to the currency's minor units.
    public static func perMonthMinor(priceMicros: Int64, num: Int64, den: Int64, digits: Int) -> Int64 {
        let divisor = den * pow10(6 - digits)
        return floorDiv(2 * priceMicros * num + divisor, 2 * divisor)
    }

    static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
        let q = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
    }

    private static let runChars: Set<Unicode.Scalar> = [".", ",", "\u{00A0}", "\u{202F}", "'", " "]
    private static func isDigit(_ c: Unicode.Scalar) -> Bool { c.value >= 48 && c.value <= 57 }

    /// Formats an amount in minor units the way the store's display price is
    /// written (same symbol, position, decimal and grouping characters). nil when
    /// the display price has no digits.
    public static func formatLike(_ displayPrice: String, minor: Int64, currency: String) -> String? {
        let chars = Array(displayPrice.unicodeScalars)
        // /\d(?:[\d.,  ' ]*\d)?/
        guard let start = chars.firstIndex(where: isDigit) else { return nil }
        var j = start + 1, end = start + 1
        while j < chars.count, isDigit(chars[j]) || runChars.contains(chars[j]) {
            if isDigit(chars[j]) { end = j + 1 }
            j += 1
        }
        let run = Array(chars[start..<end])
        let digits = currencyDigits(currency)
        var decimals = 0
        var decSep: Unicode.Scalar? = nil
        if digits > 0 && run.count > digits + 1 {
            let c = run[run.count - digits - 1]
            if (c == "." || c == ",") && run[(run.count - digits)...].allSatisfy(isDigit) { decimals = digits; decSep = c }
        }
        let intRun = decimals > 0 ? Array(run[0..<(run.count - decimals - 1)]) : run
        let group: Unicode.Scalar? = intRun.first(where: { !isDigit($0) }) ?? (decSep == "." ? "," : decSep == "," ? "." : nil)
        let scale = pow10(decimals)
        let whole: Int64
        if decimals > 0 {
            whole = floorDiv(floorDiv(minor, pow10(digits - decimals)), scale)
        } else {
            // Math.round(minor / 10^digits), half up.
            let d = pow10(digits)
            whole = floorDiv(2 * minor + d, 2 * d)
        }
        var frac = ""
        if decimals > 0 {
            var f = String(floorDiv(minor, pow10(digits - decimals)) % scale)
            while f.count < decimals { f = "0" + f }
            frac = f
        }
        var w = String(whole)
        if whole >= 1000, let group {
            let ds = Array(w)
            var out = ""
            for (i, ch) in ds.enumerated() {
                if i > 0 && (ds.count - i) % 3 == 0 { out.unicodeScalars.append(group) }
                out.append(ch)
            }
            w = out
        }
        var result = String(String.UnicodeScalarView(chars[0..<start]))
        result += w
        if let decSep, decimals > 0 { result.unicodeScalars.append(decSep); result += frac }
        result += String(String.UnicodeScalarView(chars[end...]))
        return result
    }

    static func perMonthFactor(_ p: PaywallDefinition.Period) -> (Int64, Int64)? {
        switch p { case .week: return (52, 12); case .year: return (1, 12); default: return nil }
    }

    typealias Translate = (String) -> String
    /// No translation. A function, not a stored closure: a static stored closure is shared
    /// mutable state to Swift 6's concurrency checking (the podspec allows Swift 6).
    static func asIs(_ source: String) -> String { source }

    public static func priceMain(_ p: PaywallDefinition.Product, _ price: StorePrice?) -> String? { priceMain(p, price, asIs) }

    static func priceMain(_ p: PaywallDefinition.Product, _ price: StorePrice?, _ t: Translate) -> String? {
        guard let price else { return nil }
        return price.displayPrice + (p.period == .lifetime ? " \(t("once"))" : t("/\(p.period.rawValue)"))
    }

    public static func priceLine(_ p: PaywallDefinition.Product, _ price: StorePrice?, showPerMonth: Bool) -> String? { priceLine(p, price, showPerMonth: showPerMonth, asIs) }

    static func priceLine(_ p: PaywallDefinition.Product, _ price: StorePrice?, showPerMonth: Bool, _ t: Translate) -> String? {
        guard let main = priceMain(p, price, t), let price, showPerMonth, let f = perMonthFactor(p.period) else { return priceMain(p, price, t) }
        let minor = perMonthMinor(priceMicros: price.priceMicros, num: f.0, den: f.1, digits: currencyDigits(price.currency))
        guard let per = formatLike(price.displayPrice, minor: minor, currency: price.currency) else { return main }
        return "\(main) · \(per)\(t("/month"))"
    }

    /// `products_not_found` when the store answered but a product of the definition
    /// with a store product ID is missing from the answer (CONTRACT §5), else nil.
    public static func missingPricesReason(_ def: PaywallDefinition, prices: [String: StorePrice]) -> String? {
        def.products.contains { !$0.storeProductId.isEmpty && prices[$0.storeProductId] == nil } ? "products_not_found" : nil
    }

    private static func language(_ locale: String) -> String {
        String(locale.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "").lowercased()
    }

    /// The language to show for a requested one: exact, then the same language; otherwise the source.
    public static func resolveLocale(_ def: PaywallDefinition, requested: String?) -> String {
        guard let requested, let list = def.translations, !list.isEmpty else { return def.locale }
        let wanted = requested.lowercased()
        if let exact = list.first(where: { $0.locale.lowercased() == wanted }) { return exact.locale }
        if language(def.locale) == language(wanted) { return def.locale }
        return list.first(where: { $0.locale.lowercased() == language(wanted) })?.locale
            ?? list.first(where: { language($0.locale) == language(wanted) })?.locale ?? def.locale
    }

    static func direction(_ locale: String) -> String? {
        locale.range(of: "^(ar|he|iw|fa|ur)(-|$)", options: .regularExpression) != nil ? "rtl" : nil
    }

    /// `fillPaywallText`: each `{word}` with a value is replaced in one pass; others stay as written.
    static func fill(_ template: String, _ values: [String: String]) -> String {
        let chars = Array(template)
        var out = "", i = 0
        while i < chars.count {
            if chars[i] == "{", let close = chars[(i + 1)...].firstIndex(where: { !($0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_")) }),
               close > i + 1, chars[close] == "}", let value = values[String(chars[(i + 1)..<close])] {
                out += value; i = close + 1
            } else {
                out.append(chars[i]); i += 1
            }
        }
        return out
    }

    /// The device's preferred language, for choosing a translation.
    public static var deviceLocale: String? { Locale.preferredLanguages.first }

    /// The blocks of each page as `start..<end` ranges of `def.blocks` (`paywallPageRanges`); one page without `pages`.
    static func pageRanges(_ def: PaywallDefinition) -> [Range<Int>] {
        guard let pages = def.pages, !pages.isEmpty else { return [0..<def.blocks.count] }
        var start = 0
        return pages.map { page in
            let end = min(start + page.blockCount, def.blocks.count), r = min(start, end)..<end
            start = end
            return r
        }
    }

    /// `paywallPinnedBlocks`: pin `bottom`, and when pin is left out a purchase button and legal footer that end a page
    /// (close buttons don't count).
    static func pinnedBlocks(_ def: PaywallDefinition) -> Set<Int> {
        var pinned = Set(def.blocks.indices.filter { def.blocks[$0].placement?.pin == .bottom })
        for r in pageRanges(def) {
            for i in r.reversed() {
                let b = def.blocks[i], autoPinned: Bool
                switch b {
                case .close: continue
                case let .cta(_, p), let .legal(_, _, _, _, _, p): autoPinned = p.pin == nil
                default: autoPinned = false
                }
                guard autoPinned else { break }
                pinned.insert(i)
            }
        }
        return pinned
    }

    private static func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Exactly `renderModel` in sdk-render.ts. `prices` are keyed by store product ID.
    /// `locale` is the device's language; text with no translation stays in the source language.
    public static func model(_ def: PaywallDefinition, prices: [String: StorePrice], selectedProductId: String? = nil, locale: String? = nil) -> RenderModel {
        var plansBlock: (ids: [String], selected: String)? = nil
        for b in def.blocks { if case let .plans(ids, sel, _, _, _) = b { plansBlock = (ids, sel); break } }
        let product: (String) -> PaywallDefinition.Product? = { id in def.products.first { $0.id == id } }
        let shown = (plansBlock?.ids ?? []).compactMap(product)
        let selected = shown.first { $0.id == selectedProductId } ?? shown.first { $0.id == plansBlock?.selected } ?? shown.first
        let price: (PaywallDefinition.Product) -> StorePrice? = { prices[$0.storeProductId] }
        let trial: (PaywallDefinition.Product?) -> Int = { p in
            guard let p, let pr = price(p) else { return 0 }
            return max(0, pr.trialDays)
        }
        let purchasable = selected.map { price($0) != nil && !$0.storeProductId.isEmpty } ?? false
        let active = resolveLocale(def, requested: locale), translated = active != def.locale
        let map: [String: String] = translated
            ? Dictionary((def.translations?.first { $0.locale == active }?.strings ?? []).map { ($0.source, $0.text) }, uniquingKeysWith: { _, last in last })
            : [:]
        let t: Translate = { map[$0] ?? $0 }
        let free: (Int) -> String = { n in n == 1 ? t("1 day free") : fill(t("{n} days free"), ["n": String(n)]) }
        let ranges = pageRanges(def)
        let pageOf: (Int) -> Int = { i in max(0, ranges.firstIndex { $0.contains(i) } ?? 0) }
        let pinned = pinnedBlocks(def)
        let place: (PaywallDefinition.Placement, Int) -> RenderModel.Placement = { p, i in .init(pinned: pinned.contains(i), spaceBefore: p.spaceBefore ?? 0) }
        let barItem: (PaywallDefinition.BarItem?, Int) -> RenderModel.BarItem? = { item, page in
            switch item {
            case nil, .unknown?: return nil
            case .back?: return page > 0 ? .back(label: t("Back")) : nil
            case .restore?: return .restore(label: t("Restore"))
            case let .text(text)?: return trimmed(text).isEmpty ? nil : .text(t(text))
            case .progress?:
                return ranges.count > 1
                    ? .progress(index: page, count: ranges.count, label: fill(t("Page {n} of {count}"), ["n": String(page + 1), "count": String(ranges.count)]))
                    : nil
            case let .image(url, height)?: return url.isEmpty ? nil : .image(imageUrl: url, height: height)
            }
        }
        let byIndex: [RenderModel.Block?] = def.blocks.enumerated().map { i, b in
            switch b {
            case let .close(position, delay, style, label, bar):
                let style = style ?? .overlay, page = pageOf(i)
                let text = style != .overlay && !trimmed(label ?? "").isEmpty ? label.map(t) : nil
                return .close(position: position, delaySeconds: delay, style: style, label: text,
                              bar: style == .bar ? .init(leading: barItem(bar?.leading, page), center: barItem(bar?.center, page), trailing: barItem(bar?.trailing, page)) : nil)
            // Without an image there is nothing to show (0.3.0; older SDKs drew a gradient).
            case let .hero(height, url, p): return url.isEmpty ? nil : .hero(height: height, imageUrl: url, placement: place(p, i))
            case let .headline(text, sub, p): return .headline(text: t(text), subtext: sub.isEmpty ? nil : t(sub), placement: place(p, i))
            case let .benefits(items, p): return .benefits(items: items.map(t), placement: place(p, i))
            case let .plans(ids, _, badge, perMonth, p):
                return .plans(ids.compactMap(product).map { p in
                    let days = trial(p)
                    return RenderModel.Plan(productId: p.id, storeProductId: p.storeProductId, period: p.period,
                                            title: t(p.label) + (days > 0 ? " · \(free(days))" : ""),
                                            priceLine: priceLine(p, price(p), showPerMonth: perMonth, t),
                                            badge: badge?.productId == p.id ? t(badge!.text) : nil, selected: p.id == selected?.id)
                }, placement: place(p, i))
            case let .trialTimeline(reminderDay, p):
                let n = trial(selected)
                guard let selected, n > 0 else { return nil }
                return .trialTimeline(steps: [
                    .init(label: t("Today"), text: t("full access")),
                    .init(label: fill(t("Day {n}"), ["n": String(min(reminderDay, n))]), text: t("we remind you")),
                    .init(label: fill(t("Day {n}"), ["n": String(n)]), text: fill(t("{price} unless you cancel"), ["price": priceMain(selected, price(selected), t) ?? t("the store price")])),
                ], placement: place(p, i))
            case let .testimonials(items, p):
                return .testimonials(items: items.map { .init(quote: "“\(t($0.quote))”", author: "— \($0.author)") }, placement: place(p, i))
            case let .faq(items, p): return .faq(items: items.map { .init(question: t($0.question), answer: t($0.answer)) }, placement: place(p, i))
            case let .comparison(rows, p):
                return .comparison(columns: [t("Free"), t("Pro")], rows: rows.map { .init(feature: t($0.feature), free: $0.free, pro: $0.pro) }, placement: place(p, i))
            case let .cta(label, p):
                let saysFree = label.range(of: "free", options: .caseInsensitive) != nil
                return .cta(label: t(saysFree && trial(selected) == 0 ? "Continue" : label), enabled: purchasable, placement: place(p, i))
            // iOS and macOS always show `text`; `textGooglePlay` is for Android (CONTRACT §8).
            case let .legal(terms, privacy, restore, text, _, p):
                return .legal(text: t(text), termsUrl: terms.isEmpty ? nil : terms, privacyUrl: privacy.isEmpty ? nil : privacy, restore: restore, placement: place(p, i))
            case .unknown: return nil
            }
        }
        let align = def.align ?? .top
        var model = RenderModel(name: def.name, locale: active, theme: def.theme, palette: def.palette, selectedProductId: selected?.id,
                                purchasable: purchasable, blocks: byIndex.compactMap { $0 }, align: align)
        if ranges.count > 1, let pages = def.pages {
            model.pages = ranges.enumerated().map { i, r in
                RenderModel.Page(id: pages[i].id, nextLabel: i < ranges.count - 1 ? t(pages[i].nextLabel) : nil, align: pages[i].align ?? align,
                                 blocks: byIndex[r].compactMap { $0 })
            }
        }
        if translated {
            model.direction = direction(active)
            model.labels = .init(terms: t("Terms"), privacy: t("Privacy"), restore: t("Restore purchases"), close: t("Close"), unavailablePrice: t(RenderModel.unavailablePrice))
        }
        return model
    }
}
