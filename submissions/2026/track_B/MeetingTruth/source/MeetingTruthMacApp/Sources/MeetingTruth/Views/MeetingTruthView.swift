import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MeetingTruthView: View {
    @EnvironmentObject private var store: LabStore
    @State private var isShowingTemplates = false
    @State private var isEditingKeywords = false
    @State private var isSelectingHistoricalASR = false
    @State private var previewMaterial: MeetingTruthMaterial?
    @State private var expandedStages: Set<MeetingTruthWorkflowStage> = []

    var body: some View {
        let currentStage = MeetingTruthWorkflowStage.current(for: store)

        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                MeetingTruthHero()
                MeetingTruthWorkflow(currentStage: currentStage)

                MeetingTruthStageSection(
                    stage: .materials,
                    currentStage: currentStage,
                    isComplete: MeetingTruthWorkflowStage.materials.isComplete(in: store),
                    isExpanded: expansionBinding(for: .materials, currentStage: currentStage)
                ) {
                    HStack(alignment: .top, spacing: 16) {
                        MeetingTruthMaterialPanel(
                            showTemplates: { isShowingTemplates = true },
                            editKeywords: { isEditingKeywords = true },
                            selectHistoricalASR: { isSelectingHistoricalASR = true },
                            previewMaterial: { previewMaterial = $0 }
                        )
                        MeetingTruthProgressPanel(
                            showTemplates: { isShowingTemplates = true }
                        )
                    }
                }

                MeetingTruthStageSection(
                    stage: .discover,
                    currentStage: currentStage,
                    isComplete: MeetingTruthWorkflowStage.discover.isComplete(in: store),
                    isExpanded: expansionBinding(for: .discover, currentStage: currentStage)
                ) {
                    MeetingTruthConflictCheckPanel()
                }

                MeetingTruthStageSection(
                    stage: .confirm,
                    currentStage: currentStage,
                    isComplete: MeetingTruthWorkflowStage.confirm.isComplete(in: store),
                    isExpanded: expansionBinding(for: .confirm, currentStage: currentStage)
                ) {
                    MeetingTruthConflictPanel()
                }

                MeetingTruthStageSection(
                    stage: .centralReview,
                    currentStage: currentStage,
                    isComplete: MeetingTruthWorkflowStage.centralReview.isComplete(in: store),
                    isExpanded: expansionBinding(for: .centralReview, currentStage: currentStage)
                ) {
                    MeetingTruthCentralReviewPanel()
                    MeetingTruthMultimodalPanel()
                }

                MeetingTruthStageSection(
                    stage: .package,
                    currentStage: currentStage,
                    isComplete: MeetingTruthWorkflowStage.package.isComplete(in: store),
                    isExpanded: expansionBinding(for: .package, currentStage: currentStage)
                ) {
                    MeetingTruthTranscriptPanel()
                    MeetingTruthPackagePanel()
                }
            }
            .padding(24)
        }
        .sheet(isPresented: $isShowingTemplates) {
            MeetingTruthTemplateSheet()
        }
        .sheet(isPresented: $isEditingKeywords) {
            MeetingTruthKeywordSheet()
        }
        .sheet(isPresented: $isSelectingHistoricalASR) {
            MeetingTruthHistoricalASRSheet()
        }
        .sheet(item: $previewMaterial) { material in
            MeetingTruthImagePreviewSheet(material: material)
        }
    }

    private func expansionBinding(
        for stage: MeetingTruthWorkflowStage,
        currentStage: MeetingTruthWorkflowStage
    ) -> Binding<Bool> {
        Binding(
            get: { expandedStages.contains(stage) || stage == currentStage },
            set: { isExpanded in
                if isExpanded {
                    expandedStages.insert(stage)
                } else {
                    expandedStages.remove(stage)
                }
            }
        )
    }
}

private enum MeetingTruthWorkflowStage: Int, CaseIterable, Hashable {
    case materials
    case discover
    case confirm
    case centralReview
    case package

    var number: String { "\(rawValue + 1)" }

    var title: String {
        switch self {
        case .materials: "添加会议材料"
        case .discover: "检查转写冲突"
        case .confirm: "确认冲突结果"
        case .centralReview: "中枢复核"
        case .package: "生成会议结果"
        }
    }

    var summary: String {
        switch self {
        case .materials: "导入资料、选择本地 ASR 历史"
        case .discover: "等待 Gemma 4 比对多路转写"
        case .confirm: "逐项采用、修订、跳过"
        case .centralReview: "检查阻塞项与证据缺口"
        case .package: "生成逐字稿、纪要、待办"
        }
    }

    var systemImage: String {
        switch self {
        case .materials: "tray.and.arrow.down"
        case .discover: "magnifyingglass"
        case .confirm: "checklist.checked"
        case .centralReview: "checkmark.shield"
        case .package: "shippingbox"
        }
    }

    var primaryHint: String {
        switch self {
        case .materials: "先准备真实输入；主要入口是导入会议资料和选择本地 ASR 历史。"
        case .discover: "这一步可能等待较久，运行时会持续显示 Gemma 4 当前处理状态。"
        case .confirm: "不要只一键确认；高风险片段建议逐条看上下文和证据。"
        case .centralReview: "确认成果包生成前没有阻塞项，必要时逐条回答复核问题。"
        case .package: "前置阶段通过后，再生成正式会议结果。"
        }
    }

    @MainActor
    static func current(for store: LabStore) -> MeetingTruthWorkflowStage {
        if store.isGeneratingMeetingTruthPackage || store.meetingTruthAnalysis != nil {
            return .package
        }
        if store.isReviewingMeetingTruthCentrally ||
            store.meetingTruthCentralReviewLedger == nil && store.hasDiscoveredMeetingTruthConflicts && store.meetingTruthUnresolvedCount == 0 ||
            !store.meetingTruthPendingCentralReviewClaims.isEmpty ||
            !store.meetingTruthCentralReviewBlockingItems.isEmpty {
            return .centralReview
        }
        if store.hasDiscoveredMeetingTruthConflicts &&
            !store.meetingTruthConflicts.isEmpty &&
            store.meetingTruthUnresolvedCount > 0 {
            return .confirm
        }
        if store.isDiscoveringMeetingTruthConflicts ||
            store.isResolvingMeetingTruthConflicts ||
            store.meetingTruthTranscriptSources.count >= 2 {
            return .discover
        }
        return .materials
    }

    @MainActor
    func isComplete(in store: LabStore) -> Bool {
        switch self {
        case .materials:
            return store.meetingTruthTranscriptSources.count >= 2
        case .discover:
            return store.hasDiscoveredMeetingTruthConflicts
        case .confirm:
            return store.hasDiscoveredMeetingTruthConflicts &&
                (store.meetingTruthConflicts.isEmpty || store.meetingTruthUnresolvedCount == 0)
        case .centralReview:
            return store.meetingTruthCentralReviewLedger != nil &&
                store.meetingTruthPendingCentralReviewClaims.isEmpty &&
                store.meetingTruthCentralReviewBlockingItems.isEmpty
        case .package:
            return store.meetingTruthAnalysis != nil
        }
    }
}

private struct MeetingTruthHero: View {
    @EnvironmentObject private var store: LabStore

    var body: some View {
        Surface {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 16) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(.blue)

                    VStack(alignment: .leading, spacing: 7) {
                        Text("MeetingTruth")
                            .font(.title.weight(.semibold))
                        Text(store.meetingTruthDecisionOverview.title)
                            .font(.title3.weight(.medium))
                        Text(store.meetingTruthDecisionOverview.subtitle)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 8) {
                        CapabilityBadge(title: "Gemma 4 E4B-it", color: .purple)
                        CapabilityBadge(
                            title: store.meetingTruthMultimodalProof.isProven ? "已读原图" : "待读原图",
                            color: store.meetingTruthMultimodalProof.isProven ? .green : .orange
                        )
                        CapabilityBadge(title: store.meetingTruthMultimodalMode.title, color: .blue)
                    }
                }

                HStack(alignment: .top, spacing: 10) {
                    ForEach(store.meetingTruthDecisionOverview.metrics) { metric in
                        MeetingTruthHeroMetric(metric: metric)
                    }
                    MeetingTruthNextActionPill(action: store.meetingTruthDecisionOverview.nextAction)
                }
            }
        }
    }
}

private struct MeetingTruthHeroMetric: View {
    let metric: MeetingTruthDecisionOverview.Metric

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: metric.isReady ? "checkmark.circle.fill" : "circle.dashed")
                    .font(.caption)
                    .foregroundStyle(metric.isReady ? .green : .secondary)
                Text(metric.title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            Text(metric.value)
                .font(.subheadline.weight(.semibold))
            Text(metric.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(metric.isReady ? Color.green.opacity(0.07) : Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct MeetingTruthNextActionPill: View {
    let action: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("下一步", systemImage: "arrow.forward.circle")
                .font(.caption.weight(.bold))
                .foregroundStyle(.blue)
            Text(action)
                .font(.subheadline.weight(.semibold))
            Text("按当前证据状态推进")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.blue.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct MeetingTruthWorkflow: View {
    @EnvironmentObject private var store: LabStore
    let currentStage: MeetingTruthWorkflowStage

    var body: some View {
        Surface {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("全流程示意", systemImage: "point.3.connected.trianglepath.dotted")
                            .font(.headline)
                        Text(currentStage.primaryHint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    CapabilityBadge(title: "当前：\(currentStage.title)", color: .blue)
                }

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 176), spacing: 10)],
                    alignment: .leading,
                    spacing: 10
                ) {
                    ForEach(MeetingTruthWorkflowStage.allCases, id: \.self) { stage in
                        MeetingTruthWorkflowStepCard(
                            stage: stage,
                            state: state(for: stage),
                            detail: detail(for: stage)
                        )
                    }
                }
            }
        }
    }

    private func state(for stage: MeetingTruthWorkflowStage) -> MeetingTruthStepState {
        if stage == currentStage { return store.isMeetingTruthTaskRunning ? .running : .current }
        if stage.isComplete(in: store) { return .complete }
        if stage.rawValue < currentStage.rawValue { return .attention }
        return .waiting
    }

    private func detail(for stage: MeetingTruthWorkflowStage) -> String {
        switch stage {
        case .materials:
            return "\(store.meetingTruthMaterials.count) 份资料 · \(store.meetingTruthTranscriptSources.count) 路转写"
        case .discover:
            if store.isDiscoveringMeetingTruthConflicts { return "Gemma 4 正在比对候选转写" }
            if store.isResolvingMeetingTruthConflicts { return "Gemma 4 正在交叉校验证据" }
            return store.hasDiscoveredMeetingTruthConflicts ? "已完成冲突检查" : "等待运行冲突检查"
        case .confirm:
            return "\(store.meetingTruthResolvedCount) 已确认 · \(store.meetingTruthUnresolvedCount) 待处理"
        case .centralReview:
            let blockingCount = store.meetingTruthCentralReviewBlockingItems.count
            let pendingCount = store.meetingTruthPendingCentralReviewClaims.count
            if store.isReviewingMeetingTruthCentrally { return "Gemma 4 正在做中枢复核" }
            if store.meetingTruthCentralReviewLedger == nil { return "等待运行中枢复核" }
            return "\(blockingCount) 阻塞 · \(pendingCount) 待确认"
        case .package:
            if store.isGeneratingMeetingTruthPackage { return "Gemma 4 正在生成成果包" }
            return store.meetingTruthAnalysis == nil ? "尚未生成" : "成果包已生成"
        }
    }
}

