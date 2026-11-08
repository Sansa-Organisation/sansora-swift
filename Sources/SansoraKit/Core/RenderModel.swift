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
    public var name: String
    public var locale: String
    public var theme: PaywallDefinition.Theme
    public var palette: PaywallDefinition.Palette
    public var selectedProductId: String?
    /// The selected plan has a store price, so the purchase button works.
    public var purchasable: Bool
    public var blocks: [Block]

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

    public enum Block: Equatable, Sendable {
        case close(position: PaywallDefinition.Position, delaySeconds: Int)
        case hero(height: Int, imageUrl: String?)
        case headline(text: String, subtext: String?)
        case benefits(items: [String])
        case plans([Plan])
        case trialTimeline(steps: [Step])
        case testimonials(items: [PaywallDefinition.Quote])
        case faq(items: [PaywallDefinition.Question])
        case comparison(columns: [String], rows: [PaywallDefinition.ComparisonRow])
        case cta(label: String, enabled: Bool)
        case legal(text: String, termsUrl: String?, privacyUrl: String?, restore: Bool)
    }

    public static let unavailablePrice = "Price unavailable"

    public var json: JSONValue {
        let s: (String?) -> JSONValue = { $0.map(JSONValue.string) ?? .null }
        let blocks: [JSONValue] = self.blocks.map { b in
            switch b {
            case let .close(p, d): return .object(["type": "close", "position": .string(p.rawValue), "delaySeconds": .number(Double(d))])
            case let .hero(h, u): return .object(["type": "hero", "height": .number(Double(h)), "imageUrl": s(u)])
            case let .headline(t, sub): return .object(["type": "headline", "text": .string(t), "subtext": s(sub)])
            case let .benefits(items): return .object(["type": "benefits", "items": .array(items.map(JSONValue.string))])
            case let .plans(plans):
                return .object(["type": "plans", "plans": .array(plans.map { p in
                    .object(["productId": .string(p.productId), "storeProductId": .string(p.storeProductId), "period": .string(p.period.rawValue),
                             "title": .string(p.title), "priceLine": s(p.priceLine), "badge": s(p.badge), "selected": .bool(p.selected)])
                })])
            case let .trialTimeline(steps):
                return .object(["type": "trial_timeline", "steps": .array(steps.map { .object(["label": .string($0.label), "text": .string($0.text)]) })])
            case let .testimonials(items):
                return .object(["type": "testimonials", "items": .array(items.map { .object(["quote": .string($0.quote), "author": .string($0.author)]) })])
            case let .faq(items):
                return .object(["type": "faq", "items": .array(items.map { .object(["question": .string($0.question), "answer": .string($0.answer)]) })])
            case let .comparison(cols, rows):
                return .object(["type": "comparison", "columns": .array(cols.map(JSONValue.string)),
                                "rows": .array(rows.map { .object(["feature": .string($0.feature), "free": .bool($0.free), "pro": .bool($0.pro)]) })])
            case let .cta(label, enabled): return .object(["type": "cta", "label": .string(label), "enabled": .bool(enabled)])
            case let .legal(text, terms, privacy, restore):
                return .object(["type": "legal", "text": .string(text), "termsUrl": s(terms), "privacyUrl": s(privacy), "restore": .bool(restore)])
            }
        }
        let p = palette
        return .object([
            "schema": .string(Self.schemaId), "name": .string(name), "locale": .string(locale), "theme": .string(theme.rawValue),
            "palette": .object(["background": .string(p.background), "surface": .string(p.surface), "text": .string(p.text),
                                "muted": .string(p.muted), "accent": .string(p.accent), "hero": .string(p.hero)]),
            "selectedProductId": s(selectedProductId), "purchasable": .bool(purchasable), "blocks": .array(blocks),
        ])
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

    public static func priceMain(_ p: PaywallDefinition.Product, _ price: StorePrice?) -> String? {
        guard let price else { return nil }
        return price.displayPrice + (p.period == .lifetime ? " once" : "/\(p.period.rawValue)")
    }

    public static func priceLine(_ p: PaywallDefinition.Product, _ price: StorePrice?, showPerMonth: Bool) -> String? {
        guard let main = priceMain(p, price), let price, showPerMonth, let f = perMonthFactor(p.period) else { return priceMain(p, price) }
        let minor = perMonthMinor(priceMicros: price.priceMicros, num: f.0, den: f.1, digits: currencyDigits(price.currency))
        guard let per = formatLike(price.displayPrice, minor: minor, currency: price.currency) else { return main }
        return "\(main) · \(per)/month"
    }

    /// `products_not_found` when the store answered but a product of the definition
    /// with a store product ID is missing from the answer (CONTRACT §5), else nil.
    public static func missingPricesReason(_ def: PaywallDefinition, prices: [String: StorePrice]) -> String? {
        def.products.contains { !$0.storeProductId.isEmpty && prices[$0.storeProductId] == nil } ? "products_not_found" : nil
    }

    static func days(_ n: Int) -> String { "\(n) \(n == 1 ? "day" : "days")" }

    /// Exactly `renderModel` in sdk-render.ts. `prices` are keyed by store product ID.
    public static func model(_ def: PaywallDefinition, prices: [String: StorePrice], selectedProductId: String? = nil) -> RenderModel {
        var plansBlock: (ids: [String], selected: String)? = nil
        for b in def.blocks { if case let .plans(ids, sel, _, _) = b { plansBlock = (ids, sel); break } }
        let product: (String) -> PaywallDefinition.Product? = { id in def.products.first { $0.id == id } }
        let shown = (plansBlock?.ids ?? []).compactMap(product)
        let selected = shown.first { $0.id == selectedProductId } ?? shown.first { $0.id == plansBlock?.selected } ?? shown.first
        let price: (PaywallDefinition.Product) -> StorePrice? = { prices[$0.storeProductId] }
        let trial: (PaywallDefinition.Product?) -> Int = { p in
            guard let p, let pr = price(p) else { return 0 }
            return max(0, pr.trialDays)
        }
        let purchasable = selected.map { price($0) != nil && !$0.storeProductId.isEmpty } ?? false
        var blocks: [RenderModel.Block] = []
        for b in def.blocks {
            switch b {
            case let .close(position, delay): blocks.append(.close(position: position, delaySeconds: delay))
            case let .hero(height, url): blocks.append(.hero(height: height, imageUrl: url.isEmpty ? nil : url))
            case let .headline(text, sub): blocks.append(.headline(text: text, subtext: sub.isEmpty ? nil : sub))
            case let .benefits(items): blocks.append(.benefits(items: items))
            case let .plans(ids, _, badge, perMonth):
                blocks.append(.plans(ids.compactMap(product).map { p in
                    let t = trial(p)
                    return RenderModel.Plan(productId: p.id, storeProductId: p.storeProductId, period: p.period,
                                            title: p.label + (t > 0 ? " · \(days(t)) free" : ""),
                                            priceLine: priceLine(p, price(p), showPerMonth: perMonth),
                                            badge: badge?.productId == p.id ? badge?.text : nil, selected: p.id == selected?.id)
                }))
            case let .trialTimeline(reminderDay):
                let t = trial(selected)
                guard let selected, t > 0 else { break }
                blocks.append(.trialTimeline(steps: [
                    .init(label: "Today", text: "full access"),
                    .init(label: "Day \(min(reminderDay, t))", text: "we remind you"),
                    .init(label: "Day \(t)", text: "\(priceMain(selected, price(selected)) ?? "the store price") unless you cancel"),
                ]))
            case let .testimonials(items):
                blocks.append(.testimonials(items: items.map { .init(quote: "“\($0.quote)”", author: "— \($0.author)") }))
            case let .faq(items): blocks.append(.faq(items: items))
            case let .comparison(rows): blocks.append(.comparison(columns: ["Free", "Pro"], rows: rows))
            case let .cta(label):
                let saysFree = label.range(of: "free", options: .caseInsensitive) != nil
                blocks.append(.cta(label: saysFree && trial(selected) == 0 ? "Continue" : label, enabled: purchasable))
            case let .legal(terms, privacy, restore, text):
                blocks.append(.legal(text: text, termsUrl: terms.isEmpty ? nil : terms, privacyUrl: privacy.isEmpty ? nil : privacy, restore: restore))
            case .unknown: break
            }
        }
        return RenderModel(name: def.name, locale: def.locale, theme: def.theme, palette: def.palette, selectedProductId: selected?.id,
                           purchasable: purchasable, blocks: blocks)
    }
}
