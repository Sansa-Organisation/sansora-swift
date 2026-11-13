# SansoraKit (iOS)

The Sansora iOS SDK, version `0.2.1`: downloads `sansora.config/1`, resolves
placements, draws paywalls natively (SwiftUI), buys with StoreKit 2 and delivers
`sansora.event/1` events. It implements [`CONTRACT.md`](CONTRACT.md) and
replays every shared fixture in `conformance-fixtures/`.

iOS 15+, Swift 5.9+, no third-party dependencies, no resources (the ISO country
table is compiled in as Swift source). It also compiles in the Swift 6 language mode
with complete concurrency checking, which CocoaPods uses when the app's target is Swift 6
(the podspec allows 5.9 and 6.0); Swift Package Manager builds it in Swift 5 mode.

## Install

- **Swift Package Manager:**
  `.package(url: "https://github.com/Sansa-Organisation/sansora-swift.git", from: "0.2.1")`
  and the product `.product(name: "SansoraKit", package: "sansora-swift")`. In Xcode:
  File › Add Package Dependencies, then paste the URL.
- **CocoaPods** (Flutter and React Native apps, whose plugins depend on the pod): add
  `pod 'SansoraKit', :git => 'https://github.com/Sansa-Organisation/sansora-swift.git', :tag => '0.2.1'`
  to the Podfile. SansoraKit is not on CocoaPods trunk, which becomes read-only in
  December 2026.


## Use

```swift
import SansoraKit

try Sansora.shared.configure(publicKey: "pk_live_…", options: .init(
    bundledConfig: .resource(name: "sansora-config", bundle: .main)))   // `sansora paywalls pull`
try Sansora.shared.identify("user-123")                // optional; else a persisted anon-<uuid>
try Sansora.shared.setAttributes(["level": .number(7)]) // audiences: custom.level

let result = await Sansora.shared.register(placement: "onboarding_end")
// .purchased | .restored | .closed | .holdout | .noCampaign(reason:) | .noConfig | .ignored
```

SwiftUI apps that present themselves:

```swift
Button("Go Pro") { showPaywall = true }
    .sansoraPaywall(placement: "feature_gate", isPresented: $showPaywall) { result in … }
```

### Public API (`@MainActor final class Sansora`)

| Signature | Notes |
| --- | --- |
| `static let shared: Sansora` | |
| `func configure(publicKey: String, options: Sansora.Options = .init()) throws` | Key `^pk_(test\|live)_[a-z0-9]{24}$`. Options: `appUserId`, `baseURL` (default `https://api.sansora.my`), `bundledConfig` (`.data`, `.file(URL)`, `.resource(name:bundle:)`), `logLevel`, `platform` (`ios`; bridges pass `flutter` / `react_native`). |
| `func identify(_ appUserId: String) throws` | 1–128 visible ASCII. |
| `func reset()` | New anonymous ID, custom attributes cleared. |
| `func setAttributes(_: [String: AttributeValue]) throws` / `setAttributes(any: [String: Any]) throws` | Keys `^[a-z][a-z0-9_]{0,39}$`, ≤ 20, String ≤ 200 / finite number / Bool. |
| `func register(placement: String) async -> SansoraResult` | Presents full screen over the key window's top view controller, at once: prices show a placeholder until StoreKit answers (at most 3 s, then “Price unavailable” for what is missing), and the button stays off until the selected plan has a price. |
| `func getPaywall(placement: String) -> SansoraPaywallInfo` | `resolution` + `definition`, no events, no presentation. |
| `func closePaywall()` | Closes the open paywall (reason `closed`). |
| `func restorePurchases() async -> RestoreOutcome` | `.restored`, `.nothing`, `.failed`; emits restore events. |
| `func subscriptionStatus() async -> SubscriptionStatus` | `.never`, `.trial`, `.active`, `.lapsed`. |
| `func flush() async` | Sends queued events and waiting purchase confirmations now. |
| `func openPreview(code: String) async -> SansoraResult` | Test keys only: draws the private preview a person made in the desktop app (code `XXXX-XXXX-XXXX`) with store prices. No events, no history, purchase and restore do nothing; `.closed` when dismissed, `.noCampaign(reason: "preview_not_found" \| "preview_test_key_required" \| "preview_unavailable")` otherwise. |
| `func currentAttributes() -> UserAttributes` | What audiences see. |
| `var onEvent: ((SdkEvent) -> Void)?` | Every emitted event (also queued). |
| `var appUserId: String`, `configStore`, `eventQueue`, `store`, `state` | The building blocks below. |

