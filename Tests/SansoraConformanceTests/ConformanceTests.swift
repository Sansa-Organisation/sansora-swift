import XCTest
@testable import SansoraKit

/// Replays every shared fixture in sdks/conformance/fixtures (generated from the
/// TypeScript reference; never edited by hand) against the Swift code. In the
/// standalone sansora-swift repository the export copies them to conformance-fixtures/.
enum Fixtures {
    static let directory: URL = {
        let package = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // SansoraConformanceTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // the package root: sdks/ios, or the exported repository
        let exported = package.appendingPathComponent("conformance-fixtures")
        if FileManager.default.fileExists(atPath: exported.path) { return exported }
        return package.deletingLastPathComponent().appendingPathComponent("conformance/fixtures")
    }()

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent(name))
    }

    static func json(_ name: String) throws -> JSONValue {
        try JSONValue.parse(data(name))
    }

    static func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try JSONDecoder().decode(type, from: data(name))
    }

    static var resolutionConfig: SdkConfig {
        get throws {
            let root = try json("resolution.json")
            return try XCTUnwrap(root["config"]).decode(SdkConfig.self)
        }
    }
}

/// Compares two JSON values and reports the first difference by path.
func assertJSONEqual(_ actual: JSONValue, _ expected: JSONValue, _ context: String, file: StaticString = #filePath, line: UInt = #line) {
    func diff(_ a: JSONValue, _ e: JSONValue, _ path: String) -> String? {
        switch (a, e) {
        case let (.object(x), .object(y)):
            for k in Set(x.keys).union(y.keys).sorted() {
                guard let xv = x[k] else { return "\(path).\(k): missing (expected \(y[k]!))" }
                guard let yv = y[k] else { return "\(path).\(k): unexpected \(xv)" }
                if let d = diff(xv, yv, "\(path).\(k)") { return d }
            }
            return nil
        case let (.array(x), .array(y)):
            if x.count != y.count { return "\(path): \(x.count) items, expected \(y.count)" }
            for i in x.indices { if let d = diff(x[i], y[i], "\(path)[\(i)]") { return d } }
            return nil
        default:
            return a == e ? nil : "\(path): \(a) ≠ expected \(e)"
        }
    }
    if let d = diff(actual, expected, "$") { XCTFail("\(context): \(d)", file: file, line: line) }
}

final class HashConformanceTests: XCTestCase {
    struct Case: Decodable { let seed: String; let sha256: String; let bucket: Int }

    func testHashAndBucket() throws {
        let cases = try Fixtures.decode([Case].self, "hash.json")
        XCTAssertGreaterThan(cases.count, 40)
        for c in cases {
            XCTAssertEqual(Assignment.sha256Hex(c.seed), c.sha256, c.seed)
            XCTAssertEqual(Assignment.bucket(c.seed), c.bucket, c.seed)
        }
    }
}

final class AudienceConformanceTests: XCTestCase {
    struct RuleCase: Decodable { let rule: AudienceRule; let user: UserAttributes; let expected: Bool }
    struct GroupCase: Decodable { let audience: Audience; let user: UserAttributes; let expected: Bool }
    struct File: Decodable { let rules: [RuleCase]; let groups: [GroupCase] }

    func testRules() throws {
        let f = try Fixtures.decode(File.self, "audience.json")
        XCTAssertFalse(f.rules.isEmpty)
        for (i, c) in f.rules.enumerated() {
            XCTAssertEqual(AudienceEvaluator.ruleMatches(c.rule, c.user), c.expected, "rule \(i): \(c.rule.attribute) \(c.rule.op) \(c.rule.value)")
        }
    }

    func testGroups() throws {
        let f = try Fixtures.decode(File.self, "audience.json")
        XCTAssertFalse(f.groups.isEmpty)
        for (i, c) in f.groups.enumerated() {
            XCTAssertEqual(AudienceEvaluator.matches(c.audience, c.user), c.expected, "group case \(i)")
        }
    }
}

final class ResolutionConformanceTests: XCTestCase {
    struct Case: Decodable {
        let name: String; let placement: String; let appUserId: String; let user: UserAttributes
        let history: DisplayHistory; let now: Int64; let expected: JSONValue
    }
    struct File: Decodable { let config: SdkConfig; let cases: [Case] }

