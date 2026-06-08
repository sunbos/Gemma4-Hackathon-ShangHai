import SwiftUI

struct MeetingTruthWorkflowCompareView: View {
    @EnvironmentObject private var store: LabStore
    @State private var selectedStep: MeetingTruthCompareStep = .evidence
    @State private var selectedFactID: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                workflowStrip

                HStack(alignment: .top, spacing: 16) {
                    factList
                        .frame(width: 320, alignment: .top)

                    VStack(alignment: .leading, spacing: 16) {
                        stepDetail
                        if let decision = selectedDecision {
                            selectedFactComparison(decision)
                        } else {
                            noFactState
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .padding(24)
        }
        .onAppear(perform: prepareInitialSelection)
    }

    private var header: some View {
        Surface {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: "rectangle.split.3x1")
                    .font(.system(size: 34))
                    .foregroundStyle(.blue)

                VStack(alignment: .leading, spacing: 6) {
                    Text("效果对比")
                        .font(.title.weight(.semibold))
                    Text("点选流程和事实，查看同一结论在 ASR、OCR、原图视觉、材料、人工确认之间怎样改变。")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 8) {
                    HStack(spacing: 8) {
                        CompareMetric(title: "事实", value: "\(store.meetingTruthFactDecisions.count)")
                        CompareMetric(title: "证据", value: "\(store.meetingTruthEvidenceAtoms.count)")
                        CompareMetric(title: "追问", value: "\(store.meetingTruthPendingFactQuestions.count)")
                    }
                    Button {
                        store.refreshMeetingTruthFactReviewLedger()
                        if selectedFactID == nil {
                            selectedFactID = factRows.first?.factID
                        }
                    } label: {
                        Label("刷新事实账本", systemImage: "arrow.clockwise")
                    }
                    .disabled(store.meetingTruthTrustedTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private var workflowStrip: some View {
        Surface {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 145), spacing: 10)],
                alignment: .leading,
                spacing: 10
            ) {
                ForEach(MeetingTruthCompareStep.allCases) { step in
                    Button {
                        selectedStep = step
                    } label: {
                        CompareStepTile(
                            step: step,
                            state: state(for: step),
                            isSelected: selectedStep == step
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var factList: some View {
        Surface {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("事实点", systemImage: "list.bullet.rectangle")
                        .font(.headline)
                    Spacer()
                    Text("\(factRows.count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                if factRows.isEmpty {
                    EmptyStateView(
                        systemImage: "doc.text.magnifyingglass",
                        title: "暂无事实账本",
                        message: "导入转写后刷新事实账本；页面会按真实事实显示通道差异。"
                    )
                    .frame(minHeight: 240)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(factRows) { decision in
                            Button {
                                selectedFactID = decision.factID
                                selectedStep = .evidence
                            } label: {
                                FactRowButton(
                                    decision: decision,
                                    evidenceCount: evidence(for: decision.factID).count,
                                    isSelected: decision.factID == selectedDecision?.factID
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var stepDetail: some View {
        Surface {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(selectedStep.title, systemImage: selectedStep.icon)
                            .font(.headline)
                        Text(selectedStep.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    CompareStatusBadge(state: state(for: selectedStep))
                }

                switch selectedStep {
                case .files:
                    fileRoutingDetail
                case .extract:
                    extractionDetail
                case .facts:
                    factExtractionDetail
                case .evidence:
                    evidenceMatchingDetail
                case .decision:
                    decisionDetail
                case .human:
                    humanDetail
                case .package:
                    packageGateDetail
                }
            }
        }
    }

    private var fileRoutingDetail: some View {
        VStack(alignment: .leading, spacing: 8) {
            CompareInfoRow(title: "会议资料", value: "\(store.meetingTruthMaterials.count) 份")
            CompareInfoRow(title: "候选转写", value: "\(store.meetingTruthTranscriptSources.count) 路")
            CompareInfoRow(title: "图片", value: "\(store.meetingTruthImageMaterials.count) 张")
            ForEach(store.meetingTruthMaterials.prefix(6)) { material in
                CompareSourceLine(title: material.name, subtitle: "\(material.kind) · \(material.detail)", icon: material.kind == "图片" ? "photo" : "doc.text")
            }
        }
    }

    private var extractionDetail: some View {
        VStack(alignment: .leading, spacing: 8) {
            CompareInfoRow(title: "ASR 文本", value: "\(store.meetingTruthTranscriptSources.count) 路候选")
            CompareInfoRow(title: "OCR 基线", value: "\(store.meetingTruthImageMaterials.filter { !$0.extractedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count) 张图片有文本")
            CompareInfoRow(title: "原图视觉", value: "\(store.meetingTruthVisualEvidence.count) 条 Gemma 4 视觉证据")
            ForEach(store.meetingTruthVisualEvidence.prefix(4)) { evidence in
                CompareSourceLine(
                    title: evidence.materialName,
                    subtitle: evidence.summary.isEmpty ? "已读取原图" : evidence.summary,
                    icon: "eye"
                )
            }
        }
    }

    private var factExtractionDetail: some View {
        VStack(alignment: .leading, spacing: 8) {
            CompareInfoRow(title: "事实候选", value: "\(store.meetingTruthFactCandidates.count)")
            CompareInfoRow(title: "高风险事实", value: "\(store.meetingTruthFactDecisions.filter { $0.riskLevel == .high }.count)")
            CompareInfoRow(title: "需要证据", value: "\(store.meetingTruthFactCandidates.filter(\.needsEvidence).count)")
            if let decision = selectedDecision {
                CompareSourceLine(title: decision.kind.title, subtitle: decision.claim, icon: "target")
            }
        }
    }

    private var evidenceMatchingDetail: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let decision = selectedDecision {
                let atoms = evidence(for: decision.factID)
                CompareInfoRow(title: "当前事实", value: decision.chosenText)
                CompareInfoRow(title: "支持证据", value: "\(atoms.filter(\.supportsClaim).count) 条")
                CompareInfoRow(title: "反向证据", value: "\(atoms.filter { !$0.supportsClaim }.count) 条")
            } else {
                Text("请选择一个事实点。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var decisionDetail: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let decision = selectedDecision {
                CompareInfoRow(title: "裁决", value: decision.status.title)
                CompareInfoRow(title: "置信度", value: "\(Int((decision.confidence * 100).rounded()))%")
                CompareInfoRow(title: "风险等级", value: decision.riskLevel.title)
                Text(decision.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var humanDetail: some View {
        VStack(alignment: .leading, spacing: 8) {
            CompareInfoRow(title: "待确认问题", value: "\(store.meetingTruthPendingFactQuestions.count)")
            ForEach(store.meetingTruthPendingFactQuestions.prefix(4)) { question in
                CompareSourceLine(title: question.question, subtitle: question.currentClaim, icon: "person.crop.circle.badge.questionmark")
            }
            Button {
                store.selectedSection = .meetingTruth
            } label: {
                Label("去确认修改", systemImage: "checkmark.circle")
            }
            .disabled(store.meetingTruthPendingFactQuestions.isEmpty)
        }
    }

    private var packageGateDetail: some View {
        VStack(alignment: .leading, spacing: 8) {
            CompareInfoRow(title: "可写入事实", value: "\(acceptedFacts.count)")
            CompareInfoRow(title: "暂不采用", value: "\(blockedFacts.count)")
            CompareInfoRow(title: "成果包", value: store.meetingTruthAnalysis == nil ? "未生成" : "已生成")
            Button {
                store.selectedSection = .meetingTruth
            } label: {
                Label("回到生成结果", systemImage: "wand.and.stars")
            }
        }
    }

    private func selectedFactComparison(_ decision: MeetingTruthFactDecision) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Surface {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(decision.chosenText)
                                .font(.title3.weight(.semibold))
                                .textSelection(.enabled)
                            Text("\(decision.kind.title) · \(decision.riskLevel.title) · \(decision.importance.title)优先级")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        CompareDecisionBadge(decision: decision)
                    }

                    HStack(alignment: .top, spacing: 12) {
                        BeforeAfterPanel(
                            title: "只看转写时",
                            icon: "text.quote",
                            value: decision.claim,
                            detail: decision.riskLevel == .high ? "高风险字段会混在普通文本里，容易被直接写进纪要。" : "会作为普通会议文本进入整理链路。"
                        )
                        BeforeAfterPanel(
                            title: "复核之后",
                            icon: statusIcon(for: decision.status),
                            value: decision.status.title,
                            detail: afterDetail(for: decision)
                        )
                    }
                }
            }

            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                alignment: .leading,
                spacing: 12
            ) {
                channelCard(.asr, title: "仅 ASR 文本", icon: "waveform.and.magnifyingglass", decision: decision)
                channelCard(.imageOCR, title: "图片 OCR 基线", icon: "text.viewfinder", decision: decision)
                channelCard(.rawVision, title: "原图视觉", icon: "eye", decision: decision)
                channelCard(.material, title: "文本/PDF 材料", icon: "doc.richtext", decision: decision)
                channelCard(.conflict, title: "冲突卡", icon: "exclamationmark.triangle", decision: decision)
                channelCard(.human, title: "人工确认", icon: "person.crop.circle.badge.checkmark", decision: decision)
            }

            Surface {
                VStack(alignment: .leading, spacing: 8) {
                    Label("裁决理由", systemImage: "scale.3d")
                        .font(.headline)
                    Text(decision.reason)
                        .textSelection(.enabled)
                    if !decision.missingEvidence.isEmpty {
                        ForEach(decision.missingEvidence, id: \.self) { missing in
                            Label(missing, systemImage: "questionmark.circle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
        }
    }

    private var noFactState: some View {
        Surface {
            EmptyStateView(
                systemImage: "tablecells.badge.ellipsis",
                title: "还没有可对比的事实",
                message: "导入候选转写后刷新事实账本；如果已经导入，可以点击右上角刷新。"
            )
        }
    }

    private func channelCard(
        _ channel: MeetingTruthFactChannel,
        title: String,
        icon: String,
        decision: MeetingTruthFactDecision
    ) -> some View {
        let atoms = evidence(for: decision.factID).filter { $0.channel == channel }
        return Surface {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    Label(title, systemImage: icon)
                        .font(.headline)
                    Spacer()
                    if atoms.isEmpty {
                        CompareMiniBadge(title: "未命中", color: .secondary)
                    } else if atoms.contains(where: { !$0.supportsClaim }) {
                        CompareMiniBadge(title: "有反证", color: .orange)
                    } else {
                        CompareMiniBadge(title: "支持", color: .green)
                    }
                }

                if atoms.isEmpty {
                    Text(missingChannelText(channel))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(minHeight: 56, alignment: .topLeading)
                } else {
                    ForEach(atoms.prefix(3)) { atom in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(atom.sourceName)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("\(Int((atom.weight * 100).rounded()))% 权重")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Text(atom.text.isEmpty ? "暂无文本证据" : atom.text)
                                .font(.caption)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            if !atom.visualCue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Text("视觉线索：\(atom.visualCue)")
                                    .font(.caption)
                                    .foregroundStyle(.blue)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(8)
                        .background(atom.supportsClaim ? Color.green.opacity(0.07) : Color.orange.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }

    private var factRows: [MeetingTruthFactDecision] {
        store.meetingTruthFactDecisions.sorted { lhs, rhs in
            if lhs.requiresUserInput != rhs.requiresUserInput {
                return lhs.requiresUserInput && !rhs.requiresUserInput
            }
            if lhs.riskLevel != rhs.riskLevel {
                return riskRank(lhs.riskLevel) > riskRank(rhs.riskLevel)
            }
            return lhs.confidence < rhs.confidence
        }
    }

    private var selectedDecision: MeetingTruthFactDecision? {
        if let selectedFactID,
           let decision = factRows.first(where: { $0.factID == selectedFactID }) {
            return decision
        }
        return factRows.first
    }

    private var acceptedFacts: [MeetingTruthFactDecision] {
        store.meetingTruthFactDecisions.filter { $0.status == .accepted || $0.status == .confirmed }
    }

    private var blockedFacts: [MeetingTruthFactDecision] {
        store.meetingTruthFactDecisions.filter { $0.status != .accepted && $0.status != .confirmed }
    }

    private func prepareInitialSelection() {
        if store.meetingTruthFactDecisions.isEmpty,
           !store.meetingTruthTrustedTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            store.refreshMeetingTruthFactReviewLedger()
        }
        selectedFactID = selectedFactID ?? factRows.first?.factID
    }

    private func evidence(for factID: UUID) -> [MeetingTruthEvidenceAtom] {
        store.meetingTruthEvidenceAtoms.filter { $0.factID == factID }
    }

    private func state(for step: MeetingTruthCompareStep) -> CompareWorkflowState {
        switch step {
        case .files:
            return store.hasMeetingTruthInput ? .ready : .waiting
        case .extract:
            if !store.meetingTruthVisualEvidence.isEmpty { return .ready }
            if !store.meetingTruthImageMaterials.isEmpty || !store.meetingTruthTranscriptSources.isEmpty { return .warning }
            return .waiting
        case .facts:
            return store.meetingTruthFactCandidates.isEmpty ? .waiting : .ready
        case .evidence:
            return store.meetingTruthEvidenceAtoms.isEmpty ? .waiting : .ready
        case .decision:
            if !store.meetingTruthPendingFactQuestions.isEmpty { return .warning }
            return store.meetingTruthFactDecisions.isEmpty ? .waiting : .ready
        case .human:
            if !store.meetingTruthPendingFactQuestions.isEmpty { return .warning }
            return store.meetingTruthFactDecisions.contains { $0.status == .confirmed } ? .ready : .waiting
        case .package:
            if !store.meetingTruthPendingFactQuestions.isEmpty { return .warning }
            return store.meetingTruthAnalysis == nil ? .waiting : .ready
        }
    }

    private func afterDetail(for decision: MeetingTruthFactDecision) -> String {
        switch decision.status {
        case .accepted:
            return "证据足够，可以进入可信事实白名单和成果包。"
        case .confirmed:
            return "人工确认权重最高，会写入可信逐字稿和成果包。"
        case .needsUserInput:
            return "生成会被阻止，先进入确认队列。"
        case .conflicted:
            return "不同来源冲突，必须人工裁决。"
        case .unsupported:
            return "低支撑事实不会进入正式成果。"
        case .lowConfidence:
            return "置信度不足，默认不作为高置信结论。"
        }
    }

    private func missingChannelText(_ channel: MeetingTruthFactChannel) -> String {
        switch channel {
        case .asr:
            return "没有额外 ASR 证据命中该事实。"
        case .imageOCR:
            return "OCR 基线没有命中该事实；即使命中也只算文字通道。"
        case .rawVision:
            return "原图没有提供可用的版式、圈注、手写或空间关系证据。"
        case .material:
            return "文本/PDF 材料没有命中该事实。"
        case .human:
            return "用户还没有确认该事实。"
        case .conflict:
            return "没有关联到现有冲突卡。"
        }
    }

    private func statusIcon(for status: MeetingTruthFactDecisionStatus) -> String {
        switch status {
        case .accepted, .confirmed:
            return "checkmark.seal"
        case .needsUserInput, .conflicted:
            return "questionmark.circle"
        case .unsupported, .lowConfidence:
            return "minus.circle"
        }
    }

    private func riskRank(_ risk: MeetingTruthFactRiskLevel) -> Int {
        switch risk {
        case .high: 3
        case .medium: 2
        case .low: 1
        }
    }
}

private enum MeetingTruthCompareStep: String, CaseIterable, Identifiable {
    case files
    case extract
    case facts
    case evidence
    case decision
    case human
    case package

    var id: String { rawValue }

    var title: String {
        switch self {
        case .files: "文件识别"
        case .extract: "单通道提取"
        case .facts: "全文事实抽取"
        case .evidence: "多模态匹配"
        case .decision: "事实级裁决"
        case .human: "人工确认"
        case .package: "成果门禁"
        }
    }

    var subtitle: String {
        switch self {
        case .files: "把文件分到音频、转写、图片、文本材料"
        case .extract: "ASR、OCR、PDF/文本、原图视觉各走各的通道"
        case .facts: "从可信逐字稿抽取人名、数字、日期、项目、待办"
        case .evidence: "按事实匹配 ASR、OCR、原图、材料和人工证据"
        case .decision: "输出采信、冲突、证据不足或需要追问"
        case .human: "证据不够时让用户补真实信息"
        case .package: "只把采信或确认事实写入成果包"
        }
    }

    var icon: String {
        switch self {
        case .files: "tray.and.arrow.down"
        case .extract: "square.grid.2x2"
        case .facts: "target"
        case .evidence: "link"
        case .decision: "scale.3d"
        case .human: "person.crop.circle.badge.checkmark"
        case .package: "shippingbox"
        }
    }
}

private enum CompareWorkflowState {
    case ready
    case warning
    case waiting

    var title: String {
        switch self {
        case .ready: "已生效"
        case .warning: "需处理"
        case .waiting: "等待"
        }
    }

    var color: Color {
        switch self {
        case .ready: .green
        case .warning: .orange
        case .waiting: .secondary
        }
    }

    var icon: String {
        switch self {
        case .ready: "checkmark.circle.fill"
        case .warning: "exclamationmark.circle.fill"
        case .waiting: "circle.dashed"
        }
    }
}

private struct CompareStepTile: View {
    let step: MeetingTruthCompareStep
    let state: CompareWorkflowState
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Image(systemName: step.icon)
                    .foregroundStyle(isSelected ? .blue : state.color)
                    .frame(width: 18)
                Spacer()
                Image(systemName: state.icon)
                    .font(.caption)
                    .foregroundStyle(state.color)
            }
            Text(step.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Text(step.subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
        .background(isSelected ? Color.blue.opacity(0.10) : Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.blue.opacity(0.35) : Color.clear, lineWidth: 1)
        }
    }
}

private struct FactRowButton: View {
    let decision: MeetingTruthFactDecision
    let evidenceCount: Int
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(decision.kind.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                CompareMiniBadge(title: decision.status.title, color: statusColor)
            }
            Text(decision.chosenText)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("\(decision.riskLevel.title) · \(evidenceCount) 条证据")
                Spacer()
                Text("\(Int((decision.confidence * 100).rounded()))%")
                    .monospacedDigit()
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.blue.opacity(0.10) : Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var statusColor: Color {
        switch decision.status {
        case .accepted, .confirmed:
            return .green
        case .needsUserInput, .conflicted:
            return .orange
        case .lowConfidence, .unsupported:
            return .secondary
        }
    }
}

private struct CompareMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.quaternary.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct CompareInfoRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption.weight(.medium))
                .textSelection(.enabled)
                .multilineTextAlignment(.trailing)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct CompareSourceLine: View {
    let title: String
    let subtitle: String
    let icon: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.blue)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
                Text(subtitle.isEmpty ? "暂无细节" : subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct CompareStatusBadge: View {
    let state: CompareWorkflowState

    var body: some View {
        Label(state.title, systemImage: state.icon)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .foregroundStyle(state.color)
            .background(state.color.opacity(0.14))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct CompareMiniBadge: View {
    let title: String
    let color: Color

    var body: some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(color)
            .background(color.opacity(0.14))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct CompareDecisionBadge: View {
    let decision: MeetingTruthFactDecision

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            CompareMiniBadge(title: decision.status.title, color: color)
            Text("\(Int((decision.confidence * 100).rounded()))%")
                .font(.title3.weight(.semibold))
                .monospacedDigit()
        }
    }

    private var color: Color {
        switch decision.status {
        case .accepted, .confirmed:
            return .green
        case .needsUserInput, .conflicted:
            return .orange
        case .lowConfidence, .unsupported:
            return .secondary
        }
    }
}

private struct BeforeAfterPanel: View {
    let title: String
    let icon: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 116, alignment: .topLeading)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
