import LimaKit
import SwiftUI

/// A request from AI (an MCP client) to operate VMs, waiting for the person to allow it
/// (docs/14 §6.2). Only this sheet can approve: the client has no way to.
struct AgentApprovalSheet: View {
    @Environment(AppModel.self) private var model
    let plan: VMJobs.Plan
    @State private var approved: [String: Set<GroupConfirmation>] = [:]

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    if plan.steps.isEmpty {
                        Text("この操作の対象になる仮想マシンはありません。").foregroundStyle(.secondary)
                    }
                    ForEach(Array(plan.steps.enumerated()), id: \.element.name) { index, step in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("\(index + 1).").monospacedDigit().foregroundStyle(.secondary)
                                Text(step.name)
                            }
                            ForEach(GroupConfirmation.allCases.filter { step.confirmations[$0] != nil }, id: \.self) { kind in
                                Toggle(kind.title(detail: step.confirmations[kind] ?? ""), isOn: binding(step.name, kind))
                                    .toggleStyle(.checkbox)
                                    .padding(.leading, 20)
                            }
                        }
                    }
                } header: {
                    Text("AI が仮想マシンの操作を求めています: \(actionLabel)")
                } footer: {
                    Text("MCP クライアントからの依頼です。許可した操作だけを、この順に実行します。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !plan.skipped.isEmpty {
                    Section("対象にしない") {
                        ForEach(plan.skipped, id: \.name) { skip in
                            LabeledContent(skip.name) {
                                Text(GroupRunSheet.text(skip.reason)).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("許可しない", role: .cancel) { model.agentHost.vmJobs.deny(plan) }
                    .keyboardShortcut(.cancelAction)
                Button("許可する") { model.agentHost.vmJobs.approve(plan, confirmations: approved) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(plan.steps.isEmpty)
            }
            .padding()
        }
        .frame(width: 520, height: sheetHeight)
    }

    /// Tall enough for the rows, like the group sheet (a fixed height left most of it empty).
    private var sheetHeight: CGFloat {
        let confirmations = plan.steps.reduce(0) { $0 + $1.confirmations.count }
        var height = 170 + 46 * CGFloat(max(plan.steps.count, 1)) + 40 * CGFloat(confirmations)
        if !plan.skipped.isEmpty { height += 50 + 46 * CGFloat(plan.skipped.count) }
        return min(height, 640)
    }

    private var actionLabel: String {
        switch plan.action {
        case .start: String(localized: "起動")
        case .stop: String(localized: "停止")
        case .restart: String(localized: "再起動")
        case .pause: String(localized: "一時停止")
        case .resume: String(localized: "再開")
        case .hibernate: String(localized: "休止")
        case .snapshotCreate: String(localized: "スナップショット「\(plan.tag ?? "")」の作成")
        case .snapshotRestore: String(localized: "スナップショット「\(plan.tag ?? "")」に戻す")
        }
    }

    private func binding(_ name: String, _ kind: GroupConfirmation) -> Binding<Bool> {
        Binding(get: { approved[name]?.contains(kind) ?? false },
                set: { on in
                    if on { approved[name, default: []].insert(kind) } else { approved[name]?.remove(kind) }
                })
    }
}
