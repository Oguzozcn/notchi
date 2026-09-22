import Foundation

// WHY: the Claude desktop app runs folder-less Code sessions in randomly named scratch
// folders, so cwd-based session names are meaningless. The app keeps its own session
// title in claude-code-sessions/<account>/<org>/local_*.json, keyed by the CLI session id
// that hooks report.
enum ClaudeDesktopSessionTitles {
    private static let rescanInterval: TimeInterval = 10
    private static var titlesByCLISessionId: [String: String] = [:]
    private static var lastScanAt: Date = .distantPast

    static var sessionsDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions", isDirectory: true)
    }

    static func title(forCLISessionId sessionId: String, now: Date = Date()) -> String? {
        // Rescan periodically so renamed or newly auto-titled sessions are picked up.
        if now.timeIntervalSince(lastScanAt) >= rescanInterval {
            titlesByCLISessionId = loadTitles(in: sessionsDirectoryURL)
            lastScanAt = now
        }
        return titlesByCLISessionId[sessionId]
    }

    static func loadTitles(in directory: URL) -> [String: String] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return [:]
        }

        var titles: [String: String] = [:]
        for case let url as URL in enumerator
        where url.lastPathComponent.hasPrefix("local_") && url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let (sessionId, title) = parseTitle(from: data) else {
                continue
            }
            titles[sessionId] = title
        }
        return titles
    }

    static func parseTitle(from data: Data) -> (sessionId: String, title: String)? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessionId = json["cliSessionId"] as? String, !sessionId.isEmpty,
              let rawTitle = json["title"] as? String else {
            return nil
        }
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : (sessionId, title)
    }
}