    func testResolution() throws {
        let f = try Fixtures.decode(File.self, "resolution.json")
        XCTAssertGreaterThan(f.cases.count, 40)
        for c in f.cases {
            let r = Assignment.resolvePlacement(f.config, placement: c.placement, appUserId: c.appUserId, user: c.user, history: c.history, now: c.now)
            assertJSONEqual(r.json, c.expected, c.name)
        }
    }
}

final class DefinitionConformanceTests: XCTestCase {
    func testDefinitionsRoundTrip() throws {
        let raw = try Fixtures.json("definitions.json")
        let defs = try Fixtures.decode([String: PaywallDefinition].self, "definitions.json")
        XCTAssertEqual(defs.count, raw.objectValue?.count)
        for (id, def) in defs {
            XCTAssertEqual(def.schema, PaywallDefinition.schemaId)
            XCTAssertFalse(def.blocks.contains { if case .unknown = $0 { return true }; return false }, id)
            assertJSONEqual(try JSONValue.from(def), try XCTUnwrap(raw[id]), "definition \(id)")
        }
        // Every block type is covered by the every-block definition.
        let types = Set(try XCTUnwrap(defs["every-block"]).blocks.map(\.type))
        XCTAssertEqual(types, ["close", "hero", "headline", "benefits", "plans", "trial_timeline", "testimonials", "faq", "comparison", "cta", "legal"])
    }

    func testCountriesMatchFixture() throws {
        let fixture = try Fixtures.decode([String: String].self, "countries.json")
        XCTAssertEqual(Countries.alpha3, fixture)
        XCTAssertEqual(DeviceInfo.alpha3("us"), "USA")
        XCTAssertEqual(DeviceInfo.alpha2("DEU"), "DE")
    }
}

final class RenderConformanceTests: XCTestCase {
    struct Case: Decodable { let definition: String; let prices: String; let selectedProductId: String?; let expected: JSONValue }

    func testRenderModels() throws {
        let defs = try Fixtures.decode([String: PaywallDefinition].self, "definitions.json")
        let prices = try Fixtures.decode([String: [String: StorePrice]].self, "prices.json")
        let cases = try Fixtures.decode([Case].self, "render.json")
        XCTAssertGreaterThan(cases.count, 90)
        for c in cases {
            let def = try XCTUnwrap(defs[c.definition]), p = try XCTUnwrap(prices[c.prices])
            let m = Render.model(def, prices: p, selectedProductId: c.selectedProductId)
            assertJSONEqual(m.json, c.expected, "\(c.definition) / \(c.prices) / \(c.selectedProductId ?? "default")")
        }
    }

    struct PageCase: Decodable {
        let definition: PaywallDefinition; let prices: [String: StorePrice]; let selectedProductId: String?; let locale: String?
        /// `app_store` or `google_play` for a case drawn for one store only (store-specific legal text).
        let store: String?
        let expected: JSONValue
    }

    func testRenderPagesAndLanguages() throws {
        let cases = try Fixtures.decode([PageCase].self, "render-pages.json")
        XCTAssertGreaterThanOrEqual(cases.count, 7)
        // iOS and macOS draw the App Store view: Google Play cases are Android's.
        XCTAssertGreaterThanOrEqual(cases.filter { $0.store == "app_store" }.count, 2)
        let raw = try XCTUnwrap(Fixtures.json("render-pages.json").arrayValue)
        for (i, c) in cases.enumerated() where c.store == nil || c.store == "app_store" {
            let m = Render.model(c.definition, prices: c.prices, selectedProductId: c.selectedProductId, locale: c.locale)
            assertJSONEqual(m.json, c.expected, "\(c.definition.name) / \(c.store ?? "any store") / \(c.locale ?? "source")")
            // Definitions round-trip, the Google Play legal text included.
            assertJSONEqual(try JSONValue.from(c.definition), try XCTUnwrap(raw[i]["definition"]), "definition \(c.definition.name)")
        }
    }

    struct LayoutCase: Decodable {
        let definition: PaywallDefinition; let prices: [String: StorePrice]; let selectedProductId: String?; let locale: String?
        let expected: JSONValue
    }

