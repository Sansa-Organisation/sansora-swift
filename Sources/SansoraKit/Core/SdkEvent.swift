import Foundation

/// Device fields every event carries (`DeviceContext` in sdk-session.ts).
public struct EventContext: Codable, Equatable, Sendable {
    /// `ios`, `android`, `flutter` or `react_native`.
    public var platform: String
    public var sdkVersion: String
    public var osVersion: String
    public var device: String
    /// ISO alpha-3; nil when unknown (then omitted from events).
    public var storefront: String?
    /// `app_store` or `google_play`.
    public var store: String
    public init(platform: String, sdkVersion: String, osVersion: String, device: String, storefront: String?, store: String) {
        self.platform = platform; self.sdkVersion = sdkVersion; self.osVersion = osVersion
        self.device = device; self.storefront = storefront; self.store = store
    }
}

/// One `sansora.event/1` event (packages/core/src/sdk-events.ts). Absent optionals are omitted.
public struct SdkEvent: Equatable, Sendable {
    public static let schemaId = "sansora.event/1"
    public var eventId: String
    public var appUserId: String
    public var event: String
    public var occurredAt: Int64
    public var context: EventContext
    public var placement: String?
    public var paywallId: String?
    public var variant: String?
    public var productId: String?
    public var durationMs: Int64?
    public var reason: String?
    public var attributes: [String: AttributeValue]?

    public init(eventId: String, appUserId: String, event: String, occurredAt: Int64, context: EventContext,
                placement: String? = nil, paywallId: String? = nil, variant: String? = nil, productId: String? = nil,
                durationMs: Int64? = nil, reason: String? = nil, attributes: [String: AttributeValue]? = nil) {
        self.eventId = eventId; self.appUserId = appUserId; self.event = event; self.occurredAt = occurredAt; self.context = context
        self.placement = placement; self.paywallId = paywallId; self.variant = variant; self.productId = productId
        self.durationMs = durationMs; self.reason = reason; self.attributes = attributes
    }

    public var json: JSONValue {
        var o: [String: JSONValue] = [
            "schema": .string(Self.schemaId), "eventId": .string(eventId), "appUserId": .string(appUserId), "event": .string(event),
            "occurredAt": .number(Double(occurredAt)), "platform": .string(context.platform), "sdkVersion": .string(context.sdkVersion),
            "osVersion": .string(String(context.osVersion.prefix(20))), "device": .string(String(context.device.prefix(40))),
            "store": .string(context.store),
        ]
        if let s = context.storefront { o["storefront"] = .string(s) }
        if let placement { o["placement"] = .string(placement) }
        if let paywallId { o["paywallId"] = .string(paywallId) }
        if let variant { o["variant"] = .string(variant) }
        if let productId { o["productId"] = .string(productId) }
        if let durationMs { o["durationMs"] = .number(Double(durationMs)) }
        if let reason { o["reason"] = .string(reason) }
        if let attributes { o["attributes"] = .object(attributes.mapValues { $0.json }) }
        return .object(o)
    }
}
