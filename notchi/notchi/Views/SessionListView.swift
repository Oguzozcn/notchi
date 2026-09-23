import SwiftUI

struct SessionListView: View {
    let sessions: [SessionData]
    let titleForSession: (SessionData) -> String
    let selectedSessionId: String?
    @Binding var hoveredSessionId: String?
    let onSelectSession: (String) -> Void
    let onDeleteSession: (String) -> Void
    var isRemoteControl: (SessionData) -> Bool = { _ in false }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Sessions")
                .panelFont(size: 11, weight: .medium)
                .foregroundColor(TerminalColors.secondaryText)
                .padding(.top, 8)
                .padding(.bottom, 8)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(sessions) { session in
                        SessionRowView(
                            session: session,
                            title: titleForSession(session),
                            isSelected: session.id == selectedSessionId,
                            isHovered: session.id == hoveredSessionId,
                            onTap: { onSelectSession(session.id) },
                            onHover: { hovering in
                                if hovering {
                                    hoveredSessionId = session.id
                                } else if hoveredSessionId == session.id {
                                    // SwiftUI may deliver a leave after another row's enter; only the owner clears.
                                    hoveredSessionId = nil
                                }
                            },
                            onDelete: { onDeleteSession(session.id) },
                            isRemoteControl: isRemoteControl(session)
                        )
                    }
                }
            }
            .frame(maxHeight: 200)
        }
    }
}
