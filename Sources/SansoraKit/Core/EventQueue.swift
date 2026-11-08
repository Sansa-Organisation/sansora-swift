import Foundation

/// The answer to one batch POST.
public enum FlushResponse: Equatable, Sendable {
    case status(Int)
    case network

    public enum Action: Equatable, Sendable { case remove, drop, retry }

    /// 2xx removes the batch; 400/413/422 drop it; everything else retries.
    public var action: Action {
        switch self {
        case .network: return .retry
        case .status(let s):
            if (200..<300).contains(s) { return .remove }
            if s == 400 || s == 413 || s == 422 { return .drop }
            return .retry
        }
    }
}

/// What one flush did (`FlushOutcome` in sdk-session.ts).
public struct FlushOutcome: Equatable, Sendable {
    /// Size of each batch sent, in order.
    public var sent: [Int]
    public var dropped: Int
    public var queued: Int
    public var failures: Int
    /// Delay before the automatic retry (base delay plus jitter), nil when not failing.
    public var retryAfterMs: Int64?
}

/// Sends one batch of events.
public protocol EventTransport: Sendable {
    func send(_ events: [JSONValue]) async -> FlushResponse
}

/// `POST {base}/v1/sdk/events` with `{"key":…,"events":[…]}`.
public struct HTTPEventTransport: EventTransport {
    public let baseURL: URL
    public let publicKey: String
    public let session: URLSession
    public init(baseURL: URL, publicKey: String, session: URLSession = .shared) {
        self.baseURL = baseURL; self.publicKey = publicKey; self.session = session
    }

    public func send(_ events: [JSONValue]) async -> FlushResponse {
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/sdk/events"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 30
        guard let body = try? JSONValue.object(["key": .string(publicKey), "events": .array(events)]).data(sorted: false) else { return .status(400) }
        req.httpBody = body
        do {
            let (_, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else { return .network }
            return .status(http.statusCode)
        } catch {
            return .network
        }
    }
}

/// The durable event queue (`runDelivery` in sdk-session.ts): a persisted FIFO of
/// at most 1000 events (oldest dropped), sent in order in batches of up to 100.
/// Failures back off `min(300 s, 2 s × 2^(failures−1))` plus 0–20% jitter.
/// Accepts pre-built `sansora.event/1` JSON objects, so Flutter / React Native
/// bridges can enqueue events they built themselves.
public actor EventQueue {
    public static let queueLimit = 1000
    public static let batchLimit = 100
    public static let baseDelayMs: Int64 = 2000
    public static let maxDelayMs: Int64 = 300_000

    public static func retryDelay(failures: Int) -> Int64 {
        guard failures > 0 else { return 0 }
        var d = baseDelayMs
        for _ in 1..<failures { d *= 2; if d >= maxDelayMs { return maxDelayMs } }
        return min(maxDelayMs, d)
    }

    struct State: Codable {
        var events: [JSONValue] = []
        var failures = 0
        var overflow = 0
    }

    private var state: State
    private let fileURL: URL?
    private var transport: EventTransport?
    private let jitter: @Sendable () -> Double
    private let autoFlush: Bool
    private let debounceNs: UInt64
    private var flushing = false
    private var trimmedInFlight = 0
    private var debounceTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?

    /// - Parameters:
    ///   - fileURL: where the queue is persisted (nil: memory only).
    ///   - transport: nil until configured; flushes do nothing without one.
    ///   - jitter: fraction of the delay added to retries, 0…0.2 (0 in tests).
    ///   - autoFlush: debounce a flush after enqueue and retry on the backoff timer.
    public init(fileURL: URL?, transport: EventTransport? = nil, jitter: @escaping @Sendable () -> Double = { Double.random(in: 0...0.2) },
                autoFlush: Bool = true, debounceSeconds: Double = 1) {
        self.fileURL = fileURL
        self.transport = transport
        self.jitter = jitter
        self.autoFlush = autoFlush
        self.debounceNs = UInt64(max(0, debounceSeconds) * 1_000_000_000)
        if let fileURL, let data = try? Data(contentsOf: fileURL), let s = try? JSONDecoder().decode(State.self, from: data) {
            state = s
        } else {
            state = State()
        }
    }

    /// The default location: Application Support/Sansora/events.json.
    public static func defaultFileURL() -> URL {
        SansoraStorage.directory().appendingPathComponent("events.json")
    }

    public func setTransport(_ transport: EventTransport?) { self.transport = transport }

    /// Number of events waiting.
    public var count: Int { state.events.count }
    /// Events waiting, oldest first.
    public var pending: [JSONValue] { state.events }
    /// Consecutive failed flushes (persisted).
    public var failures: Int { state.failures }
    /// Events dropped because the queue was full (persisted).
    public var overflow: Int { state.overflow }

    /// Adds events at the end; the oldest go when there are more than 1000.
    public func enqueue(_ events: [JSONValue]) {
        guard !events.isEmpty else { return }
        state.events.append(contentsOf: events)
        if state.events.count > Self.queueLimit {
            let extra = state.events.count - Self.queueLimit
            state.overflow += extra
            state.events.removeFirst(extra)
            if flushing { trimmedInFlight += extra }
        }
        persist()
        if autoFlush { scheduleFlush() }
    }

    public func enqueue(_ event: SdkEvent) { enqueue([event.json]) }

    /// Enqueues a JSON array of event objects (or a single object), e.g. from a bridge.
    public func enqueue(jsonEvents data: Data) throws {
        let value = try JSONValue.parse(data)
        switch value {
        case .array(let a): enqueue(a.filter { $0.objectValue != nil })
        case .object: enqueue([value])
        default: throw CocoaError(.coderInvalidValue)
        }
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

    /// Sends batches until the queue is empty, a batch fails, or `maxBatches` were sent.
    @discardableResult
    public func flush(maxBatches: Int = .max) async -> FlushOutcome {
        guard !flushing, let transport else {
            return FlushOutcome(sent: [], dropped: 0, queued: state.events.count, failures: state.failures, retryAfterMs: nil)
        }
        flushing = true
        defer { flushing = false }
        retryTask?.cancel(); retryTask = nil
        var sent: [Int] = [], dropped = 0, batches = 0
        while batches < maxBatches, !state.events.isEmpty {
            batches += 1
            let batch = Array(state.events.prefix(Self.batchLimit))
            sent.append(batch.count)
            trimmedInFlight = 0
            let response = await transport.send(batch)
            let action = response.action
            if action == .retry {
                state.failures += 1
                persist()
                break
            }
            state.failures = 0
            // Events trimmed by overflow while the batch was in flight were the batch's own.
            let remove = max(0, min(state.events.count, batch.count - trimmedInFlight))
            state.events.removeFirst(remove)
            if action == .drop { dropped += batch.count }
            persist()
        }
        var retry: Int64? = nil
        if state.failures > 0 {
            let base = Self.retryDelay(failures: state.failures)
            let j = min(0.2, max(0, jitter()))
            retry = base + Int64((Double(base) * j).rounded())
            if autoFlush, let retry { scheduleRetry(afterMs: retry) }
        }
        return FlushOutcome(sent: sent, dropped: dropped, queued: state.events.count, failures: state.failures, retryAfterMs: retry)
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
            SansoraLog.error("Could not save the event queue: \(error.localizedDescription)")
        }
    }
}
