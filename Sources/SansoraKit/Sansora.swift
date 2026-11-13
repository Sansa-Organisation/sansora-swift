import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The result of `register(placement:)`.
public enum SansoraResult: Equatable, Sendable {
    /// Bought or started a trial from the paywall.
    case purchased
    /// Restored from the paywall.
    case restored
    /// The person closed the paywall.
    case closed
    /// The user is in a holdout: nothing shows.
    case holdout
    /// No campaign shows here: `no_campaign_for_placement`, `no_audience_match`, `frequency_capped`,
    /// or `no_window` / `invalid_placement` when the SDK could not show one.
    case noCampaign(reason: String)
    /// No config yet (nothing downloaded or bundled), or `configure` was not called.
    case noConfig
    /// A paywall is already showing; this register was ignored (no events).
    case ignored
}

public enum SansoraError: Error, Equatable {
    case invalidPublicKey
    case invalidAppUserId
    case invalidAttribute(String)
    case notConfigured
}

/// Resolution and definition for a placement, without presenting or emitting events.
public struct SansoraPaywallInfo: Equatable, Sendable {
    /// nil when there is no config.
    public var resolution: Resolution?
    /// The paywall definition when the resolution is `.paywall`.
    public var definition: PaywallDefinition?
}

/// The Sansora SDK. Use from the main thread.
///
///     try Sansora.shared.configure(publicKey: "pk_live_…")
///     let result = await Sansora.shared.register(placement: "onboarding_end")
@MainActor
public final class Sansora {
    public static let shared = Sansora()

    public enum BundledConfig: Sendable {
        case data(Data)
        case file(URL)
        /// A JSON file in a bundle, e.g. `.resource(name: "sansora-config", bundle: .main)`.
        case resource(name: String, bundle: Bundle)

        var data: Data? {
            switch self {
            case .data(let d): return d
            case .file(let u): return try? Data(contentsOf: u)
            case let .resource(name, bundle): return bundle.url(forResource: name, withExtension: "json").flatMap { try? Data(contentsOf: $0) }
            }
        }
    }

    public struct Options: Sendable {
        public var appUserId: String?
        /// Default `https://api.sansora.my`.
        public var baseURL: URL
        /// A `sansora.config/1` document shipped with the app (`sansora paywalls pull`).
        public var bundledConfig: BundledConfig?
        public var logLevel: SansoraLogLevel
        /// `ios`, or `flutter` / `react_native` when a bridge configures the SDK.
        public var platform: String
        public init(appUserId: String? = nil, baseURL: URL = URL(string: "https://api.sansora.my")!, bundledConfig: BundledConfig? = nil,
                    logLevel: SansoraLogLevel = .error, platform: String = "ios") {
            self.appUserId = appUserId; self.baseURL = baseURL; self.bundledConfig = bundledConfig
            self.logLevel = logLevel; self.platform = platform
        }
    }

    public static let publicKeyPattern = "^pk_(test|live)_[a-z0-9]{24}$"

    /// Every event the SDK emits (also queued for delivery). For logs and analytics mirrors.
    public var onEvent: ((SdkEvent) -> Void)?

    public private(set) var configStore: ConfigStore?
    public private(set) var eventQueue: EventQueue?
    private var confirmations: PurchaseConfirmationQueue?
    #if canImport(StoreKit)
    public let store = StoreKitStore()
    #endif
    public let state: LocalState
    public private(set) var isConfigured = false

    private var session: PaywallSession?
    private var options = Options()
    private var custom: [String: AttributeValue] = [:]
    private var storefront: String?
    private var subscription: SubscriptionStatus?
    private var busy = false
    private var finishPresentation: ((String) -> Void)?
    private var observers: [NSObjectProtocol] = []

    /// How long a paywall shows placeholders for prices the store hasn't sent yet; after that
    /// they read “Price unavailable” until the answer comes (CONTRACT §8).
    var priceWaitNanoseconds: UInt64 = 3_000_000_000
    /// How long the store's answer is awaited at all; then `prices_load_failed` with `timeout`.
    var priceLimitNanoseconds: UInt64 = 15_000_000_000
    /// Store prices by store product ID: StoreKit, unless a test replaces it.
    var priceLoader: (@Sendable ([String]) async throws -> [String: StorePrice])?