private enum MeetingTruthStepState {
    case complete
    case current
    case running
    case attention
    case waiting

    var title: String {
        switch self {
        case .complete: "已完成"
        case .current: "当前阶段"
        case .running: "执行中"
        case .attention: "需回看"
        case .waiting: "未开始"
        }
    }

    var color: Color {
        switch self {
        case .complete: .green
        case .current: .blue
        case .running: .orange
        case .attention: .orange
        case .waiting: .secondary
        }
    }

    var icon: String {
        switch self {
        case .complete: "checkmark.circle.fill"
        case .current: "arrow.right.circle.fill"
        case .running: "hourglass.circle.fill"
        case .attention: "exclamationmark.circle.fill"
        case .waiting: "circle.dashed"
        }
    }
}

private struct MeetingTruthWorkflowStepCard: View {
    let stage: MeetingTruthWorkflowStage
    let state: MeetingTruthStepState
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Text(stage.number)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(state.color)
                    .clipShape(Circle())
                Image(systemName: state.icon)
                    .font(.caption)
                    .foregroundStyle(state.color)
                Spacer()
                Text(state.title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(state.color)
            }
            Label(stage.title, systemImage: stage.systemImage)
                .font(.subheadline.weight(.semibold))
            Text(stage.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(detail)
                .font(.caption2.weight(.medium))
                .foregroundStyle(state.color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
        .background(state.color.opacity(state == .waiting ? 0.06 : 0.10))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(state.color.opacity(state == .current || state == .running ? 0.35 : 0.14))
        }
    }
}

private struct MeetingTruthStageSection<Content: View>: View {
    let stage: MeetingTruthWorkflowStage
    let currentStage: MeetingTruthWorkflowStage
    let isComplete: Bool
    @Binding var isExpanded: Bool
    @ViewBuilder var content: Content

    var body: some View {
        Surface {
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: 14) {
                    Divider()
                    content
                }
                .padding(.top, 4)
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: icon)
                        .font(.title3)
                        .foregroundStyle(color)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text("\(stage.number). \(stage.title)")
                                .font(.headline)
                            CapabilityBadge(title: stateTitle, color: color)
                        }
                        Text(stage.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(isExpanded ? "收起" : "展开")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var color: Color {
        if stage == currentStage { return .blue }
        return isComplete ? .green : .secondary
    }

    private var icon: String {
        if stage == currentStage { return "arrow.right.circle.fill" }
        return isComplete ? "checkmark.circle.fill" : "circle.dashed"
    }

    private var stateTitle: String {
        if stage == currentStage { return "当前" }
        return isComplete ? "已完成" : "未开始"
    }
}

private struct MeetingTruthMultimodalPanel: View {
    @EnvironmentObject private var store: LabStore
    @State private var isShowingArbitrationWorkbench = false
    @State private var isShowingImpactFindings = true
    @State private var isShowingOCRComparison = false
    @State private var isShowingCorrectionLedger = false
    @State private var isShowingSubjectComparison = false
    @State private var isShowingVisualEvidence = false

    var body: some View {
        Surface {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("处理详情", systemImage: "list.bullet.clipboard")
                            .font(.headline)
                        Text("这里保留完整检查依据和系统处理细节。日常整理请优先使用侧边栏里的「会议整理」。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("当前模式", selection: Binding(
                        get: { store.meetingTruthMultimodalMode },
                        set: { store.setMeetingTruthMultimodalMode($0) }
                    )) {
                        ForEach(MeetingTruthMultimodalMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 190)
                }

                MeetingTruthDecisionOverviewBar(overview: store.meetingTruthDecisionOverview)
                MeetingTruthMultimodalCallCard(status: store.meetingTruthMultimodalCallStatus)
                MeetingTruthMultimodalProofCard(proof: store.meetingTruthMultimodalProof)
                MeetingTruthArbitrationWorkbench(isExpanded: $isShowingArbitrationWorkbench)
                MeetingTruthInputRouteTable(routes: store.meetingTruthInputRoutes)

                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                    alignment: .leading,
                    spacing: 8
                ) {
                    ForEach(store.meetingTruthEvidenceChannelStatuses) { channel in
                        MeetingTruthEvidenceChannelCard(channel: channel)
                    }
                }

                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                    alignment: .leading,
                    spacing: 10
                ) {
                    ForEach(store.meetingTruthMultimodalImpactRows) { row in
                        MeetingTruthImpactModeCard(
                            row: row,
                            isSelected: row.mode == store.meetingTruthMultimodalMode
                        )
                    }
                }

                DisclosureGroup(isExpanded: $isShowingImpactFindings) {
                    if store.meetingTruthMultimodalImpactFindings.isEmpty {
                        EmptyStateView(
                            systemImage: "arrow.left.arrow.right",
                            title: "还没有可量化影响",
                            message: "运行 Gemma 4 读取图片、发现冲突或生成成果包后，这里会直接对比不用多模态和使用后的差别。"
                        )
                        .frame(minHeight: 104)
                    } else {
                        LazyVGrid(
                            columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                            alignment: .leading,
                            spacing: 10
                        ) {
                            ForEach(store.meetingTruthMultimodalImpactFindings) { finding in
                                MeetingTruthImpactFindingCard(
                                    finding: finding,
                                    confidenceColor: confidenceColor(finding.confidence)
                                )
                            }
                        }
                    }
                } label: {
                    sectionLabel("当前项目真实影响", systemImage: "arrow.left.arrow.right", count: "\(store.meetingTruthMultimodalImpactFindings.count) 项")
                }

                Divider()

                DisclosureGroup(isExpanded: $isShowingOCRComparison) {
                    if store.meetingTruthOCRValueComparisons.isEmpty {
                        EmptyStateView(
                            systemImage: "text.viewfinder",
                            title: "还没有 OCR/原图差异",
                            message: "导入手写纪要或截图后，先运行 Gemma 4 读取图片；这里会显示 OCR 文本分析和原图多模态理解的差别。"
                        )
                        .frame(minHeight: 104)
                    } else {
                        ForEach(store.meetingTruthOCRValueComparisons) { comparison in
                            MeetingTruthOCRValueComparisonRow(
                                comparison: comparison,
                                confidenceColor: confidenceColor(comparison.confidence)
                            )
                        }
                    }
                } label: {
                    sectionLabel("仅 OCR vs Gemma 原图", systemImage: "text.viewfinder", count: "\(store.meetingTruthOCRValueComparisons.count) 项")
                }

                Divider()

                DisclosureGroup(isExpanded: $isShowingCorrectionLedger) {
                    if store.meetingTruthCorrectionLedger.isEmpty {
                        EmptyStateView(
                            systemImage: "checklist.checked",
                            title: "还没有修正台账",
                            message: "导入至少两路候选转写并运行冲突发现后，这里会列出不能直接采用 ASR 的片段、采用结论和交叉校验证据。"
                        )
                        .frame(minHeight: 104)
                    } else {
                        ForEach(store.meetingTruthCorrectionLedger) { row in
                            MeetingTruthCorrectionLedgerRowView(
                                row: row,
                                confidenceColor: confidenceColor(row.confidence)
                            )
                        }
                    }
                } label: {
                    sectionLabel("为什么这样修改", systemImage: "checklist.checked", count: "\(store.meetingTruthCorrectionLedger.count) 条")
                }

                Divider()

                DisclosureGroup(isExpanded: $isShowingSubjectComparison) {
                    if store.meetingTruthMultimodalSubjectComparisons.isEmpty {
                        EmptyStateView(
                            systemImage: "tablecells.badge.ellipsis",
                            title: "还没有可见差异",
                            message: "先导入候选转写和图片，再运行 Gemma 4 读取图片或发现冲突；这里会按术语、数字、待办、冲突片段展示四种结果。"
                        )
                        .frame(minHeight: 112)
                    } else {
                        ForEach(store.meetingTruthMultimodalSubjectComparisons) { comparison in
                            MeetingTruthSubjectComparisonCard(
                                comparison: comparison,
                                confidenceColor: confidenceColor(comparison.confidence)
                            )
                        }
                    }
                } label: {
                    sectionLabel("不同来源的说法对照", systemImage: "tablecells", count: "\(store.meetingTruthMultimodalSubjectComparisons.count) 项")
                }

                Divider()

                DisclosureGroup(isExpanded: $isShowingVisualEvidence) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("原图经 image_url 进入 Gemma 4；这里展示手写、版式、圈注、箭头和 OCR 文本会丢失的线索。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            store.applyMeetingTruthVisualEvidenceToASRHotwords()
                        } label: {
                            Label("辅助：写入 ASR 热词", systemImage: "text.badge.checkmark")
                        }
                        .disabled(store.meetingTruthASRIterationTerms.isEmpty)
                        Button {
                            store.applyMeetingTruthVisualEvidenceAndRerunASR()
                        } label: {
                            Label("辅助：写入并重跑 ASR", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .disabled(store.meetingTruthASRIterationTerms.isEmpty || store.selectedAudioPath.isEmpty || store.isRunning)
                        Button {
                            if store.isExtractingMeetingTruthVisualEvidence {
                                store.cancelMeetingTruthTask()
                            } else {
                                store.extractMeetingTruthVisualEvidenceWithGemma()
                            }
                        } label: {
                            Label(
                                store.isExtractingMeetingTruthVisualEvidence ? "停止" : "Gemma 4 读取图片",
                                systemImage: store.isExtractingMeetingTruthVisualEvidence ? "stop.circle" : "eye"
                            )
                        }
                        .tint(store.isExtractingMeetingTruthVisualEvidence ? .red : .accentColor)
                        .disabled(!store.isExtractingMeetingTruthVisualEvidence && store.meetingTruthImageMaterials.isEmpty)
                    }

                    if store.meetingTruthVisualEvidence.isEmpty {
                        EmptyStateView(
                            systemImage: "photo.on.rectangle.angled",
                            title: store.meetingTruthImageMaterials.isEmpty ? "还没有图片材料" : "图片尚未生成可见证据",
                            message: store.meetingTruthImageMaterials.isEmpty
                                ? "导入截图、白板或手写笔记后，这里会展示 Gemma 4 读到的数字、关键词和待办线索。"
                                : "点击“Gemma 4 读取图片”，让多模态能力变成可展示证据。"
                        )
                        .frame(minHeight: 110)
                    } else {
                        ForEach(store.meetingTruthVisualEvidence) { evidence in
                            let material = store.meetingTruthImageMaterials.first { $0.id == evidence.materialID }
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(evidence.materialName)
                                        .font(.subheadline.weight(.semibold))
                                    CapabilityBadge(title: evidence.confidence.title, color: confidenceColor(evidence.confidence))
                                    Spacer()
                                    Toggle("用于 ASR 迭代", isOn: Binding(
                                        get: { evidence.useForASRIteration },
                                        set: { store.setMeetingTruthVisualEvidenceForASR(evidence.id, enabled: $0) }
                                    ))
                                    .font(.caption)
                                    .toggleStyle(.switch)
                                    Text(evidence.model)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Text(evidence.summary)
                                    .textSelection(.enabled)
                                if let ocrText = material?.extractedText.trimmingCharacters(in: .whitespacesAndNewlines),
                                   !ocrText.isEmpty {
                                    Text("本机 OCR 基线：\(ocrPreview(ocrText))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                                if !evidence.extractedNumbers.isEmpty {
                                    Text("数字/编号：\(evidence.extractedNumbers.joined(separator: "、"))")
                                        .font(.caption)
                                        .textSelection(.enabled)
                                }
                                if !evidence.keywords.isEmpty {
                                    Text("关键词：\(evidence.keywords.joined(separator: "、"))")
                                        .font(.caption)
                                        .textSelection(.enabled)
                                }
                                if !evidence.participants.isEmpty {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("参会人员/人名证据")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.blue)
                                        ForEach(evidence.participants) { participant in
                                            Text("• \(participant.displayText) · \(participant.confidence.title)\(participant.evidence.isEmpty ? "" : " · \(participant.evidence)")")
                                                .font(.caption)
                                                .textSelection(.enabled)
                                        }
                                    }
                                }
                                if !evidence.iterationTerms.isEmpty {
                                    Text(evidence.useForASRIteration
                                         ? "ASR 迭代词：\(evidence.iterationTerms.joined(separator: "、"))"
                                         : "待确认 ASR 候选：\(evidence.iterationTerms.joined(separator: "、"))")
                                        .font(.caption)
                                        .foregroundStyle(evidence.useForASRIteration ? .green : .orange)
                                        .textSelection(.enabled)
                                }
                                if !evidence.actionHints.isEmpty {
                                    Text("疑似待办：\(evidence.actionHints.joined(separator: "、"))")
                                        .font(.caption)
                                        .textSelection(.enabled)
                                }
                                if !evidence.layoutCues.isEmpty {
                                    Text("版式结构：\(evidence.layoutCues.joined(separator: "、"))")
                                        .font(.caption)
                                        .foregroundStyle(.blue)
                                        .textSelection(.enabled)
                                }
                                if !evidence.visualMarks.isEmpty {
                                    Text("圈注/箭头/提示框：\(evidence.visualMarks.joined(separator: "、"))")
                                        .font(.caption)
                                        .foregroundStyle(.purple)
                                        .textSelection(.enabled)
                                }
                                if !evidence.ocrContrast.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    Text("仅 OCR 会丢失：\(evidence.ocrContrast)")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                        .textSelection(.enabled)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(.green.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                } label: {
                    sectionLabel("图片和资料参考", systemImage: "photo.on.rectangle.angled", count: "\(store.meetingTruthVisualEvidence.count) 条")
                }
            }
        }
    }

    private func confidenceColor(_ confidence: MeetingTruthConfidence) -> Color {
        switch confidence {
        case .high: .green
        case .medium: .blue
        case .low: .orange
        }
    }

    private func ocrPreview(_ text: String) -> String {
        text.count > 120 ? "\(text.prefix(120))..." : text
    }

    private func sectionLabel(_ title: String, systemImage: String, count: String) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
            Spacer()
            Text(count)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }
}

