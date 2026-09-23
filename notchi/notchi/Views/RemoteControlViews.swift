import SwiftUI

struct RemoteControlBadge: View {
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .panelFont(size: 8, weight: .semibold)
            Text("Remote")
                .panelFont(size: 9, weight: .semibold)
        }
        .foregroundColor(TerminalColors.claudeOrange)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(
            Capsule().fill(TerminalColors.claudeOrange.opacity(0.15))
        )
        .fixedSize()
        .help("Remote Control is on for this session")
    }
}

// Remote Control sessions that are idle send no hook events, so they are listed from the
// Claude desktop app's session metadata instead. Clicking one opens it in the app.
struct RemoteControlSessionsView: View {
    let sessions: [ClaudeDesktopSessionInfo]

    @State private var hoveredId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Remote Control")
                .panelFont(size: 11, weight: .medium)
                .foregroundColor(TerminalColors.secondaryText)
                .padding(.bottom, 4)

            ForEach(sessions) { session in
                Button(action: { ClaudeDesktopSessionTitles.open(session) }) {
                    HStack(spacing: 8) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .panelFont(size: 10, weight: .semibold)
                            .foregroundColor(TerminalColors.claudeOrange)
                        Text(session.displayTitle)
                            .panelFont(size: 12, weight: .medium)
                            .foregroundColor(TerminalColors.primaryText)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text("Idle")
                            .panelFont(size: 10)
                            .foregroundColor(TerminalColors.dimmedText)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                    .background(hoveredId == session.id ? TerminalColors.hoverBackground : Color.clear)
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    if hovering {
                        hoveredId = session.id
                    } else if hoveredId == session.id {
                        hoveredId = nil
                    }
                }
            }
        }
    }
}