    private let storageDirectory: URL?

    init(state: LocalState = .shared, storageDirectory: URL? = nil) {
        self.state = state
        self.storageDirectory = storageDirectory
        // The last known storefront, until StoreKit answers (CONTRACT §5).
        self.storefront = state.storefront
    }

    /// Device fields for events, with the current (or last known) storefront.
    func eventContext() -> EventContext {
        DeviceInfo.eventContext(platform: options.platform, storefrontAlpha2: storefront)
    }

    /// The current user ID (identified, or the persisted anonymous one).
    public var appUserId: String { state.appUserId }

    // MARK: Setup

    public func configure(publicKey: String, options: Options = Options()) throws {
        guard publicKey.range(of: Self.publicKeyPattern, options: .regularExpression) != nil else { throw SansoraError.invalidPublicKey }
        if let id = options.appUserId { guard Self.validUserId(id) else { throw SansoraError.invalidAppUserId } }
        guard !isConfigured else { SansoraLog.error("Sansora is already configured; ignoring the second configure."); return }
        SansoraLog.level = options.logLevel
        self.options = options
        state.recordLaunch()
        if let id = options.appUserId { state.identify(id) }

        let dir = storageDirectory ?? SansoraStorage.directory()
        let configStore = ConfigStore(publicKey: publicKey, baseURL: options.baseURL, directory: dir, bundledConfig: options.bundledConfig?.data)
        let queue = EventQueue(fileURL: dir.appendingPathComponent("events.json"), transport: HTTPEventTransport(baseURL: options.baseURL, publicKey: publicKey))
        let confirmations = PurchaseConfirmationQueue(fileURL: dir.appendingPathComponent("purchase-confirmations.json"),
                                                      transport: HTTPPurchaseConfirmationTransport(baseURL: options.baseURL, publicKey: publicKey),
                                                      appUserId: state.appUserId)
        self.configStore = configStore
        self.eventQueue = queue
        self.confirmations = confirmations

        let session = PaywallSession(context: eventContext(), appUserId: state.appUserId,
                                     config: configStore.config, history: state.history,
                                     clock: { LocalState.nowMs() }, makeEventId: { UUID().uuidString.lowercased() })
        session.onEvent = { [weak self] e in
            Task { await queue.enqueue(e) }
            self?.onEvent?(e)
        }
        session.locale = Render.deviceLocale
        session.onHistoryChange = { [weak self] h in self?.state.history = h }
        session.onDismiss = { [weak self] reason in
            if reason == "closed" { self?.state.recordDecline() }
            let finish = self?.finishPresentation
            self?.finishPresentation = nil
            finish?(reason)
        }
        self.session = session
        isConfigured = true

        #if canImport(StoreKit)
        store.setConfirmationQueue(confirmations)
        store.startTransactionListener { _ in
            Task { @MainActor in _ = await Sansora.shared.refreshSubscription() }
        }
        #endif
        observeLifecycle()

        Task { @MainActor in
            if let sf = await DeviceInfo.storefront() {
                self.storefront = sf
                self.state.storefront = sf
                self.session?.context = self.eventContext()
            }
            _ = await self.refreshSubscription()
            await configStore.refresh(force: true)
            self.session?.config = configStore.config
            await queue.flush()
            await confirmations.flush()
        }
    }