private struct MeetingTruthMultimodalCallCard: View {
    let status: MeetingTruthMultimodalCallStatus

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: status.isMultimodalCallProven ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(status.isMultimodalCallProven ? .green : .orange)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(status.title)
                        .font(.subheadline.weight(.semibold))
                    CapabilityBadge(title: status.model, color: .purple)
                }
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                    GridRow {
                        callLine("原图", status.rawImageInput)
                        callLine("OCR", status.ocrTextInput)
                    }
                    GridRow {
                        callLine("ASR", status.asrInput)
                        callLine("融合", status.fusionInput)
                    }
                }
            }
            Spacer()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(status.isMultimodalCallProven ? Color.green.opacity(0.08) : Color.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func callLine(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct MeetingTruthDecisionOverviewBar: View {
    let overview: MeetingTruthDecisionOverview

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(overview.title)
                        .font(.subheadline.weight(.semibold))
                    Text(overview.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Label(overview.nextAction, systemImage: "arrow.forward.circle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.blue)
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    ForEach(overview.metrics) { metric in
                        metricCell(metric)
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func metricCell(_ metric: MeetingTruthDecisionOverview.Metric) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: metric.isReady ? "checkmark.circle.fill" : "circle.dashed")
                    .font(.caption2)
                    .foregroundStyle(metric.isReady ? .green : .secondary)
                Text(metric.title)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            Text(metric.value)
                .font(.subheadline.weight(.semibold))
            Text(metric.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MeetingTruthMultimodalProofCard: View {
    let proof: MeetingTruthMultimodalProof

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: proof.isProven ? "checkmark.shield.fill" : "clock.badge.exclamationmark")
                    .font(.title3)
                    .foregroundStyle(proof.isProven ? .green : .orange)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(proof.title)
                            .font(.subheadline.weight(.semibold))
                        CapabilityBadge(title: proof.model, color: .purple)
                    }
                    Text(timeLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    proofColumn("输入通道", proof.inputSummary)
                    proofColumn("Gemma 4 产出", proof.outputSummary)
                    proofColumn("影响判断", proof.derivedJudgementSummary)
                }
            }

            if !proof.rawImageInputs.isEmpty {
                Text("原图输入：\(proof.rawImageInputs.prefix(3).joined(separator: " / "))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !proof.missingRequirements.isEmpty {
                Text("待补齐：\(proof.missingRequirements.joined(separator: " / "))")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(proof.isProven ? Color.green.opacity(0.07) : Color.orange.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var timeLine: String {
        guard let latestCallAt = proof.latestCallAt else {
            return "最近读图：暂无 Gemma 4 原图调用结果"
        }
        return "最近读图：\(Self.dateFormatter.string(from: latestCallAt))"
    }

    private func proofColumn(_ title: String, _ values: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                Text(value)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
}

private struct MeetingTruthArbitrationWorkbench: View {
    @EnvironmentObject private var store: LabStore
    @Binding var isExpanded: Bool

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                MeetingTruthWorkflowNodeStrip(nodes: store.meetingTruthArbitrationWorkflowNodes)

                HStack(alignment: .top, spacing: 12) {
                    MeetingTruthArbitrationTuningPanel()
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    MeetingTruthArbitrationSummaryPanel(decisions: store.meetingTruthArbitrationDecisions)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }

                if store.meetingTruthArbitrationDecisions.isEmpty {
                    EmptyStateView(
                        systemImage: "scale.3d",
                        title: "等待冲突输入",
                        message: "导入至少两路 ASR 并运行冲突发现后，仲裁引擎会显示每个结论的证据评分、阈值和参数影响。"
                    )
                    .frame(minHeight: 112)
                } else {
                    ForEach(store.meetingTruthArbitrationDecisions) { decision in
                        MeetingTruthArbitrationDecisionRow(decision: decision)
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            HStack {
                Label("为什么这样判断", systemImage: "slider.horizontal.3")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(store.meetingTruthArbitrationDecisions.count) 个决策")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color.indigo.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.indigo.opacity(0.16))
        }
    }
}

private struct MeetingTruthWorkflowNodeStrip: View {
    let nodes: [MeetingTruthArbitrationWorkflowNode]

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 142), spacing: 8)],
            alignment: .leading,
            spacing: 8
        ) {
            ForEach(nodes) { node in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 5) {
                        Image(systemName: icon(for: node.state))
                            .font(.caption)
                            .foregroundStyle(color(for: node.state))
                        Text(node.title)
                            .font(.caption.weight(.bold))
                    }
                    Text(node.subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(node.result)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .frame(maxWidth: .infinity, minHeight: 86, alignment: .topLeading)
                .background(color(for: node.state).opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 7))
            }
        }
    }

    private func icon(for state: MeetingTruthArbitrationWorkflowNode.State) -> String {
        switch state {
        case .ready: "checkmark.circle.fill"
        case .waiting: "circle.dashed"
        case .warning: "exclamationmark.circle.fill"
        }
    }

    private func color(for state: MeetingTruthArbitrationWorkflowNode.State) -> Color {
        switch state {
        case .ready: .green
        case .waiting: .secondary
        case .warning: .orange
        }
    }
}

private struct MeetingTruthArbitrationTuningPanel: View {
    @EnvironmentObject private var store: LabStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("仲裁参数", systemImage: "dial.low")
                    .font(.caption.weight(.bold))
                Spacer()
                Button {
                    store.resetMeetingTruthArbitrationConfig()
                } label: {
                    Label("默认", systemImage: "arrow.counterclockwise")
                }
                .font(.caption)
            }

            tuningSlider("ASR 共识", value: \.asrConsensusWeight, range: 0...0.8)
            tuningSlider("原图权重", value: \.visualEvidenceWeight, range: 0...0.8)
            tuningSlider("OCR 权重", value: \.ocrEvidenceWeight, range: 0...0.5)
            tuningSlider("材料权重", value: \.textMaterialWeight, range: 0...0.5)
            tuningSlider("人工阈值", value: \.humanReviewThreshold, range: 0.3...0.95)
            tuningSlider("高风险惩罚", value: \.highRiskPenalty, range: 0...0.5)

            Toggle("允许原图补足 ASR 缺失术语", isOn: boolBinding(\.allowVisualToPromoteMissingASRTerms))
                .font(.caption)
            Toggle("数字/人名/日期更严格", isOn: boolBinding(\.strictHighRiskReview))
                .font(.caption)
        }
        .padding(10)
        .background(.background.opacity(0.62))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.secondary.opacity(0.12))
        }
    }

    private func tuningSlider(
        _ title: String,
        value: WritableKeyPath<MeetingTruthArbitrationConfig, Double>,
        range: ClosedRange<Double>
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(percent(store.meetingTruthArbitrationConfig[keyPath: value]))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { store.meetingTruthArbitrationConfig[keyPath: value] },
                    set: { newValue in
                        store.updateMeetingTruthArbitrationConfig { config in
                            config[keyPath: value] = newValue
                        }
                    }
                ),
                in: range
            )
        }
    }

    private func boolBinding(_ keyPath: WritableKeyPath<MeetingTruthArbitrationConfig, Bool>) -> Binding<Bool> {
        Binding(
            get: { store.meetingTruthArbitrationConfig[keyPath: keyPath] },
            set: { newValue in
                store.updateMeetingTruthArbitrationConfig { config in
                    config[keyPath: keyPath] = newValue
                }
            }
        )
    }

    private func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}

