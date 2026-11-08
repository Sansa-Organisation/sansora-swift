import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(StoreKit)
import StoreKit
#endif

/// Device facts for events and audiences (CONTRACT §3 and §5).
public enum DeviceInfo {
    public static let sdkVersion = "0.1.0"

    /// Model identifier (`utsname.machine`, or `SIMULATOR_MODEL_IDENTIFIER` in the Simulator), ≤ 40 characters.
    public static var modelIdentifier: String {
        if let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"], !sim.isEmpty { return String(sim.prefix(40)) }
        var u = utsname()
        uname(&u)
        let machine = withUnsafeBytes(of: &u.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        return String(machine.prefix(40))
    }

    /// "18.2" or "18.2.1".
    public static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let s = v.patchVersion > 0 ? "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)" : "\(v.majorVersion).\(v.minorVersion)"
        return String(s.prefix(20))
    }

    /// `iphone` or `ipad`.
    @MainActor public static var deviceKind: String {
        #if canImport(UIKit) && !os(watchOS)
        return UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        #else
        return "iphone"
        #endif
    }

    /// Lowercase primary language of the preferred locale, e.g. `en`.
    public static var language: String? {
        guard let first = Locale.preferredLanguages.first else { return nil }
        let primary = first.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? first
        return primary.isEmpty ? nil : primary.lowercased()
    }

    public static var appVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    /// ISO 3166 alpha-2 → alpha-3 (`countries.json`).
    public static func alpha3(_ alpha2: String) -> String? { Countries.alpha3[alpha2.uppercased()] }
    public static func alpha2(_ alpha3: String) -> String? { Countries.alpha2[alpha3.uppercased()] }

    /// The App Store storefront as alpha-2 (uppercase), nil when StoreKit has none.
    public static func storefront() async -> String? {
        #if canImport(StoreKit)
        if let code = await Storefront.current?.countryCode { return alpha2(code) }
        #endif
        return nil
    }

    /// Fields every event carries. `platform` is `ios`, `flutter` or `react_native` on iOS.
    public static func eventContext(platform: String = "ios", sdkVersion: String = DeviceInfo.sdkVersion, storefrontAlpha2: String?) -> EventContext {
        EventContext(platform: platform, sdkVersion: sdkVersion, osVersion: osVersion, device: modelIdentifier,
                     storefront: storefrontAlpha2.flatMap(alpha3), store: "app_store")
    }

    /// Audience attributes (`campaigns.ts` names). Missing facts are left out, so they never match.
    /// - Parameters:
    ///   - subscription: `never|trial|active|lapsed` from the store, nil when unknown.
    ///   - custom: custom attributes, sent as `custom.<key>`.
    @MainActor
    public static func attributes(state: LocalState = .shared, storefrontAlpha2: String?, subscription: String?,
                                  custom: [String: AttributeValue] = [:], now: Int64 = LocalState.nowMs()) -> UserAttributes {
        var a: UserAttributes = [:]
        if let s = storefrontAlpha2 { a["storefront"] = .string(s.uppercased()) }
        if let l = language { a["language"] = .string(l) }
        a["device"] = .string(deviceKind)
        a["os_version"] = .string(osVersion)
        if let v = appVersion { a["app_version"] = .string(v) }
        if let d = state.daysSinceInstall(now: now) { a["days_since_install"] = .number(Double(d)) }
        a["sessions"] = .number(Double(state.sessions))
        if let s = subscription { a["subscription"] = .string(s) }
        a["paywall_declined"] = .number(Double(state.paywallDeclined))
        if let d = state.daysSinceDecline(now: now) { a["days_since_decline"] = .number(Double(d)) }
        for (k, v) in custom { a["custom.\(k)"] = v }
        return a
    }
}
