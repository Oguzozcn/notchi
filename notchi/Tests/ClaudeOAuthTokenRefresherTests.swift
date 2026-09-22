import Foundation
import XCTest
@testable import notchi

final class ClaudeOAuthTokenRefresherTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testMakeRequestSendsRefreshGrantWithClaudeCodeClientID() throws {
        let request = ClaudeOAuthTokenRefresher.makeRequest(
            url: ClaudeOAuthTokenRefresher.tokenURLs[0],
            refreshToken: "refresh-1"
        )

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String]
        )
        XCTAssertEqual(body, [
            "grant_type": "refresh_token",
            "refresh_token": "refresh-1",
            "client_id": ClaudeOAuthTokenRefresher.clientID,
        ])
    }

    func testParseGrantReadsRotatedTokenExpiryAndScopes() throws {
        let data = Data(#"{"access_token":"access-2","refresh_token":"refresh-2","expires_in":28800,"scope":"user:inference user:profile"}"#.utf8)

        let grant = try XCTUnwrap(ClaudeOAuthTokenRefresher.parseGrant(from: data, now: now))

        XCTAssertEqual(grant.accessToken, "access-2")
        XCTAssertEqual(grant.refreshToken, "refresh-2")
        XCTAssertEqual(grant.expiresAt, now.addingTimeInterval(28800))
        XCTAssertEqual(grant.scopes, ["user:inference", "user:profile"])
    }

    func testParseGrantRejectsMissingAccessToken() {
        let data = Data(#"{"refresh_token":"refresh-2"}"#.utf8)
        XCTAssertNil(ClaudeOAuthTokenRefresher.parseGrant(from: data, now: now))
    }

    func testRequestGrantStopsOnRejectionWithoutTryingNextEndpoint() async {
        var requestedURLs: [URL] = []

        let outcome = await ClaudeOAuthTokenRefresher.requestGrant(refreshToken: "refresh-1", now: now) { request in
            requestedURLs.append(request.url!)
            return (Data(#"{"error":"invalid_grant"}"#.utf8), Self.response(for: request, status: 400))
        }

        XCTAssertEqual(outcome, .rejected)
        XCTAssertEqual(requestedURLs, [ClaudeOAuthTokenRefresher.tokenURLs[0]])
    }

    func testRequestGrantFallsBackToNextEndpointOnServerError() async {
        var requestedURLs: [URL] = []

        let outcome = await ClaudeOAuthTokenRefresher.requestGrant(refreshToken: "refresh-1", now: now) { request in
            requestedURLs.append(request.url!)
            if requestedURLs.count == 1 {
                return (Data(), Self.response(for: request, status: 503))
            }
            return (Data(#"{"access_token":"access-2","expires_in":60}"#.utf8), Self.response(for: request, status: 200))
        }

        XCTAssertEqual(outcome, .granted(ClaudeOAuthTokenGrant(
            accessToken: "access-2",
            refreshToken: nil,
            expiresAt: now.addingTimeInterval(60),
            scopes: nil
        )))
        XCTAssertEqual(requestedURLs, ClaudeOAuthTokenRefresher.tokenURLs)
    }

    func testRequestGrantIsUnavailableWhenEveryEndpointFails() async {
        let outcome = await ClaudeOAuthTokenRefresher.requestGrant(refreshToken: "refresh-1", now: now) { _ in
            throw URLError(.notConnectedToInternet)
        }

        XCTAssertEqual(outcome, .unavailable)
    }

    func testMergeGrantPreservesUnrelatedCredentialFields() throws {
        let json: [String: Any] = [
            "claudeAiOauth": [
                "accessToken": "access-1",
                "refreshToken": "refresh-1",
                "expiresAt": 1,
                "scopes": ["user:profile"],
                "subscriptionType": "max",
            ],
            "otherTopLevel": true,
        ]
        let grant = ClaudeOAuthTokenGrant(
            accessToken: "access-2",
            refreshToken: "refresh-2",
            expiresAt: now,
            scopes: nil
        )

        let merged = KeychainManager.mergeGrant(grant, into: json)
        let oauth = try XCTUnwrap(merged["claudeAiOauth"] as? [String: Any])

        XCTAssertEqual(oauth["accessToken"] as? String, "access-2")
        XCTAssertEqual(oauth["refreshToken"] as? String, "refresh-2")
        XCTAssertEqual(oauth["expiresAt"] as? Int64, Int64(now.timeIntervalSince1970 * 1000))
        XCTAssertEqual(oauth["scopes"] as? [String], ["user:profile"])
        XCTAssertEqual(oauth["subscriptionType"] as? String, "max")
        XCTAssertEqual(merged["otherTopLevel"] as? Bool, true)

        let roundTripped = try XCTUnwrap(KeychainManager.decodeClaudeOAuthCredentials(
            from: JSONSerialization.data(withJSONObject: merged)
        ))
        XCTAssertEqual(roundTripped.accessToken, "access-2")
        XCTAssertEqual(roundTripped.expiresAt, now)
    }

    func testDecodeRefreshTokenIgnoresBlankValues() {
        XCTAssertNil(KeychainManager.decodeRefreshToken(from: ["claudeAiOauth": ["refreshToken": "  "]]))
        XCTAssertEqual(
            KeychainManager.decodeRefreshToken(from: ["claudeAiOauth": ["refreshToken": " refresh-1 "]]),
            "refresh-1"
        )
    }

    func testPlanLabelIncludesTierMultiplier() {
        XCTAssertEqual(KeychainManager.planLabel(subscriptionType: "max", rateLimitTier: "default_claude_max_5x"), "Max (5x)")
        XCTAssertEqual(KeychainManager.planLabel(subscriptionType: "max", rateLimitTier: "default_claude_max_20x"), "Max (20x)")
        XCTAssertEqual(KeychainManager.planLabel(subscriptionType: "pro", rateLimitTier: "default_claude_pro"), "Pro")
        XCTAssertEqual(KeychainManager.planLabel(subscriptionType: "pro", rateLimitTier: nil), "Pro")
        XCTAssertNil(KeychainManager.planLabel(subscriptionType: nil, rateLimitTier: "default_claude_max_5x"))
    }

    private static func response(for request: URLRequest, status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }
}