    private func observeLifecycle() {
        #if canImport(UIKit) && !os(watchOS)
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in Sansora.shared.didEnterBackground() }
        })
        observers.append(nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in Sansora.shared.willEnterForeground() }
        })
        #endif
    }

    func didEnterBackground() {
        state.didEnterBackground()
        guard let queue = eventQueue else { return }
        let confirmations = confirmations
        #if canImport(UIKit) && !os(watchOS)
        var bg: UIBackgroundTaskIdentifier = .invalid
        bg = UIApplication.shared.beginBackgroundTask(withName: "Sansora flush") { UIApplication.shared.endBackgroundTask(bg); bg = .invalid }
        Task {
            await queue.flush()
            await confirmations?.flush()
            await MainActor.run { if bg != .invalid { UIApplication.shared.endBackgroundTask(bg) } }
        }
        #else
        Task {
            await queue.flush()
            await confirmations?.flush()
        }
        #endif
    }

    func willEnterForeground() {
        if state.willEnterForeground() { session?.newSession() }
        guard let configStore else { return }
        Task { @MainActor in
            if configStore.isStale, await configStore.refresh() { self.session?.config = configStore.config }
            _ = await self.refreshSubscription()
        }
    }

    static func validUserId(_ id: String) -> Bool {
        (1...128).contains(id.utf8.count) && id.unicodeScalars.allSatisfy { $0.value >= 0x21 && $0.value <= 0x7E }
    }

    // MARK: Identity and attributes

    /// Sets the app's own user ID (1–128 visible ASCII characters).
    public func identify(_ appUserId: String) throws {
        guard Self.validUserId(appUserId) else { throw SansoraError.invalidAppUserId }
        state.identify(appUserId)
        session?.appUserId = appUserId
        updateConfirmationUser()
    }

    /// Forgets the user: a new anonymous ID and no custom attributes.
    public func reset() {
        state.resetUser()
        custom = [:]
        session?.appUserId = state.appUserId
        updateConfirmationUser()
    }

    private func updateConfirmationUser() {
        guard let confirmations else { return }
        let id = state.appUserId
        Task { await confirmations.setAppUserId(id) }
    }

    /// Custom attributes (keys `^[a-z][a-z0-9_]{0,39}$`, at most 20), used in
    /// audiences as `custom.<key>` and sent with `placement_fired`.
    public func setAttributes(_ attributes: [String: AttributeValue]) throws {
        var merged = custom
        for (k, v) in attributes {
            guard k.range(of: "^[a-z][a-z0-9_]{0,39}$", options: .regularExpression) != nil else { throw SansoraError.invalidAttribute(k) }
            switch v {
            case .string(let s): guard s.count <= 200 else { throw SansoraError.invalidAttribute(k) }
            case .number(let d): guard d.isFinite else { throw SansoraError.invalidAttribute(k) }
            case .bool: break
            }
            merged[k] = v
        }
        guard merged.count <= 20 else { throw SansoraError.invalidAttribute("more than 20 attributes") }
        custom = merged
    }

    /// Same as `setAttributes(_:)` for String / number / Bool values (e.g. from a bridge).
    public func setAttributes(any attributes: [String: Any]) throws {
        var out: [String: AttributeValue] = [:]
        for (k, v) in attributes {
            switch v {
            case let n as NSNumber:
                out[k] = CFGetTypeID(n) == CFBooleanGetTypeID() ? .bool(n.boolValue) : .number(n.doubleValue)
            case let s as String: out[k] = .string(s)
            default: throw SansoraError.invalidAttribute(k)
            }
        }
        try setAttributes(out)
    }

    /// Audience attributes as the SDK sees them now.
    public func currentAttributes() -> UserAttributes {
        DeviceInfo.attributes(state: state, storefrontAlpha2: storefront, subscription: subscription?.rawValue, custom: custom)
    }

    // MARK: Placements

    /// Fires a placement; when it resolves to a paywall, presents it full screen
    /// over the key window's top view controller and returns when it closes.
    public func register(placement: String) async -> SansoraResult {
        #if canImport(UIKit) && !os(watchOS)
        var host: UIViewController?
        return await run(placement: placement, canPresent: { Self.topViewController() != nil }, present: { vm in
            guard let top = Self.topViewController() else { return }
            let vc = PaywallHostingController(rootView: SansoraPaywallView(model: vm))
            vc.dark = vm.model.theme == .dark
            vc.modalPresentationStyle = .fullScreen
            top.present(vc, animated: true)
            host = vc
        }, dismiss: {
            host?.presentingViewController?.dismiss(animated: true)
            host = nil
        })
        #else
        return await run(placement: placement, canPresent: { false }, present: { _ in }, dismiss: {})
        #endif
    }

    /// Opens a private preview with the code from Paywall editor › Preview on my iPhone (test
    /// keys only). Call it from a debug screen or deep link in your app: it sends no events,
    /// records no history, and buying and restoring are off. Prices come from the store.
    ///
    /// Returns `.closed` when dismissed, or `.noCampaign` with `preview_not_found`,
    /// `preview_test_key_required`, `preview_unavailable` or `no_window`.
    public func openPreview(code: String) async -> SansoraResult {
        guard let configStore, session != nil else { return .noConfig }
        guard let normalized = Preview.normalize(code) else { return .noCampaign(reason: "preview_not_found") }
        guard !busy, session?.presented == nil else { return .ignored }
        busy = true
        defer { busy = false }
        let definition: PaywallDefinition
        switch await Preview.fetch(baseURL: configStore.baseURL, publicKey: configStore.publicKey, code: normalized) {
        case .success(let def): definition = def
        case .failure(let reason): return .noCampaign(reason: reason.rawValue)
        }
        #if canImport(UIKit) && !os(watchOS)
        guard let top = Self.topViewController() else { return .noCampaign(reason: "no_window") }
        // Drawn at once; the store's prices replace the placeholders when they come (CONTRACT §8).
        let locale = Render.deviceLocale
        let preview = PreviewState(definition: definition, locale: locale)
        let vm = PaywallViewModel(model: preview.model)
        vm.isPreview = true
        vm.onSelect = { [weak vm] id in
            preview.selected = id
            vm?.update(preview.model)
        }
        if !Self.storeProductIds(definition).isEmpty {
            vm.pricesLoading = true
            loadPrices(for: definition, into: vm) { [weak vm] answer in
                preview.prices = answer.prices
                vm?.update(preview.model)
                return true
            }
        }
        let vc = PaywallHostingController(rootView: SansoraPaywallView(model: vm))
        vc.dark = vm.model.theme == .dark
        vc.modalPresentationStyle = .fullScreen
        return await withCheckedContinuation { (cont: CheckedContinuation<SansoraResult, Never>) in
            vm.onClose = { [weak vc] in
                vc?.presentingViewController?.dismiss(animated: true)
                cont.resume(returning: .closed)
            }
            top.present(vc, animated: true)
        }
        #else
        return .noCampaign(reason: "no_window")
        #endif
    }

    /// Closes the open paywall (as if the person tapped Close), e.g. before a deep link.
    public func closePaywall() {
        session?.close()
    }

    /// Resolves a placement without presenting it: emits no events and records no history.
    public func getPaywall(placement: String) -> SansoraPaywallInfo {
        guard let session, let config = configStore?.config ?? session.config else { return SansoraPaywallInfo(resolution: nil, definition: nil) }
        let r = Assignment.resolvePlacement(config, placement: placement, appUserId: state.appUserId, user: currentAttributes(),
                                            history: session.history, now: LocalState.nowMs())
        var def: PaywallDefinition?
        if case let .paywall(_, versionId, _, _, _, _) = r { def = config.paywall(versionId: versionId)?.definition }
        return SansoraPaywallInfo(resolution: r, definition: def)
    }

    static let placementPattern = "^[a-z][a-z0-9_]{0,63}$"

    /// The whole placement flow with a caller-supplied presenter (UIKit or SwiftUI).
    func run(placement: String, canPresent: () -> Bool = { true }, present: (PaywallViewModel) -> Void,
             dismiss: @escaping () -> Void) async -> SansoraResult {
        guard let session else { return .noConfig }
        guard placement.range(of: Self.placementPattern, options: .regularExpression) != nil else {
            SansoraLog.error("Invalid placement name: \(placement)")
            return .noCampaign(reason: "invalid_placement")
        }
        guard !busy, session.presented == nil else { return .ignored }
        busy = true
        defer { busy = false }
        if let c = configStore?.config { session.config = c }
        guard let fired = session.fire(placement: placement, attributes: currentAttributes(), custom: custom) else { return .ignored }
        let resolution: Resolution
        switch fired {
        case .noConfig: return .noConfig
        case .resolved(let r): resolution = r
        }
        guard case let .paywall(_, versionId, _, _, _, _) = resolution, let def = session.config?.paywall(versionId: versionId)?.definition else {
            if case .holdout = resolution { return .holdout }
            if case .noCampaign(let reason) = resolution { return .noCampaign(reason: reason.rawValue) }
            return .noConfig
        }
        guard canPresent() else {
            SansoraLog.error("No view controller to present the paywall on.")
            session.paywallLoadFailed(placement: placement, reason: "no_window")
            return .noCampaign(reason: "no_window")
        }
        // Drawn at once with placeholders for the prices and the purchase button off; the
        // store's answer fills them in (CONTRACT §8). Before 0.2.1 nothing showed until it came.
        let awaiting = !Self.storeProductIds(def).isEmpty
        guard session.present(placement: placement, resolution: resolution, prices: [:], pricesError: nil, awaitingPrices: awaiting),
              let model = session.renderModel, let presentation = session.presented?.id else { return .noConfig }
        let vm = PaywallViewModel(model: model)
        wire(vm, session: session)
        if awaiting {
            vm.pricesLoading = true
            loadPrices(for: def, into: vm, waitEnded: { session.priceWaitEnded(presentation: presentation) }) { [weak vm] answer in
                guard session.pricesLoaded(answer.prices, pricesError: answer.error, presentation: presentation) else { return false }
                if let m = session.renderModel { vm?.update(m) }
                return true
            }
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<SansoraResult, Never>) in
            finishPresentation = { reason in
                dismiss()
                cont.resume(returning: reason == "purchased" ? .purchased : reason == "restored" ? .restored : .closed)
            }
            present(vm)
        }
    }

    /// The store's answer for a paywall's products: prices, and the `prices_load_failed` reason
    /// (the store error, `products_not_found`, or `timeout`).
    struct PriceAnswer: Sendable {
        var prices: [String: StorePrice]
        var error: String?
    }

    static func storeProductIds(_ def: PaywallDefinition) -> [String] {
        Array(Set(def.products.map(\.storeProductId).filter { !$0.isEmpty })).sorted()
    }

    private nonisolated static func priceAnswer(_ load: @Sendable ([String]) async throws -> [String: StorePrice],
                                                ids: [String], definition: PaywallDefinition) async -> PriceAnswer {
        do {
            let prices = try await load(ids)
            return PriceAnswer(prices: prices, error: Render.missingPricesReason(definition, prices: prices))
        } catch {
            #if canImport(StoreKit)
            return PriceAnswer(prices: [:], error: StoreKitStore.errorReason(error))
            #else
            return PriceAnswer(prices: [:], error: "store_error")
            #endif
        }
    }

    /// Asks the store for `definition`'s prices while the paywall is on screen. The view shows
    /// placeholders for `priceWaitNanoseconds` (3 s), then “Price unavailable” for what is still
    /// missing (`waitEnded` runs then); the answer is applied whenever it comes within
    /// `priceLimitNanoseconds` (15 s), else `apply` gets `timeout`. `apply` returns false when
    /// the paywall has gone.
    private func loadPrices(for definition: PaywallDefinition, into vm: PaywallViewModel, waitEnded: @escaping @MainActor () -> Void = {},
                            apply: @escaping @MainActor (PriceAnswer) -> Bool) {
        let ids = Self.storeProductIds(definition)
        let load: @Sendable ([String]) async throws -> [String: StorePrice]
        if let priceLoader {
            load = priceLoader
        } else {
            #if canImport(StoreKit)
            let store = self.store
            load = { ids in try await store.prices(for: ids) }
            #else
            load = { _ in [:] }
            #endif
        }
        let wait = priceWaitNanoseconds, limit = max(priceLimitNanoseconds, priceWaitNanoseconds)
        let settle: @MainActor (PriceAnswer) -> Void = { [weak vm] answer in
            guard let vm, !vm.pricesSettled else { return }
            guard apply(answer) else { return }
            vm.pricesSettled = true
            vm.pricesLoading = false
        }
        let timer = Task { @MainActor [weak vm] in
            try? await Task.sleep(nanoseconds: wait)
            guard !Task.isCancelled else { return }
            vm?.pricesLoading = false
            waitEnded()
            try? await Task.sleep(nanoseconds: limit - wait)
            guard !Task.isCancelled else { return }
            settle(PriceAnswer(prices: [:], error: "timeout"))
        }
        Task { @MainActor in
            let answer = await Self.priceAnswer(load, ids: ids, definition: definition)
            timer.cancel()
            settle(answer)
        }
    }

    private func wire(_ vm: PaywallViewModel, session: PaywallSession) {
        vm.onSelect = { [weak vm] id in
            session.select(productId: id)
            if let m = session.renderModel { vm?.update(m) }
        }
        vm.onClose = { session.close() }
        vm.onPurchase = { [weak self, weak vm] in
            guard let self, let vm, let product = session.beginPurchase() else { return }
            vm.purchasing = true
            Task { @MainActor in
                #if canImport(StoreKit)
                let outcome = await self.store.purchase(storeProductId: product.storeProductId)
                #else
                let outcome = PurchaseOutcome.failed("store_unavailable")
                #endif
                vm.purchasing = false
                session.finishPurchase(product, outcome: outcome)
                if outcome == .purchased || outcome == .trial { _ = await self.refreshSubscription() }
                if let m = session.renderModel { vm.update(m) }
            }
        }
        vm.onRestore = { [weak self, weak vm] in
            guard let self, let vm else { return }
            vm.restoring = true
            Task { @MainActor in
                _ = await self.restorePurchases()
                vm.restoring = false
            }
        }
    }

    // MARK: Purchases

    /// Restores purchases (`AppStore.sync()`); closes an open paywall when something was restored.
    @discardableResult
    public func restorePurchases() async -> RestoreOutcome {
        #if canImport(StoreKit)
        session?.restoreStarted()
        let outcome = await store.restore()
        session?.restoreFinished(outcome)
        if outcome == .restored { _ = await refreshSubscription() }
        return outcome
        #else
        return .failed
        #endif
    }

    /// `never`, `trial`, `active` or `lapsed`, from the store.
    public func subscriptionStatus() async -> SubscriptionStatus {
        await refreshSubscription()
    }

    @discardableResult
    func refreshSubscription() async -> SubscriptionStatus {
        #if canImport(StoreKit)
        let s = await store.subscriptionStatus()
        subscription = s
        return s
        #else
        return .never
        #endif
    }

    /// Sends queued events now.
    public func flush() async {
        await eventQueue?.flush()
        await confirmations?.flush()
    }

    // MARK: Presentation helpers

    #if canImport(UIKit) && !os(watchOS)
    static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap { $0.windows }
        guard var top = (windows.first { $0.isKeyWindow } ?? windows.first)?.rootViewController else { return nil }
        while true {
            if let p = top.presentedViewController, !p.isBeingDismissed { top = p; continue }
            if let n = top as? UINavigationController, let v = n.visibleViewController { top = v; continue }
            if let t = top as? UITabBarController, let s = t.selectedViewController { top = s; continue }
            return top
        }
    }
    #endif
}

