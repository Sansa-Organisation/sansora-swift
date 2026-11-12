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
        let encode: (Block) -> JSONValue = { b in
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
        var out: [String: JSONValue] = [
            "schema": .string(Self.schemaId), "name": .string(name), "locale": .string(locale), "theme": .string(theme.rawValue),
            "palette": .object(["background": .string(p.background), "surface": .string(p.surface), "text": .string(p.text),
                                "muted": .string(p.muted), "accent": .string(p.accent), "hero": .string(p.hero)]),
            "selectedProductId": s(selectedProductId), "purchasable": .bool(purchasable), "blocks": .array(blocks.map(encode)),
        ]
        if let pages {
            out["pages"] = .array(pages.map { .object(["id": .string($0.id), "nextLabel": s($0.nextLabel), "blocks": .array($0.blocks.map(encode))]) })
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
    static let asIs: Translate = { $0 }

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

    static func fill(_ template: String, _ values: [String: String]) -> String {
        values.reduce(template) { $0.replacingOccurrences(of: "{\($1.key)}", with: $1.value) }
    }

    /// The device's preferred language, for choosing a translation.
    public static var deviceLocale: String? { Locale.preferredLanguages.first }

    /// Exactly `renderModel` in sdk-render.ts. `prices` are keyed by store product ID.
    /// `locale` is the device's language; text with no translation stays in the source language.
    public static func model(_ def: PaywallDefinition, prices: [String: StorePrice], selectedProductId: String? = nil, locale: String? = nil) -> RenderModel {
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
        let active = resolveLocale(def, requested: locale), translated = active != def.locale
        let map: [String: String] = translated
            ? Dictionary((def.translations?.first { $0.locale == active }?.strings ?? []).map { ($0.source, $0.text) }, uniquingKeysWith: { _, last in last })
            : [:]
        let t: Translate = { map[$0] ?? $0 }
        let free: (Int) -> String = { n in n == 1 ? t("1 day free") : fill(t("{n} days free"), ["n": String(n)]) }
        let byIndex: [RenderModel.Block?] = def.blocks.map { b in
            switch b {
            case let .close(position, delay): return .close(position: position, delaySeconds: delay)
            case let .hero(height, url): return .hero(height: height, imageUrl: url.isEmpty ? nil : url)
            case let .headline(text, sub): return .headline(text: t(text), subtext: sub.isEmpty ? nil : t(sub))
            case let .benefits(items): return .benefits(items: items.map(t))
            case let .plans(ids, _, badge, perMonth):
                return .plans(ids.compactMap(product).map { p in
                    let days = trial(p)
                    return RenderModel.Plan(productId: p.id, storeProductId: p.storeProductId, period: p.period,
                                            title: t(p.label) + (days > 0 ? " · \(free(days))" : ""),
                                            priceLine: priceLine(p, price(p), showPerMonth: perMonth, t),
                                            badge: badge?.productId == p.id ? t(badge!.text) : nil, selected: p.id == selected?.id)
                })
            case let .trialTimeline(reminderDay):
                let n = trial(selected)
                guard let selected, n > 0 else { return nil }
                return .trialTimeline(steps: [
                    .init(label: t("Today"), text: t("full access")),
                    .init(label: fill(t("Day {n}"), ["n": String(min(reminderDay, n))]), text: t("we remind you")),
                    .init(label: fill(t("Day {n}"), ["n": String(n)]), text: fill(t("{price} unless you cancel"), ["price": priceMain(selected, price(selected), t) ?? t("the store price")])),
                ])
            case let .testimonials(items):
                return .testimonials(items: items.map { .init(quote: "“\(t($0.quote))”", author: "— \($0.author)") })
            case let .faq(items): return .faq(items: items.map { .init(question: t($0.question), answer: t($0.answer)) })
            case let .comparison(rows):
                return .comparison(columns: [t("Free"), t("Pro")], rows: rows.map { .init(feature: t($0.feature), free: $0.free, pro: $0.pro) })
            case let .cta(label):
                let saysFree = label.range(of: "free", options: .caseInsensitive) != nil
                return .cta(label: t(saysFree && trial(selected) == 0 ? "Continue" : label), enabled: purchasable)
            case let .legal(terms, privacy, restore, text):
                return .legal(text: t(text), termsUrl: terms.isEmpty ? nil : terms, privacyUrl: privacy.isEmpty ? nil : privacy, restore: restore)
            case .unknown: return nil
            }
        }
        var model = RenderModel(name: def.name, locale: active, theme: def.theme, palette: def.palette, selectedProductId: selected?.id,
                                purchasable: purchasable, blocks: byIndex.compactMap { $0 })
        if let pages = def.pages, pages.count > 1 {
            var start = 0
            model.pages = pages.enumerated().map { i, page in
                let end = min(start + page.blockCount, byIndex.count)
                defer { start = end }
                return RenderModel.Page(id: page.id, nextLabel: i < pages.count - 1 ? t(page.nextLabel) : nil, blocks: byIndex[start..<end].compactMap { $0 })
            }
        }
        if translated {
            model.direction = direction(active)
            model.labels = .init(terms: t("Terms"), privacy: t("Privacy"), restore: t("Restore purchases"), close: t("Close"), unavailablePrice: t(RenderModel.unavailablePrice))
        }
        return model
    }
}
