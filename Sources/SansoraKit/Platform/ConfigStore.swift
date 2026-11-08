import Foundation

/// Downloads and caches `sansora.config/1` (CONTRACT §1).
/// Source order: cached download → bundled fallback → none. A refresh keeps the
/// previous config on any non-200/304 answer, parse failure or wrong schema.
public final class ConfigStore: @unchecked Sendable {
    public static let staleAfter: TimeInterval = 15 * 60

    struct Meta: Codable { var etag: String?; var fetchedAt: Date }

    public let publicKey: String
    public let baseURL: URL
    private let session: URLSession
    private let directory: URL?
    private let bundled: Data?
    private let lock = NSLock()
    private var current: (config: SdkConfig, data: Data, source: Source)?
    private var meta: Meta?
    private var refreshing: Task<Bool, Never>?

    public enum Source: String, Sendable { case cache, bundled, network }

    // One cache per key, so switching between test and live keys never mixes configs.
    private var configFile: String { "config-\(Assignment.sha256Hex(publicKey).prefix(12)).json" }
    private var metaFile: String { "config-\(Assignment.sha256Hex(publicKey).prefix(12))-meta.json" }

    /// - Parameters:
    ///   - directory: cache folder (nil: no disk cache).
    ///   - bundledConfig: a `sansora.config/1` document the app ships (`sansora paywalls pull`).
    public init(publicKey: String, baseURL: URL, directory: URL? = SansoraStorage.directory(), bundledConfig: Data? = nil,
                session: URLSession = .shared) {
        self.publicKey = publicKey
        self.baseURL = baseURL
        self.directory = directory
        self.bundled = bundledConfig
        self.session = session
        if let directory,
           let data = try? Data(contentsOf: directory.appendingPathComponent(configFile)), let c = SdkConfig.parse(data) {
            current = (c, data, .cache)
            meta = (try? Data(contentsOf: directory.appendingPathComponent(metaFile))).flatMap { try? JSONDecoder().decode(Meta.self, from: $0) }
        } else if let bundledConfig, let c = SdkConfig.parse(bundledConfig) {
            current = (c, bundledConfig, .bundled)
        } else if bundledConfig != nil {
            SansoraLog.error("The bundled config is not a valid sansora.config/1 document.")
        }
    }

    /// The config in use, nil when there is none yet.
    public var config: SdkConfig? { lock.lock(); defer { lock.unlock() }; return current?.config }
    /// The config in use as JSON (for bridges).
    public var configJSON: Data? { lock.lock(); defer { lock.unlock() }; return current?.data }
    public var source: Source? { lock.lock(); defer { lock.unlock() }; return current?.source }
    /// When the cached copy was last confirmed by the server.
    public var lastFetchedAt: Date? { lock.lock(); defer { lock.unlock() }; return meta?.fetchedAt }

    public var isStale: Bool {
        guard let at = lastFetchedAt else { return true }
        return Date().timeIntervalSince(at) >= Self.staleAfter
    }

    /// Refreshes when older than 15 minutes (or `force`). Returns true when the config changed.
    @discardableResult
    public func refresh(force: Bool = false) async -> Bool {
        if !force && !isStale { return false }
        let task: Task<Bool, Never> = lock.sync {
            if let r = refreshing { return r }
            let t = Task { await self.fetch() }
            refreshing = t
            return t
        }
        let changed = await task.value
        lock.sync { refreshing = nil }
        return changed
    }

    private func fetch() async -> Bool {
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/sdk/config"))
        req.setValue(publicKey, forHTTPHeaderField: "X-Sansora-Key")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 20
        let etag: String? = lock.sync { current?.source == .cache || current?.source == .network ? meta?.etag : nil }
        if let etag { req.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else { return false }
            if http.statusCode == 304 {
                lock.sync { meta = Meta(etag: meta?.etag, fetchedAt: Date()) }
                saveMeta()
                return false
            }
            guard http.statusCode == 200, let c = SdkConfig.parse(data) else {
                SansoraLog.info("Config refresh kept the previous config (HTTP \(http.statusCode)).")
                return false
            }
            let newTag = http.value(forHTTPHeaderField: "ETag")
            let changed: Bool = lock.sync {
                let changed = current?.config != c
                current = (c, data, .network)
                meta = Meta(etag: newTag, fetchedAt: Date())
                return changed
            }
            if let directory {
                try? data.write(to: directory.appendingPathComponent(configFile), options: .atomic)
            }
            saveMeta()
            return changed
        } catch {
            SansoraLog.info("Config refresh failed: \(error.localizedDescription)")
            return false
        }
    }

    private func saveMeta() {
        guard let directory, let m = lock.sync({ meta }), let d = try? JSONEncoder().encode(m) else { return }
        try? d.write(to: directory.appendingPathComponent(metaFile), options: .atomic)
    }
}