private struct MeetingTruthArbitrationSummaryPanel: View {
    let decisions: [MeetingTruthArbitrationDecision]

    var body: some View {
        let reviewCount = decisions.filter(\.needsHumanReview).count
        let acceptedCount = decisions.filter { $0.decision == .accept }.count
        let averageScore = decisions.isEmpty ? 0 : decisions.map(\.score).reduce(0, +) / Double(decisions.count)

        return VStack(alignment: .leading, spacing: 8) {
            Label("决策账本概览", systemImage: "chart.bar.doc.horizontal")
                .font(.caption.weight(.bold))
            HStack(spacing: 8) {
                summaryCell("自动接受", "\(acceptedCount)")
                summaryCell("需确认", "\(reviewCount)")
                summaryCell("平均分", "\(Int((averageScore * 100).rounded()))%")
            }
            Text("这些分数不是替代 Gemma 4，而是把 ASR 共识、原图证据、OCR、文本材料和人工确认的影响显式化。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(.background.opacity(0.62))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.secondary.opacity(0.12))
        }
    }

    private func summaryCell(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

private struct MeetingTruthArbitrationDecisionRow: View {
    let decision: MeetingTruthArbitrationDecision

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                CapabilityBadge(title: decision.decision.title, color: decision.needsHumanReview ? .orange : .green)
                Text(decision.subject)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(scoreText)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(decision.needsHumanReview ? .orange : .green)
            }

            Text(decision.claim)
                .font(.caption)
                .textSelection(.enabled)

            HStack(alignment: .center, spacing: 8) {
                ProgressView(value: decision.score, total: 1)
                    .tint(decision.needsHumanReview ? .orange : .green)
                Text("阈值 \(percent(decision.threshold))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                alignment: .leading,
                spacing: 8
            ) {
                evidenceList("支持证据", items: decision.supportingEvidence)
                evidenceList("反向证据", items: decision.contradictingEvidence)
            }

            Text("评分：\(decision.scoreBreakdown.joined(separator: " / "))")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Text(decision.parameterEffect)
                .font(.caption2)
                .foregroundStyle(.blue)
                .fixedSize(horizontal: false, vertical: true)
            Text(decision.gemmaRole)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background((decision.needsHumanReview ? Color.orange : Color.green).opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var scoreText: String {
        "\(percent(decision.score)) · \(decision.confidence.title)"
    }

    private func evidenceList(_ title: String, items: [MeetingTruthEvidenceItem]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            if items.isEmpty {
                Text("无")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(items.prefix(4)) { item in
                    Text("【\(item.channel.title)】\(item.source)：\(item.text) · \(percent(item.weight))")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(8)
        .background(.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}

private struct MeetingTruthInputRouteTable: View {
    let routes: [MeetingTruthInputRoute]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("输入路由与多模态边界", systemImage: "arrow.triangle.branch")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(routes.filter(\.isActive).count)/\(routes.count) 路有效")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            ForEach(routes) { route in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: route.isActive ? "checkmark.circle.fill" : "circle.dashed")
                        .font(.caption)
                        .foregroundStyle(route.isActive ? .green : .secondary)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(route.channel)
                                .font(.caption.weight(.semibold))
                            CapabilityBadge(title: route.isMultimodal ? "多模态" : "文本/基线", color: route.isMultimodal ? .blue : .secondary)
                            Text(route.input)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text(route.route)
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(route.role)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(8)
                .background(route.isMultimodal ? Color.blue.opacity(0.07) : Color.secondary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 7))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.secondary.opacity(0.12))
        }
    }
}

private struct MeetingTruthEvidenceChannelCard: View {
    let channel: MeetingTruthEvidenceChannelStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Image(systemName: channel.isActive ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(channel.isActive ? .green : .secondary)
                Text(channel.title)
                    .font(.caption.weight(.semibold))
                Spacer()
            }
            Text(channel.value)
                .font(.caption.weight(.medium))
            Text(channel.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(channel.isActive ? Color.blue.opacity(0.08) : Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct MeetingTruthImpactModeCard: View {
    let row: MeetingTruthMultimodalImpactRow
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                CapabilityBadge(title: row.mode.title, color: isSelected ? .blue : .secondary)
                Spacer()
                Label(row.isReady ? "可对照" : "缺输入", systemImage: row.isReady ? "checkmark.circle.fill" : "circle.dashed")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(row.isReady ? .green : .secondary)
            }

            Text(row.visibleEffect)
                .font(.caption)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                Text("输入：\(row.inputChannels.isEmpty ? "暂无" : row.inputChannels.joined(separator: " / "))")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(row.effectItems.prefix(3), id: \.self) { item in
                    Label(item, systemImage: "smallcircle.filled.circle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("限制：\(row.limitation)")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(10)
        .background(isSelected ? Color.blue.opacity(0.10) : Color.secondary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct MeetingTruthImpactFindingCard: View {
    let finding: MeetingTruthMultimodalImpactFinding
    let confidenceColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                CapabilityBadge(title: finding.kind.title, color: confidenceColor)
                Text(finding.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Text(finding.confidence.title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(confidenceColor)
            }

            HStack(alignment: .top, spacing: 8) {
                impactColumn(title: "不用多模态", text: finding.withoutMultimodal, color: .orange)
                Image(systemName: "arrow.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 19)
                impactColumn(title: "使用后", text: finding.withMultimodal, color: .green)
            }

            Text("证据：\(finding.evidence)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.green.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func impactColumn(title: String, text: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(color)
            Text(text)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(8)
        .background(color.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

private struct MeetingTruthSubjectComparisonCard: View {
    let comparison: MeetingTruthMultimodalSubjectComparison
    let confidenceColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                CapabilityBadge(title: comparison.kind.title, color: confidenceColor)
                Text(comparison.subject)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Text(comparison.confidence.title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(confidenceColor)
            }

            Grid(alignment: .topLeading, horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    comparisonColumn(title: "仅 ASR 文本", text: comparison.asrOnly, color: .orange)
                    comparisonColumn(title: "仅图片", text: comparison.visionOnly, color: .blue)
                }
                GridRow {
                    comparisonColumn(title: "分别应用", text: comparison.separateUse, color: .secondary)
                    comparisonColumn(title: "多模态融合", text: comparison.fusedUse, color: .green)
                }
            }

            Text("证据：\(comparison.evidence)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.green.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func comparisonColumn(title: String, text: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(color)
            Text(text)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(8)
        .background(color.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

private struct MeetingTruthOCRValueComparisonRow: View {
    let comparison: MeetingTruthOCRValueComparison
    let confidenceColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                CapabilityBadge(title: comparison.kind.title, color: confidenceColor)
                Text(comparison.subject)
                    .font(.subheadline.weight(.semibold))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(comparison.confidence.title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(confidenceColor)
            }

            Grid(alignment: .topLeading, horizontalSpacing: 10, verticalSpacing: 7) {
                GridRow {
                    MeetingTruthCompactEvidenceCell(title: "仅 OCR 文本", value: comparison.ocrOnly)
                    MeetingTruthCompactEvidenceCell(title: "Gemma 原图", value: comparison.gemmaImage)
                }
                GridRow {
                    MeetingTruthCompactEvidenceCell(title: "融合影响", value: comparison.fusedImpact)
                    MeetingTruthCompactEvidenceCell(title: "证据", value: comparison.evidence)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct MeetingTruthCorrectionLedgerRowView: View {
    let row: MeetingTruthCorrectionLedgerRow
    let confidenceColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                CapabilityBadge(title: row.confidence.title, color: confidenceColor)
                Text(row.subject)
                    .font(.subheadline.weight(.semibold))
                    .textSelection(.enabled)
                Spacer()
                Text(row.status)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(confidenceColor)
            }

            Grid(alignment: .topLeading, horizontalSpacing: 10, verticalSpacing: 7) {
                GridRow {
                    MeetingTruthCompactEvidenceCell(title: "ASR 候选风险", value: row.asrRisk)
                    MeetingTruthCompactEvidenceCell(title: "采用/建议结论", value: row.selectedConclusion)
                }
                GridRow {
                    MeetingTruthCompactEvidenceCell(title: "交叉校验", value: row.crossCheck)
                    MeetingTruthCompactEvidenceCell(title: "图片参与判断", value: row.visualEvidence)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(confidenceColor.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct MeetingTruthCompactEvidenceCell: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MeetingTruthMaterialPanel: View {
    @EnvironmentObject private var store: LabStore
    @State private var isShowingAuxiliaryInputs = false
    let showTemplates: () -> Void
    let editKeywords: () -> Void
    let selectHistoricalASR: () -> Void
    let previewMaterial: (MeetingTruthMaterial) -> Void

    var body: some View {
        Surface {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    Label("会议资料", systemImage: "tray.full")
                        .font(.headline)
                    Spacer()
                    CapabilityBadge(title: "主输入", color: .blue)
                }

                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                    alignment: .leading,
                    spacing: 10
                ) {
                    MeetingTruthPrimaryInputButton(
                        title: "导入会议资料",
                        detail: "PDF、PPT、图片、术语表、录音",
                        systemImage: "tray.and.arrow.down"
                    ) {
                        openMaterialPanel()
                    }

                    MeetingTruthPrimaryInputButton(
                        title: "选择本地 ASR 历史",
                        detail: "从已有转写中选至少两路候选",
                        systemImage: "clock.arrow.circlepath"
                    ) {
                        selectHistoricalASR()
                    }
                    .disabled(store.meetingTruthHistoricalASRResults.count < 2)
                }

                ForEach(store.meetingTruthMaterials) { material in
                    HStack(spacing: 10) {
                        Image(systemName: icon(for: material.kind))
                            .foregroundStyle(.blue)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(material.name)
                                .lineLimit(1)
                            Text("\(material.kind) · \(material.detail)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        if material.kind == "图片", material.localPath != nil {
                            Button("查看") {
                                previewMaterial(material)
                            }
                            .font(.caption)
                        }
                        Button {
                            store.removeMeetingTruthMaterial(material.id)
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                        .help("删除这份资料")
                    }
                    if material.id != store.meetingTruthMaterials.last?.id {
                        Divider()
                    }
                }

                if store.meetingTruthMaterials.isEmpty {
                    EmptyStateView(
                        systemImage: "tray.and.arrow.down",
                        title: "还没有会议资料",
                        message: "请导入真实会议录音、PDF、PPT、图片或术语表。"
                    )
                    .frame(minHeight: 110)
                }

                Divider()

                HStack(alignment: .top) {
                    Text("候选转写")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(store.meetingTruthTranscriptSources.count) 路")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(store.meetingTruthTranscriptSources.count >= 2 ? .green : .orange)
                }

                ForEach(store.meetingTruthTranscriptSources) { source in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(source.name)
                            .font(.subheadline.weight(.medium))
                        Text(source.hasTimestamp ? "含时间戳" : "无时间戳 · Gemma 4 将使用片段序号定位")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(source.hasTimestamp ? .green : .orange)
                        Text(source.preview)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                if store.meetingTruthTranscriptSources.isEmpty {
                    Text("尚未导入候选转写。至少需要两份 UTF-8 文本，才能执行多源冲突发现。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                DisclosureGroup(isExpanded: $isShowingAuxiliaryInputs) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Button {
                                openTranscriptPanel()
                            } label: {
                                Label("手动导入候选转写", systemImage: "text.badge.plus")
                            }
                            Button {
                                store.importMeetingTruthImageFromClipboard()
                            } label: {
                                Label("从剪贴板导入图片", systemImage: "photo.badge.plus")
                            }
                            Button {
                                editKeywords()
                            } label: {
                                Label("编辑关键词", systemImage: "text.book.closed")
                            }
                            Button {
                                showTemplates()
                            } label: {
                                Label("查看模板", systemImage: "doc.questionmark")
                            }
                        }
                        Text("PDF 和文本会在本机提取文字；图片会直接作为 Gemma 多模态输入参与冲突校验和纪要生成。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 6)
                } label: {
                    Label("辅助输入与模板", systemImage: "slider.horizontal.3")
                        .font(.subheadline.weight(.semibold))
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func openMaterialPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "导入"
        if panel.runModal() == .OK {
            store.importMeetingTruthMaterials(from: panel.urls)
        }
    }

    private func openTranscriptPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            .plainText,
            .json,
            .commaSeparatedText,
            UTType(filenameExtension: "md") ?? .plainText
        ]
        panel.allowsMultipleSelection = true
        panel.prompt = "导入"
        if panel.runModal() == .OK {
            store.importMeetingTruthTranscriptSources(from: panel.urls)
        }
    }

    private func icon(for kind: String) -> String {
        switch kind {
        case "会议录音": "waveform"
        case "会议材料": "doc.richtext"
        case "术语表", "文本 / 术语表": "text.book.closed"
        default: "photo"
        }
    }
}

private struct MeetingTruthPrimaryInputButton: View {
    let title: String
    let detail: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(.blue)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
            .background(Color.blue.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

private struct MeetingTruthConflictCheckPanel: View {
    @EnvironmentObject private var store: LabStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("检查转写冲突")
                        .font(.title2.weight(.semibold))
                    Text("Gemma 4 会先比对多路候选转写，再结合材料与图片证据回看全文。")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if store.isDiscoveringMeetingTruthConflicts || store.isResolvingMeetingTruthConflicts {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            HStack(alignment: .top, spacing: 12) {
                MeetingTruthRunStatusCard(
                    title: store.isDiscoveringMeetingTruthConflicts ? "正在发现冲突" : "冲突发现",
                    detail: discoverDetail,
                    systemImage: "magnifyingglass",
                    color: store.isDiscoveringMeetingTruthConflicts ? .orange : (store.hasDiscoveredMeetingTruthConflicts ? .green : .blue)
                )

                MeetingTruthRunStatusCard(
                    title: store.isResolvingMeetingTruthConflicts ? "正在交叉校验" : "证据校验",
                    detail: resolveDetail,
                    systemImage: "sparkles",
                    color: store.isResolvingMeetingTruthConflicts ? .orange : (store.meetingTruthConflicts.isEmpty ? .secondary : .purple)
                )
            }

            HStack(spacing: 10) {
                Button {
                    if store.isDiscoveringMeetingTruthConflicts {
                        store.cancelMeetingTruthTask()
                    } else {
                        store.discoverMeetingTruthConflictsWithGemma()
                    }
                } label: {
                    Label(
                        store.isDiscoveringMeetingTruthConflicts ? "停止冲突检查" : "开始检查冲突",
                        systemImage: store.isDiscoveringMeetingTruthConflicts ? "stop.circle" : "magnifyingglass"
                    )
                }
                .tint(store.isDiscoveringMeetingTruthConflicts ? .red : .accentColor)
                .disabled(!store.isDiscoveringMeetingTruthConflicts && store.meetingTruthTranscriptSources.count < 2)

                Button {
                    if store.isResolvingMeetingTruthConflicts {
                        store.cancelMeetingTruthTask()
                    } else {
                        store.resolveMeetingTruthConflictsWithGemma()
                    }
                } label: {
                    Label(
                        store.isResolvingMeetingTruthConflicts ? "停止证据校验" : "复查已有冲突",
                        systemImage: store.isResolvingMeetingTruthConflicts ? "stop.circle" : "sparkles"
                    )
                }
                .tint(store.isResolvingMeetingTruthConflicts ? .red : .accentColor)
                .disabled(!store.isResolvingMeetingTruthConflicts && store.meetingTruthConflicts.isEmpty)

                Button("加载示例") {
                    store.loadMeetingTruthDemo()
                }
            }

            Text(store.meetingTruthValidationStatus)
                .font(.caption.weight(.medium))
                .foregroundStyle(statusColor)
                .fixedSize(horizontal: false, vertical: true)

            if let error = store.meetingTruthError {
                MeetingTruthInlineError(error: error)
            }
        }
    }

    private var discoverDetail: String {
        if store.isDiscoveringMeetingTruthConflicts {
            return store.meetingTruthValidationStatus
        }
        if store.hasDiscoveredMeetingTruthConflicts {
            return "已发现 \(store.meetingTruthConflicts.count) 个冲突片段。"
        }
        if store.meetingTruthTranscriptSources.count < 2 {
            return "至少需要两路候选转写。"
        }
        return "输入已就绪，可以开始检查。"
    }

    private var resolveDetail: String {
        if store.isResolvingMeetingTruthConflicts {
            return store.meetingTruthValidationStatus
        }
        if store.meetingTruthConflicts.isEmpty {
            return "发现冲突后再运行证据校验。"
        }
        return "可对 \(store.meetingTruthConflicts.count) 个冲突重新生成建议和证据。"
    }

    private var statusColor: Color {
        store.isDiscoveringMeetingTruthConflicts || store.isResolvingMeetingTruthConflicts ? .orange : .secondary
    }
}

private struct MeetingTruthRunStatusCard: View {
    let title: String
    let detail: String
    let systemImage: String
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .background(color.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct MeetingTruthInlineError: View {
    @EnvironmentObject private var store: LabStore
    let error: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("操作失败", systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.red)
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
            Button("关闭提示") {
                store.dismissMeetingTruthError()
            }
            .font(.caption)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.red.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct MeetingTruthProgressPanel: View {
    @EnvironmentObject private var store: LabStore
    let showTemplates: () -> Void

    var body: some View {
        Surface {
            VStack(alignment: .leading, spacing: 12) {
                Label("可信整理进度", systemImage: "checkmark.shield")
                    .font(.headline)

                ProgressView(value: store.meetingTruthOverallProgress)

                HStack(spacing: 10) {
                    MetricPill(title: "冲突片段", value: "\(store.meetingTruthConflicts.count)")
                    MetricPill(title: "已确认", value: "\(store.meetingTruthResolvedCount)")
                    MetricPill(title: "待人工确认", value: "\(store.meetingTruthReviewCount)")
                }

                VStack(alignment: .leading, spacing: 5) {
                    MeetingTruthStageRow(
                        title: "1. 导入",
                        detail: "会议资料和至少两份候选转写",
                        isComplete: store.meetingTruthTranscriptSources.count >= 2
                    )
                    MeetingTruthStageRow(
                        title: "2. 发现冲突",
                        detail: "Gemma 4 对照候选转写",
                        isComplete: store.hasDiscoveredMeetingTruthConflicts
                    )
                    MeetingTruthStageRow(
                        title: "3. 人工确认",
                        detail: "确认低置信片段和关键数字",
                        isComplete: !store.meetingTruthConflicts.isEmpty && store.meetingTruthUnresolvedCount == 0
                    )
                    MeetingTruthStageRow(
                        title: "4. 复核",
                        detail: "多模态中枢复核",
                        isComplete: store.meetingTruthCentralReviewLedger != nil &&
                            store.meetingTruthPendingCentralReviewClaims.isEmpty &&
                            store.meetingTruthCentralReviewBlockingItems.isEmpty
                    )
                    MeetingTruthStageRow(
                        title: "5. 生成",
                        detail: "生成逐字稿、纪要、待办和思维导图",
                        isComplete: store.meetingTruthAnalysis != nil
                    )
                }

                HStack(spacing: 8) {
                    Button("查看模板") {
                        showTemplates()
                    }

                    Button("清空成果") {
                        store.clearMeetingTruthResults()
                    }
                    .disabled(store.meetingTruthConflicts.isEmpty && store.meetingTruthAnalysis == nil)

                    Button(role: .destructive) {
                        store.resetMeetingTruthProject()
                    } label: {
                        Label("清空项目", systemImage: "trash")
                    }
                    .disabled(!store.hasMeetingTruthInput && store.meetingTruthAnalysis == nil)
                }

                Text(store.meetingTruthValidationStatus)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(progressHint)
                    .font(.caption)
                    .foregroundStyle(store.meetingTruthUnresolvedCount == 0 ? .green : .orange)
                    .fixedSize(horizontal: false, vertical: true)

                if let error = store.meetingTruthError {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("操作失败", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.red)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("关闭提示") {
                            store.dismissMeetingTruthError()
                        }
                        .font(.caption)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.red.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .frame(width: 430)
    }

    private var progressHint: String {
        if store.meetingTruthConflicts.isEmpty {
            if store.hasDiscoveredMeetingTruthConflicts {
                return "Gemma 4 未发现冲突，可以直接生成可信成果包。"
            }
            return "导入真实候选转写后，先让 Gemma 4 发现冲突。"
        }
        if store.meetingTruthUnresolvedCount == 0 {
            return "全部冲突已确认，可以生成可信成果包。"
        }
        if store.meetingTruthReviewCount == 0 {
            return "低置信内容已处理，请接受或复核其余高置信建议。"
        }
        return "低置信内容不会自动写入纪要，需要用户确认。"
    }
}

private struct MeetingTruthStageRow: View {
    let title: String
    let detail: String
    let isComplete: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: isComplete ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isComplete ? .green : .secondary)
            Text(title)
                .font(.caption.weight(.semibold))
                .frame(width: 72, alignment: .leading)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct MeetingTruthConflictPanel: View {
    @EnvironmentObject private var store: LabStore
    @State private var selectedHistoryEntry: MeetingTruthHistoryEntry?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("查看并确认冲突结果")
                        .font(.title2.weight(.semibold))
                    Text("逐条查看上下文、候选转写和证据；低置信或高风险片段需要人工确认。")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !store.meetingTruthConflicts.isEmpty {
                    CapabilityBadge(title: "\(store.meetingTruthUnresolvedCount) 待处理", color: store.meetingTruthUnresolvedCount == 0 ? .green : .orange)
                }
            }

            ForEach(store.meetingTruthConflicts) { conflict in
                MeetingTruthConflictCard(conflict: conflict)
            }

            if store.meetingTruthConflicts.isEmpty {
                EmptyStateView(
                    systemImage: "checkmark.shield",
                    title: store.hasDiscoveredMeetingTruthConflicts ? "未发现需要确认的冲突" : "等待真实冲突发现",
                    message: store.hasDiscoveredMeetingTruthConflicts
                        ? "Gemma 4 已完成比对，可以直接使用可信逐字稿生成会议成果包。"
                        : "导入至少两份候选转写后，点击“发现冲突”。Gemma 4 会根据真实文本、文本材料和图片原图生成待核对片段。"
                )
                .frame(minHeight: 150)
            }

            if !store.meetingTruthHistory.isEmpty {
                Surface {
                    MeetingTruthHistoryList(
                        entries: Array(store.meetingTruthHistory.prefix(8)),
                        onSelect: { selectedHistoryEntry = $0 }
                    )
                }
            }
        }
        .sheet(item: $selectedHistoryEntry) { entry in
            MeetingTruthHistoryDetailSheet(entry: entry)
        }
    }
}

private struct MeetingTruthConflictCard: View {
    @EnvironmentObject private var store: LabStore
    let conflict: MeetingTruthConflict

    var body: some View {
        Surface {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(conflict.timestamp)
                        .font(.body.monospacedDigit().weight(.semibold))
                    CapabilityBadge(title: conflict.kind.title, color: .blue)
                    CapabilityBadge(title: conflict.confidence.title, color: confidenceColor)
                    Spacer()
                    if conflict.isResolved {
                        Label("已确认", systemImage: "checkmark.circle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.green)
                    }
                }

                Text(conflict.context)
                    .foregroundStyle(.secondary)

                HStack(alignment: .top, spacing: 10) {
                    ForEach(conflict.candidates) { candidate in
                        Button {
                            store.resolveMeetingTruthConflict(conflict.id, text: candidate.text)
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(candidate.source)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(candidate.text)
                                    .font(.body.weight(.medium))
                                if conflict.selectedText == candidate.text {
                                    Label("采用", systemImage: "checkmark")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.green)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(conflict.selectedText == candidate.text ? Color.green.opacity(0.12) : Color.secondary.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.purple)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Gemma 4 建议：\(conflict.recommendation)")
                            .font(.subheadline.weight(.semibold))
                        Text(conflict.evidence)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        store.resolveMeetingTruthConflict(conflict.id, text: conflict.recommendation)
                    } label: {
                        Label(conflict.requiresHumanReview ? "确认采用建议" : "采用建议", systemImage: "checkmark.circle")
                    }
                }

                TextField(
                    "手工修订：可直接输入核对后的正确文本",
                    text: Binding(
                        get: { conflict.selectedText ?? "" },
                        set: { store.resolveMeetingTruthConflict(conflict.id, text: $0) }
                    )
                )
                .textFieldStyle(.roundedBorder)

                HStack(spacing: 10) {
                    Button {
                        store.resolveMeetingTruthConflict(conflict.id, text: conflict.recommendation)
                    } label: {
                        Label("采用本项建议", systemImage: "checkmark.circle")
                    }

                    Button {
                        store.updateMeetingTruthConflictAction(conflict.id, action: .deferForReview)
                    } label: {
                        Label("暂不处理", systemImage: "clock.badge.exclamationmark")
                    }

                    Button {
                        store.updateMeetingTruthConflictAction(conflict.id, action: .markIrrelevant)
                    } label: {
                        Label("标记无关", systemImage: "xmark.circle")
                    }

                    Spacer()

                    Button {
                        store.updateMeetingTruthConflictAction(conflict.id, action: .clearSelection)
                    } label: {
                        Label("撤销本项确认", systemImage: "arrow.counterclockwise")
                    }
                    .disabled(!conflict.isResolved)
                }
                .font(.caption)

                if let preview = store.meetingTruthReplacementPreview(for: conflict) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("替换定位预览")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        if preview.originalContexts.isEmpty {
                            Text("当前底稿中未能稳定定位原候选文本，建议人工再核一下上下文。")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        } else {
                            Text("原文命中 \(preview.originalMatchCount) 处")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ForEach(Array(preview.originalContexts.enumerated()), id: \.offset) { _, context in
                                Text(context)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(.secondary.opacity(0.08))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                        }

                        if preview.resolvedContexts.isEmpty {
                            Text("替换后的可信逐字稿里还没定位到这条文本，说明当前替换结果可能没有稳定落到正文。")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        } else {
                            Text("替换后命中 \(preview.resolvedMatchCount) 处")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ForEach(Array(preview.resolvedContexts.enumerated()), id: \.offset) { _, context in
                                Text(context)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(.green.opacity(0.10))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }
                }
            }
        }
    }

    private var confidenceColor: Color {
        switch conflict.confidence {
        case .high: .green
        case .medium: .blue
        case .low: .orange
        }
    }
}

private struct MeetingTruthCentralReviewPanel: View {
    @EnvironmentObject private var store: LabStore
    @State private var answers: [UUID: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("中枢复核")
                        .font(.title2.weight(.semibold))
                    Text("生成成果包前，把冲突确认、材料证据、图片理解和待确认缺口合并检查一遍。")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    if store.isReviewingMeetingTruthCentrally {
                        store.cancelMeetingTruthTask()
                    } else {
                        store.runMeetingTruthCentralReviewWithGemma()
                    }
                } label: {
                    Label(
                        store.isReviewingMeetingTruthCentrally ? "停止复核" : "运行中枢复核",
                        systemImage: store.isReviewingMeetingTruthCentrally ? "stop.circle" : "checkmark.shield"
                    )
                }
                .tint(store.isReviewingMeetingTruthCentrally ? .red : .accentColor)
                .disabled(!store.isReviewingMeetingTruthCentrally && !store.canRunMeetingTruthCentralReview)
            }

            HStack(alignment: .top, spacing: 12) {
                MeetingTruthRunStatusCard(
                    title: store.isReviewingMeetingTruthCentrally ? "复核执行中" : "复核状态",
                    detail: centralStatusDetail,
                    systemImage: "checkmark.shield",
                    color: centralStatusColor
                )
                MeetingTruthRunStatusCard(
                    title: "待确认问题",
                    detail: "\(store.meetingTruthPendingCentralReviewClaims.count) 条中枢问题 · \(store.meetingTruthPendingFactQuestions.count) 条事实问题",
                    systemImage: "person.crop.circle.badge.questionmark",
                    color: store.meetingTruthPendingCentralReviewClaims.isEmpty && store.meetingTruthPendingFactQuestions.isEmpty ? .green : .orange
                )
            }

            if let ledger = store.meetingTruthCentralReviewLedger {
                MeetingTruthCentralLedgerSummary(ledger: ledger)

                let blockingItems = ledger.blockingItems
                if !blockingItems.isEmpty {
                    MeetingTruthCentralItemList(
                        title: "阻塞项",
                        systemImage: "exclamationmark.triangle.fill",
                        color: .orange,
                        items: blockingItems
                    )
                }

                let advisoryItems = ledger.advisoryItems
                if !advisoryItems.isEmpty {
                    MeetingTruthCentralItemList(
                        title: "提示项",
                        systemImage: "info.circle",
                        color: .blue,
                        items: advisoryItems
                    )
                }

                if ledger.claims.isEmpty {
                    EmptyStateView(
                        systemImage: "checkmark.seal",
                        title: "暂无需要复核的事实项",
                        message: "中枢复核没有生成可逐项处理的问题。"
                    )
                    .frame(minHeight: 110)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("复核结论")
                            .font(.headline)
                        ForEach(ledger.claims) { claim in
                            MeetingTruthCentralClaimCard(
                                claim: claim,
                                answer: Binding(
                                    get: { answers[claim.id] ?? claim.proposedCanonicalText },
                                    set: { answers[claim.id] = $0 }
                                ),
                                onSave: {
                                    store.answerMeetingTruthCentralReviewClaim(
                                        claim.id,
                                        answer: answers[claim.id] ?? claim.proposedCanonicalText
                                    )
                                }
                            )
                        }
                    }
                }
            } else {
                EmptyStateView(
                    systemImage: "checkmark.shield",
                    title: "还没有中枢复核结果",
                    message: "完成冲突确认后运行中枢复核；这里会显示阻塞项、提示项和需要逐项确认的问题。"
                )
                .frame(minHeight: 138)
            }

            Text(store.meetingTruthValidationStatus)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var centralStatusDetail: String {
        if store.isReviewingMeetingTruthCentrally {
            return store.meetingTruthValidationStatus
        }
        guard let ledger = store.meetingTruthCentralReviewLedger else {
            return "等待运行中枢复核。"
        }
        if ledger.blockingItems.isEmpty {
            return ledger.advisoryItems.isEmpty ? "复核通过，可以生成成果包。" : "复核通过，提示项会写入成果包。"
        }
        return "发现 \(ledger.blockingItems.count) 个需要处理的问题。"
    }

    private var centralStatusColor: Color {
        if store.isReviewingMeetingTruthCentrally { return .orange }
        guard let ledger = store.meetingTruthCentralReviewLedger else { return .secondary }
        return ledger.blockingItems.isEmpty ? .green : .orange
    }
}

private struct MeetingTruthCentralLedgerSummary: View {
    let ledger: MeetingTruthCentralReviewLedger

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
            alignment: .leading,
            spacing: 10
        ) {
            MetricPill(title: "复核模型", value: ledger.model)
            MetricPill(title: "复核结论", value: "\(ledger.claims.count)")
            MetricPill(title: "视觉证据", value: "\(ledger.visualObservations.count)")
        }
    }
}

private struct MeetingTruthCentralItemList: View {
    let title: String
    let systemImage: String
    let color: Color
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(color)
            ForEach(Array(items.prefix(6).enumerated()), id: \.offset) { _, item in
                Text("• \(item)")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct MeetingTruthCentralClaimCard: View {
    let claim: MeetingTruthCentralClaim
    @Binding var answer: String
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                CapabilityBadge(title: claim.kind.title, color: color)
                CapabilityBadge(title: claim.status.title, color: color)
                Text(percent(claim.confidence))
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(color)
                Spacer()
            }

            Text(claim.claim)
                .font(.subheadline.weight(.semibold))
                .textSelection(.enabled)
            if !claim.sourceSpan.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(claim.sourceSpan)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Text("中枢判断：\(claim.decisionReason)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            if claim.requiresHumanReview {
                TextField("填写确认后的真实信息", text: $answer)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button {
                        onSave()
                    } label: {
                        Label("保存本项确认", systemImage: "checkmark.circle")
                    }
                    Spacer()
                    Text(claim.humanQuestion ?? "需要人工确认后才能视为通过。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                alignment: .leading,
                spacing: 8
            ) {
                evidenceColumn("支持证据", claim.supportingEvidence)
                evidenceColumn("反向证据", claim.contradictingEvidence)
            }
        }
        .padding(10)
        .background(color.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var color: Color {
        claim.requiresHumanReview ? .orange : .green
    }

    private func evidenceColumn(_ title: String, _ evidence: [MeetingTruthCentralEvidence]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            if evidence.isEmpty {
                Text("无")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(evidence.prefix(3)) { item in
                    Text("\(item.channel.title)：\(item.sourceName) · \(item.text)")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}

private struct MeetingTruthTranscriptPanel: View {
    @EnvironmentObject private var store: LabStore

    var body: some View {
        Surface {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("可信逐字稿预览", systemImage: "doc.text.magnifyingglass")
                        .font(.headline)
                    Spacer()
                    Button {
                        if store.isGeneratingMeetingTruthPackage {
                            store.cancelMeetingTruthTask()
                        } else {
                            store.generateMeetingTruthPackage()
                        }
                    } label: {
                        Label(
                            store.isGeneratingMeetingTruthPackage ? "停止" : "生成成果包",
                            systemImage: store.isGeneratingMeetingTruthPackage ? "stop.circle" : "wand.and.stars"
                        )
                    }
                    .tint(store.isGeneratingMeetingTruthPackage ? .red : .accentColor)
                    .disabled(
                        !store.isGeneratingMeetingTruthPackage &&
                        (store.meetingTruthUnresolvedCount > 0 ||
                         !store.meetingTruthPendingFactQuestions.isEmpty ||
                         !store.meetingTruthPendingCentralReviewClaims.isEmpty ||
                         !store.hasDiscoveredMeetingTruthConflicts ||
                         store.meetingTruthTrustedTranscript.isEmpty)
                    )
                }

                Text(store.meetingTruthTrustedTranscript)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(.quaternary.opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                if store.meetingTruthTrustedTranscript.isEmpty {
                    Text("等待真实候选转写。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text("以候选全文为底稿替换已确认冲突。成果包会结合可信逐字稿、文本材料，以及直接发送给 Gemma 的图片原图。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct MeetingTruthPackagePanel: View {
    @EnvironmentObject private var store: LabStore

    var body: some View {
        if let analysis = store.meetingTruthAnalysis {
            Surface {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Label("会议成果包", systemImage: "shippingbox")
                            .font(.headline)
                        Spacer()
                        CapabilityBadge(title: analysis.model, color: .purple)
                        Button("清空成果") {
                            store.clearMeetingTruthResults()
                        }
                    }

                    MeetingTruthOutcomeBlock(title: "1. 可信逐字稿", systemImage: "doc.text.magnifyingglass") {
                        if let primary = store.meetingTruthPrimaryTranscriptSource {
                            Text("主底稿：\(primary.name)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let anchor = store.meetingTruthTimestampAnchorSource {
                            Text("定位锚点：\(anchor.name)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(store.meetingTruthTrustedTranscript)
                            .textSelection(.enabled)
                            .font(.body.monospaced())
                    }

                    MeetingTruthOutcomeBlock(title: "2. 正式会议纪要", systemImage: "doc.richtext") {
                        MeetingTruthBulletList(items: analysis.minutes)
                    }

                    MeetingTruthOutcomeBlock(title: "3. 思维导图", systemImage: "point.3.connected.trianglepath.dotted") {
                        MeetingMindMapCanvas(nodes: analysis.mindMap, rootTitle: "会议结果")
                    }

                    MeetingTruthOutcomeBlock(title: "4. 会后一页纸", systemImage: "doc.text") {
                        Text(analysis.summary)
                            .textSelection(.enabled)
                    }

                    MeetingTruthOutcomeBlock(title: "5. 关键要点", systemImage: "list.bullet.rectangle") {
                        MeetingTruthBulletList(items: analysis.keyPoints)
                    }

                    MeetingTruthOutcomeBlock(title: "6. 待办事项", systemImage: "checklist") {
                        if analysis.actionItems.isEmpty {
                            Text("暂无明确待办")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(analysis.actionItems) { item in
                                Text("• \(item.task) · \(item.owner ?? "待确认") · \(item.due ?? "待确认")")
                                    .textSelection(.enabled)
                            }
                        }
                    }

                    if !analysis.evidenceNotes.isEmpty {
                        MeetingTruthOutcomeBlock(title: "7. 多模态证据来源", systemImage: "link.badge.plus") {
                            MeetingTruthBulletList(items: analysis.evidenceNotes)
                        }
                    }

                    if !store.meetingTruthConclusionEvidence.isEmpty {
                        MeetingTruthOutcomeBlock(title: "8. 最终结论证据链", systemImage: "checkmark.seal.text.page") {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(store.meetingTruthConclusionEvidence) { evidence in
                                    MeetingTruthConclusionEvidenceRow(evidence: evidence)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct MeetingTruthConclusionEvidenceRow: View {
    let evidence: MeetingTruthConclusionEvidence

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                CapabilityBadge(title: evidence.kind.title, color: color(for: evidence.confidence))
                Text(evidence.conclusion)
                    .font(.subheadline.weight(.semibold))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 6) {
                MeetingTruthEvidenceLine(label: "ASR", text: evidence.asrEvidence)
                MeetingTruthEvidenceLine(label: "OCR", text: evidence.ocrEvidence)
                MeetingTruthEvidenceLine(label: "图片原图", text: evidence.imageEvidence)
                MeetingTruthEvidenceLine(label: "融合判断", text: evidence.fusionReason)
                MeetingTruthEvidenceLine(label: "不能直接采用 ASR", text: evidence.risk)
            }
            .font(.caption)
        }
        .padding(10)
        .background(.background.opacity(0.58))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.secondary.opacity(0.12))
        }
    }

    private func color(for confidence: MeetingTruthConfidence) -> Color {
        switch confidence {
        case .high: .green
        case .medium: .blue
        case .low: .orange
        }
    }
}

private struct MeetingTruthEvidenceLine: View {
    let label: String
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            Text(text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct MeetingTruthHistoryDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    let entry: MeetingTruthHistoryEntry

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.title)
                            .font(.title2.weight(.semibold))
                        Text(entry.message)
                            .foregroundStyle(.secondary)
                        Text(Self.dateTimeFormatter.string(from: entry.recordedAt))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("完成") { dismiss() }
                }

                MeetingTruthHistorySection(title: "状态概览", systemImage: "clock.arrow.circlepath") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("项目状态：\(entry.project.validationStatus)")
                        Text("成果状态：\(entry.project.packageStatus.message ?? entry.project.packageStatus.state.rawValue)")
                        if let audioPath = entry.project.selectedAudioPath, !audioPath.isEmpty {
                            Text("关联录音：\(URL(fileURLWithPath: audioPath).lastPathComponent)")
                        }
                        if let details = entry.details, !details.isEmpty {
                            Text("记录详情：\(details)")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                MeetingTruthHistorySection(title: "会议资料", systemImage: "tray.full") {
                    if entry.project.materials.isEmpty {
                        Text("当时没有导入会议资料。")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(entry.project.materials) { material in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(material.name)
                                    .font(.subheadline.weight(.medium))
                                Text("\(material.kind) · \(material.detail)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if !material.extractedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    Text(material.extractedText)
                                        .font(.caption.monospaced())
                                        .lineLimit(5)
                                        .textSelection(.enabled)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(.secondary.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }

                MeetingTruthHistorySection(title: "候选转写", systemImage: "text.alignleft") {
                    if entry.project.transcriptSources.isEmpty {
                        Text("当时没有导入候选转写。")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(entry.project.transcriptSources) { source in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(source.name)
                                    .font(.subheadline.weight(.medium))
                                Text(source.text)
                                    .font(.caption.monospaced())
                                    .lineLimit(8)
                                    .textSelection(.enabled)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(.secondary.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }

                MeetingTruthHistorySection(title: "冲突与确认", systemImage: "checkmark.shield") {
                    if entry.project.conflicts.isEmpty {
                        Text("当时没有记录到待确认冲突。")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(entry.project.conflicts) { conflict in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(conflict.timestamp) · \(conflict.kind.title) · \(conflict.confidence.title)")
                                    .font(.subheadline.weight(.medium))
                                Text(conflict.context)
                                    .font(.caption)
                                Text("建议：\(conflict.recommendation)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if let selectedText = conflict.selectedText, !selectedText.isEmpty {
                                    Text("已确认：\(selectedText)")
                                        .font(.caption)
                                        .foregroundStyle(.green)
                                }
                                Text(conflict.evidence)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(.secondary.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }

                if let transcript = entry.project.trustedTranscriptSnapshot, !transcript.isEmpty {
                    MeetingTruthHistorySection(title: "可信逐字稿", systemImage: "doc.text.magnifyingglass") {
                        Text(transcript)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(.secondary.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }

                if let analysis = entry.project.analysis {
                    MeetingTruthHistorySection(title: "会议成果包", systemImage: "shippingbox") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(analysis.summary)
                                .textSelection(.enabled)
                            if !analysis.keyPoints.isEmpty {
                                MeetingTruthBulletList(items: analysis.keyPoints)
                            }
                            if !analysis.minutes.isEmpty {
                                Divider()
                                MeetingTruthBulletList(items: analysis.minutes)
                            }
                        }
                    }
                }

                if let failure = entry.project.lastFailure {
                    MeetingTruthHistorySection(title: "失败信息", systemImage: "exclamationmark.triangle") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(failure.message)
                            if let details = failure.details, !details.isEmpty {
                                Text(details)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(22)
        }
        .frame(width: 860, height: 760)
    }

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
}

private struct MeetingTruthHistoryList: View {
    let entries: [MeetingTruthHistoryEntry]
    let onSelect: (MeetingTruthHistoryEntry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("最近记录")
                .font(.subheadline.weight(.semibold))
            ForEach(entries) { entry in
                Button {
                    onSelect(entry)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(entry.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.primary)
                            Spacer()
                            Text(Self.historyDateTimeFormatter.string(from: entry.recordedAt))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text(entry.message)
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let details = entry.details, !details.isEmpty, details != entry.message {
                            Text(details)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Text(historySummary(entry.project))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func historySummary(_ project: MeetingTruthProject) -> String {
        "材料 \(project.materials.count) · 转写 \(project.transcriptSources.count) · 冲突 \(project.conflicts.count) · \(project.packageStatus.message ?? project.validationStatus)"
    }

    private static let historyDateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter
    }()
}

private struct MeetingTruthHistorySection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        Surface {
            VStack(alignment: .leading, spacing: 10) {
                Label(title, systemImage: systemImage)
                    .font(.headline)
                content
            }
        }
    }
}

private struct MeetingTruthTemplateSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("MeetingTruth 导入模板")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("完成") { dismiss() }
            }

            Text("准备两份或更多候选转写文本。每份文本使用相同时间线，方便 Gemma 4 定位差异。会议资料可额外导入 PDF、PPT、图片、术语表或会议录音。")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            templateBlock(
                title: "候选转写文本模板",
                content: """
                00:00:12 张三：本次会议讨论项目推进安排。
                00:03:40 李四：一期预算按照 300 万元测算。
                00:08:20 王五：下周五前补充实施计划。
                """
            )

            templateBlock(
                title: "术语表模板",
                content: """
                数字金融战略
                MeetingTruth
                误识别词 => 正确术语
                """
            )

            Text("成果包固定包含：可信逐字稿、正式会议纪要、思维导图、会后一页纸、关键要点和待办事项。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(22)
        .frame(width: 640)
    }

    private func templateBlock(title: String, content: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                Button("复制") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(content, forType: .string)
                }
            }
            Text(content)
                .font(.body.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.quaternary.opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

private struct MeetingTruthKeywordSheet: View {
    @EnvironmentObject private var store: LabStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("编辑关键词与术语")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("新增分组") { store.addHotwordSet() }
                Button("完成") { dismiss() }
            }
            Text("启用后的关键词会作为 ASR 热词和 MeetingTruth 材料上下文使用。支持换行、逗号、顿号分隔，也支持“误识别 => 正确词”。")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach($store.hotwordSets) { $set in
                        Surface {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Toggle("", isOn: $set.isEnabled)
                                        .labelsHidden()
                                    TextField("关键词组名称", text: $set.name)
                                        .font(.headline)
                                }
                                TextEditor(text: Binding(
                                    get: { set.words.joined(separator: "\n") },
                                    set: { store.updateHotwords(for: set.id, text: $0) }
                                ))
                                .font(.body.monospaced())
                                .frame(minHeight: 82)
                                .scrollContentBackground(.hidden)
                                .background(.quaternary.opacity(0.3))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                }
            }
        }
        .padding(22)
        .frame(width: 660, height: 560)
    }
}

struct MeetingTruthImagePreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let material: MeetingTruthMaterial

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(material.name)
                        .font(.title2.weight(.semibold))
                    Text(material.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { dismiss() }
            }

            if let localPath = material.localPath,
               let image = NSImage(contentsOfFile: localPath) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 440)
                    .background(.quaternary.opacity(0.25))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                EmptyStateView(
                    systemImage: "photo.badge.exclamationmark",
                    title: "图片无法预览",
                    message: "本地图片文件可能已被移动或删除。"
                )
                .frame(minHeight: 180)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(material.kind == "图片" ? "Gemma 多模态图片输入" : "本机提取文字")
                    .font(.headline)
                ScrollView {
                    Text(material.extractedText.isEmpty
                         ? (material.kind == "图片"
                            ? "这张图片不会先走本机 OCR；在冲突校验和纪要生成时会直接作为 Gemma 的视觉输入。"
                            : "未提取到文字。")
                         : material.extractedText)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 80, maxHeight: 160)
                .padding(10)
                .background(.quaternary.opacity(0.25))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(22)
        .frame(width: 760, height: 680)
    }
}

struct MeetingTruthHistoricalASRSheet: View {
    @EnvironmentObject private var store: LabStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedIDs: Set<String> = []
    @State private var selectedAudioPath: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("选择本地 ASR 历史结果")
                        .font(.title2.weight(.semibold))
                    Text("选择同一段会议录音的至少两条结果。可以回溯不同批次；无时间戳文本会由 Gemma 4 使用片段序号定位。")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("取消") { dismiss() }
                Button("载入 \(selectedIDs.count) 条") {
                    if store.importMeetingTruthHistoricalASRResults(ids: selectedIDs) {
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedIDs.count < 2)
            }

            HStack {
                Label("可回溯 \(store.meetingTruthHistoricalASRResults.count) 条非空结果", systemImage: "clock.arrow.circlepath")
                    .font(.caption.weight(.medium))
                Spacer()
                if let selectedAudioPath {
                    Text("当前录音：\(URL(fileURLWithPath: selectedAudioPath).lastPathComponent)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            if let error = store.meetingTruthError {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                    Spacer()
                    Button("关闭") { store.dismissMeetingTruthError() }
                        .font(.caption)
                }
                .padding(10)
                .background(.red.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(historyEntries) { entry in
                        let candidates = candidates(for: entry)
                        Surface {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(URL(fileURLWithPath: entry.audioPath).lastPathComponent)
                                            .font(.headline)
                                            .lineLimit(1)
                                        Text(LabStore.historyDateFormatter.string(from: entry.createdAt))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text("\(candidates.count) 条")
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(.secondary)
                                }

                                ForEach(candidates) { candidate in
                                    Button {
                                        toggle(candidate)
                                    } label: {
                                        HStack(alignment: .top, spacing: 10) {
                                            Image(systemName: selectedIDs.contains(candidate.id) ? "checkmark.square.fill" : "square")
                                                .foregroundStyle(selectedIDs.contains(candidate.id) ? .blue : .secondary)
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(candidate.modelName)
                                                    .font(.subheadline.weight(.medium))
                                                    .lineLimit(1)
                                                Text(candidate.text)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(2)
                                            }
                                            Spacer()
                                            VStack(alignment: .trailing, spacing: 3) {
                                                CapabilityBadge(
                                                    title: candidate.hasTimestamp ? "含时间戳" : "无时间戳",
                                                    color: candidate.hasTimestamp ? .green : .orange
                                                )
                                                Text("\(candidate.text.count) 字")
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)

                                    if candidate.id != candidates.last?.id {
                                        Divider()
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(22)
        .frame(width: 820, height: 680)
    }

    private var historyEntries: [RunHistoryEntry] {
        store.runHistory.filter { !candidates(for: $0).isEmpty }
    }

    private func candidates(for entry: RunHistoryEntry) -> [MeetingTruthHistoricalASRResult] {
        store.meetingTruthHistoricalASRResults.filter { $0.historyID == entry.id }
    }

    private func toggle(_ candidate: MeetingTruthHistoricalASRResult) {
        if selectedIDs.remove(candidate.id) != nil {
            if selectedIDs.isEmpty {
                selectedAudioPath = nil
            }
            return
        }

        if let selectedAudioPath, selectedAudioPath != candidate.audioPath {
            selectedIDs.removeAll()
        }
        selectedAudioPath = candidate.audioPath
        selectedIDs.insert(candidate.id)
    }
}

private struct MeetingTruthOutcomeBlock<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(.quaternary.opacity(0.28))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct MeetingTruthBulletList: View {
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Text("• \(item)")
                    .textSelection(.enabled)
            }
        }
    }
}
