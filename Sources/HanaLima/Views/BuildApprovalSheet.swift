import SwiftUI

/// AI asks to delete what it made, or to build something that needs the person's say (more
/// memory than the Mac has, say) (docs/14 §6.1).
struct BuildApprovalSheet: View {
    @Environment(AppModel.self) private var model
    let request: BuildJobs.ApprovalRequest

    var body: some View {
        VStack(spacing: 0) {
            Form {
                switch request.kind {
                case .delete(let vms, _, let networks):
                    Section {
                        ForEach(vms, id: \.self) { Label($0, systemImage: "desktopcomputer") }
                        ForEach(networks, id: \.self) { Label($0, systemImage: "network") }
                    } header: {
                        Text("AI が削除を求めています")
                    } footer: {
                        Text("MCP で作った仮想マシンとネットワークです。仮想マシンはディスクとスナップショットも消え、元に戻せません。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                case .build(_, let plan):
                    Section {
                        ForEach(plan.networks.map(\.network.name), id: \.self) { Label($0, systemImage: "network") }
                        ForEach(plan.vms.map(\.name), id: \.self) { Label($0, systemImage: "desktopcomputer") }
                    } header: {
                        Text("AI が構築を求めています")
                    }
                    Section("確認が要る理由") {
                        ForEach(plan.approvals, id: \.self) { Text(verbatim: $0) }
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("許可しない", role: .cancel) { model.agentHost.buildJobs.deny(request) }
                    .keyboardShortcut(.cancelAction)
                switch request.kind {
                case .delete: Button("削除する", role: .destructive) { model.agentHost.buildJobs.approve(request) }
                case .build: Button("構築する") { model.agentHost.buildJobs.approve(request) }.keyboardShortcut(.defaultAction)
                }
            }
            .padding()
        }
        .frame(width: 480, height: min(260 + 34 * CGFloat(rows), 600))
    }

    private var rows: Int {
        switch request.kind {
        case .delete(let vms, _, let networks): vms.count + networks.count
        case .build(_, let plan): plan.networks.count + plan.vms.count + plan.approvals.count
        }
    }
}