    /// 0.3.0 layout (CONTRACT §8): close styles and the top bar, pinned blocks, `spaceBefore`, `align`, and a hero
    /// without an image left out.
    func testRenderLayout() throws {
        let cases = try Fixtures.decode([LayoutCase].self, "render-layout.json")
        XCTAssertGreaterThanOrEqual(cases.count, 4)
        let raw = try XCTUnwrap(Fixtures.json("render-layout.json").arrayValue)
        var styles: Set<String> = []
        for (i, c) in cases.enumerated() {
            let m = Render.model(c.definition, prices: c.prices, selectedProductId: c.selectedProductId, locale: c.locale)
            assertJSONEqual(m.json, c.expected, "\(c.definition.name) / \(c.locale ?? "source")")
            // Definitions round-trip, layout fields included (a bar slot written as null stays null, one left out stays out).
            assertJSONEqual(try JSONValue.from(c.definition), try XCTUnwrap(raw[i]["definition"]), "definition \(c.definition.name)")
            for b in m.pages?.flatMap(\.blocks) ?? m.blocks { if case let .close(_, _, style, _, _) = b { styles.insert(style.rawValue) } }
        }
        XCTAssertEqual(styles, ["overlay", "bar", "row"])
    }

    func testPreviewCodes() {
        XCTAssertEqual(Preview.normalize("abcd-efgh-jkmn"), "ABCDEFGHJKMN")
        XCTAssertEqual(Preview.normalize(" 0o1i l234 5678 "), "001112345678")
        XCTAssertNil(Preview.normalize("too-short"))
        XCTAssertNil(Preview.normalize("UUUU-UUUU-UUUU"))
    }

    struct PriceCase: Decodable {
        let displayPrice: String; let priceMicros: Int64; let currency: String; let num: Int64; let den: Int64
        let minor: Int64; let expected: String?
    }

    func testPriceFormat() throws {
        let cases = try Fixtures.decode([PriceCase].self, "price-format.json")
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            let minor = Render.perMonthMinor(priceMicros: c.priceMicros, num: c.num, den: c.den, digits: Render.currencyDigits(c.currency))
            XCTAssertEqual(minor, c.minor, c.displayPrice)
            XCTAssertEqual(Render.formatLike(c.displayPrice, minor: minor, currency: c.currency), c.expected, c.displayPrice)
        }
    }
}

final class SessionConformanceTests: XCTestCase {
    struct Step: Decodable {
        let op: String
        let ms: Int64?
        let placement: String?
        let prices: [String: StorePrice]?
        let pricesError: String?
        let productId: String?
        let outcome: String?
        let reason: String?
    }
    struct Expected: Decodable { let events: [JSONValue]; let results: [JSONValue] }
    struct Scenario: Decodable {
        let name: String; let device: EventContext; let appUserId: String; let attributes: UserAttributes
        let custom: [String: AttributeValue]; let now: Int64; let config: String?; let steps: [Step]; let expected: Expected
    }

    final class Clock { var now: Int64 = 0; var ids = 0 }

    static func fixtureUuid(_ n: Int) -> String {
        let s = String(n)
        return "00000000-0000-4000-8000-" + String(repeating: "0", count: max(0, 12 - s.count)) + s
    }

    func testSessions() throws {
        let scenarios = try Fixtures.decode([Scenario].self, "sessions.json")
        let config = try Fixtures.resolutionConfig
        XCTAssertGreaterThan(scenarios.count, 10)
        for s in scenarios {
            XCTAssertTrue(s.config == nil || s.config == "resolution", s.name)
            let clock = Clock()
            clock.now = s.now
            var events: [JSONValue] = []
            var results: [JSONValue] = []
            let session = PaywallSession(context: s.device, appUserId: s.appUserId, config: s.config == nil ? nil : config,
                                         clock: { clock.now }, makeEventId: { clock.ids += 1; return Self.fixtureUuid(clock.ids) })
            session.onEvent = { events.append($0.json) }
            for step in s.steps {
                var resolution: JSONValue = .null
                switch step.op {
                case "advance": clock.now += step.ms ?? 0
                case "new_session": session.newSession()
                case "register":
                    let placement = try XCTUnwrap(step.placement)
                    guard let fired = session.fire(placement: placement, attributes: s.attributes, custom: s.custom) else { break }
                    switch fired {
                    case .noConfig: resolution = .object(["kind": "no_config"])
                    case .resolved(let r):
                        resolution = r.json
                        if case .paywall = r {
                            session.present(placement: placement, resolution: r, prices: step.prices ?? [:], pricesError: step.pricesError)
                        }
                    }
                case "select": session.select(productId: try XCTUnwrap(step.productId))
                case "purchase":
                    if let p = session.beginPurchase() {
                        let outcome: PurchaseOutcome
                        switch step.outcome {
                        case "purchased": outcome = .purchased
                        case "trial": outcome = .trial
                        case "cancelled": outcome = .cancelled
                        case "pending": outcome = .pending
                        default: outcome = .failed(step.reason ?? "store_error")
                        }
                        session.finishPurchase(p, outcome: outcome)
                    }
                case "restore":
                    session.restoreStarted()
                    session.restoreFinished(step.outcome == "restored" ? .restored : step.outcome == "nothing" ? .nothing : .failed)
                case "close": session.close()
                default: XCTFail("Unknown step \(step.op) in \(s.name)")
                }
                var showing: JSONValue = .null
                if let p = session.presented, let m = session.renderModel {
                    showing = .object(["paywallId": .string(p.paywallId), "variant": .string(p.variant),
                                       "selectedProductId": m.selectedProductId.map(JSONValue.string) ?? .null, "purchasable": .bool(m.purchasable)])
                }
                results.append(.object(["resolution": resolution, "showing": showing]))
            }
            assertJSONEqual(.array(events), .array(s.expected.events), "\(s.name) events")
            assertJSONEqual(.array(results), .array(s.expected.results), "\(s.name) results")
        }
    }
}

