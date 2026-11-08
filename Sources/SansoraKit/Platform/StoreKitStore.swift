import Foundation
#if canImport(StoreKit)
import StoreKit

/// Subscription state for the `subscription` audience attribute.
public enum SubscriptionStatus: String, Sendable {
    case never, trial, active, lapsed
}

/// StoreKit 2 purchases (CONTRACT §7). Public so the Flutter and React Native
/// bridges use the same store code.
public final class StoreKitStore: @unchecked Sendable {
    private let lock = NSLock()
    private var products: [String: Product] = [:]
    private var updatesTask: Task<Void, Never>?

    public init() {}

    deinit { updatesTask?.cancel() }

    /// Store prices by store product ID. Free trial days are given only when the
    /// intro offer is a free trial **and** this user is eligible for it.
    /// Products the store doesn't know are left out. Throws when the store fails.
    public func prices(for storeProductIds: [String]) async throws -> [String: StorePrice] {
        let ids = Array(Set(storeProductIds.filter { !$0.isEmpty }))
        guard !ids.isEmpty else { return [:] }
        let found = try await Product.products(for: ids)
        var out: [String: StorePrice] = [:]
        for p in found {
            lock.sync { products[p.id] = p }
            var trial = 0
            if let sub = p.subscription, let intro = sub.introductoryOffer, intro.paymentMode == .freeTrial,
               await sub.isEligibleForIntroOffer {
                trial = Self.days(intro.period)
            }
            out[p.id] = StorePrice(priceMicros: Self.micros(p.price), currency: p.priceFormatStyle.currencyCode,
                                   displayPrice: p.displayPrice, trialDays: trial)
        }
        return out
    }

    /// The `reason` for a failed price load.
    public static func errorReason(_ error: Error) -> String {
        if let e = error as? StoreKitError {
            switch e {
            case .networkError: return "network"
            case .systemError: return "system_error"
            case .notAvailableInStorefront: return "not_available_in_storefront"
            case .notEntitled: return "not_entitled"
            case .userCancelled: return "cancelled"
            default: return "store_error"
            }
        }
        return "store_error"
    }

    static func days(_ period: Product.SubscriptionPeriod) -> Int {
        switch period.unit {
        case .day: return period.value
        case .week: return period.value * 7
        case .month: return period.value * 30
        case .year: return period.value * 365
        @unknown default: return 0
        }
    }

    static func micros(_ price: Decimal) -> Int64 {
        var v = price * 1_000_000
        var r = Decimal()
        NSDecimalRound(&r, &v, 0, .plain)
        return NSDecimalNumber(decimal: r).int64Value
    }

    private func product(_ id: String) async throws -> Product? {
        if let p = lock.sync({ products[id] }) { return p }
        let p = try await Product.products(for: [id]).first
        if let p { lock.sync { products[id] = p } }
        return p
    }

    /// Buys a product: verified transactions are finished; `.trial` when the
    /// transaction used the free-trial intro offer, else `.purchased`.
    public func purchase(storeProductId: String, appAccountToken: UUID? = nil) async -> PurchaseOutcome {
        do {
            guard let product = try await product(storeProductId) else { return .failed("product_not_found") }
            var options: Set<Product.PurchaseOption> = []
            if let appAccountToken { options.insert(.appAccountToken(appAccountToken)) }
            let result = try await product.purchase(options: options)
            switch result {
            case .success(let verification):
                guard case .verified(let t) = verification else { return .failed("unverified") }
                await t.finish()
                let freeTrial = t.offerType == .introductory && product.subscription?.introductoryOffer?.paymentMode == .freeTrial
                return freeTrial ? .trial : .purchased
            case .userCancelled: return .cancelled
            case .pending: return .pending
            @unknown default: return .failed("store_error")
            }
        } catch {
            if let e = error as? StoreKitError, case .userCancelled = e { return .cancelled }
            if let e = error as? Product.PurchaseError {
                switch e {
                case .productUnavailable: return .failed("product_unavailable")
                case .purchaseNotAllowed: return .failed("purchase_not_allowed")
                case .ineligibleForOffer: return .failed("ineligible_for_offer")
                default: return .failed("purchase_error")
                }
            }
            return .failed(Self.errorReason(error))
        }
    }

    /// `AppStore.sync()` then `Transaction.currentEntitlements`.
    public func restore() async -> RestoreOutcome {
        do { try await AppStore.sync() } catch { return .failed }
        return await hasEntitlement() ? .restored : .nothing
    }

    /// Any verified, unrevoked current entitlement.
    public func hasEntitlement() async -> Bool {
        for await r in Transaction.currentEntitlements {
            if case .verified(let t) = r, t.revocationDate == nil { return true }
        }
        return false
    }

    /// `trial` (active in a free trial), `active`, `lapsed` (had one that ended) or `never`.
    public func subscriptionStatus() async -> SubscriptionStatus {
        var active = false, trial = false
        for await r in Transaction.currentEntitlements {
            guard case .verified(let t) = r, t.revocationDate == nil else { continue }
            if let exp = t.expirationDate, exp < Date() { continue }
            active = true
            if t.productType == .autoRenewable, t.offerType == .introductory,
               let p = try? await product(t.productID), p.subscription?.introductoryOffer?.paymentMode == .freeTrial {
                trial = true
            }
        }
        if trial { return .trial }
        if active { return .active }
        for await r in Transaction.all {
            if case .verified = r { return .lapsed }
        }
        return .never
    }

    /// Listens to `Transaction.updates` (renewals, Ask to Buy, other devices) and
    /// finishes verified transactions. Call once at configure.
    public func startTransactionListener(onTransaction: (@Sendable (_ productId: String) -> Void)? = nil) {
        lock.sync {
            guard updatesTask == nil else { return }
            updatesTask = Task.detached(priority: .background) {
                for await update in Transaction.updates {
                    if case .verified(let t) = update {
                        await t.finish()
                        onTransaction?(t.productID)
                    }
                }
            }
        }
    }
}
#endif
