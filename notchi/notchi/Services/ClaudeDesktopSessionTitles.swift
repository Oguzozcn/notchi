import AppKit
import Foundation

struct ClaudeDesktopSessionInfo: Equatable, Identifiable {
    let desktopSessionId: String
    let cliSessionId: String
    let title: String?
    let isRemoteControlEnabled: Bool
    let isArchived: Bool
    let lastActivityAt: Date?

    var id: String { desktopSessionId }

    var displayTitle: String { title ?? String(localized: "Untitled session") }

    // Opens the session in the Claude desktop app.
    var appURL: URL? { URL(string: "claude://claude.ai/epitaxy/\(desktopSessionId)") }
}

// WHY: the Claude desktop app runs folder-less Code sessions in randomly named scratch
// folders, so cwd-based session names are meaningless, and a Remote Control session that is
// idle sends no hook events at all. The app keeps its own per-session metadata (title,
// Remote Control state) in claude-code-sessions/<account>/<org>/local_*.json, keyed by the
// CLI session id that hooks report.
enum ClaudeDesktopSessionTitles {
    private static let rescanInterval: TimeInterval = 10
    private static var sessionsByCLISessionId: [String: ClaudeDesktopSessionInfo] = [:]
    private static var lastScanAt: Date = .distantPast

    static var sessionsDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions", isDirectory: true)
    }

    static func title(forCLISessionId sessionId: String, now: Date = Date()) -> String? {
        refreshIfNeeded(now: now)
        return sessionsByCLISessionId[sessionId]?.title
    }

    static func isRemoteControlEnabled(forCLISessionId sessionId: String, now: Date = Date()) -> Bool {
        refreshIfNeeded(now: now)
        return sessionsByCLISessionId[sessionId]?.isRemoteControlEnabled ?? false
    }

    // Non-archived sessions with Remote Control on, most recently active first.
    static func remoteControlSessions(now: Date = Date()) -> [ClaudeDesktopSessionInfo] {
        refreshIfNeeded(now: now)
        return sessionsByCLISessionId.values
            .filter { $0.isRemoteControlEnabled && !$0.isArchived }
            .sorted { ($0.lastActivityAt ?? .distantPast) > ($1.lastActivityAt ?? .distantPast) }
    }

    static func open(_ session: ClaudeDesktopSessionInfo) {
        guard let url = session.appURL else { return }
        NSWorkspace.shared.open(url)
    }

    // Rescan periodically so renamed, newly titled or newly remote sessions are picked up.
    private static func refreshIfNeeded(now: Date) {
        guard now.timeIntervalSince(lastScanAt) >= rescanInterval else { return }
        sessionsByCLISessionId = Dictionary(
            loadSessions(in: sessionsDirectoryURL).map { ($0.cliSessionId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        lastScanAt = now
    }

    static func loadTitles(in directory: URL) -> [String: String] {
        var titles: [String: String] = [:]
        for session in loadSessions(in: directory) {
            if let title = session.title {
                titles[session.cliSessionId] = title
            }
        }
        return titles
    }

    static func loadSessions(in directory: URL) -> [ClaudeDesktopSessionInfo] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var sessions: [ClaudeDesktopSessionInfo] = []
        for case let url as URL in enumerator
        where url.lastPathComponent.hasPrefix("local_") && url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let session = parseSession(from: data) else {
                continue
            }
            sessions.append(session)
        }
        return sessions
    }

    static func parseTitle(from data: Data) -> (sessionId: String, title: String)? {
        guard let session = parseSession(from: data), let title = session.title else {
            return nil
        }
        return (session.cliSessionId, title)
    }

    static func parseSession(from data: Data) -> ClaudeDesktopSessionInfo? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cliSessionId = json["cliSessionId"] as? String, !cliSessionId.isEmpty else {
            return nil
        }
        let title = (json["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let lastActivityMs = (json["lastActivityAt"] as? NSNumber)?.doubleValue
        return ClaudeDesktopSessionInfo(
            desktopSessionId: json["sessionId"] as? String ?? cliSessionId,
            cliSessionId: cliSessionId,
            title: title?.isEmpty == false ? title : nil,
            isRemoteControlEnabled: json["remoteControlUserEnabled"] as? Bool ?? false,
            isArchived: json["isArchived"] as? Bool ?? false,
            lastActivityAt: lastActivityMs.map { Date(timeIntervalSince1970: $0 / 1000) }
        )
    }
}
