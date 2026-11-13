import Foundation

public enum PurchaseOutcome: Equatable, Sendable {
    case purchased
    case trial
    case cancelled
    case pending
    /// A store error string (`store_error` when the store gave none, `unverified` for a failed verification).
    case failed(String)
}

public enum RestoreOutcome: String, Equatable, Sendable {
    case restored
    case nothing
    case failed
}

/// Headless paywall session: resolution, display history and event emission,
/// exactly as `runSession` in sdk-session.ts. Time, event IDs and store results
/// are injected, so the conformance fixtures replay through this same code.
/// Not thread-safe: use from one thread (the SDK uses the main actor).
public final class PaywallSession {
    public struct Presented: Equatable {
        public var placement: String
        public var paywallId: String
        public var variant: String
        public var campaignId: String
        public var versionId: String
        public var shownAt: Int64
        public var selected: String?
        public var prices: [String: StorePrice]
        public var definition: PaywallDefinition
        /// Counts presentations, so a late store answer can't reach a later paywall.
        public var id: Int = 0
        /// Drawn before the store answered (0.2.1): `pricesLoaded` brings the prices.
        public var awaitingPrices = false
        /// `paywall_shown` has been sent.
        public var shownSent = true
    }

    public enum FireResult: Equatable {
        case noConfig
        case resolved(Resolution)
    }

    public var context: EventContext
    public var appUserId: String
    public var config: SdkConfig?
    public var history: DisplayHistory
    /// The device's language, for choosing a translation.
    public var locale: String?
    public private(set) var presented: Presented?
    private var presentations = 0
    private let clock: () -> Int64
    private let makeEventId: () -> String
    /// Every emitted event, in order.
    public var onEvent: (SdkEvent) -> Void = { _ in }
    /// Called after the display history changes (persist it).
    public var onHistoryChange: (DisplayHistory) -> Void = { _ in }
    /// Called when the open paywall goes away, with the `paywall_closed` reason.
    public var onDismiss: (String) -> Void = { _ in }

    public init(context: EventContext, appUserId: String, config: SdkConfig?, history: DisplayHistory = DisplayHistory(),
                clock: @escaping () -> Int64, makeEventId: @escaping () -> String) {
        self.context = context; self.appUserId = appUserId; self.config = config; self.history = history
        self.clock = clock; self.makeEventId = makeEventId
    }

    private func emit(_ event: String, placement: String? = nil, productId: String? = nil, durationMs: Int64? = nil,
                      reason: String? = nil, attributes: [String: AttributeValue]? = nil) {
        var e = SdkEvent(eventId: makeEventId(), appUserId: appUserId, event: event, occurredAt: clock(), context: context)
        if let p = presented { e.placement = p.placement; e.paywallId = p.paywallId; e.variant = p.variant }
        if let placement { e.placement = placement }
        e.productId = productId; e.durationMs = durationMs; e.reason = reason; e.attributes = attributes
        onEvent(e)
    }

    /// A new app session (cold start, or foreground after 30 minutes): once-per-session caps reset.
    public func newSession() {
        history.session = []
        onHistoryChange(history)
    }

    /// Fires a placement: `placement_fired`, then resolution. nil when a paywall is
    /// already open (ignored, no events). `custom` is sent as `attributes`.
    public func fire(placement: String, attributes: UserAttributes, custom: [String: AttributeValue]) -> FireResult? {
        if presented != nil { return nil }
        emit("placement_fired", placement: placement, attributes: custom.isEmpty ? nil : custom)
        guard let config else {
            emit("paywall_load_failed", placement: placement, reason: "no_config")
            return .noConfig
        }
        return .resolved(Assignment.resolvePlacement(config, placement: placement, appUserId: appUserId, user: attributes, history: history, now: clock()))
    }

    /// Shows the paywall a `.paywall` resolution chose with the store prices
    /// (`pricesError` when they failed: the paywall still shows, after `prices_load_failed`).
    ///
    /// With `awaitingPrices` it is drawn before the store answered, with no prices (0.2.1,
    /// CONTRACT §8). `paywall_shown` then waits for `pricesLoaded`, so the events are the same
    /// as when the prices came first, but no longer than `priceWaitEnded` or the person's first
    /// action. `paywall_closed.durationMs` counts from now, when it is drawn.
    @discardableResult
    public func present(placement: String, resolution: Resolution, prices: [String: StorePrice], pricesError: String?, awaitingPrices: Bool = false) -> Bool {
        guard presented == nil, case let .paywall(campaignId, versionId, paywallId, variant, _, _) = resolution,
              let def = config?.paywall(versionId: versionId)?.definition else { return false }
        presentations += 1
        presented = Presented(placement: placement, paywallId: paywallId, variant: variant, campaignId: campaignId, versionId: versionId,
                              shownAt: clock(), selected: nil, prices: prices, definition: def, id: presentations,
                              awaitingPrices: awaitingPrices, shownSent: false)
        if awaitingPrices { return true }
        if let pricesError { emit("prices_load_failed", reason: pricesError) }
        sendShown()
        return true
    }