`SansoraResult.ignored` is a `register` while a paywall is open (no events).
`.noCampaign(reason: "no_window" | "invalid_placement")` is an iOS addition.
When the store answers without a product of the definition that has a store
product ID, `prices_load_failed` is emitted with reason `products_not_found`
(`Render.missingPricesReason(_:prices:)`); store errors keep their reason, and no
answer within 15 s is `timeout`. `paywall_shown` follows StoreKit's answer, or the end of
the 3-second wait, or the person's first action, whichever comes first (CONTRACT §5). The
last known storefront is persisted (`LocalState.storefront`) and used for
attributes and events until StoreKit answers.

A definition's legal footer may carry `textGooglePlay` (0.2.1) for Android; SansoraKit reads
and keeps it (`PaywallDefinition.Block.legal(…, textGooglePlay:)`) and always draws `text`.

## Building blocks for the Flutter and React Native bridges

All public. A bridge either drives the facade (`configure(…, options: .init(platform: "flutter"))`,
`register`, …) **or** uses these classes directly — not both on the same event
file, since `EventQueue.defaultFileURL()` is shared.

### `StoreKitStore` (StoreKit 2, CONTRACT §7)

```swift
public final class StoreKitStore: @unchecked Sendable {
    public init()
    /// By store product ID; missing products are left out. trialDays only when the
    /// intro offer is a free trial and the user is eligible. Throws on store failure.
    public func prices(for storeProductIds: [String]) async throws -> [String: StorePrice]
    public static func errorReason(_ error: Error) -> String         // `reason` for prices_load_failed
    public func purchase(storeProductId: String, appAccountToken: UUID? = nil) async -> PurchaseOutcome
    public func restore() async -> RestoreOutcome                     // AppStore.sync() + currentEntitlements
    public func hasEntitlement() async -> Bool
    public func subscriptionStatus() async -> SubscriptionStatus
    public func startTransactionListener(onTransaction: (@Sendable (_ productId: String) -> Void)? = nil)
}
public struct StorePrice { priceMicros: Int64; currency: String; displayPrice: String; trialDays: Int }
public enum PurchaseOutcome { case purchased, trial, cancelled, pending, failed(String) } // failed: "unverified", "product_not_found", store errors
public enum RestoreOutcome: String { case restored, nothing, failed }
public enum SubscriptionStatus: String { case never, trial, active, lapsed }
```

### `EventQueue` (durable delivery, CONTRACT §6)

```swift
public actor EventQueue {
    public init(fileURL: URL?, transport: EventTransport? = nil,
                jitter: @escaping @Sendable () -> Double = { Double.random(in: 0...0.2) },
                autoFlush: Bool = true, debounceSeconds: Double = 1)
    public static func defaultFileURL() -> URL                // Application Support/Sansora/events.json
    public func setTransport(_ transport: EventTransport?)
    public func enqueue(_ events: [JSONValue])
    public func enqueue(_ event: SdkEvent)
    public func enqueue(jsonEvents data: Data) throws         // a JSON array of event objects, or one object
    public func scheduleFlush()                               // debounced ~1 s
    @discardableResult public func flush(maxBatches: Int = .max) async -> FlushOutcome
    public var count: Int { get }; public var pending: [JSONValue] { get }
    public var failures: Int { get }; public var overflow: Int { get }
}
public struct HTTPEventTransport: EventTransport { public init(baseURL: URL, publicKey: String, session: URLSession = .shared) }
public protocol EventTransport: Sendable { func send(_ events: [JSONValue]) async -> FlushResponse }
```

Bridge events must already be complete `sansora.event/1` objects (use
`DeviceInfo.eventContext(platform:storefrontAlpha2:)` for the device fields).

### `ConfigStore` (CONTRACT §1)

```swift
public final class ConfigStore: @unchecked Sendable {
    public init(publicKey: String, baseURL: URL, directory: URL? = SansoraStorage.directory(),
                bundledConfig: Data? = nil, session: URLSession = .shared)
    public var config: SdkConfig? { get }
    public var configJSON: Data? { get }                      // the config in use, as JSON
    public var source: ConfigStore.Source? { get }            // .cache, .bundled, .network
    public var lastFetchedAt: Date? { get }
    public var isStale: Bool { get }                          // older than 15 minutes
    @discardableResult public func refresh(force: Bool = false) async -> Bool   // true when it changed
}
```

### `DeviceInfo` and `LocalState`

