import Foundation
import XCTest
@testable import notchi

final class ClaudeDesktopSessionTitlesTests: XCTestCase {
    func testParseTitleReadsCLISessionIdAndTitle() throws {
        let data = Data(#"{"sessionId":"local_1","cliSessionId":"cli-1","title":"  Fix usage bar  "}"#.utf8)

        let parsed = try XCTUnwrap(ClaudeDesktopSessionTitles.parseTitle(from: data))

        XCTAssertEqual(parsed.sessionId, "cli-1")
        XCTAssertEqual(parsed.title, "Fix usage bar")
    }

    func testParseTitleIgnoresMissingOrBlankTitle() {
        XCTAssertNil(ClaudeDesktopSessionTitles.parseTitle(from: Data(#"{"cliSessionId":"cli-1"}"#.utf8)))
        XCTAssertNil(ClaudeDesktopSessionTitles.parseTitle(from: Data(#"{"cliSessionId":"cli-1","title":" "}"#.utf8)))
        XCTAssertNil(ClaudeDesktopSessionTitles.parseTitle(from: Data(#"{"title":"No id"}"#.utf8)))
    }

    func testParseSessionReadsRemoteControlStateAndDesktopId() throws {
        let data = Data(#"{"sessionId":"local_1","cliSessionId":"cli-1","title":"Plan","remoteControlUserEnabled":true,"isArchived":false,"lastActivityAt":1790180185935}"#.utf8)

        let session = try XCTUnwrap(ClaudeDesktopSessionTitles.parseSession(from: data))

        XCTAssertEqual(session.desktopSessionId, "local_1")
        XCTAssertTrue(session.isRemoteControlEnabled)
        XCTAssertFalse(session.isArchived)
        XCTAssertEqual(try XCTUnwrap(session.lastActivityAt).timeIntervalSince1970, 1_790_180_185.935, accuracy: 0.001)
        XCTAssertEqual(session.appURL?.absoluteString, "claude://claude.ai/epitaxy/local_1")
    }

    func testParseSessionDefaultsRemoteControlOffAndKeepsUntitledSessions() throws {
        let data = Data(#"{"sessionId":"local_2","cliSessionId":"cli-2"}"#.utf8)

        let session = try XCTUnwrap(ClaudeDesktopSessionTitles.parseSession(from: data))

        XCTAssertFalse(session.isRemoteControlEnabled)
        XCTAssertNil(session.title)
    }

    func testLoadTitlesScansNestedSessionFilesOnly() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let nested = root.appendingPathComponent("account/org", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data(#"{"cliSessionId":"cli-1","title":"First"}"#.utf8)
            .write(to: nested.appendingPathComponent("local_a.json"))
        try Data(#"{"cliSessionId":"cli-2","title":"Second"}"#.utf8)
            .write(to: nested.appendingPathComponent("local_b.json"))
        try Data(#"{"cliSessionId":"cli-3","title":"Ignored"}"#.utf8)
            .write(to: nested.appendingPathComponent("scheduled-tasks.json"))

        XCTAssertEqual(
            ClaudeDesktopSessionTitles.loadTitles(in: root),
            ["cli-1": "First", "cli-2": "Second"]
        )
    }
}
