import Foundation

public enum PlanLimitsError: Error, Equatable, Sendable {
    case noCredentials
    case loginExpired
    /// HTTP 403: this login can't read plan limits (e.g. not a Pro/Max subscription).
    /// Re-reading the login won't help, unlike 401.
    case notAvailable
    case rateLimited
    case http(Int)
    case badResponse
    case network

    public var message: String {
        switch self {
        case .noCredentials: return "Sign in to Claude Code with your Claude subscription to see plan limits."
        case .loginExpired: return "Claude Code login expired. Open Claude Code once to refresh it."
        case .notAvailable: return "Plan limits aren't available for this Claude account."
        case .rateLimited: return "Rate limited by Anthropic. Will retry later."
        case .http(let code): return "Limits unavailable (HTTP \(code))."
        case .badResponse: return "Limits unavailable (unexpected response)."
        case .network: return "Can't reach Anthropic right now."
        }
    }
}

/// Fetches the session (5-hour) and weekly (7-day) limits from the **unofficial**
/// endpoint that Claude Code's `/usage` command uses, signed in with Claude Code's
/// own OAuth login.
///
/// Security:
/// - The token is only read, never refreshed or written back.
/// - It's sent only to `api.anthropic.com` over HTTPS. Redirects are refused, so it
///   can't be forwarded to another host.
/// - Nothing touches disk: no URL cache (the default one stores request headers,
///   including `Authorization`, in `~/Library/Caches/<bundle id>/Cache.db`), no cookies.
/// - Responses larger than `maxResponseBytes` are refused without being held in memory.
///
/// Anthropic may change or remove this endpoint at any time.
public final class PlanLimitsClient: @unchecked Sendable {
    public static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    private let session: URLSession
    private let readCredentials: @Sendable () -> String?
    private let now: @Sendable () -> Date
    private let userAgent: String
    private let lock = NSLock()
    /// Kept in memory so the Keychain isn't read on every refresh. Re-read when it expires,
    /// when the server rejects it (Claude Code may have refreshed its login), and at least
    /// every `credentialsMaxAge` so switching Claude accounts shows up within minutes.
    private var cachedCredentials: Credentials?
    private var cachedAt = Date.distantPast
    static let credentialsMaxAge: TimeInterval = 10 * 60
    /// The real response is under 1 KB. Anything past this cap is refused.
    static let maxResponseBytes = 256 << 10

    public convenience init(readCredentials: @escaping @Sendable () -> String? = CredentialStore.read,
                            now: @escaping @Sendable () -> Date = { Date() }) {
        self.init(configuration: .ephemeral, readCredentials: readCredentials, now: now)
    }

    init(configuration: URLSessionConfiguration,
         readCredentials: @escaping @Sendable () -> String?,
         now: @escaping @Sendable () -> Date) {
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        session = URLSession(configuration: configuration, delegate: RefuseRedirects(), delegateQueue: nil)
        self.readCredentials = readCredentials
        self.now = now
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        userAgent = "Tokenwick/\(version)"
    }

    deinit {
        session.invalidateAndCancel()
    }

    public func fetch() async -> Result<PlanLimits, PlanLimitsError> {
        guard var credentials = await credentials(reload: false) else { return .failure(.noCredentials) }
        if credentials.isExpired(at: now()) {
            guard let fresh = await self.credentials(reload: true) else { return .failure(.noCredentials) }
            if fresh.isExpired(at: now()) { return .failure(.loginExpired) }
            credentials = fresh
        }

        let result = await request(with: credentials)
        guard result == .failure(.loginExpired) else { return result }

        // 401: Claude Code may have refreshed its login (or signed out) since we cached it.
        guard let fresh = await self.credentials(reload: true) else { return .failure(.noCredentials) }
        guard fresh.accessToken != credentials.accessToken, !fresh.isExpired(at: now()) else { return result }
        return await request(with: fresh) // retry once with the new login
    }

