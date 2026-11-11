import SwiftUI

/// AI asks to delete VMs and networks it made through MCP (docs/14 §6.1): always the person's call.
struct DeleteApprovalSheet: View {
    @Environment(AppModel.self) private var model
    let request: BuildJobs.DeleteRequest

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    ForEach(request.vms, id: \.self) { Label($0, systemImage: "desktopcomputer") }
                    ForEach(request.networks, id: \.self) { Label($0, systemImage: "network") }
                } header: {
                    Text("AI が削除を求めています")
                } footer: {
                    Text("MCP で作った仮想マシンとネットワークです。仮想マシンはディスクとスナップショットも消え、元に戻せません。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("許可しない", role: .cancel) { model.agentHost.buildJobs.deny(request) }
                    .keyboardShortcut(.cancelAction)
                Button("削除する", role: .destructive) { model.agentHost.buildJobs.approve(request) }
            }
            .padding()
        }
        .frame(width: 480, height: min(220 + 34 * CGFloat(request.vms.count + request.networks.count), 560))
    }
}