/// What a private preview draws: its definition, the store's prices once they come, and the plan picked.
@MainActor
final class PreviewState {
    let definition: PaywallDefinition
    let locale: String?
    var prices: [String: StorePrice] = [:]
    var selected: String?
    init(definition: PaywallDefinition, locale: String?) { self.definition = definition; self.locale = locale }
    var model: RenderModel { Render.model(definition, prices: prices, selectedProductId: selected, locale: locale) }
}

#if canImport(UIKit) && !os(watchOS)
final class PaywallHostingController: UIHostingController<SansoraPaywallView> {
    var dark = false
    override var preferredStatusBarStyle: UIStatusBarStyle { dark ? .lightContent : .darkContent }
}
#endif

// MARK: SwiftUI

public extension View {
    /// Fires `placement` when `isPresented` becomes true and shows the paywall (if
    /// any) as a full-screen cover. `isPresented` returns to false when done.
    func sansoraPaywall(placement: String, isPresented: Binding<Bool>, onResult: @escaping (SansoraResult) -> Void = { _ in }) -> some View {
        modifier(SansoraPaywallModifier(placement: placement, isPresented: isPresented, onResult: onResult))
    }
}

struct SansoraPaywallModifier: ViewModifier {
    let placement: String
    @Binding var isPresented: Bool
    let onResult: (SansoraResult) -> Void
    @State private var vm: PaywallViewModel?

    func body(content: Content) -> some View {
        content
            .onChange(of: isPresented) { show in
                guard show else { return }
                Task { @MainActor in
                    let r = await Sansora.shared.run(placement: placement, present: { vm in self.vm = vm }, dismiss: { self.vm = nil })
                    isPresented = false
                    onResult(r)
                }
            }
            #if os(iOS)
            .fullScreenCover(item: $vm) { vm in SansoraPaywallView(model: vm) }
            #else
            .sheet(item: $vm) { vm in SansoraPaywallView(model: vm) }
            #endif
    }
}
