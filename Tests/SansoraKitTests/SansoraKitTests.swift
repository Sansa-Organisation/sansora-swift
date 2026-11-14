import XCTest
@testable import SansoraKit

private func tempURL(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("sansora-\(name)-\(UUID().uuidString)")
}

final class JSTests: XCTestCase {
    func testJavaScriptStringOfNumbers() {
        XCTAssertEqual(JS.string(7), "7")
        XCTAssertEqual(JS.string(2.5), "2.5")
        XCTAssertEqual(JS.string(-0.0), "0")
        XCTAssertEqual(JS.string(1e21), "1e+21")
        XCTAssertEqual(JS.string(.nan), "NaN")
    }

    func testJavaScriptNumberOfStrings() {
        XCTAssertEqual(JS.number(""), 0)
        XCTAssertEqual(JS.number("  10 "), 10)
        XCTAssertEqual(JS.number("0x10"), 16)
        XCTAssertEqual(JS.number("1e3"), 1000)
        XCTAssertTrue(JS.number("many").isNaN)
        XCTAssertTrue(JS.number("inf").isNaN)
        XCTAssertTrue(JS.number("nan").isNaN)
        XCTAssertEqual(JS.number("Infinity"), .infinity)
    }

    func testVersionCompare() {
        XCTAssertEqual(AudienceEvaluator.versionCompare("17.4.1", "17.4"), 1)
        XCTAssertEqual(AudienceEvaluator.versionCompare("17.4", "17.4.0"), 0)
        XCTAssertEqual(AudienceEvaluator.versionCompare("2.4", "2.10"), -1)
        XCTAssertEqual(AudienceEvaluator.versionCompare("2.4.x", "2.4.0"), 0) // NaN parts compare equal
    }

    func testCustomAttributeNames() {
        XCTAssertTrue(AudienceEvaluator.isCustomName("custom.level"))
        XCTAssertFalse(AudienceEvaluator.isCustomName("custom.Level"))
        XCTAssertFalse(AudienceEvaluator.isCustomName("custom."))
        XCTAssertEqual(AudienceEvaluator.attrType("unknown"), "text")
    }

    func testBoolCustomAttribute() {
        let rule = AudienceRule(attribute: "custom.beta", op: "is", value: .string("TRUE"))
        XCTAssertTrue(AudienceEvaluator.ruleMatches(rule, ["custom.beta": .bool(true)]))
        let numeric = AudienceRule(attribute: "custom.beta", op: "eq", value: .number(1))
        XCTAssertTrue(AudienceEvaluator.ruleMatches(numeric, ["custom.beta": .bool(true)]))
    }

