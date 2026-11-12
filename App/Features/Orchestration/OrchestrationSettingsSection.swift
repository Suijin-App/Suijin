import MercuryUI
import SwiftUI

/// Settings > Agents: orchestration status and the opt-in user-level skill.
struct OrchestrationSettingsSection: View {
    @Environment(AppModel.self) private var model
    @State private var userSkillInstalled = FileManager.default.fileExists(atPath: OrchestrationLaunch.userClaudeSkill().path)
    @State private var error: String?

    var body: some View {
        Section {
            LabeledContent("Broker") {
                let orchestration = model.runtimes.orchestration
                if orchestration.isConnected {
                    Text("Connected").foregroundStyle(.secondary)
                } else if let problem = orchestration.problem {
                    Text(verbatim: problem).foregroundStyle(MercuryColor.warningText).lineLimit(3)
                } else {
                    Text("Not connected").foregroundStyle(.secondary)
                }
            }
            Toggle("Also install the orchestration skill in ~/.claude/skills", isOn: Binding(
                get: { userSkillInstalled },
                set: { install in
                    do {
                        try OrchestrationLaunch.setUserClaudeSkill(installed: install)
                        userSkillInstalled = install
                        error = nil
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
            ))
            if let error {
                Text(verbatim: error).font(.caption).foregroundStyle(MercuryColor.warningText)
            }
        } header: {
            Text("Orchestration")
        } footer: {
            Text("Agents in Mercury's terminals can start worker agents with the `mercury` command and get their results back. Mercury's Claude sessions already load the guide; the toggle adds it to Claude Code outside Mercury too, where `mercury` itself does not work.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
