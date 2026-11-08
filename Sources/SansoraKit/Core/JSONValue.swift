import Foundation

/// A JSON value. Used for event payloads (so bridges can enqueue pre-built
/// events), attributes and fixture comparison. Numbers are doubles; integers up
/// to 2^53 round-trip exactly and are written without a fraction.
public enum JSONValue: Equatable, Hashable, Codable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int64.self) { self = .number(Double(i)); return }
        if let d = try? c.decode(Double.self) { self = .number(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Not a JSON value")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let d):
            if d.rounded() == d, abs(d) < 9_007_199_254_740_992 { try c.encode(Int64(d)) } else { try c.encode(d) }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    /// From `JSONSerialization` output (distinguishes booleans from numbers).
    public init?(any: Any?) {
        guard let any else { self = .null; return }
        switch any {
        case is NSNull: self = .null
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { self = .bool(n.boolValue) } else { self = .number(n.doubleValue) }
        case let s as String: self = .string(s)
        case let a as [Any]:
            var out: [JSONValue] = []
            for x in a { guard let v = JSONValue(any: x) else { return nil }; out.append(v) }
            self = .array(out)
        case let o as [String: Any]:
            var out: [String: JSONValue] = [:]
            for (k, x) in o { guard let v = JSONValue(any: x) else { return nil }; out[k] = v }
            self = .object(out)
        default: return nil
        }
    }

    /// For `JSONSerialization` / bridges.
    public var anyValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let d):
            if d.rounded() == d, abs(d) < 9_007_199_254_740_992 { return Int64(d) }
            return d
        case .string(let s): return s
        case .array(let a): return a.map { $0.anyValue }
        case .object(let o): return o.mapValues { $0.anyValue }
        }
    }

    public static func parse(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    public func data(sorted: Bool = true) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = sorted ? [.sortedKeys, .withoutEscapingSlashes] : [.withoutEscapingSlashes]
        return try e.encode(self)
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var doubleValue: Double? { if case .number(let d) = self { return d }; return nil }
    public var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    public var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }

    /// Re-encodes any Encodable as a JSONValue.
    public static func from<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }

    /// Decodes this value into a Decodable type.
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: data(sorted: false))
    }
}

/// JavaScript `String(x)` and `Number(x)` for the audience rules, so the device
/// gives the same answers as the TypeScript reference.
enum JS {
    static func string(_ d: Double) -> String {
        if d.isNaN { return "NaN" }
        if d.isInfinite { return d < 0 ? "-Infinity" : "Infinity" }
        if d == 0 { return "0" }
        if d.rounded() == d, abs(d) < 1e21 {
            if abs(d) < 9.2e18 { return String(Int64(d)) }
            return String(format: "%.0f", d)
        }
        return "\(d)"
    }

    /// `Number(string)`: trimmed, empty is 0, decimal or 0x/0o/0b integers, else NaN.
    static func number(_ raw: String) -> Double {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return 0 }
        let lower = s.lowercased()
        for (prefix, radix) in [("0x", 16), ("0o", 8), ("0b", 2)] where lower.hasPrefix(prefix) {
            let body = String(lower.dropFirst(2))
            guard !body.isEmpty, let v = UInt64(body, radix: radix) else { return .nan }
            return Double(v)
        }
        if s == "Infinity" || s == "+Infinity" { return .infinity }
        if s == "-Infinity" { return -.infinity }
        // Only plain decimal literals (JS rejects "inf", "nan" and hex floats).
        let allowed = Set("0123456789+-.eE")
        guard s.allSatisfy({ allowed.contains($0) }), s.contains(where: { $0.isNumber }) else { return .nan }
        return Double(s) ?? .nan
    }
}
