import SwiftUI

struct MeetingTruthToolCallingABView: View {
    @EnvironmentObject private var store: LabStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                readinessCard

                if let result = store.meetingTruthToolCallingABResult, result.hasContent {
                    comparisonSummary(result: result)
                    abColumns(result: result)
                    trustMetrics(result: result)
                    openClawExample(result: result)
                    evidenceOverview(result: result)
                    toolCallTimeline(records: result.toolCalling.ledger?.toolCallRecords ?? [])
                    resultImpact(result: result)
                } else {
                    emptyState
                }
            }
            .padding(24)
        }
    }

    private var header: some View {
        Surface {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: "function")
                    .font(.system(size: 34))
                    .foregroundStyle(.blue)

                VStack(alignment: .leading, spacing: 6) {
                    Text("直接生成 vs 证据核验后生成")
                        .font(.title.weight(.semibold))
                    Text("同一批 MeetingTruth 输入跑两遍：直接生成更快；证据核验更慢，但能发现并修正高风险转写错误。")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 8) {
                    if let result = store.meetingTruthToolCallingABResult {
                        HStack(spacing: 8) {
                            ABMetric(title: "直接耗时", value: durationText(result.promptOnly.durationSeconds))
                            ABMetric(title: "核验耗时", value: durationText(result.toolCalling.durationSeconds))
                            ABMetric(title: "核验工具", value: "\(result.toolCalling.toolFunctionStepCount)")
                        }
                    } else {
                        HStack(spacing: 8) {
                            ABMetric(title: "直接耗时", value: "-")
                            ABMetric(title: "核验耗时", value: "-")
                            ABMetric(title: "核验工具", value: "0")
                        }
                    }

                    Button {
                        store.runMeetingTruthToolCallingABTest()
                    } label: {
                        Label(
                            store.isRunningMeetingTruthToolAB ? "AB 运行中" : "运行可信度 AB",
                            systemImage: store.isRunningMeetingTruthToolAB ? "hourglass" : "play.circle"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isMeetingTruthTaskRunning || !store.canRunMeetingTruthCentralReview)

                    Button {
                        store.loadMeetingTruthOpenClawEvidenceDemo()
                    } label: {
                        Label("加载 OpenClaw 样例", systemImage: "wand.and.stars")
                    }
                    .buttonStyle(.bordered)
                    .disabled(store.isMeetingTruthTaskRunning)
                }
            }
        }
    }

    private var readinessCard: some View {
        Surface {
            HStack(alignment: .top, spacing: 12) {
                ABReadinessItem(
                    title: "输入",
                    value: "\(store.meetingTruthTranscriptSources.count) 路 ASR · \(store.meetingTruthMaterials.count) 份资料",
                    state: store.meetingTruthTranscriptSources.isEmpty && store.meetingTruthMaterials.isEmpty ? .waiting : .ready
                )
                ABReadinessItem(
                    title: "原图证据",
                    value: "\(store.meetingTruthVisualEvidence.count) 条 rawVision",
                    state: store.meetingTruthImageMaterials.isEmpty ? .neutral : (store.meetingTruthVisualEvidence.isEmpty ? .warning : .ready)
                )
                ABReadinessItem(
                    title: "事实账本",
                    value: "\(store.meetingTruthFactDecisions.count) 个事实裁决",
                    state: store.meetingTruthFactDecisions.isEmpty ? .waiting : .ready
                )
                ABReadinessItem(
                    title: "AB 结果",
                    value: store.meetingTruthToolCallingABResult == nil ? "未生成" : "已生成",
                    state: store.meetingTruthToolCallingABResult == nil ? .waiting : .ready
                )
            }
        }
    }

    private func comparisonSummary(result: MeetingTruthToolCallingABResult) -> some View {
        Surface {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("AB 结论：\(result.outcomeKind.title)", systemImage: "chart.bar.doc.horizontal")
                            .font(.headline)
                        Text(result.outcomeDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    ABBadge(
                        text: result.outcomeKind.title,
                        color: outcomeColor(result.outcomeKind)
                    )
                    ABBadge(
                        text: result.nativeToolCallingObserved ? "证据工具已执行" : "未观察到执行工具",
                        color: result.nativeToolCallingObserved ? .green : .orange
                    )
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ABStatCard(title: "直接生成耗时", value: durationText(result.promptOnly.durationSeconds), detail: branchStateText(result.promptOnly))
                    ABStatCard(title: "证据核验耗时", value: durationText(result.toolCalling.durationSeconds), detail: branchStateText(result.toolCalling))
                    ABStatCard(title: "直接生成 token", value: tokenText(result.promptOnly.tokenUsage), detail: result.promptOnly.tokenUsage == nil ? "endpoint 未返回 usage" : "实测 usage")
                    ABStatCard(title: "证据核验 token", value: tokenText(result.toolCalling.tokenUsage), detail: result.toolCalling.tokenUsage == nil ? "endpoint 未返回 usage" : "包含工具选择与最终复核")
                }

                ABBullet(text: result.timingSummary, color: .blue)
                ABBullet(text: "直接生成更快；证据核验更慢，但能发现并修正高风险转写错误。前提是工具裁决、最终 ledger 和纪要变化必须一致。", color: outcomeColor(result.outcomeKind))
                ABBullet(text: "短样例中证据核验 token 和耗时更高；只有确实产生证据链、自动修正或人工确认任务时，才算换来了可信度收益。长会议 token 优化需要后续用长会议样本验证。", color: .orange)

                if !result.resultDifferences.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("结果差异")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(Array(result.resultDifferences.enumerated()), id: \.offset) { _, item in
                            ABBullet(text: item, color: .green)
                        }
                    }
                }

                if !result.effectDifferences.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("效果差异")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(Array(result.effectDifferences.enumerated()), id: \.offset) { _, item in
                            ABBullet(text: item, color: .orange)
                        }
                    }
                }
            }
        }
    }

    private func abColumns(result: MeetingTruthToolCallingABResult) -> some View {
        HStack(alignment: .top, spacing: 16) {
            ABModeColumn(
                title: result.promptOnly.title,
                subtitle: "低风险内容的快速路线",
                icon: "text.quote",
                tint: .secondary,
                summary: result.promptOnly.modeDescription,
                rows: branchRows(result.promptOnly, isToolCalling: false)
            )
            ABModeColumn(
                title: result.toolCalling.title,
                subtitle: "高风险事实的可信路线",
                icon: "function",
                tint: .blue,
                summary: result.toolCalling.modeDescription,
                rows: branchRows(result.toolCalling, isToolCalling: true)
            )
        }
    }

    private func trustMetrics(result: MeetingTruthToolCallingABResult) -> some View {
        Surface {
            VStack(alignment: .leading, spacing: 12) {
                Label("可信度指标", systemImage: "checkmark.shield")
                    .font(.headline)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ABStatCard(title: "耗时", value: "\(durationText(result.promptOnly.durationSeconds)) / \(durationText(result.toolCalling.durationSeconds))", detail: "直接 / 核验")
                    ABStatCard(title: "token", value: "\(tokenText(result.promptOnly.tokenUsage)) / \(tokenText(result.toolCalling.tokenUsage))", detail: "直接 / 核验")
                    ABStatCard(title: "发现转写差异数", value: "\(result.toolCalling.asrDifferenceCount)", detail: "多路 ASR 候选差异")
                    ABStatCard(title: "自动修正数", value: "\(result.toolCalling.automaticCorrectionCount)", detail: "可自动裁决并修正")
                    ABStatCard(title: "需要确认数", value: "\(result.toolCalling.confirmationNeededCount)", detail: "仍需人工判断")
                    ABStatCard(title: "证据链数量", value: "\(result.toolCalling.evidenceChainCount)", detail: "材料/图片/ASR/上下文")
                    ABStatCard(title: "最终纪要变化数", value: "\(result.toolCalling.finalMinutesChangeCount)", detail: "写入或修正的位置")
                    ABStatCard(title: "工具函数步骤数", value: "\(result.toolCalling.toolFunctionStepCount)", detail: "Swift 已执行步骤")
                    ABStatCard(title: "多模态证据数量", value: "\(result.toolCalling.multimodalEvidenceCount)", detail: "材料/图片/rawVision")
                    ABStatCard(title: "直接生成未处理风险项", value: "\(result.promptOnly.unhandledRiskItemCount)", detail: "缺证据链或需确认")
                }
            }
        }
    }

    private func openClawExample(result: MeetingTruthToolCallingABResult) -> some View {
        Surface {
            VStack(alignment: .leading, spacing: 10) {
                Label("OpenClaw 样例", systemImage: "text.magnifyingglass")
                    .font(.headline)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ABOverviewBlock(
                        title: "直接生成",
                        text: "可能写成 OpenCloud / OpenCL；速度和 token 更少，但不主动拆解三路 ASR 差异，也没有稳定证据链。",
                        tint: .secondary
                    )
                    ABOverviewBlock(
                        title: "证据核验",
                        text: "发现 OpenClaw / OpenCloud / OpenCL 差异；材料和图片均支持 OpenClaw；系统自动修正为 OpenClaw；最终纪要写入 OpenClaw；无需人工确认。",
                        tint: .blue
                    )
                }
            }
        }
    }

    private func toolCallTimeline(records: [MeetingTruthToolCallRecord]) -> some View {
        Surface {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("证据裁决工具链", systemImage: "list.bullet.rectangle")
                        .font(.headline)
                    Spacer()
                    Text("\(records.count) 条")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                if records.isEmpty {
                    EmptyStateView(
                        systemImage: "function",
                        title: "本轮没有工具调用流水",
                        message: "如果证据核验分支也没有工具记录，说明当前 endpoint 没有返回原生 tool_calls，或模型判断无需调用工具。"
                    )
                    .frame(minHeight: 180)
                } else {
                    toolAuditOverview(records: records)
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(records) { record in
                            ABToolCallRow(record: record)
                        }
                    }
                }
            }
        }
    }

    private func toolAuditOverview(records: [MeetingTruthToolCallRecord]) -> some View {
        let summary = MeetingTruthToolAuditSummary.make(from: records)
        return VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ABOverviewBlock(title: "调用总数", text: "\(summary.totalCount) 次；已执行 \(summary.executedCount) 步", tint: .blue)
                ABOverviewBlock(title: "原生调用", text: "\(summary.nativeCount) 次；fallback \(summary.fallbackCount)，auto \(summary.autoCount)", tint: summary.nativeCount > 0 ? .green : .orange)
                ABOverviewBlock(title: "停止原因", text: "\(summary.stopTitle)\n\(summary.stopDetail)", tint: summary.missingRequiredTools.isEmpty ? .green : .orange)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(summary.rows) { row in
                    HStack(alignment: .top, spacing: 8) {
                        ABBadge(text: "\(row.count) 次", color: toolAuditRowColor(row))
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(row.title)
                                    .font(.caption.weight(.semibold))
                                ABBadge(text: row.stateText, color: toolAuditRowColor(row))
                            }
                            Text(row.callReason)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if row.count > 0 {
                                Text("native \(row.nativeCount) · fallback \(row.fallbackCount) · auto \(row.autoCount) · executed \(row.executedCount) · skipped \(row.skippedCount) · failed \(row.failedCount)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(.blue.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func toolAuditRowColor(_ row: MeetingTruthToolAuditSummary.Row) -> Color {
        switch row.stateKind {
        case .called:
            row.failedCount > 0 ? .red : .green
        case .missing:
            .orange
        case .conditional:
            .secondary
        }
    }

    private func evidenceOverview(result: MeetingTruthToolCallingABResult) -> some View {
        let records = result.toolCalling.ledger?.toolCallRecords ?? []
        let conflicts = records.flatMap { $0.asrConflicts ?? [] }
        let scores = records.flatMap { $0.candidateScores ?? [] }
        let decisions = records.compactMap(\.factDecision)
        let reviewTasks = records.compactMap(\.humanReviewTask)
        let affectedTexts = records.compactMap(\.affectedMinutesText)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        return Surface {
            VStack(alignment: .leading, spacing: 12) {
                Label("用户可读裁决摘要", systemImage: "checklist.checked")
                    .font(.headline)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ABOverviewBlock(
                        title: "本轮判定",
                        text: "\(result.outcomeKind.title)：\(result.outcomeDetail)",
                        tint: outcomeColor(result.outcomeKind)
                    )
                    ABOverviewBlock(
                        title: "裁决一致性",
                        text: result.toolCalling.verificationAnomalyCount == 0
                            ? "工具裁决与最终 ledger 暂未发现结构性矛盾。"
                            : "发现 \(result.toolCalling.verificationAnomalyCount) 处结构性矛盾：工具要求冲突/确认/拒绝，但最终 ledger 没有一致阻塞或解释。",
                        tint: result.toolCalling.verificationAnomalyCount == 0 ? .green : .red
                    )
                    ABOverviewBlock(
                        title: "高风险事实列表",
                        text: conflicts.isEmpty
                            ? "暂无高风险 ASR 差异。"
                            : conflicts.prefix(4).map { "\($0.conflictType)：\($0.candidates.joined(separator: " / "))；影响纪要：\($0.impactsMinutes ? "是" : "否")" }.joined(separator: "\n"),
                        tint: .red
                    )
                    ABOverviewBlock(
                        title: "自动修正记录",
                        text: decisions.filter { $0.status == .corrected }.isEmpty
                            ? "暂无自动修正。"
                            : decisions.filter { $0.status == .corrected }.prefix(4).map { "\($0.correctedFrom.joined(separator: " / ")) -> \($0.finalText)：\($0.explanation)" }.joined(separator: "\n"),
                        tint: .green
                    )
                    ABOverviewBlock(
                        title: "候选评分结论",
                        text: scores.isEmpty
                            ? "暂无候选评分。"
                            : scores.prefix(6).map { "\($0.candidate)：\(Int(($0.score * 100).rounded())) 分；\($0.recommendedDecision.title)" }.joined(separator: "\n"),
                        tint: .blue
                    )
                    ABOverviewBlock(
                        title: "人工确认队列",
                        text: reviewTasks.isEmpty
                            ? "当前证据足够，未生成新的人工确认任务。"
                            : reviewTasks.prefix(4).map { "\($0.question)\n影响：\($0.impact)" }.joined(separator: "\n\n"),
                        tint: .orange
                    )
                }

                if !affectedTexts.isEmpty {
                    ABInfoBlock(title: "最终纪要受影响的位置", text: affectedTexts.joined(separator: "\n"))
                }
            }
        }
    }

    private func resultImpact(result: MeetingTruthToolCallingABResult) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Surface {
                VStack(alignment: .leading, spacing: 10) {
                    Label("最终裁决对照", systemImage: "scale.3d")
                        .font(.headline)

                    ABBranchImpactBlock(title: result.promptOnly.title, branch: result.promptOnly, tint: .secondary)
                    ABBranchImpactBlock(title: result.toolCalling.title, branch: result.toolCalling, tint: .blue)
                }
            }

            Surface {
                VStack(alignment: .leading, spacing: 10) {
                    Label("效果怎么看", systemImage: "eye")
                        .font(.headline)
                    ABBullet(
                        text: "直接生成可以给最终结果，速度更快、token 更少；但看不到模型是否真的拆解了 ASR 差异、查证图片/材料、评分候选并裁决事实。",
                        color: .secondary
                    )
                    ABBullet(
                        text: "证据核验把差异候选、证据链、候选分数、自动修正和人工确认任务写入 ledger，可复查、可录屏、可给评委看。",
                        color: .blue
                    )
                    ABBullet(
                        text: result.outcomeKind == .verificationAnomaly
                            ? "本轮出现核验异常，不能把工具步骤数当成可信度收益；要先修正裁决一致性。"
                            : result.outcomeKind == .noVisibleGain
                                ? "本轮无明显收益：最终采信文本没有明显变化，证据核验只能算审计成本，不能包装成结果提升。"
                                : "本轮证据核验确实减少风险、产生修正，或改变了最终纪要中的高风险事实。",
                        color: outcomeColor(result.outcomeKind)
                    )
                    ABBullet(
                        text: result.nativeToolCallingObserved
                            ? "本轮证据核验分支实际执行了 \(result.toolCalling.toolFunctionStepCount) 个工具函数步骤。"
                            : "本轮未观察到执行工具，需要确认当前 Gemma endpoint 是否真的支持 tools/tool_calls。",
                        color: result.nativeToolCallingObserved ? .green : .orange
                    )
                }
            }
        }
    }

    private var emptyState: some View {
        Surface {
            VStack(alignment: .leading, spacing: 14) {
                EmptyStateView(
                    systemImage: "function",
                    title: "还没有 AB 结果",
                    message: "点击运行后，系统会真实跑直接生成和证据核验两条路线，并记录耗时、token、证据链、自动修正和未处理风险。"
                )
                .frame(minHeight: 220)

                HStack {
                    Button {
                        store.selectedSection = .meetingTruth
                    } label: {
                        Label("回到会议整理", systemImage: "doc.text.magnifyingglass")
                    }
                    Button {
                        store.runMeetingTruthToolCallingABTest()
                    } label: {
                        Label("运行可信度 AB", systemImage: "play.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isMeetingTruthTaskRunning || !store.canRunMeetingTruthCentralReview)
                    Button {
                        store.loadMeetingTruthOpenClawEvidenceDemo()
                    } label: {
                        Label("加载 OpenClaw 样例", systemImage: "wand.and.stars")
                    }
                    .disabled(store.isMeetingTruthTaskRunning)
                    Spacer()
                }
            }
        }
    }

    private func branchRows(_ branch: MeetingTruthABBranchResult, isToolCalling: Bool) -> [ABModeRow] {
        var rows = [
            ABModeRow(title: "运行状态", value: branchStateText(branch), detail: branch.errorMessage ?? "本分支完成并返回中枢复核账本。"),
            ABModeRow(title: "耗时", value: durationText(branch.durationSeconds), detail: "开始 \(timeText(branch.startedAt))，结束 \(timeText(branch.finishedAt))。"),
            ABModeRow(title: "token", value: tokenText(branch.tokenUsage), detail: branch.tokenUsage == nil ? "endpoint 未返回 usage；不伪造 token 数据。" : "来自 endpoint usage。"),
            ABModeRow(title: "事实裁决", value: "\(branch.claimCount) 个", detail: "阻塞 \(branch.blockingCount) · 提示 \(branch.advisoryCount) · rawVision 观察 \(branch.rawVisionObservationCount)。")
        ]

        if isToolCalling {
            let names = branch.ledger?.toolCallRecords
                .filter { $0.status == .executed }
                .map(\.functionName)
                .uniqued()
                .joined(separator: "、") ?? ""
            rows.append(ABModeRow(title: "工具函数步骤", value: names.isEmpty ? "暂无执行工具" : names, detail: "\(branch.toolCallCount) 条流水，\(branch.executedToolCallCount) 条执行成功。"))
            rows.append(ABModeRow(title: "可信度产物", value: "\(branch.evidenceChainCount) 条证据链", detail: "自动修正 \(branch.automaticCorrectionCount) · 人工确认 \(branch.confirmationNeededCount) · 纪要变化 \(branch.finalMinutesChangeCount)。"))
        } else {
            rows.append(ABModeRow(title: "工具调用", value: "0", detail: "本分支显式关闭 useToolCalling，不向模型发送 tools。"))
            rows.append(ABModeRow(title: "未处理风险项", value: "\(branch.unhandledRiskItemCount)", detail: "只能查看最终结果，看不到稳定证据链和工程裁决步骤。"))
        }
        return rows
    }

    private func branchStateText(_ branch: MeetingTruthABBranchResult) -> String {
        branch.succeeded ? "成功" : "失败"
    }

    private func durationText(_ seconds: Double) -> String {
        if seconds < 1 {
            return "\(Int((seconds * 1000).rounded()))ms"
        }
        return "\(String(format: "%.2f", seconds))s"
    }

    private func timeText(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .standard)
    }

    private func tokenText(_ usage: MeetingTruthTokenUsage?) -> String {
        guard let usage, usage.hasContent else { return "未返回" }
        if let total = usage.totalTokens {
            return "\(total)"
        }
        let prompt = usage.promptTokens.map(String.init) ?? "?"
        let completion = usage.completionTokens.map(String.init) ?? "?"
        return "\(prompt)+\(completion)"
    }

    private func outcomeColor(_ kind: MeetingTruthABOutcomeKind) -> Color {
        switch kind {
        case .trustGain: .green
        case .noVisibleGain: .orange
        case .verificationAnomaly: .red
        }
    }
}