```swift
public enum DeviceInfo {
    public static let sdkVersion: String                      // "0.2.1"
    public static var modelIdentifier: String { get }         // utsname / SIMULATOR_MODEL_IDENTIFIER
    public static var osVersion: String { get }
    @MainActor public static var deviceKind: String { get }   // iphone | ipad
    public static var language: String? { get }
    public static var appVersion: String? { get }
    public static func alpha3(_ alpha2: String) -> String?
    public static func alpha2(_ alpha3: String) -> String?
    public static func storefront() async -> String?          // alpha-2 from StoreKit Storefront.current
    public static func eventContext(platform: String = "ios", sdkVersion: String = DeviceInfo.sdkVersion,
                                    storefrontAlpha2: String?) -> EventContext
    @MainActor public static func attributes(state: LocalState = .shared, storefrontAlpha2: String?, subscription: String?,
                                             custom: [String: AttributeValue] = [:], now: Int64 = LocalState.nowMs()) -> UserAttributes
}
public final class LocalState {   // install date, sessions, history, declines, user ID (Application Support/Sansora/state.json)
    public static let shared: LocalState
    public var appUserId: String { get }; public func identify(_:); public func resetUser()
    public func recordLaunch(now:); public func didEnterBackground(now:); public func willEnterForeground(now:) -> Bool
    public var history: DisplayHistory; public func recordDecline(now:)
    public var storefront: String?   // last StoreKit storefront, alpha-2
}
```

### Pure logic (same answers as the TypeScript reference)

`Assignment.bucket(_:)`, `Assignment.resolvePlacement(_:placement:appUserId:user:history:now:)`,
`AudienceEvaluator.ruleMatches(_:_:)` / `matches(_:_:)`, `Render.model(_:prices:selectedProductId:)`,
`Render.formatLike(_:minor:currency:)`, `Render.missingPricesReason(_:prices:)`, `Render.perMonthMinor(priceMicros:num:den:digits:)`,
`PaywallSession` (headless event emission with injected clock and IDs; `present(…, awaitingPrices: true)`,
`pricesLoaded(_:pricesError:presentation:)` and `priceWaitEnded(presentation:)` for a paywall drawn before
the prices), `RenderModel.json`,
`Resolution.json`, `SdkEvent.json`. UI: `SansoraPaywallView(model: PaywallViewModel)`
(`PaywallViewModel.pricesLoading` draws the price placeholders).

## Test

```sh
cd sansora-swift
swift test                                   # macOS host: unit + conformance
xcodebuild test -scheme SansoraKit \
  -destination "platform=iOS Simulator,id=<udid>"   # same suites on the iOS Simulator
```

`SansoraConformanceTests` loads the shared fixtures via `#filePath`
(`conformance-fixtures/`): hash,
audience, resolution, definitions (round trip), countries, render, price-format,
sessions (events and step results as JSON objects) and delivery.


## Changes

### 0.2.1 (2026-11-12)

- **No blank screen while prices load.** `register`, `.sansoraPaywall` and `openPreview` draw
  the paywall at once. Price lines show a placeholder until StoreKit answers; after 3 seconds
  what is still missing reads “Price unavailable” (translated as before), and prices that arrive
  later (up to 15 s) still fill in. The purchase button stays off until the selected plan has a
  price. Events are unchanged when StoreKit answers within the 3 seconds; otherwise
  `paywall_shown` is sent when the wait ends and a later failure follows it. No answer within
  15 s is `prices_load_failed` with `timeout`. Before, nothing showed until StoreKit answered
  (about 5 s in the Simulator).
- **Swift 6.** Compiles in the Swift 6 language mode with complete concurrency checking.
  CocoaPods builds the pod in Swift 6 when the app's target is Swift 6 (an Expo 58 app, for
  example), and 0.2.0 failed there on `Render.asIs`, a non-`Sendable` static closure; it is a
  function now.
- **Store-specific legal text.** The definition's `legal.textGooglePlay` is read and kept
  (`PaywallDefinition.Block.legal` has a fifth value, `textGooglePlay`, defaulting to `nil`; a
  `switch` that binds four values needs a fifth). iOS always shows `text`.
- Events report `sdkVersion` `0.2.1`.

### 0.2.0 (2026-11-12)

- **Purchase confirmation.** Every verified StoreKit purchase the SDK handles for the first
  time (from the paywall or `Transaction.updates`: renewals, Ask to Buy, other devices) is
  written to a small queue on the device before it is finished, then sent to Sansora
  (`POST /v1/sdk/purchases/confirm`) with the app user at that moment, so the server can tie
  the purchase to the user. The queue survives restarts, retries with backoff and never
  delays or changes the purchase. `identify` and `reset` change the user for later purchases.
  Signed transactions are never logged.
- **Multi-page paywalls.** A definition with pages shows one page at a time with a next
  button.
- **Translations and right-to-left.** The paywall uses the translation for the device
  language when the definition has one; right-to-left languages lay out right to left, and
  Terms, Privacy, Restore, Close and “Price unavailable” come from the translation.
- **Preview.** `openPreview(code:)` shows a paywall a person is still working on, from a code
  made in the Sansora desktop app (test keys only). Nothing is recorded and purchases are off.
- Events report `sdkVersion` `0.2.0`.

### 0.1.0 (2026-11-08)

First release.
