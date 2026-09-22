import Foundation
import os.log

nonisolated private let logger = Logger(subsystem: "com.ruban.notchi", category: "ClaudeOAuthTokenRefresher")

struct ClaudeOAuthTokenGrant: Equatable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date?
    let scopes: [String]?
}

enum ClaudeOAuthTokenRefreshOutcome: Equatable {
    case granted(ClaudeOAuthTokenGrant)
    // The server refused the refresh token (already rotated or revoked).
    case rejected
    // Network failure or unexpected response; the refresh token was not consumed.
    case unavailable
}

// WHY: Claude Code's access token only lives ~8h and only the CLI refreshes it.
// Users on the Claude desktop app or an IDE extension never run the CLI, so the
// keychain token goes stale and usage stops. Refreshing it ourselves (with the same
// public OAuth client Claude Code uses) keeps usage working for them.
enum ClaudeOAuthTokenRefresher {
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let tokenURLs = [
        URL(string: "https://platform.claude.com/v1/oauth/token")!,
        URL(string: "https://console.anthropic.com/v1/oauth/token")!,
    ]

    static func makeRequest(url: URL, refreshToken: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let body: [String: Any] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func parseGrant(from data: Data, now: Date) -> ClaudeOAuthTokenGrant? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawAccessToken = json["access_token"] as? String else {
            return nil
        }

        let accessToken = rawAccessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accessToken.isEmpty else { return nil }

        let refreshToken = (json["refresh_token"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue
        let scopes = (json["scope"] as? String)?
            .split(separator: " ")
            .map(String.init)

        return ClaudeOAuthTokenGrant(
            accessToken: accessToken,
            refreshToken: refreshToken?.isEmpty == false ? refreshToken : nil,
            expiresAt: expiresIn.map { now.addingTimeInterval($0) },
            scopes: scopes?.isEmpty == false ? scopes : nil
        )
    }

    static func requestGrant(
        refreshToken: String,
        now: Date = Date(),
        send: (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }
    ) async -> ClaudeOAuthTokenRefreshOutcome {
        for url in tokenURLs {
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await send(makeRequest(url: url, refreshToken: refreshToken))
            } catch {
                logger.warning("OAuth refresh request to \(url.host() ?? "?", privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                continue
            }

            guard let httpResponse = response as? HTTPURLResponse else { continue }

            switch httpResponse.statusCode {
            case 200:
                if let grant = parseGrant(from: data, now: now) {
                    logger.info("Refreshed Claude OAuth token via \(url.host() ?? "?", privacy: .public)")
                    return .granted(grant)
                }
                logger.warning("OAuth refresh returned 200 without an access token")
                return .unavailable
            case 400, 401, 403:
                // WHY: don't retry the next endpoint with a token the server already refused.
                logger.warning("OAuth refresh rejected with HTTP \(httpResponse.statusCode)")
                return .rejected
            default:
                logger.warning("OAuth refresh to \(url.host() ?? "?", privacy: .public) returned HTTP \(httpResponse.statusCode)")
                continue
            }
        }

        return .unavailable
    }
}
