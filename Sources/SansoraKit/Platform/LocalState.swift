import Foundation
import os

public enum SansoraLogLevel: Int, Comparable, Sendable {
    case none = 0, error, info, debug
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

enum SansoraLog {
    private static let logger = Logger(subsystem: "com.sansora.kit", category: "Sansora")
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _level: SansoraLogLevel = .error
    static var level: SansoraLogLevel {
        get { lock.lock(); defer { lock.unlock() }; return _level }
        set { lock.lock(); _level = newValue; lock.unlock() }
    }
    static func error(_ m: String) { if level >= .error { logger.error("\(m, privacy: .public)") } }
    static func info(_ m: String) { if level >= .info { logger.info("\(m, privacy: .public)") } }
    static func debug(_ m: String) { if level >= .debug { logger.debug("\(m, privacy: .public)") } }
}

/// Where the SDK keeps its files: Application Support/Sansora (excluded from backups).
public enum SansoraStorage {
    public static func directory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        var dir = base.appendingPathComponent("Sansora", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? dir.setResourceValues(values)
        }
        return dir
    }
}

/// What the SDK remembers on the device: the user ID, install date, session
/// count, display history and paywall declines. Thread-safe; persisted as JSON.
public final class LocalState: @unchecked Sendable {
    struct Stored: Codable {
        var appUserId: String?
        var identified = false
        var installedAt: Int64?
        var sessions = 0
        var backgroundAt: Int64?
        var history = DisplayHistory()
        var declines = 0
        var lastDeclineAt: Int64?
        var storefront: String?
    }

    /// A new session starts after this long in the background.
    public static let sessionGapMs: Int64 = 30 * 60 * 1000

    private let lock = NSLock()
    private var s: Stored
    private let fileURL: URL?

    public static let shared = LocalState(fileURL: SansoraStorage.directory().appendingPathComponent("state.json"))

    public init(fileURL: URL?) {
        self.fileURL = fileURL
        if let fileURL, let d = try? Data(contentsOf: fileURL), let v = try? JSONDecoder().decode(Stored.self, from: d) { s = v } else { s = Stored() }
    }

    private func mutate<T>(_ f: (inout Stored) -> T) -> T {
        lock.lock()
        let r = f(&s)
        if let fileURL, let data = try? JSONEncoder().encode(s) { try? data.write(to: fileURL, options: .atomic) }
        lock.unlock()
        return r
    }
    private func read<T>(_ f: (Stored) -> T) -> T { lock.lock(); defer { lock.unlock() }; return f(s) }

    /// Milliseconds since 1970.
    public static func nowMs() -> Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded()) }

    /// The identified user, else the persisted `anon-<uuid>` (made on first use).
    public var appUserId: String {
        if let id = read({ $0.appUserId }) { return id }
        return mutate { st in
            if st.appUserId == nil { st.appUserId = "anon-" + UUID().uuidString.lowercased() }
            return st.appUserId!
        }
    }
    public var isIdentified: Bool { read { $0.identified } }
    public func identify(_ id: String) { mutate { $0.appUserId = id; $0.identified = true } }
    /// A new anonymous ID.
    public func resetUser() { mutate { $0.appUserId = "anon-" + UUID().uuidString.lowercased(); $0.identified = false } }

    /// Cold start: stores the install date the first time and counts a session.
    public func recordLaunch(now: Int64 = LocalState.nowMs()) {
        mutate { st in
            if st.installedAt == nil { st.installedAt = now }
            st.sessions += 1
            st.history.session = []
            st.backgroundAt = nil
        }
    }

    public func didEnterBackground(now: Int64 = LocalState.nowMs()) { mutate { $0.backgroundAt = now } }

    /// Returns true when this foreground starts a new session (≥ 30 min in background).
    @discardableResult
    public func willEnterForeground(now: Int64 = LocalState.nowMs()) -> Bool {
        mutate { st in
            defer { st.backgroundAt = nil }
            guard let bg = st.backgroundAt, now - bg >= Self.sessionGapMs else { return false }
            st.sessions += 1
            st.history.session = []
            return true
        }
    }

    public var sessions: Int { read { $0.sessions } }
    public var installedAt: Int64? { read { $0.installedAt } }

    public func daysSinceInstall(now: Int64 = LocalState.nowMs()) -> Int? {
        read { st in st.installedAt.map { Int(max(0, now - $0) / 86_400_000) } }
    }

    public var history: DisplayHistory {
        get { read { $0.history } }
        set { mutate { $0.history = newValue } }
    }

    /// The last storefront StoreKit reported (alpha-2), used until it answers again.
    public var storefront: String? {
        get { read { $0.storefront } }
        set { mutate { $0.storefront = newValue?.uppercased() } }
    }

    /// A `paywall_closed` with reason `closed`.
    public func recordDecline(now: Int64 = LocalState.nowMs()) { mutate { $0.declines += 1; $0.lastDeclineAt = now } }
    public var paywallDeclined: Int { read { $0.declines } }
    public func daysSinceDecline(now: Int64 = LocalState.nowMs()) -> Int? {
        read { st in st.lastDeclineAt.map { Int(max(0, now - $0) / 86_400_000) } }
    }
}

extension NSLock {
    func sync<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