    private func request(with credentials: Credentials) async -> Result<PlanLimits, PlanLimitsError> {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        // Streamed, so the body can be capped: `data(for:)` would hold whatever the server
        // (or a TLS-inspecting proxy) sends in memory, however large.
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            return .failure(.network)
        }
        defer { bytes.task.cancel() } // frees the connection if the body isn't read to the end

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300: break
        case 401: return .failure(.loginExpired)
        case 403: return .failure(.notAvailable)
        case 429: return .failure(.rateLimited)
        default: return .failure(.http(status))
        }

        var data = Data()
        do {
            for try await byte in bytes {
                guard data.count < Self.maxResponseBytes else { return .failure(.badResponse) }
                data.append(byte)
            }
        } catch {
            return .failure(.network)
        }

        guard let limits = Self.parseUsage(data) else { return .failure(.badResponse) }
        return .success(limits)
    }

    private func credentials(reload: Bool) async -> Credentials? {
        if !reload, let (cached, readAt) = lock.withLock({ cachedCredentials.map { ($0, cachedAt) } }),
           now().timeIntervalSince(readAt) < Self.credentialsMaxAge {
            return cached
        }
        // Reading runs a subprocess that can block (e.g. on a Keychain prompt),
        // so keep it off Swift's cooperative thread pool.
        let read = readCredentials
        let json = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            DispatchQueue.global(qos: .utility).async { continuation.resume(returning: read()) }
        }
        let parsed = json.flatMap(Self.parseCredentials)
        let readAt = now()
        lock.withLock {
            cachedCredentials = parsed
            cachedAt = readAt
        }
        return parsed
    }

    // MARK: - Parsing (lenient, so new fields don't break anything)

    struct Credentials: Equatable {
        let accessToken: String
        let expiresAt: Date?

        /// Treat a token as expired 30 s early so it can't expire mid-request.
        func isExpired(at now: Date) -> Bool {
            expiresAt.map { $0 <= now.addingTimeInterval(30) } ?? false
        }
    }

    static func parseCredentials(_ json: String) -> Credentials? {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        // `expiresAt` is milliseconds since 1970.
        let expiresAt = (oauth["expiresAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        return Credentials(accessToken: token, expiresAt: expiresAt)
    }

    /// Reads `five_hour` (session), `seven_day` (weekly) and extra usage. Nil if neither
    /// window is present.
    static func parseUsage(_ data: Data) -> PlanLimits? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let session = window(root["five_hour"])
        let weekly = window(root["seven_day"])
        guard session != nil || weekly != nil else { return nil }
        return PlanLimits(session: session, weekly: weekly,
                          extra: extraUsage(spend: root["spend"], flags: root["extra_usage"]))
    }

    /// Extra usage comes in two objects. `spend` has the amounts, each in a self-describing
    /// format (`amount_minor` + `exponent` + `currency`), so amounts are only ever read from
    /// there. `extra_usage` adds flags (limit reached, switched off by the user). Its own
    /// amount fields don't say which unit they're in, so they're ignored.
    static func extraUsage(spend: Any?, flags: Any?) -> ExtraUsage? {
        let spend = spend as? [String: Any]
        let flags = flags as? [String: Any]
        guard spend != nil || flags != nil else { return nil }
        return ExtraUsage(
            isEnabled: (spend?["enabled"] as? Bool) ?? (flags?["is_enabled"] as? Bool) ?? false,
            used: money(spend?["used"]),
            limit: money(spend?["limit"]),
            balance: money(spend?["balance"]),
            percentUsed: number(spend?["percent"]) ?? number(flags?["utilization"]),
            limitReached: (flags?["spend_limit_reached"] as? Bool) ?? false,
            turnedOffByUser: (flags?["user_disabled"] as? Bool) ?? false)
    }

    /// `{"amount_minor": 1234, "exponent": 2, "currency": "USD"}` → $12.34. Nil for anything else.
    static func money(_ value: Any?) -> Money? {
        guard let dict = value as? [String: Any], let minor = number(dict["amount_minor"]) else { return nil }
        let exponent = (dict["exponent"] as? NSNumber)?.intValue ?? 2
        guard (0...6).contains(exponent) else { return nil }
        // Only a plain 3-letter code reaches the currency formatter.
        let currency = (dict["currency"] as? String).flatMap { code in
            code.count == 3 && code.allSatisfy { $0.isASCII && $0.isLetter } ? code.uppercased() : nil
        }
        return Money(amount: minor / pow(10, Double(exponent)), currency: currency)
    }

    /// A finite JSON number. JSON true/false also arrive as NSNumber; those are refused.
    private static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
        return n.doubleValue
    }

    private static func window(_ value: Any?) -> LimitWindow? {
        guard let dict = value as? [String: Any],
              let utilization = number(dict["utilization"]) else { return nil }
        let resetsAt = (dict["resets_at"] as? String).flatMap(ISODate.parse)
        // Clamp: the UI converts this to Int, which traps on huge values (e.g. 1e300).
        let percent = min(max(utilization, 0), 1_000)
        return LimitWindow(percentUsed: percent, resetsAt: resetsAt)
    }
}

/// Never follow redirects: the request carries a bearer token.
final class RefuseRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Reads Claude Code's stored login.
public enum CredentialStore {
    /// Claude Code stores its login in the macOS Keychain using the `security` tool, so
    /// reading it the same way normally doesn't trigger an access prompt. Falls back to
    /// `~/.claude/.credentials.json`, which some setups use instead.
    @Sendable public static func read() -> String? {
        if let fromKeychain = readKeychain() { return fromKeychain }
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
        // A login file is a few hundred bytes. Refuse FIFOs, devices and huge files, which would hang or exhaust memory.
        return SafeFile.read(file, maxBytes: 64 << 10).flatMap { String(data: $0, encoding: .utf8) }
    }

    private static func readKeychain() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        // Don't wait forever if a Keychain prompt is left unanswered.
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: watchdog)
        // A login entry is a few hundred bytes; cap the read so an oversized one can't eat memory.
        let maxBytes = 1 << 20
        var data = Data()
        let reader = stdout.fileHandleForReading
        while let chunk = try? reader.read(upToCount: 64 << 10), !chunk.isEmpty {
            data.append(chunk)
            if data.count > maxBytes {
                process.terminate()
                break
            }
        }
        process.waitUntilExit()
        watchdog.cancel()

        guard data.count <= maxBytes,
              process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }
}
