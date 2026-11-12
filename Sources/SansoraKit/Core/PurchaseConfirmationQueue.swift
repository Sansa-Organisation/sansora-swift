import Foundation

public extension FlushResponse {
    /// What a purchase confirmation does with this answer (CONTRACT §7): 2xx
    /// removes it, every 4xx but 429 is permanent, anything else retries.
    var confirmationAction: Action {
        switch self {
        case .network: return .retry
        case .status(let s):
            if (200..<300).contains(s) { return .remove }
            if (400..<500).contains(s) && s != 429 { return .drop }
            return .retry
        }
    }
}

/// Sends one purchase confirmation.
public protocol PurchaseConfirmationTransport: Sendable {
    func send(appUserId: String, signedTransaction: String) async -> FlushResponse
}

/// `POST {base}/v1/sdk/purchases/confirm` with
/// `{"key":…,"appUserId":…,"store":"app_store","signedTransaction":…}`.
public struct HTTPPurchaseConfirmationTransport: PurchaseConfirmationTransport {
    public let baseURL: URL
    public let publicKey: String
    public let session: URLSession
    public init(baseURL: URL, publicKey: String, session: URLSession = .shared) {
        self.baseURL = baseURL; self.publicKey = publicKey; self.session = session
    }

    public func send(appUserId: String, signedTransaction: String) async -> FlushResponse {
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/sdk/purchases/confirm"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 30
        let body: JSONValue = .object([
            "key": .string(publicKey),
            "appUserId": .string(appUserId),
            "store": .string("app_store"),
            "signedTransaction": .string(signedTransaction),
        ])
        guard let data = try? body.data(sorted: false) else { return .status(400) }
        req.httpBody = data
        do {
            let (_, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else { return .network }
            return .status(http.statusCode)
        } catch {
            return .network
        }
    }
}

/// The durable queue of purchase confirmations (CONTRACT §7), which store code
/// fills and nothing waits on: a persisted FIFO sent one at a time, retrying with
/// the backoff of `EventQueue`. Each entry keeps the app user who made the
/// purchase, however the user changes before it is sent.
///
/// Public so the Flutter and React Native bridges use the same queue. Those
/// layers learn the user only after their native side is set up, so a purchase
/// that arrives first waits, unsent, for `setAppUserId`.
public actor PurchaseConfirmationQueue {
    public static let queueLimit = 100

    struct Entry: Codable, Equatable, Sendable {
        var seq: Int
        var id: String
        var appUserId: String?
        var signedTransaction: String
    }

    struct State: Codable {
        var entries: [Entry] = []
        var failures = 0
        var nextSeq = 1
    }

    private var state: State
    private var appUserId: String?
    private let fileURL: URL?
    private let transport: PurchaseConfirmationTransport?
    private let jitter: @Sendable () -> Double
    private let autoFlush: Bool
    private let debounceNs: UInt64
    private var flushing = false
    private var debounceTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?

    /// - Parameters:
    ///   - fileURL: where the queue is persisted (nil: memory only).
    ///   - appUserId: the current user, when it is already known.
    ///   - jitter: fraction of the delay added to retries, 0…0.2 (0 in tests).
    ///   - autoFlush: debounce a flush after enqueue and retry on the backoff timer.
    public init(fileURL: URL?, transport: PurchaseConfirmationTransport?, appUserId: String? = nil,
                jitter: @escaping @Sendable () -> Double = { Double.random(in: 0...0.2) },
                autoFlush: Bool = true, debounceSeconds: Double = 1) {
        self.fileURL = fileURL
        self.transport = transport
        self.appUserId = appUserId
        self.jitter = jitter
        self.autoFlush = autoFlush
        self.debounceNs = UInt64(max(0, debounceSeconds) * 1_000_000_000)
        if let fileURL, let data = try? Data(contentsOf: fileURL), let s = try? JSONDecoder().decode(State.self, from: data) {
            state = s
        } else {
            state = State()
        }
    }

    /// Confirmations waiting, oldest first.
    public var count: Int { state.entries.count }
    /// Consecutive failed sends (persisted).
    public var failures: Int { state.failures }
    /// The app user of each waiting confirmation, oldest first.
    public var pendingUsers: [String?] { state.entries.map(\.appUserId) }

    /// The current user: later purchases, and any that were waiting for one, belong to it.
    public func setAppUserId(_ id: String?) {
        appUserId = id
        guard let id, state.entries.contains(where: { $0.appUserId == nil }) else { return }
        for i in state.entries.indices where state.entries[i].appUserId == nil { state.entries[i].appUserId = id }
        persist()
        if autoFlush { scheduleFlush() }
    }

    /// Adds a verified purchase. [id] is the store's original transaction ID, so a
    /// renewal replaces a confirmation of the same subscription that hasn't gone yet.
    public func enqueue(id: String, signedTransaction: String) {
        guard !id.isEmpty, !signedTransaction.isEmpty else { return }
        let user = appUserId
        if let i = state.entries.firstIndex(where: { $0.id == id && $0.appUserId == user }) {
            state.entries[i].signedTransaction = signedTransaction
            // A new number, so a send of the old copy that is in flight can't remove this one.
            state.entries[i].seq = state.nextSeq
        } else {
            state.entries.append(Entry(seq: state.nextSeq, id: id, appUserId: user, signedTransaction: signedTransaction))
            if state.entries.count > Self.queueLimit {
                state.entries.removeFirst(state.entries.count - Self.queueLimit)
                SansoraLog.debug("Purchase confirmation queue full; dropped the oldest.")
            }
        }
        state.nextSeq += 1
        persist()
        if autoFlush { scheduleFlush() }
    }

    /// Debounced flush (~1 s).
    public func scheduleFlush() {
        debounceTask?.cancel()
        let ns = debounceNs
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: ns)
            if Task.isCancelled { return }
            // A separate task, so cancelling this timer never cancels a request in flight.
            Task { _ = await self?.flush() }
        }
    }

    /// Sends confirmations until none are left, one fails, or `maxSends` were sent.
    @discardableResult
    public func flush(maxSends: Int = .max) async -> FlushOutcome {
        guard !flushing, let transport else {
            return FlushOutcome(sent: [], dropped: 0, queued: state.entries.count, failures: state.failures, retryAfterMs: nil)
        }
        flushing = true
        defer { flushing = false }
        retryTask?.cancel(); retryTask = nil
        var sent: [Int] = [], dropped = 0, sends = 0
        while sends < maxSends, let entry = state.entries.first(where: { $0.appUserId != nil }), let user = entry.appUserId {
            sends += 1
            sent.append(1)
            let response = await transport.send(appUserId: user, signedTransaction: entry.signedTransaction)
            let action = response.confirmationAction
            if action == .retry {
                state.failures += 1
                persist()
                break
            }
            state.failures = 0
            state.entries.removeAll { $0.seq == entry.seq }
            if action == .drop {
                dropped += 1
                if case .status(let s) = response { SansoraLog.debug("Dropped a purchase confirmation (HTTP \(s)).") }
            }
            persist()
        }
        var retry: Int64? = nil
        if state.failures > 0, state.entries.contains(where: { $0.appUserId != nil }) {
            let base = EventQueue.retryDelay(failures: state.failures)
            let j = min(0.2, max(0, jitter()))
            retry = base + Int64((Double(base) * j).rounded())
            if autoFlush, let retry { scheduleRetry(afterMs: retry) }
        }
        return FlushOutcome(sent: sent, dropped: dropped, queued: state.entries.count, failures: state.failures, retryAfterMs: retry)
    }

    private func scheduleRetry(afterMs ms: Int64) {
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
            if Task.isCancelled { return }
            // A separate task, so cancelling this timer never cancels a request in flight.
            Task { _ = await self?.flush() }
        }
    }

    private func persist() {
        guard let fileURL else { return }
        do {
            let data = try JSONEncoder().encode(state)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            SansoraLog.error("Could not save the purchase confirmations: \(error.localizedDescription)")
        }
    }
}