private struct ABModeRow: Identifiable {
    var id: String { title }
    var title: String
    var value: String
    var detail: String
}

private struct ABMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private enum ABReadinessState {
    case ready
    case waiting
    case warning
    case neutral

    var color: Color {
        switch self {
        case .ready: .green
        case .waiting: .secondary
        case .warning: .orange
        case .neutral: .blue
        }
    }

    var icon: String {
        switch self {
        case .ready: "checkmark.circle.fill"
        case .waiting: "circle"
        case .warning: "exclamationmark.triangle.fill"
        case .neutral: "info.circle.fill"
        }
    }
}

private struct ABReadinessItem: View {
    let title: String
    let value: String
    let state: ABReadinessState

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: state.icon)
                .foregroundStyle(state.color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Text(value)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct ABStatCard: View {
    let title: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.secondary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct ABModeColumn: View {
    let title: String
    let subtitle: String
    let icon: String
    let tint: Color
    let summary: String
    let rows: [ABModeRow]

    var body: some View {
        Surface {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: icon)
                        .font(.title3)
                        .foregroundStyle(tint)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.headline)
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(rows) { row in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(row.value)
                                .font(.subheadline.weight(.semibold))
                                .fixedSize(horizontal: false, vertical: true)
                            Text(row.detail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(8)
                        .background(tint.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }
}

private struct ABOverviewBlock: View {
    let title: String
    let text: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(tint.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct ABToolCallRow: View {
    let record: MeetingTruthToolCallRecord

    var body: some View {
        let source = record.invocationSource ?? .unknown
        HStack(alignment: .top, spacing: 10) {
            Text("\(record.callIndex)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(statusColor)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(record.functionName)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    ABBadge(text: record.status.title, color: statusColor)
                }

                ABInfoBlock(title: "处理来源", text: ABProcessingSource.toolRecord(record))
                ABInfoBlock(title: source.shouldShowToolCallLabel ? "tool_call" : "执行输入", text: record.argumentsSummary)
                ABInfoBlock(title: source.shouldShowToolCallLabel ? "tool_response" : "执行结果", text: record.resultSummary)
                ABInfoBlock(title: "影响", text: record.impactSummary)

                if let conflicts = record.asrConflicts, !conflicts.isEmpty {
                    ABInfoBlock(title: "ASR 差异对比", text: conflicts.prefix(4).map { conflict in
                        "\(conflict.conflictType)：\(conflict.candidates.joined(separator: " / "))\n风险：\(conflict.riskLevel.title)；影响纪要：\(conflict.impactsMinutes ? "是" : "否")\n\(conflict.reason)"
                    }.joined(separator: "\n\n"))
                }

                if let evidence = record.evidenceChain, !evidence.isEmpty {
                    ABInfoBlock(title: "证据链", text: evidence.prefix(6).map { item in
                        "\(item.supportType.title) \(item.candidate)：\(ABProcessingSource.evidence(item.sourceType)) · \(item.matchedText) · \(Int((item.confidence * 100).rounded()))%"
                    }.joined(separator: "\n"))
                }

                if let scores = record.candidateScores, !scores.isEmpty {
                    ABInfoBlock(title: "候选事实评分", text: scores.prefix(5).map { score in
                        "本地工具函数 / 候选评分：\(score.candidate) · \(Int((score.score * 100).rounded())) 分 · \(score.recommendedDecision.title)\n\(score.reason)"
                    }.joined(separator: "\n\n"))
                }

                if let decision = record.factDecision {
                    ABInfoBlock(title: "最终事实裁决", text: """
                    \(decision.status.title)：\(decision.finalText)
                    置信度：\(Int((decision.confidence * 100).rounded()))%
                    写入纪要：\(decision.enterMinutes ? "是" : "否")
                    修正来源：\(decision.correctedFrom.isEmpty ? "无" : decision.correctedFrom.joined(separator: " / "))
                    解释：\(decision.explanation)
                    """)
                }

                if let task = record.humanReviewTask {
                    ABInfoBlock(title: "人工确认任务", text: """
                    \(task.question)
                    选项：\(task.options.joined(separator: " / "))
                    原因：\(task.whyNeeded)
                    影响：\(task.impact)
                    """)
                }

                if let affected = record.affectedMinutesText, !affected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ABInfoBlock(title: "最终纪要受影响位置", text: affected)
                }
            }
            .padding(10)
            .background(.secondary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var statusColor: Color {
        switch record.status {
        case .executed: .green
        case .skipped: .orange
        case .failed: .red
        }
    }
}

private struct ABBranchImpactBlock: View {
    let title: String
    let branch: MeetingTruthABBranchResult
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                ABBadge(text: branch.succeeded ? "成功" : "失败", color: branch.succeeded ? .green : .red)
            }
            Text("事实 \(branch.claimCount) · 阻塞 \(branch.blockingCount) · 提示 \(branch.advisoryCount) · rawVision \(branch.rawVisionObservationCount)")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            if let claim = branch.ledger?.claims.first {
                Text(claim.proposedCanonicalText)
                    .font(.caption.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(claim.decisionReason)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let error = branch.errorMessage {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("本分支没有返回 claim。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(tint.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct ABBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.16))
            .foregroundStyle(color)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private enum ABProcessingSource {
    static func evidence(_ sourceType: MeetingTruthEvidenceSupport.SourceType) -> String {
        switch sourceType {
        case .asr:
            return "Swift 规则 / ASR 候选对齐"
        case .imageOCR:
            return "OCR / 图片文字识别"
        case .rawVision:
            return "Gemma 多模态 / 原图理解"
        case .material:
            return "Swift 规则 / 会议材料检索"
        case .glossary:
            return "Swift 规则 / 术语表检索"
        case .context:
            return "Swift 规则 / 上下文窗口"
        case .human:
            return "人工确认"
        case .meetingNotice:
            return "Swift 规则 / 会议通知证据"
        case .handwrittenNote:
            return "OCR 或 Gemma 多模态 / 手写纪要证据"
        case .slideOrPPT:
            return "Swift 规则 / PPT 或正式材料证据"
        case .whiteboard:
            return "Gemma 多模态 / 白板板书理解"
        case .screenshot:
            return "OCR 或 Gemma 多模态 / 系统截图证据"
        }
    }

    static func toolRecord(_ record: MeetingTruthToolCallRecord) -> String {
        let source = record.invocationSource ?? .unknown
        let action: String
        switch record.functionName {
        case "extract_meeting_fact_candidates":
            action = "Swift 规则 / 候选准入"
        case "filter_reviewable_facts":
            action = "Swift 规则 / 低价值过滤"
        case "detect_asr_conflicts":
            action = "本地工具函数 / ASR 冲突分组"
        case "retrieve_supporting_evidence":
            action = "本地工具函数 / 证据检索"
        case "score_fact_candidates":
            action = "本地工具函数 / 候选评分"
        case "make_fact_decision":
            action = "本地工具函数 / 事实裁决；Gemma 语义判断会在中枢复核阶段读取结果"
        case "create_human_review_task":
            action = "本地工具函数 / 人工确认任务生成"
        default:
            action = "本地工具函数 / 未知工具"
        }
        return "\(source.title)；\(action)"
    }
}

private struct ABInfoBlock: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text.isEmpty ? "暂无" : text)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}

private struct ABBullet: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .padding(.top, 5)
            Text(text)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private extension Array where Element == String {
    func uniqued() -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for item in self {
            guard seen.insert(item).inserted else { continue }
            result.append(item)
        }
        return result
    }
}