final class PurchaseConfirmationConformanceTests: XCTestCase {
    struct Response: Decodable { let status: Int?; let network: Bool?; let action: String? }
    struct Step: Decodable { let op: String; let id: String?; let user: String?; let responses: [Response]? }
    struct Outcome: Decodable, Equatable { let sent: [Int]; let dropped: Int; let queued: Int; let failures: Int; let retryAfterMs: Int64? }
    struct Scenario: Decodable { let name: String; let steps: [Step]; let expected: [Outcome] }
    struct Body: Decodable, Equatable { let key: String; let appUserId: String; let store: String; let signedTransaction: String? }
    struct Bodies: Decodable { let app_store: Body }
    struct Fixture: Decodable { let path: String; let bodies: Bodies; let responses: [Response]; let scenarios: [Scenario] }

    final class ScriptedTransport: PurchaseConfirmationTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var responses: [FlushResponse] = []
        func load(_ r: [FlushResponse]) { lock.lock(); responses = r; lock.unlock() }
        private func next() -> FlushResponse { lock.lock(); defer { lock.unlock() }; return responses.isEmpty ? .network : responses.removeFirst() }
        func send(appUserId: String, signedTransaction: String) async -> FlushResponse { next() }
    }

    private func response(_ r: Response) -> FlushResponse { r.network == true ? .network : .status(r.status ?? 0) }

    func testClassification() throws {
        let f = try Fixtures.decode(Fixture.self, "purchase-confirmation.json")
        XCTAssertFalse(f.responses.isEmpty)
        for r in f.responses {
            let expected: FlushResponse.Action = r.action == "remove" ? .remove : r.action == "drop" ? .drop : .retry
            XCTAssertEqual(response(r).confirmationAction, expected, "\(r)")
        }
    }

    /// Answers 200 and keeps the request it saw.
    final class Capture: URLProtocol {
        nonisolated(unsafe) static var path: String?
        nonisolated(unsafe) static var body = Data()
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.path = request.url?.path
            var d = request.httpBody ?? Data()
            if d.isEmpty, let s = request.httpBodyStream {
                s.open(); defer { s.close() }
                var buf = [UInt8](repeating: 0, count: 4096)
                while s.hasBytesAvailable { let n = s.read(&buf, maxLength: buf.count); if n <= 0 { break }; d.append(buf, count: n) }
            }
            Self.body = d
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{}".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    func testBody() async throws {
        let f = try Fixtures.decode(Fixture.self, "purchase-confirmation.json")
        let want = f.bodies.app_store
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [Capture.self]
        let t = HTTPPurchaseConfirmationTransport(baseURL: URL(string: "http://127.0.0.1:9")!, publicKey: want.key, session: URLSession(configuration: c))
        let r = await t.send(appUserId: want.appUserId, signedTransaction: try XCTUnwrap(want.signedTransaction))
        XCTAssertEqual(r, FlushResponse.status(200))
        XCTAssertEqual(Capture.path, f.path)
        XCTAssertEqual(try JSONDecoder().decode(Body.self, from: Capture.body), want)
        // The route is strict: only these keys are accepted.
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: Capture.body) as? [String: Any]).keys
        XCTAssertEqual(Set(keys), ["key", "appUserId", "store", "signedTransaction"])
    }

    func testScenarios() async throws {
        let f = try Fixtures.decode(Fixture.self, "purchase-confirmation.json")
        XCTAssertFalse(f.scenarios.isEmpty)
        for s in f.scenarios {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("sansora-confirm-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: file) }
            let transport = ScriptedTransport()
            func open() -> PurchaseConfirmationQueue { PurchaseConfirmationQueue(fileURL: file, transport: transport, jitter: { 0 }, autoFlush: false) }
            var queue = open()
            var outcomes: [Outcome] = []
            for step in s.steps {
                switch step.op {
                case "setUser": await queue.setAppUserId(step.user)
                case "enqueue": await queue.enqueue(id: step.id ?? "", signedTransaction: "jws-\(step.id ?? "")")
                case "restart":
                    let user = step.user
                    queue = open()
                    await queue.setAppUserId(user)
                case "flush":
                    let responses = (step.responses ?? []).map(response)
                    transport.load(responses)
                    let o = await queue.flush(maxSends: responses.count)
                    outcomes.append(Outcome(sent: o.sent, dropped: o.dropped, queued: o.queued, failures: o.failures, retryAfterMs: o.retryAfterMs))
                default: XCTFail("Unknown step \(step.op)")
                }
            }
            XCTAssertEqual(outcomes, s.expected, s.name)
        }
    }
}