    func testJSONValueKeepsBooleansApartFromNumbers() throws {
        let v = try JSONValue.parse(Data(#"{"a":true,"b":1,"c":1.5,"d":null,"e":["x"]}"#.utf8))
        XCTAssertEqual(v["a"], .bool(true))
        XCTAssertEqual(v["b"], .number(1))
        XCTAssertEqual(v["c"], .number(1.5))
        XCTAssertEqual(v["d"], .null)
        XCTAssertEqual(String(decoding: try JSONValue.number(1793000000000).data(), as: UTF8.self), "1793000000000")
        XCTAssertEqual(JSONValue(any: try JSONSerialization.jsonObject(with: v.data())), v)
    }
}

final class EventTests: XCTestCase {
    let ctx = EventContext(platform: "ios", sdkVersion: "0.3.0", osVersion: "18.2", device: "iPhone16,1", storefront: nil, store: "app_store")

    func testAbsentOptionalsAreOmitted() throws {
        let e = SdkEvent(eventId: "00000000-0000-4000-8000-000000000001", appUserId: "u", event: "restore_started", occurredAt: 1, context: ctx)
        let keys = Set(try XCTUnwrap(e.json.objectValue).keys)
        XCTAssertEqual(keys, ["schema", "eventId", "appUserId", "event", "occurredAt", "platform", "sdkVersion", "osVersion", "device", "store"])
    }

    func testLongDeviceFieldsAreCut() {
        var c = ctx
        c.osVersion = String(repeating: "1", count: 30)
        c.device = String(repeating: "x", count: 60)
        let e = SdkEvent(eventId: "id", appUserId: "u", event: "paywall_shown", occurredAt: 1, context: c)
        XCTAssertEqual(e.json["osVersion"]?.stringValue?.count, 20)
        XCTAssertEqual(e.json["device"]?.stringValue?.count, 40)
    }

    func testRegisterWhileShowingIsIgnoredAndNoConfigFails() throws {
        var events: [SdkEvent] = []
        let s = PaywallSession(context: ctx, appUserId: "u", config: nil, clock: { 5 }, makeEventId: { UUID().uuidString.lowercased() })
        s.onEvent = { events.append($0) }
        XCTAssertEqual(s.fire(placement: "x", attributes: [:], custom: [:]), .noConfig)
        XCTAssertEqual(events.map(\.event), ["placement_fired", "paywall_load_failed"])
        XCTAssertEqual(events.last?.reason, "no_config")
    }
}

final class RenderTests: XCTestCase {
    func testUnknownBlocksAreSkipped() throws {
        let json = #"""
        {"schema":"sansora.paywall/1","name":"n","locale":"en","theme":"dark",
         "palette":{"background":"#000000","surface":"#111111","text":"#FFFFFF","muted":"#888888","accent":"#3451D1","hero":"#222222"},
         "products":[{"id":"m","storeProductId":"com.example.m","label":"Monthly","period":"month","trialDays":0,"previewPrice":null,"currency":"USD"}],
         "blocks":[{"type":"carousel","pages":3},{"type":"cta","label":"Start free trial"}]}
        """#
        let def = try JSONDecoder().decode(PaywallDefinition.self, from: Data(json.utf8))
        let m = Render.model(def, prices: [:])
        // A purchase button that ends the page is pinned (0.3.0).
        XCTAssertEqual(m.blocks, [.cta(label: "Continue", enabled: false, placement: .init(pinned: true))])
        XCTAssertNil(m.selectedProductId)
        XCTAssertFalse(m.purchasable)
    }

    func testMissingProductsAreAPriceFailure() throws {
        let json = #"""
        {"schema":"sansora.paywall/1","name":"n","locale":"en","theme":"light",
         "palette":{"background":"#FFFFFF","surface":"#FFFFFF","text":"#000000","muted":"#888888","accent":"#3451D1","hero":"#222222"},
         "products":[{"id":"y","storeProductId":"com.example.y","label":"Yearly","period":"year","trialDays":0,"previewPrice":null,"currency":"USD"},
                     {"id":"m","storeProductId":"com.example.m","label":"Monthly","period":"month","trialDays":0,"previewPrice":null,"currency":"USD"},
                     {"id":"draft","storeProductId":"","label":"No ID yet","period":"week","trialDays":0,"previewPrice":null,"currency":"USD"}],
         "blocks":[{"type":"cta","label":"Continue"}]}
        """#
        let def = try JSONDecoder().decode(PaywallDefinition.self, from: Data(json.utf8))
        let price = StorePrice(priceMicros: 9_990_000, currency: "USD", displayPrice: "$9.99", trialDays: 0)
        // An empty store answer, or one missing any product with a store ID: products_not_found.
        XCTAssertEqual(Render.missingPricesReason(def, prices: [:]), "products_not_found")
        XCTAssertEqual(Render.missingPricesReason(def, prices: ["com.example.m": price]), "products_not_found")
        // Every product with a store ID answered (the one without an ID doesn't count).
        XCTAssertNil(Render.missingPricesReason(def, prices: ["com.example.m": price, "com.example.y": price]))
    }

    func testHalfUpRounding() {
        // 0.125 USD per month rounds half up to 13 cents.
        XCTAssertEqual(Render.perMonthMinor(priceMicros: 1_500_000, num: 1, den: 12, digits: 2), 13)
        XCTAssertEqual(Render.formatLike("1.234,56 €", minor: 123456, currency: "EUR"), "1.234,56 €")
        XCTAssertNil(Render.formatLike("Gratis", minor: 0, currency: "EUR"))
    }

    func testDisplayHistoryKeepsLatestFifty() {
        var h = DisplayHistory()
        for i in 0..<60 { h.record(campaignId: "c", at: Int64(i)) }
        XCTAssertEqual(h.shown["c"]?.count, 50)
        XCTAssertEqual(h.shown["c"]?.first, 10)
        XCTAssertEqual(h.session, ["c"])
    }
}

final class EventQueueTests: XCTestCase {
    final class Recorder: EventTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var _batches: [[JSONValue]] = []
        let answer: FlushResponse
        init(_ answer: FlushResponse) { self.answer = answer }
        private func record(_ e: [JSONValue]) { lock.lock(); _batches.append(e); lock.unlock() }
        var batches: [[JSONValue]] { lock.lock(); defer { lock.unlock() }; return _batches }
        func send(_ events: [JSONValue]) async -> FlushResponse { record(events); return answer }
    }

    func testBridgeJSONEnqueueAndPersistence() async throws {
        let file = tempURL("queue.json")
        defer { try? FileManager.default.removeItem(at: file) }
        let q = EventQueue(fileURL: file, transport: nil, autoFlush: false)
        try await q.enqueue(jsonEvents: Data(#"[{"event":"placement_fired","n":1},{"event":"paywall_shown","n":2},3]"#.utf8))
        try await q.enqueue(jsonEvents: Data(#"{"event":"paywall_closed","n":3}"#.utf8))
        let count = await q.count
        XCTAssertEqual(count, 3)
        let reopened = EventQueue(fileURL: file, transport: Recorder(.status(200)), autoFlush: false)
        let pending = await reopened.pending
        XCTAssertEqual(pending.map { $0["n"] }, [.number(1), .number(2), .number(3)])
        let outcome = await reopened.flush()
        XCTAssertEqual(outcome.sent, [3])
        XCTAssertEqual(outcome.queued, 0)
    }

    func testBackoffWithJitter() async {
        let q = EventQueue(fileURL: nil, transport: Recorder(.network), jitter: { 0.2 }, autoFlush: false)
        await q.enqueue([.object(["n": .number(1)])])
        let first = await q.flush()
        XCTAssertEqual(first.retryAfterMs, 2400)
        let second = await q.flush()
        XCTAssertEqual(second.retryAfterMs, 4800)
        XCTAssertEqual(EventQueue.retryDelay(failures: 9), 300_000)
        XCTAssertEqual(EventQueue.retryDelay(failures: 60), 300_000)
        XCTAssertEqual(EventQueue.retryDelay(failures: 0), 0)
    }

    func testWithoutTransportNothingIsSent() async {
        let q = EventQueue(fileURL: nil, transport: nil, autoFlush: false)
        await q.enqueue([.object([:])])
        let o = await q.flush()
        XCTAssertEqual(o.sent, [])
        XCTAssertEqual(o.queued, 1)
    }

    func testHTTPTransportBody() async throws {
        StubProtocol.handler = { req in
            XCTAssertEqual(req.httpMethod, "POST")
            XCTAssertEqual(req.url?.path, "/v1/sdk/events")
            XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
            let body = try JSONValue.parse(StubProtocol.body(req))
            XCTAssertEqual(body["key"], .string("pk_test_abcdefghijklmnopqrstuvwx"))
            XCTAssertEqual(body["events"]?.arrayValue?.count, 2)
            return (202, [:], Data(#"{"accepted":2,"duplicates":0,"rejected":[]}"#.utf8))
        }
        let t = HTTPEventTransport(baseURL: URL(string: "http://127.0.0.1:9")!, publicKey: "pk_test_abcdefghijklmnopqrstuvwx", session: StubProtocol.session())
        let r = await t.send([.object(["a": .number(1)]), .object(["b": .number(2)])])
        XCTAssertEqual(r, .status(202))
        XCTAssertEqual(r.action, .remove)
        XCTAssertEqual(FlushResponse.status(413).action, .drop)
        XCTAssertEqual(FlushResponse.status(401).action, .retry)
    }
}

final class PurchaseConfirmationQueueTests: XCTestCase {
    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("sansora-confirm-\(UUID().uuidString).json")
    }

    /// Records every send and answers from a script (network failure once it runs out).
    final class Recorder: PurchaseConfirmationTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [FlushResponse]
        private var _sent: [(user: String, jws: String)] = []
        init(_ answers: [FlushResponse]) { self.answers = answers }
        private func record(_ user: String, _ jws: String) -> FlushResponse {
            lock.lock(); defer { lock.unlock() }
            _sent.append((user, jws))
            return answers.isEmpty ? .network : answers.removeFirst()
        }
        var sent: [(user: String, jws: String)] { lock.lock(); defer { lock.unlock() }; return _sent }
        func send(appUserId: String, signedTransaction: String) async -> FlushResponse { record(appUserId, signedTransaction) }
    }

    /// A send that never answers until released.
    actor Gate { var open = false; func release() { open = true }; func wait() async { while !open { try? await Task.sleep(nanoseconds: 1_000_000) } } }
    struct BlockedTransport: PurchaseConfirmationTransport {
        let gate: Gate
        func send(appUserId: String, signedTransaction: String) async -> FlushResponse { await gate.wait(); return .status(200) }
    }

    func testKeepsThePurchaseAcrossRestartsUntilConfirmed() async throws {
        let file = tempFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let failing = Recorder([.status(503)])
        let q = PurchaseConfirmationQueue(fileURL: file, transport: failing, appUserId: "user-1", jitter: { 0 }, autoFlush: false)
        await q.enqueue(id: "1000", signedTransaction: "jws-a")
        let first = await q.flush()
        XCTAssertEqual(first.queued, 1)
        XCTAssertEqual(first.retryAfterMs, 2000)

        let ok = Recorder([.status(200)])
        let reopened = PurchaseConfirmationQueue(fileURL: file, transport: ok, jitter: { 0 }, autoFlush: false)
        let failures = await reopened.failures
        XCTAssertEqual(failures, 1)
        let second = await reopened.flush()
        XCTAssertEqual(second.queued, 0)
        XCTAssertEqual(second.failures, 0)
        XCTAssertEqual(ok.sent.map(\.user), ["user-1"])
        XCTAssertEqual(ok.sent.map(\.jws), ["jws-a"])
    }

    func testPermanentRefusalIsDroppedAndTheNextIsSent() async {
        let t = Recorder([.status(409), .status(200)])
        let q = PurchaseConfirmationQueue(fileURL: nil, transport: t, appUserId: "user-1", jitter: { 0 }, autoFlush: false)
        await q.enqueue(id: "1", signedTransaction: "a")
        await q.enqueue(id: "2", signedTransaction: "b")
        let o = await q.flush()
        XCTAssertEqual(o.sent, [1, 1])
        XCTAssertEqual(o.dropped, 1)
        XCTAssertEqual(o.queued, 0)
        XCTAssertEqual(o.failures, 0)
    }

    func testBackoffUsesTheEventQueueDelays() async {
        let t = Recorder([.status(429), .network])
        let q = PurchaseConfirmationQueue(fileURL: nil, transport: t, appUserId: "user-1", jitter: { 0.2 }, autoFlush: false)
        await q.enqueue(id: "1", signedTransaction: "a")
        let first = await q.flush()
        XCTAssertEqual(first.retryAfterMs, 2400)
        let second = await q.flush()
        XCTAssertEqual(second.retryAfterMs, 4800)
    }

    func testRenewalReplacesAWaitingConfirmationOfTheSameSubscription() async {
        let t = Recorder([.status(200)])
        let q = PurchaseConfirmationQueue(fileURL: nil, transport: t, appUserId: "user-1", jitter: { 0 }, autoFlush: false)
        await q.enqueue(id: "1000", signedTransaction: "old")
        await q.enqueue(id: "1000", signedTransaction: "new")
        let waiting = await q.count
        XCTAssertEqual(waiting, 1)
        _ = await q.flush()
        XCTAssertEqual(t.sent.map(\.jws), ["new"])
    }

    func testThePurchaseKeepsTheUserWhoMadeIt() async {
        let t = Recorder([.status(200), .status(200)])
        let q = PurchaseConfirmationQueue(fileURL: nil, transport: t, appUserId: "user-1", jitter: { 0 }, autoFlush: false)
        await q.enqueue(id: "1", signedTransaction: "a")
        await q.setAppUserId("user-2")
        await q.enqueue(id: "2", signedTransaction: "b")
        _ = await q.flush()
        XCTAssertEqual(t.sent.map(\.user), ["user-1", "user-2"])
    }

    func testAPurchaseBeforeTheUserIsKnownWaitsForIt() async {
        let t = Recorder([.status(200)])
        let q = PurchaseConfirmationQueue(fileURL: nil, transport: t, jitter: { 0 }, autoFlush: false)
        await q.enqueue(id: "1", signedTransaction: "a")
        let early = await q.flush()
        XCTAssertEqual(early.sent, [])
        XCTAssertEqual(early.queued, 1)
        XCTAssertTrue(t.sent.isEmpty)
        await q.setAppUserId("anon-1")
        let users = await q.pendingUsers
        XCTAssertEqual(users, ["anon-1"])
        let late = await q.flush()
        XCTAssertEqual(late.queued, 0)
        XCTAssertEqual(t.sent.map(\.user), ["anon-1"])
    }

    func testEnqueueNeverWaitsForASlowSend() async {
        let gate = Gate()
        let q = PurchaseConfirmationQueue(fileURL: nil, transport: BlockedTransport(gate: gate), appUserId: "user-1", jitter: { 0 }, autoFlush: false)
        await q.enqueue(id: "1", signedTransaction: "a")
        let flushing = Task { await q.flush() }
        try? await Task.sleep(nanoseconds: 20_000_000)
        // The first send is still in flight; a new purchase must queue without waiting for it.
        await q.enqueue(id: "2", signedTransaction: "b")
        let waiting = await q.count
        XCTAssertEqual(waiting, 2)
        await gate.release()
        let o = await flushing.value
        XCTAssertEqual(o.queued, 0)
    }

    func testAReplacedEntrySurvivesTheSendOfItsOldCopy() async {
        let gate = Gate()
        struct OneGated: PurchaseConfirmationTransport {
            let gate: Gate
            func send(appUserId: String, signedTransaction: String) async -> FlushResponse { await gate.wait(); return .status(200) }
        }
        let q = PurchaseConfirmationQueue(fileURL: nil, transport: OneGated(gate: gate), appUserId: "user-1", jitter: { 0 }, autoFlush: false)
        await q.enqueue(id: "1", signedTransaction: "old")
        let flushing = Task { await q.flush(maxSends: 1) }
        try? await Task.sleep(nanoseconds: 20_000_000)
        await q.enqueue(id: "1", signedTransaction: "new")
        await gate.release()
        _ = await flushing.value
        let waiting = await q.count
        XCTAssertEqual(waiting, 1)
    }

    func testQueueKeepsTheNewestAtTheLimit() async {
        let q = PurchaseConfirmationQueue(fileURL: nil, transport: nil, appUserId: "user-1", autoFlush: false)
        for i in 0..<(PurchaseConfirmationQueue.queueLimit + 5) { await q.enqueue(id: "\(i)", signedTransaction: "jws") }
        let waiting = await q.count
        XCTAssertEqual(waiting, PurchaseConfirmationQueue.queueLimit)
    }
}

final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, [String: String], Data))?
    static func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: c)
    }
    static func body(_ r: URLRequest) -> Data {
        if let b = r.httpBody { return b }
        guard let s = r.httpBodyStream else { return Data() }
        s.open(); defer { s.close() }
        var d = Data(), buf = [UInt8](repeating: 0, count: 4096)
        while s.hasBytesAvailable { let n = s.read(&buf, maxLength: buf.count); if n <= 0 { break }; d.append(buf, count: n) }
        return d
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, headers, data) = try XCTUnwrap(Self.handler)(request)
            let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

final class ConfigStoreTests: XCTestCase {
    static let key = "pk_test_abcdefghijklmnopqrstuvwx"
    static func config(generatedAt: Int64) -> Data {
        Data(#"{"schema":"sansora.config/1","appId":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","generatedAt":\#(generatedAt),"paywalls":[],"campaigns":[]}"#.utf8)
    }

    func testBundledFallbackThenDownloadThenCache() async throws {
        let dir = tempURL("config")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var seenEtag: String?
        StubProtocol.handler = { req in
            XCTAssertEqual(req.value(forHTTPHeaderField: "X-Sansora-Key"), Self.key)
            XCTAssertEqual(req.url?.path, "/v1/sdk/config")
            seenEtag = req.value(forHTTPHeaderField: "If-None-Match")
            if seenEtag == "\"v2\"" { return (304, [:], Data()) }
            return (200, ["ETag": "\"v2\""], Self.config(generatedAt: 2))
        }
        let base = URL(string: "http://127.0.0.1:9")!
        let store = ConfigStore(publicKey: Self.key, baseURL: base, directory: dir, bundledConfig: Self.config(generatedAt: 1), session: StubProtocol.session())
        XCTAssertEqual(store.source, .bundled)
        XCTAssertEqual(store.config?.generatedAt, 1)
        let changed = await store.refresh(force: true)
        XCTAssertTrue(changed)
        XCTAssertNil(seenEtag)
        XCTAssertEqual(store.config?.generatedAt, 2)
        XCTAssertFalse(store.isStale)

        // A new process reads the cache first and revalidates with the ETag.
        let again = ConfigStore(publicKey: Self.key, baseURL: base, directory: dir, bundledConfig: Self.config(generatedAt: 1), session: StubProtocol.session())
        XCTAssertEqual(again.source, .cache)
        XCTAssertEqual(again.config?.generatedAt, 2)
        let changed304 = await again.refresh(force: true)
        XCTAssertFalse(changed304)
        XCTAssertEqual(seenEtag, "\"v2\"")
        XCTAssertEqual(again.config?.generatedAt, 2)

        // Errors and wrong schemas keep the previous config.
        StubProtocol.handler = { _ in (500, [:], Data()) }
        _ = await again.refresh(force: true)
        XCTAssertEqual(again.config?.generatedAt, 2)
        StubProtocol.handler = { _ in (200, [:], Data(#"{"schema":"sansora.config/2"}"#.utf8)) }
        _ = await again.refresh(force: true)
        XCTAssertEqual(again.config?.generatedAt, 2)

        // Another key never reads this key's cache.
        let other = ConfigStore(publicKey: "pk_live_abcdefghijklmnopqrstuvwx", baseURL: base, directory: dir, bundledConfig: nil, session: StubProtocol.session())
        XCTAssertNil(other.config)
    }
}

final class LocalStateTests: XCTestCase {
    func testInstallSessionsDeclinesAndIdentity() throws {
        let file = tempURL("state.json")
        defer { try? FileManager.default.removeItem(at: file) }
        let day: Int64 = 86_400_000
        let s = LocalState(fileURL: file)
        let anon = s.appUserId
        XCTAssertTrue(anon.hasPrefix("anon-"))
        XCTAssertEqual(s.appUserId, anon)
        s.recordLaunch(now: 1000)
        s.recordLaunch(now: 2000)
        XCTAssertEqual(s.installedAt, 1000)
        XCTAssertEqual(s.sessions, 2)
        XCTAssertEqual(s.daysSinceInstall(now: 1000 + 3 * day + 5), 3)
        s.didEnterBackground(now: 10_000)
        XCTAssertFalse(s.willEnterForeground(now: 10_000 + LocalState.sessionGapMs - 1))
        s.didEnterBackground(now: 20_000)
        XCTAssertTrue(s.willEnterForeground(now: 20_000 + LocalState.sessionGapMs))
        XCTAssertEqual(s.sessions, 3)
        s.recordDecline(now: 5 * day)
        XCTAssertEqual(s.paywallDeclined, 1)
        XCTAssertEqual(s.daysSinceDecline(now: 7 * day), 2)
        XCTAssertNil(s.storefront)
        s.storefront = "de"
        s.identify("user-42")
        // Persisted.
        let reread = LocalState(fileURL: file)
        XCTAssertEqual(reread.appUserId, "user-42")
        XCTAssertTrue(reread.isIdentified)
        XCTAssertEqual(reread.sessions, 3)
        XCTAssertEqual(reread.storefront, "DE")
        reread.resetUser()
        XCTAssertTrue(reread.appUserId.hasPrefix("anon-"))
        XCTAssertNotEqual(reread.appUserId, anon)
    }
}

@MainActor
final class FacadeTests: XCTestCase {
    func testValidation() throws {
        let s = Sansora(state: LocalState(fileURL: nil))
        XCTAssertThrowsError(try s.configure(publicKey: "pk_prod_123")) { XCTAssertEqual($0 as? SansoraError, .invalidPublicKey) }
        XCTAssertThrowsError(try s.identify("has space")) { XCTAssertEqual($0 as? SansoraError, .invalidAppUserId) }
        XCTAssertThrowsError(try s.identify(String(repeating: "a", count: 129)))
        XCTAssertThrowsError(try s.setAttributes(["Bad": .bool(true)]))
        XCTAssertThrowsError(try s.setAttributes(["ratio": .number(.infinity)]))
        try s.setAttributes(any: ["level": 7, "beta": true, "plan": "gold"])
        let attrs = s.currentAttributes()
        XCTAssertEqual(attrs["custom.level"], .number(7))
        XCTAssertEqual(attrs["custom.beta"], .bool(true))
        XCTAssertEqual(attrs["custom.plan"], .string("gold"))
        XCTAssertEqual(attrs["paywall_declined"], .number(0))
        XCTAssertThrowsError(try s.setAttributes(Dictionary(uniqueKeysWithValues: (0..<20).map { ("k\($0)", AttributeValue.number(1)) })))
    }

    func testLastKnownStorefrontIsUsedUntilStoreKitAnswers() {
        let state = LocalState(fileURL: nil)
        state.storefront = "DE"
        let s = Sansora(state: state)
        XCTAssertEqual(s.currentAttributes()["storefront"], .string("DE"))
        XCTAssertEqual(s.eventContext().storefront, "DEU")
        let fresh = Sansora(state: LocalState(fileURL: nil))
        XCTAssertNil(fresh.currentAttributes()["storefront"])
        XCTAssertNil(fresh.eventContext().storefront)
    }

    func testGetPaywallEmitsNothingAndRecordsNoHistory() throws {
        let dir = tempURL("facade")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = #"""
        {"schema":"sansora.config/1","appId":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","generatedAt":1,
         "paywalls":[{"versionId":"cccccccc-cccc-4ccc-8ccc-ccccccccccc1","paywallId":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb1","version":1,"variant":"A",
           "definition":{"schema":"sansora.paywall/1","name":"n","locale":"en","theme":"light",
             "palette":{"background":"#FFFFFF","surface":"#FFFFFF","text":"#000000","muted":"#888888","accent":"#3451D1","hero":"#222222"},
             "products":[{"id":"m","storeProductId":"com.example.m","label":"Monthly","period":"month","trialDays":0,"previewPrice":null,"currency":"USD"}],
             "blocks":[{"type":"cta","label":"Continue"}]}}],
         "campaigns":[{"id":"11111111-1111-4111-8111-111111111111","placement":"onboarding_end","audience":{"match":"all","rules":[],"groups":[]},
           "frequency":"once_ever","priority":1,"holdoutBps":0,"paywallVersionId":"cccccccc-cccc-4ccc-8ccc-ccccccccccc1","experiment":null}]}
        """#
        let state = LocalState(fileURL: dir.appendingPathComponent("state.json"))
        let s = Sansora(state: state, storageDirectory: dir)
        var events: [SdkEvent] = []
        s.onEvent = { events.append($0) }
        try s.configure(publicKey: "pk_test_abcdefghijklmnopqrstuvwx",
                        options: .init(baseURL: URL(string: "http://127.0.0.1:9")!, bundledConfig: .data(Data(config.utf8)), logLevel: .none))
        for _ in 0..<3 {
            let info = s.getPaywall(placement: "onboarding_end")
            guard case .paywall(let campaignId, _, _, let variant, _, _)? = info.resolution else { return XCTFail("expected a paywall") }
            XCTAssertEqual(campaignId, "11111111-1111-4111-8111-111111111111")
            XCTAssertEqual(variant, "A")
            XCTAssertEqual(info.definition?.name, "n")
        }
        XCTAssertEqual(s.getPaywall(placement: "settings_open").resolution, .noCampaign(.noCampaignForPlacement))
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(state.history, DisplayHistory())
    }

    func testRegisterBeforeConfigure() async {
        let s = Sansora(state: LocalState(fileURL: nil))
        let r = await s.register(placement: "onboarding_end")
        XCTAssertEqual(r, .noConfig)
        XCTAssertNil(s.getPaywall(placement: "onboarding_end").resolution)
    }
}

/// 0.2.1: the Google Play legal text is read and kept, and never drawn on iOS.
final class StoreLegalTextTests: XCTestCase {
    func testGooglePlayLegalTextIsKeptButIOSShowsText() throws {
        let json = #"""
        {"schema":"sansora.paywall/1","name":"n","locale":"en","theme":"light",
         "palette":{"background":"#FFFFFF","surface":"#FFFFFF","text":"#000000","muted":"#888888","accent":"#3451D1","hero":"#222222"},
         "products":[{"id":"m","storeProductId":"com.example.m","label":"Monthly","period":"month","trialDays":0,"previewPrice":null,"currency":"USD"}],
         "blocks":[{"type":"legal","termsUrl":"","privacyUrl":"","restore":true,"text":"Cancel in Settings.","textGooglePlay":"Cancel in Google Play."}]}
        """#
        let def = try JSONDecoder().decode(PaywallDefinition.self, from: Data(json.utf8))
        XCTAssertEqual(def.blocks, [.legal(termsUrl: "", privacyUrl: "", restore: true, text: "Cancel in Settings.", textGooglePlay: "Cancel in Google Play.")])
        XCTAssertEqual(try JSONValue.from(def)["blocks"], try JSONValue.parse(Data(json.utf8))["blocks"])
        XCTAssertEqual(Render.model(def, prices: [:]).blocks, [.legal(text: "Cancel in Settings.", termsUrl: nil, privacyUrl: nil, restore: true, placement: .init(pinned: true))])
        // Without it nothing is written back.
        let plain = PaywallDefinition.Block.legal(termsUrl: "", privacyUrl: "", restore: false, text: "t")
        XCTAssertNil(try JSONValue.from(plain)["textGooglePlay"])
    }
}

/// 0.3.0 layout (CONTRACT §8). The shared fixtures (render-layout.json) cover the model; these cover what they don't.
final class LayoutTests: XCTestCase {
    private func definition(_ blocks: String, extra: String = "") throws -> PaywallDefinition {
        let json = """
        {"schema":"sansora.paywall/1","name":"n","locale":"en","theme":"light",\(extra)
         "palette":{"background":"#FFFFFF","surface":"#FFFFFF","text":"#000000","muted":"#888888","accent":"#3451D1","hero":"#222222"},
         "products":[{"id":"m","storeProductId":"com.example.m","label":"Monthly","period":"month","trialDays":0,"previewPrice":null,"currency":"USD"}],
         "blocks":[\(blocks)]}
        """
        return try JSONDecoder().decode(PaywallDefinition.self, from: Data(json.utf8))
    }

    /// A value from a newer editor reads as left out: the paywall still shows, with the defaults.
    func testUnknownLayoutValuesFallBackToTheDefaults() throws {
        let def = try definition(#"""
        {"type":"close","position":"left","delaySeconds":0,"style":"sheet","bar":{"center":{"kind":"avatar"}}},
        {"type":"headline","text":"Hi","subtext":"","pin":"middle","spaceBefore":12},
        {"type":"cta","label":"Continue"}
        """#, extra: #""align":"stretch","#)
        XCTAssertNil(def.align)
        XCTAssertEqual(def.blocks[0], .close(position: .left, delaySeconds: 0, style: nil, label: nil, bar: .init(center: .unknown(kind: "avatar"))))
        XCTAssertEqual(def.blocks[1].placement, .init(pin: nil, spaceBefore: 12))
        let m = Render.model(def, prices: [:])
        XCTAssertEqual(m.align, .top)
        XCTAssertEqual(m.blocks, [
            .close(position: .left, delaySeconds: 0, style: .overlay, label: nil, bar: nil),
            .headline(text: "Hi", subtext: nil, placement: .init(pinned: false, spaceBefore: 12)),
            .cta(label: "Continue", enabled: false, placement: .init(pinned: true)),
        ])
    }

    /// Closes don't count when finding the purchase button and legal footer that end a page; another block does.
    func testAutomaticPinning() throws {
        let def = try definition(#"""
        {"type":"cta","label":"Continue"},{"type":"headline","text":"Hi","subtext":""},
        {"type":"cta","label":"Continue"},{"type":"legal","termsUrl":"","privacyUrl":"","restore":false,"text":""},
        {"type":"close","position":"right","delaySeconds":0,"style":"row","label":"  "}
        """#)
        let pinned = Render.model(def, prices: [:]).blocks.map { $0.placement?.pinned }
        XCTAssertEqual(pinned, [false, false, true, true, nil])
        // A label of spaces is no label.
        XCTAssertEqual(Render.model(def, prices: [:]).blocks.last, .close(position: .right, delaySeconds: 0, style: .row, label: nil, bar: nil))
    }

    func testPlaceholdersAreFilledInOnePass() {
        XCTAssertEqual(Render.fill("Page {n} of {count}", ["n": "2", "count": "3"]), "Page 2 of 3")
        XCTAssertEqual(Render.fill("{n} {x} {} {n", ["n": "{x}"]), "{x} {x} {} {n")
    }

    /// How SansoraPaywallView splits a page into its regions.
    func testPageRegions() {
        let hero = RenderModel.Block.hero(height: 120, imageUrl: "https://example.com/hero.png")
        let headline = RenderModel.Block.headline(text: "Hi", subtext: nil, placement: .init(spaceBefore: 24))
        let benefits = RenderModel.Block.benefits(items: ["One"], placement: .init(pinned: true))
        let bar = RenderModel.Block.close(position: .right, delaySeconds: 2, style: .bar, label: "Skip", bar: .init(center: .text("Pro")))
        let page = PaywallPageLayout(blocks: [bar, hero, headline, benefits], nextLabel: "Continue", align: .center)
        XCTAssertEqual(page.close, PaywallClose(position: .right, delaySeconds: 2, style: .bar, label: "Skip", bar: .init(center: .text("Pro"))))
        XCTAssertTrue(page.hasTopBar)
        XCTAssertNil(page.floatingClose)
        XCTAssertEqual(page.content, [hero, headline])
        XCTAssertEqual(page.pinned, [benefits])
        XCTAssertTrue(page.hasPinnedArea)

        // A row stays where it is in the content; a second close on the page is not drawn.
        let row = RenderModel.Block.close(position: .left, delaySeconds: 0, style: .row)
        let rowPage = PaywallPageLayout(blocks: [headline, row, .close(position: .right, delaySeconds: 0)], nextLabel: nil, align: .top)
        XCTAssertEqual(rowPage.content, [headline, row])
        XCTAssertFalse(rowPage.hasTopBar)
        XCTAssertNil(rowPage.floatingClose)
        XCTAssertFalse(rowPage.hasPinnedArea)

        let overlay = PaywallPageLayout(blocks: [.close(position: .left, delaySeconds: 0), headline], nextLabel: nil, align: .bottom)
        XCTAssertEqual(overlay.floatingClose?.position, .left)
        XCTAssertEqual(overlay.content, [headline])
    }
}

/// 0.2.1: the paywall is drawn before the store answers (CONTRACT §8).
@MainActor
final class PriceLoadingTests: XCTestCase {
    static let config = #"""
    {"schema":"sansora.config/1","appId":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","generatedAt":1,
     "paywalls":[{"versionId":"cccccccc-cccc-4ccc-8ccc-ccccccccccc1","paywallId":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb1","version":1,"variant":"A",
       "definition":{"schema":"sansora.paywall/1","name":"n","locale":"en","theme":"light",
         "palette":{"background":"#FFFFFF","surface":"#FFFFFF","text":"#000000","muted":"#888888","accent":"#3451D1","hero":"#222222"},
         "products":[{"id":"m","storeProductId":"com.example.m","label":"Monthly","period":"month","trialDays":0,"previewPrice":null,"currency":"USD"}],
         "blocks":[{"type":"plans","productIds":["m"],"selected":"m","badge":null,"showPerMonth":false},{"type":"cta","label":"Continue"}]}}],
     "campaigns":[{"id":"11111111-1111-4111-8111-111111111111","placement":"onboarding_end","audience":{"match":"all","rules":[],"groups":[]},
       "frequency":"every_time","priority":1,"holdoutBps":0,"paywallVersionId":"cccccccc-cccc-4ccc-8ccc-ccccccccccc1","experiment":null}]}
    """#
    nonisolated static let monthly = StorePrice(priceMicros: 9_990_000, currency: "USD", displayPrice: "$9.99", trialDays: 0)

    private var dir: URL!

    override func setUp() async throws {
        dir = tempURL("prices")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func sdk(_ loader: @escaping @Sendable ([String]) async throws -> [String: StorePrice]) throws -> (Sansora, () -> [String]) {
        let s = Sansora(state: LocalState(fileURL: dir.appendingPathComponent("state.json")), storageDirectory: dir)
        final class Box { var events: [SdkEvent] = [] }
        let box = Box()
        s.onEvent = { box.events.append($0) }
        s.priceLoader = loader
        s.priceWaitNanoseconds = 100_000_000
        s.priceLimitNanoseconds = 600_000_000
        try s.configure(publicKey: "pk_test_abcdefghijklmnopqrstuvwx",
                        options: .init(baseURL: URL(string: "http://127.0.0.1:9")!, bundledConfig: .data(Data(Self.config.utf8)), logLevel: .none))
        return (s, { box.events.map { $0.event + ($0.reason.map { ":\($0)" } ?? "") } })
    }

    private func until(_ what: String, timeout: Double = 3, _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > end { return XCTFail("timed out waiting for \(what)") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func priceLine(_ vm: PaywallViewModel) -> String? {
        for b in vm.model.blocks { if case let .plans(plans, _) = b { return plans.first?.priceLine } }
        return nil
    }

    func testDrawnAtOnceThenTheLateAnswerFillsThePrices() async throws {
        let (s, events) = try sdk { _ in
            try await Task.sleep(nanoseconds: 300_000_000)
            return ["com.example.m": PriceLoadingTests.monthly]
        }
        var shown: PaywallViewModel?
        let result = Task { await s.run(placement: "onboarding_end", present: { shown = $0 }, dismiss: {}) }
        try await until("the paywall") { shown != nil }
        let vm = try XCTUnwrap(shown)
        // On screen before the store answered: a placeholder and the button off. paywall_shown
        // waits for the answer, at most until the wait ends.
        XCTAssertTrue(vm.pricesLoading)
        XCTAssertNil(priceLine(vm))
        XCTAssertFalse(vm.model.purchasable)
        XCTAssertEqual(events(), ["placement_fired"])
        // After the wait the placeholder becomes “Price unavailable”; the answer still counts when it comes.
        try await until("the end of the wait") { !vm.pricesLoading }
        XCTAssertNil(priceLine(vm))
        XCTAssertEqual(events(), ["placement_fired", "paywall_shown"])
        try await until("the prices") { priceLine(vm) != nil }
        XCTAssertEqual(priceLine(vm), "$9.99/month")
        XCTAssertTrue(vm.model.purchasable)
        XCTAssertEqual(events(), ["placement_fired", "paywall_shown"])
        vm.close()
        let closed = await result.value
        XCTAssertEqual(closed, .closed)
        XCTAssertEqual(events(), ["placement_fired", "paywall_shown", "paywall_closed:closed"])
    }

    func testAStoreErrorWithinTheWaitKeepsTheEventOrder() async throws {
        struct Down: Error {}
        let (s, events) = try sdk { _ in throw Down() }
        var shown: PaywallViewModel?
        let result = Task { await s.run(placement: "onboarding_end", present: { shown = $0 }, dismiss: {}) }
        try await until("the paywall") { shown != nil }
        let vm = try XCTUnwrap(shown)
        try await until("the failure") { events().count == 3 }
        // As before 0.2.1 (sessions.json): the failure, then paywall_shown.
        XCTAssertEqual(events(), ["placement_fired", "prices_load_failed:store_error", "paywall_shown"])
        XCTAssertFalse(vm.pricesLoading)
        XCTAssertFalse(vm.model.purchasable)
        vm.close()
        _ = await result.value
    }

    func testNoAnswerWithinTheLimitIsATimeout() async throws {
        let (s, events) = try sdk { _ in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            return ["com.example.m": PriceLoadingTests.monthly]
        }
        var shown: PaywallViewModel?
        let result = Task { await s.run(placement: "onboarding_end", present: { shown = $0 }, dismiss: {}) }
        try await until("the paywall") { shown != nil }
        let vm = try XCTUnwrap(shown)
        try await until("the timeout") { events().count == 3 }
        XCTAssertEqual(events(), ["placement_fired", "paywall_shown", "prices_load_failed:timeout"])
        XCTAssertNil(priceLine(vm))
        vm.close()
        _ = await result.value
    }

    func testClosedBeforeTheAnswerSendsNoFailure() async throws {
        let (s, events) = try sdk { _ in
            try await Task.sleep(nanoseconds: 200_000_000)
            return [:]
        }
        var shown: PaywallViewModel?
        let result = Task { await s.run(placement: "onboarding_end", present: { shown = $0 }, dismiss: {}) }
        try await until("the paywall") { shown != nil }
        shown?.close()
        let closed = await result.value
        XCTAssertEqual(closed, .closed)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(events(), ["placement_fired", "paywall_shown", "paywall_closed:closed"])
    }

    func testALateAnswerNeverReachesTheNextPaywall() throws {
        var events: [String] = []
        let config = try JSONDecoder().decode(SdkConfig.self, from: Data(Self.config.utf8))
        let session = PaywallSession(context: EventContext(platform: "ios", sdkVersion: "0.3.0", osVersion: "18", device: "x", storefront: nil, store: "app_store"),
                                     appUserId: "u", config: config, clock: { 1 }, makeEventId: { UUID().uuidString.lowercased() })
        session.onEvent = { events.append($0.event) }
        guard case .resolved(let r)? = session.fire(placement: "onboarding_end", attributes: [:], custom: [:]) else { return XCTFail() }
        XCTAssertTrue(session.present(placement: "onboarding_end", resolution: r, prices: [:], pricesError: nil, awaitingPrices: true))
        let first = try XCTUnwrap(session.presented?.id)
        XCTAssertEqual(events, ["placement_fired"])
        // Closing before the answer: paywall_shown first.
        session.close()
        guard case .resolved(let r2)? = session.fire(placement: "onboarding_end", attributes: [:], custom: [:]) else { return XCTFail() }
        XCTAssertTrue(session.present(placement: "onboarding_end", resolution: r2, prices: [:], pricesError: nil, awaitingPrices: true))
        XCTAssertFalse(session.pricesLoaded(["com.example.m": Self.monthly], pricesError: "late", presentation: first))
        XCTAssertEqual(session.renderModel?.purchasable, false)
        let second = try XCTUnwrap(session.presented?.id)
        XCTAssertTrue(session.pricesLoaded(["com.example.m": Self.monthly], pricesError: nil, presentation: second))
        XCTAssertFalse(session.pricesLoaded([:], pricesError: "again", presentation: second))
        XCTAssertEqual(session.renderModel?.purchasable, true)
        XCTAssertEqual(events, ["placement_fired", "paywall_shown", "paywall_closed", "placement_fired", "paywall_shown"])
    }
}
