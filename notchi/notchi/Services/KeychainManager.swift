import Foundation
import os.log
import Security

nonisolated private let logger = Logger(subsystem: "com.ruban.notchi", category: "KeychainManager")

struct ClaudeOAuthCredentials: Equatable {
    let accessToken: String
    let expiresAt: Date?
    let scopes: Set<String>
}

enum KeychainManager {
    private static let claudeCodeService = "Claude Code-credentials"
    private static let notchiService = "com.ruban.notchi"
    private static let anthropicApiKeyAccount = "anthropicApiKey"
    private static let openAIApiKeyAccount = "openAIApiKey"
    private static let cachedOAuthTokenAccount = "cachedOAuthToken"
    private static let recentCredentialCacheTTL: TimeInterval = 5
    private static let securityCLIBackoffInterval: TimeInterval = 60
    private static let networkRefreshLeeway: TimeInterval = 5 * 60
    @MainActor private static var inFlightNetworkRefresh: Task<String?, Never>?
    private static let credentialReadLock = NSLock()
    private nonisolated(unsafe) static var recentCredentialCacheEntry: ClaudeCredentialCacheEntry?
    private nonisolated(unsafe) static var lastSecurityCLIFailureAt: Date?
    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let isoBasic = ISO8601DateFormatter()

    private struct ClaudeCredentialCacheEntry {
        let credentials: ClaudeOAuthCredentials
        let resolvedAt: Date
        let source: String
    }

    #if DEBUG
    private nonisolated(unsafe) static var taskSecurityCLIReadOverride: (() -> [String: Any]?)?
    private nonisolated(unsafe) static var taskSecurityFrameworkReadOverride: ((Bool) -> [String: Any]?)?
    private nonisolated(unsafe) static var taskSecurityCLIWriteOverride: (([String: Any], String) -> Bool)?
    private nonisolated(unsafe) static var taskNowOverride: (() -> Date)?
    #endif

    static func refreshAccessTokenSilently() -> String? {
        guard let credentials = getOAuthCredentials(allowInteraction: false) else {
            return nil
        }
        cacheOAuthToken(credentials.accessToken)
        return credentials.accessToken
    }

    // Refreshes the Claude Code OAuth token over the network and writes the rotated
    // credentials back to Claude Code's keychain item, so the CLI and IDE extensions
    // keep working with the same login. Used when nothing else refreshes the token
    // (e.g. the user only uses the Claude desktop app or an IDE extension).
    @MainActor
    static func refreshAccessTokenOverNetwork() async -> String? {
        if let inFlight = inFlightNetworkRefresh {
            return await inFlight.value
        }
        let task = Task { await performNetworkRefresh() }
        inFlightNetworkRefresh = task
        defer { inFlightNetworkRefresh = nil }
        return await task.value
    }

    @MainActor
    private static func performNetworkRefresh() async -> String? {
        // WHY: bypass the short-lived cache; another client may have just rotated the token.
        invalidateRecentCredentialCache()
        guard let json = readClaudeCodeKeychainViaCLI(),
              let credentials = decodeClaudeOAuthCredentials(from: json),
              let refreshToken = decodeRefreshToken(from: json) else {
            logger.info("No Claude Code refresh token available for network refresh")
            return nil
        }

        let now = currentDate()
        if let expiresAt = credentials.expiresAt,
           expiresAt.timeIntervalSince(now) > networkRefreshLeeway {
            cacheOAuthToken(credentials.accessToken)
            return credentials.accessToken
        }

        let account = claudeCodeKeychainAccount() ?? NSUserName()

        // WHY: refresh tokens rotate. If the rotated token could not be saved, Claude Code
        // would be logged out, so prove the item is writable before consuming the old one.
        guard writeClaudeCodeKeychain(json, account: account) else {
            logger.warning("Claude Code keychain item is not writable; skipping network refresh")
            return nil
        }

        switch await ClaudeOAuthTokenRefresher.requestGrant(refreshToken: refreshToken, now: now) {
        case let .granted(grant):
            invalidateRecentCredentialCache()
            if !writeClaudeCodeKeychain(mergeGrant(grant, into: json), account: account)
                || readClaudeCodeKeychainViaCLI().flatMap(decodeClaudeOAuthCredentials(from:))?.accessToken != grant.accessToken {
                logger.error("Refreshed Claude OAuth token but failed to save it to the keychain")
            }
            invalidateRecentCredentialCache()
            cacheOAuthToken(grant.accessToken)
            return grant.accessToken

        case .rejected:
            // Another client may have rotated the token between our read and the request.
            guard let latest = readClaudeCodeKeychainViaCLI().flatMap(decodeClaudeOAuthCredentials(from:)),
                  latest.accessToken != credentials.accessToken else {
                return nil
            }
            cacheOAuthToken(latest.accessToken)
            return latest.accessToken

        case .unavailable:
            return nil
        }
    }