final class DeliveryConformanceTests: XCTestCase {
    struct Response: Decodable { let status: Int?; let network: Bool? }
    struct Step: Decodable { let op: String; let count: Int?; let responses: [Response]? }
    struct Outcome: Decodable, Equatable { let sent: [Int]; let dropped: Int; let queued: Int; let failures: Int; let retryAfterMs: Int64? }
    struct Expected: Decodable { let outcomes: [Outcome]; let overflow: Int; let firstQueuedEvent: Int? }
    struct Scenario: Decodable { let name: String; let steps: [Step]; let expected: Expected }

    final class ScriptedTransport: EventTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var responses: [FlushResponse] = []
        private(set) var batches: [[JSONValue]] = []
        func load(_ r: [FlushResponse]) { lock.lock(); responses = r; lock.unlock() }
        private func next(_ events: [JSONValue]) -> FlushResponse {
            lock.lock(); defer { lock.unlock() }
            batches.append(events)
            return responses.isEmpty ? .network : responses.removeFirst()
        }
        func send(_ events: [JSONValue]) async -> FlushResponse { next(events) }
    }

    func testDelivery() async throws {
        let scenarios = try Fixtures.decode([Scenario].self, "delivery.json")
        XCTAssertFalse(scenarios.isEmpty)
        for s in scenarios {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("sansora-delivery-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: file) }
            let transport = ScriptedTransport()
            var queue = EventQueue(fileURL: file, transport: transport, jitter: { 0 }, autoFlush: false)
            var next = 1, outcomes: [Outcome] = []
            for step in s.steps {
                switch step.op {
                case "enqueue":
                    let n = step.count ?? 0
                    await queue.enqueue((0..<n).map { i in .object(["n": .number(Double(next + i))]) })
                    next += n
                case "restart":
                    // The queue and failure count are persisted: a new instance reads them back.
                    queue = EventQueue(fileURL: file, transport: transport, jitter: { 0 }, autoFlush: false)
                case "flush":
                    let responses = (step.responses ?? []).map { r -> FlushResponse in r.network == true ? .network : .status(r.status ?? 0) }
                    transport.load(responses)
                    let o = await queue.flush(maxBatches: responses.count)
                    outcomes.append(Outcome(sent: o.sent, dropped: o.dropped, queued: o.queued, failures: o.failures, retryAfterMs: o.retryAfterMs))
                default: XCTFail("Unknown step \(step.op)")
                }
            }
            XCTAssertEqual(outcomes, s.expected.outcomes, s.name)
            let overflow = await queue.overflow
            XCTAssertEqual(overflow, s.expected.overflow, s.name)
            let first = await queue.pending.first?["n"]?.doubleValue.map { Int($0) }
            XCTAssertEqual(first, s.expected.firstQueuedEvent, s.name)
            // Each batch is a consecutive run of events in queue order.
            for batch in transport.batches {
                let numbers = batch.compactMap { $0["n"]?.doubleValue }
                XCTAssertEqual(numbers, numbers.first.map { f in (0..<numbers.count).map { f + Double($0) } } ?? [], s.name)
            }
        }
    }
}
