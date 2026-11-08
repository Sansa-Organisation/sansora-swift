import Foundation

/// A device or custom attribute value used by audience rules.
public enum AttributeValue: Equatable, Hashable, Codable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int64.self) { self = .number(Double(i)); return }
        if let d = try? c.decode(Double.self) { self = .number(d); return }
        self = .string(try c.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws { try json.encode(to: encoder) }

    public var json: JSONValue {
        switch self {
        case .string(let s): return .string(s)
        case .number(let d): return .number(d)
        case .bool(let b): return .bool(b)
        }
    }

    /// JavaScript `String(value)`.
    var jsString: String {
        switch self {
        case .string(let s): return s
        case .number(let d): return JS.string(d)
        case .bool(let b): return b ? "true" : "false"
        }
    }

    /// JavaScript `Number(value)`.
    var jsNumber: Double {
        switch self {
        case .string(let s): return JS.number(s)
        case .number(let d): return d
        case .bool(let b): return b ? 1 : 0
        }
    }
}

/// Attributes of this user for audiences: `storefront`, `language`, …, `custom.<key>`.
public typealias UserAttributes = [String: AttributeValue]

/// One audience rule (`campaigns.ts`).
public struct AudienceRule: Codable, Equatable, Sendable {
    public enum Value: Codable, Equatable, Sendable {
        case string(String)
        case number(Double)
        case list([String])

        public init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let l = try? c.decode([String].self) { self = .list(l); return }
            if let d = try? c.decode(Double.self) { self = .number(d); return }
            self = .string(try c.decode(String.self))
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .string(let s): try c.encode(s)
            case .number(let d): try JSONValue.number(d).encode(to: encoder)
            case .list(let l): try c.encode(l)
            }
        }

        var jsString: String {
            switch self {
            case .string(let s): return s
            case .number(let d): return JS.string(d)
            case .list(let l): return l.joined(separator: ",")
            }
        }
        var jsNumber: Double {
            switch self {
            case .number(let d): return d
            default: return JS.number(jsString)
            }
        }
    }

    public var attribute: String
    public var op: String
    public var value: Value

    public init(attribute: String, op: String, value: Value) {
        self.attribute = attribute; self.op = op; self.value = value
    }
}

public struct AudienceGroup: Codable, Equatable, Sendable {
    public var match: String
    public var rules: [AudienceRule]
}

public struct Audience: Codable, Equatable, Sendable {
    public var match: String
    public var rules: [AudienceRule]
    public var groups: [AudienceGroup]
    public static let everyone = Audience(match: "all", rules: [], groups: [])
    public init(match: String, rules: [AudienceRule], groups: [AudienceGroup]) {
        self.match = match; self.rules = rules; self.groups = groups
    }
}

/// Audience evaluation identical to `ruleMatches` / `audienceMatches` in campaigns.ts.
public enum AudienceEvaluator {
    private static let types: [String: String] = [
        "storefront": "list", "language": "list", "device": "enum", "os_version": "version", "app_version": "version",
        "days_since_install": "number", "sessions": "number", "subscription": "enum", "paywall_declined": "number",
        "days_since_decline": "number", "apple_ads_campaign": "text", "apple_ads_keyword": "text",
    ]

    static func isCustomName(_ name: String) -> Bool {
        guard name.hasPrefix("custom.") else { return false }
        let rest = Array(name.dropFirst(7).unicodeScalars)
        guard (1...40).contains(rest.count), let first = rest.first, ("a"..."z").contains(first) else { return false }
        return rest.dropFirst().allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" }
    }

    static func attrType(_ attribute: String) -> String {
        isCustomName(attribute) ? "custom" : types[attribute] ?? "text"
    }

    /// `versionCmp`: dot-separated numbers; a missing part is 0, a non-numeric part compares equal.
    static func versionCompare(_ a: String, _ b: String) -> Int {
        let x = a.components(separatedBy: ".").map(JS.number), y = b.components(separatedBy: ".").map(JS.number)
        for i in 0..<max(x.count, y.count) {
            let d = (i < x.count ? x[i] : 0) - (i < y.count ? y[i] : 0)
            if d.isNaN || d == 0 { continue }
            return d > 0 ? 1 : -1
        }
        return 0
    }

    private static func norm(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    /// A missing attribute never matches.
    public static func ruleMatches(_ r: AudienceRule, _ user: UserAttributes) -> Bool {
        guard let actual = user[r.attribute] else { return false }
        if attrType(r.attribute) == "version" {
            let c = versionCompare(actual.jsString, r.value.jsString)
            return r.op == "gte" ? c >= 0 : r.op == "lte" ? c <= 0 : c == 0
        }
        let a = norm(actual.jsString)
        switch r.op {
        case "one_of", "not_one_of":
            let list: [String]
            if case .list(let l) = r.value { list = l } else { return false }
            let found = list.contains { norm($0) == a }
            return r.op == "one_of" ? found : !found
        case "is": return a == norm(r.value.jsString)
        case "is_not": return a != norm(r.value.jsString)
        case "contains":
            let needle = norm(r.value.jsString)
            return needle.isEmpty || a.contains(needle)
        default: break
        }
        let n = actual.jsNumber, v = r.value.jsNumber
        if !n.isFinite { return false }
        switch r.op {
        case "eq": return n == v
        case "ne": return n != v
        case "gt": return n > v
        case "gte": return n >= v
        case "lt": return n < v
        default: return n <= v
        }
    }

    private static func combine(_ match: String, _ results: [Bool]) -> Bool {
        results.isEmpty || (match == "all" ? results.allSatisfy { $0 } : results.contains(true))
    }

    public static func matches(_ a: Audience, _ user: UserAttributes) -> Bool {
        combine(a.match, a.rules.map { ruleMatches($0, user) } + a.groups.map { g in combine(g.match, g.rules.map { ruleMatches($0, user) }) })
    }
}