    /// `paywall_shown` and the display history, once per presentation.
    private func sendShown() {
        guard let p = presented, !p.shownSent else { return }
        presented?.shownSent = true
        emit("paywall_shown")
        history.record(campaignId: p.campaignId, at: p.shownAt)
        onHistoryChange(history)
    }

    /// The store's answer for a paywall drawn with `awaitingPrices`: its prices, then
    /// `prices_load_failed` when they failed (the store error, `products_not_found` or
    /// `timeout`) and `paywall_shown` if it hasn't been sent. False, with nothing emitted,
    /// when that paywall (`presentation`, its `Presented.id`) is gone or already has its answer.
    @discardableResult
    public func pricesLoaded(_ prices: [String: StorePrice], pricesError: String?, presentation: Int) -> Bool {
        guard let p = presented, p.id == presentation, p.awaitingPrices else { return false }
        presented?.prices = prices
        presented?.awaitingPrices = false
        if let pricesError { emit("prices_load_failed", reason: pricesError) }
        sendShown()
        return true
    }

    /// The wait for prices (3 s) ended before the store answered: the paywall counts as
    /// shown from now on; a failure that comes later follows `paywall_shown`.
    public func priceWaitEnded(presentation: Int) {
        guard presented?.id == presentation else { return }
        sendShown()
    }

    /// A resolved paywall could not be shown (e.g. no window to present on).
    public func paywallLoadFailed(placement: String, reason: String) {
        guard presented == nil else { return }
        emit("paywall_load_failed", placement: placement, reason: reason)
    }

    /// What the open paywall draws.
    public var renderModel: RenderModel? {
        presented.map { Render.model($0.definition, prices: $0.prices, selectedProductId: $0.selected, locale: locale) }
    }

    private func product(_ id: String) -> PaywallDefinition.Product? { presented?.definition.products.first { $0.id == id } }

    /// The person picked a plan (definition product id).
    @discardableResult
    public func select(productId: String) -> Bool {
        guard presented != nil, let p = product(productId) else { return false }
        sendShown()
        presented?.selected = p.id
        emit("plan_selected", productId: p.storeProductId)
        return true
    }

    /// Starts buying the selected plan: emits `purchase_started` and returns the
    /// product, or nil when nothing is purchasable.
    public func beginPurchase() -> PaywallDefinition.Product? {
        guard presented != nil, let m = renderModel, m.purchasable, let id = m.selectedProductId, let p = product(id) else { return nil }
        sendShown()
        emit("purchase_started", productId: p.storeProductId)
        return p
    }

    /// The store's answer for the purchase begun with `beginPurchase`.
    public func finishPurchase(_ product: PaywallDefinition.Product, outcome: PurchaseOutcome) {
        guard presented != nil else { return }
        switch outcome {
        case .purchased: emit("purchase_completed", productId: product.storeProductId); dismiss("purchased")
        case .trial: emit("trial_started", productId: product.storeProductId); dismiss("purchased")
        case .cancelled: emit("purchase_failed", productId: product.storeProductId, reason: "cancelled")
        case .pending: emit("purchase_failed", productId: product.storeProductId, reason: "pending")
        case .failed(let r): emit("purchase_failed", productId: product.storeProductId, reason: String((r.isEmpty ? "store_error" : r).prefix(200)))
        }
    }

    public func restoreStarted() {
        sendShown()
        emit("restore_started")
    }

    public func restoreFinished(_ outcome: RestoreOutcome) {
        emit("restore_completed", reason: outcome == .nothing ? "nothing_to_restore" : outcome.rawValue)
        if outcome == .restored && presented != nil { dismiss("restored") }
    }

    /// The person closed the paywall.
    public func close() { if presented != nil { dismiss("closed") } }

    private func dismiss(_ reason: String) {
        guard let p = presented else { return }
        sendShown()
        emit("paywall_closed", durationMs: min(600_000, max(0, clock() - p.shownAt)), reason: reason)
        presented = nil
        onDismiss(reason)
    }
}
