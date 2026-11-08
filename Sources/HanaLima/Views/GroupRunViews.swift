import LimaKit
import SwiftUI

/// The plan of a group-wide operation, shown before it runs (docs/12 5.3): the VMs in order,
/// the confirmations some need, the ones left out and why.
struct GroupRunSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: GroupRunRequest
    @State private var approved: [String: Set<GroupConfirmation>] = [:]

    private var plan: GroupPlan { request.plan }

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
                                if step.resumes {
                                    Text("休止から再開").font(.caption).foregroundStyle(.indigo)
                                }
                            }
                            ForEach(GroupConfirmation.allCases.filter { step.confirmations[$0] != nil }, id: \.self) { kind in
                                Toggle(isOn: binding(step.name, kind)) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(confirmationTitle(kind, detail: step.confirmations[kind] ?? ""))
                                        if kind == .allowNetworkConflict {
                                            Text(step.confirmations[kind] ?? "").font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .toggleStyle(.checkbox)
                                .padding(.leading, 20)
                            }
                        }
                    }
                } header: {
                    Text(stepsHeader)
                } footer: {
                    if plan.steps.contains(where: { !$0.confirmations.isEmpty }) {
                        Text("確認の項目にチェックを付けた仮想マシンだけを起動します。チェックの無いものは飛ばします。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !plan.skipped.isEmpty {
                    Section("対象にしない") {
                        ForEach(plan.skipped, id: \.name) { skip in
                            LabeledContent(skip.name) {
                                Text(Self.text(skip.reason)).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                            }
                        }
                    }
                }
                if let note = resourceNote {
                    Section {
                        Label(note.text, systemImage: note.warning ? "exclamationmark.triangle" : "info.circle")
                            .foregroundStyle(note.warning ? .orange : .secondary)
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("キャンセル", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(plan.action.label) {
                    model.startGroupRun(request, approved: approved)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(plan.steps.isEmpty)
            }
            .padding()
        }
        .frame(width: 520, height: 520)
    }

    private var stepsHeader: String {
        switch plan.action {
        case .start: String(localized: "「\(request.group)」の仮想マシンを、この順に起動します")
        case .stop: String(localized: "「\(request.group)」の仮想マシンを、この順に停止します")
        case .hibernate: String(localized: "「\(request.group)」の仮想マシンを、この順に休止します")
        }
    }

    private func binding(_ name: String, _ kind: GroupConfirmation) -> Binding<Bool> {
        Binding(get: { approved[name]?.contains(kind) ?? false },
                set: { on in
                    if on { approved[name, default: []].insert(kind) } else { approved[name]?.remove(kind) }
                })
    }

    private func confirmationTitle(_ kind: GroupConfirmation, detail: String) -> String {
        switch kind {
        case .removeDeletedNICs: String(localized: "削除したネットワーク（\(detail)）の NIC を外して起動する")
        case .allowNetworkConflict: String(localized: "socket_vmnet と HanaLima の仮想ネットワークを同時に使って起動する")
        }
    }

    /// Memory for a start; free space for a hibernation (docs/12 5.3). Notes, not blockers:
    /// a VZ guest uses only the memory it touches, and each hibernation checks its own space.
    private var resourceNote: (text: String, warning: Bool)? {
        let gib = Double(1 << 30)
        switch plan.action {
        case .start:
            guard plan.memoryToStart > 0 else { return nil }
            let physical = Int64(ProcessInfo.processInfo.physicalMemory)
            let total = request.runningMemory + plan.memoryToStart
            let text = request.runningMemory > 0
                ? String(localized: "起動する仮想マシンのメモリの合計は \(Formatting.bytes(plan.memoryToStart)) です（実行中の仮想マシンは \(Formatting.bytes(request.runningMemory))、この Mac の物理メモリは \(Formatting.bytes(physical))）。")
                : String(localized: "起動する仮想マシンのメモリの合計は \(Formatting.bytes(plan.memoryToStart)) です（この Mac の物理メモリは \(Formatting.bytes(physical))）。")
            return (text, total > physical)
        case .hibernate:
            guard !plan.steps.isEmpty else { return nil }
            let needed = plan.steps.reduce(Int64(0)) { $0 + $1.memory } + Int64(gib)
            guard let free = request.freeSpace else { return nil }
            let text = String(localized: "保存には最大 \(Formatting.bytes(needed)) を使います（空き \(Formatting.bytes(free))）。")
            return (text, free < needed)
        case .stop:
            return nil
        }
    }

    static func text(_ reason: GroupSkipReason) -> String {
        switch reason {
        case .alreadyRunning: String(localized: "実行中です。")
        case .alreadyStopped: String(localized: "停止しています。")
        case .hibernated: String(localized: "休止中です。")
        case .busy: String(localized: "ほかの処理の最中です。")
        case .notHanaLimaDriver: String(localized: "休止できるのは HanaLima のドライバーで動く仮想マシンだけです。")
        case .notReady: String(localized: "起動の完了を待っています。")
        case .inOtherRun: String(localized: "ほかのグループの一括操作の対象です。")
        case .refused(let why): why
        case .deletedNetworksWhileHibernated:
            String(localized: "削除したネットワークの NIC があるので、休止した状態から再開できません。「保存した状態を捨てる…」のあとで起動してください。")
        }
    }
}

/// Progress and results of a group-wide operation, on the group page.
struct GroupRunPanel: View {
    @Environment(AppModel.self) private var model
    let group: String
    let run: GroupRunState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(run.action.label).font(.headline)
                Text(status).foregroundStyle(.secondary)
                Spacer()
                if run.finished {
                    Button("閉じる") { model.clearGroupRun(group) }
                } else {
                    Button("中止") { model.cancelGroupRun(group) }
                        .disabled(run.cancelRequested)
                        .help("いま処理している仮想マシンが終わったら、次へ進まずに止めます。")
                }
            }
            ForEach(run.plan.steps, id: \.name) { step in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    icon(for: step)
                    Text(step.name)
                    if let text = outcomeText(step) {
                        Text(text).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                    }
                    Spacer()
                    if case .failed? = outcome(step), step.resumes, model.isHibernated(step.name) {
                        Button("保存した状態を捨てて起動…") { model.offerDiscardAfterFailedResume(step.name) }
                            .controlSize(.small)
                            .disabled(model.isBusy(step.name))
                    }
                }
                .font(.callout)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .padding([.horizontal, .top])
    }

    private var status: String {
        if !run.finished {
            if run.cancelRequested { return String(localized: "中止しています…") }
            return run.current.map { String(localized: "\($0) を処理しています…") } ?? ""
        }
        let failed = run.results.filter { if case .failed = $0.outcome { true } else { false } }.count
        return failed == 0 ? String(localized: "終わりました") : String(localized: "終わりました（失敗 \(failed) 台）")
    }

    private func outcome(_ step: GroupPlan.Step) -> GroupStepOutcome? {
        run.results.first { $0.name == step.name }?.outcome
    }

    @ViewBuilder
    private func icon(for step: GroupPlan.Step) -> some View {
        switch outcome(step) {
        case .done?: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed?: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .skipped?, .notConfirmed?, .notRun?: Image(systemName: "minus.circle").foregroundStyle(.secondary)
        case nil:
            if run.current == step.name && !run.finished {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: "circle").foregroundStyle(.tertiary)
            }
        }
    }

    private func outcomeText(_ step: GroupPlan.Step) -> String? {
        switch outcome(step) {
        case .done?: nil
        case .skipped(let why)?: String(localized: "飛ばしました: \(why)")
        case .notConfirmed?: String(localized: "確認にチェックが無いので飛ばしました。")
        case .failed(let why)?: why
        case .notRun?: String(localized: "行いませんでした。")
        case nil: nil
        }
    }
}