    static func mergeGrant(_ grant: ClaudeOAuthTokenGrant, into json: [String: Any]) -> [String: Any] {
        var oauth = json["claudeAiOauth"] as? [String: Any] ?? [:]
        oauth["accessToken"] = grant.accessToken
        if let refreshToken = grant.refreshToken {
            oauth["refreshToken"] = refreshToken
        }
        if let expiresAt = grant.expiresAt {
            // Claude Code stores expiresAt as epoch milliseconds.
            oauth["expiresAt"] = Int64((expiresAt.timeIntervalSince1970 * 1000).rounded())
        }
        if let scopes = grant.scopes {
            oauth["scopes"] = scopes
        }
        var updated = json
        updated["claudeAiOauth"] = oauth
        return updated
    }

    static func decodeRefreshToken(from json: [String: Any]) -> String? {
        guard let oauth = json["claudeAiOauth"] as? [String: Any],
              let rawToken = oauth["refreshToken"] as? String else {
            return nil
        }
        let refreshToken = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        return refreshToken.isEmpty ? nil : refreshToken
    }

    private static func claudeCodeKeychainAccount() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: claudeCodeService,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip
        ]

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let attributes = result as? [String: Any],
              let account = attributes[kSecAttrAccount as String] as? String,
              !account.isEmpty else {
            return nil
        }
        return account
    }

    // WHY: write through /usr/bin/security (as Claude Code does) so the item's ACL keeps
    // trusting the same tool and no keychain dialog appears. The command goes over stdin
    // in interactive mode so the credentials never show up in the process list.
    private static func writeClaudeCodeKeychain(_ json: [String: Any], account: String) -> Bool {
        #if DEBUG
        if let override = taskSecurityCLIWriteOverride {
            return override(json, account)
        }
        #endif

        guard !account.contains(where: { $0 == "\"" || $0 == "\\" || $0.isNewline }),
              let data = try? JSONSerialization.data(withJSONObject: json) else {
            return false
        }

        let hexPassword = data.map { String(format: "%02x", $0) }.joined()
        let command = "add-generic-password -U -a \"\(account)\" -s \"\(claudeCodeService)\" -X \(hexPassword)\n"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["-i"]

        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }

        do {
            try process.run()
        } catch {
            return false
        }

        input.fileHandleForWriting.write(Data(command.utf8))
        try? input.fileHandleForWriting.close()

        if done.wait(timeout: .now() + .seconds(5)) == .timedOut {
            process.terminate()
            return false
        }

        return process.terminationStatus == 0
    }

    private static func invalidateRecentCredentialCache() {
        credentialReadLock.lock()
        recentCredentialCacheEntry = nil
        credentialReadLock.unlock()
    }

    // MARK: - Anthropic API Key

    static func getAnthropicApiKey(allowInteraction: Bool = false) -> String? {
        readString(
            service: notchiService,
            account: anthropicApiKeyAccount,
            allowInteraction: allowInteraction
        )
    }

    static func setAnthropicApiKey(_ key: String?) {
        if let key, !key.isEmpty {
            saveString(key, service: notchiService, account: anthropicApiKeyAccount)
        } else {
            deleteItem(service: notchiService, account: anthropicApiKeyAccount)
        }
    }

    static func getOpenAIApiKey(allowInteraction: Bool = false) -> String? {
        readString(
            service: notchiService,
            account: openAIApiKeyAccount,
            allowInteraction: allowInteraction
        )
    }

    static func setOpenAIApiKey(_ key: String?) {
        if let key, !key.isEmpty {
            saveString(key, service: notchiService, account: openAIApiKeyAccount)
        } else {
            deleteItem(service: notchiService, account: openAIApiKeyAccount)
        }
    }

    // MARK: - Cached OAuth Token

    static func getCachedOAuthToken(allowInteraction: Bool = false) -> String? {
        readString(
            service: notchiService,
            account: cachedOAuthTokenAccount,
            allowInteraction: allowInteraction
        )
    }

    static func cacheOAuthToken(_ token: String) {
        saveString(token, service: notchiService, account: cachedOAuthTokenAccount)
    }

    static func clearCachedOAuthToken() {
        deleteItem(service: notchiService, account: cachedOAuthTokenAccount)
    }

    // MARK: - Claude Code Credentials

    static func getOAuthCredentials(allowInteraction: Bool) -> ClaudeOAuthCredentials? {
        let now = currentDate()
        if let cached = recentCredentialCache(at: now) {
            return cached.credentials
        }

        // Primary: /usr/bin/security CLI (avoids ACL dialog)
        if shouldAttemptSecurityCLI(at: now) {
            if let json = readClaudeCodeKeychainViaCLI(),
               let credentials = decodeClaudeOAuthCredentials(from: json) {
                cacheRecentCredential(credentials, source: "/usr/bin/security CLI", at: now)
                clearSecurityCLIBackoff()
                return credentials
            }
            recordSecurityCLIFailure(at: now)
        }

        // Fallback: Security.framework using the caller's interaction policy.
        guard let json = readClaudeCodeKeychain(allowInteraction: allowInteraction),
              let credentials = decodeClaudeOAuthCredentials(from: json) else {
            return nil
        }
        cacheRecentCredential(credentials, source: "Security.framework", at: now)
        return credentials
    }

    private static func readClaudeCodeKeychainViaCLI() -> [String: Any]? {
        #if DEBUG
        if let override = taskSecurityCLIReadOverride {
            return override()
        }
        #endif

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", claudeCodeService, "-w"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }

        do {
            try process.run()
        } catch {
            return nil
        }

        if done.wait(timeout: .now() + .seconds(2)) == .timedOut {
            process.terminate()
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard !data.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    private static func readClaudeCodeKeychain(allowInteraction: Bool) -> [String: Any]? {
        #if DEBUG
        if let override = taskSecurityFrameworkReadOverride {
            return override(allowInteraction)
        }
        #endif

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: claudeCodeService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        if !allowInteraction {
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
        }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        return json
    }

    private static func recentCredentialCache(at now: Date) -> ClaudeCredentialCacheEntry? {
        credentialReadLock.lock()
        defer { credentialReadLock.unlock() }

        guard let entry = recentCredentialCacheEntry else {
            return nil
        }

        guard now.timeIntervalSince(entry.resolvedAt) <= recentCredentialCacheTTL else {
            recentCredentialCacheEntry = nil
            return nil
        }

        return entry
    }

    private static func cacheRecentCredential(_ credentials: ClaudeOAuthCredentials, source: String, at now: Date) {
        credentialReadLock.lock()
        recentCredentialCacheEntry = ClaudeCredentialCacheEntry(
            credentials: credentials,
            resolvedAt: now,
            source: source
        )
        credentialReadLock.unlock()
    }

    private static func shouldAttemptSecurityCLI(at now: Date) -> Bool {
        credentialReadLock.lock()
        defer { credentialReadLock.unlock() }

        guard let lastFailure = lastSecurityCLIFailureAt else {
            return true
        }

        if now.timeIntervalSince(lastFailure) >= securityCLIBackoffInterval {
            lastSecurityCLIFailureAt = nil
            return true
        }

        return false
    }

    private static func recordSecurityCLIFailure(at now: Date) {
        credentialReadLock.lock()
        lastSecurityCLIFailureAt = now
        credentialReadLock.unlock()
    }

    private static func clearSecurityCLIBackoff() {
        credentialReadLock.lock()
        lastSecurityCLIFailureAt = nil
        credentialReadLock.unlock()
    }

    private static func currentDate() -> Date {
        #if DEBUG
        if let override = taskNowOverride {
            return override()
        }
        #endif
        return Date()
    }

    #if DEBUG
    static func _setSecurityCLIReadOverrideForTesting(_ override: (() -> [String: Any]?)?) {
        taskSecurityCLIReadOverride = override
    }

    static func _setSecurityFrameworkReadOverrideForTesting(_ override: ((Bool) -> [String: Any]?)?) {
        taskSecurityFrameworkReadOverride = override
    }

    static func _setSecurityCLIWriteOverrideForTesting(_ override: (([String: Any], String) -> Bool)?) {
        taskSecurityCLIWriteOverride = override
    }

    static func _setNowOverrideForTesting(_ override: (() -> Date)?) {
        taskNowOverride = override
    }

    static func _resetCredentialResolutionStateForTesting() {
        credentialReadLock.lock()
        recentCredentialCacheEntry = nil
        lastSecurityCLIFailureAt = nil
        credentialReadLock.unlock()
        taskSecurityCLIReadOverride = nil
        taskSecurityFrameworkReadOverride = nil
        taskSecurityCLIWriteOverride = nil
        taskNowOverride = nil
    }
    #endif

    static func decodeClaudeOAuthCredentials(from data: Data) -> ClaudeOAuthCredentials? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return decodeClaudeOAuthCredentials(from: json)
    }

    static func decodeClaudeOAuthCredentials(from json: [String: Any]) -> ClaudeOAuthCredentials? {
        guard let oauth = json["claudeAiOauth"] as? [String: Any],
              let rawToken = oauth["accessToken"] as? String else {
            return nil
        }

        let accessToken = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accessToken.isEmpty else {
            return nil
        }

        return ClaudeOAuthCredentials(
            accessToken: accessToken,
            expiresAt: parseExpiresAt(from: oauth["expiresAt"] ?? oauth["expires_at"]),
            scopes: parseScopes(from: oauth["scopes"])
        )
    }

    private static func parseScopes(from rawValue: Any?) -> Set<String> {
        if let scopes = rawValue as? [String] {
            return Set(scopes.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        }

        if let scopeString = rawValue as? String {
            let separators = CharacterSet(charactersIn: ", ")
            let scopes = scopeString
                .components(separatedBy: separators)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return Set(scopes)
        }

        return []
    }

    private static func parseExpiresAt(from rawValue: Any?) -> Date? {
        switch rawValue {
        case let date as Date:
            return date
        case let number as NSNumber:
            return parseEpoch(number.doubleValue)
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if let epoch = Double(trimmed) {
                return parseEpoch(epoch)
            }
            return isoFractional.date(from: trimmed) ?? isoBasic.date(from: trimmed)
        default:
            return nil
        }
    }

    private static func parseEpoch(_ value: Double) -> Date {
        let seconds = value > 1_000_000_000_000 ? value / 1000.0 : value
        return Date(timeIntervalSince1970: seconds)
    }

    // MARK: - Generic Keychain Helpers

    // Even own-service keychain items can trigger a Security dialog when the app's
    // code signature changes between Xcode rebuilds, invalidating prior "Always Allow".
    private static func readString(service: String, account: String, allowInteraction: Bool) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        if !allowInteraction {
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
        }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }

        return string
    }

    private static func saveString(_ value: String, service: String, account: String) {
        let data = Data(value.utf8)

        // Try to update existing item first
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)

        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    private static func deleteItem(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
