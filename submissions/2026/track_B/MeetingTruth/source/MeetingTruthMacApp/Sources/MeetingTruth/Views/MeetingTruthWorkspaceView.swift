import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MeetingTruthWorkspaceView: View {
    @EnvironmentObject private var store: LabStore
    @State private var isSelectingHistoricalASR = false
    @State private var previewMaterial: MeetingTruthMaterial?
    @State private var expandedStages: Set<MeetingTruthWorkspaceStage> = []

    var body: some View {
        let currentStage = MeetingTruthWorkspaceStage.current(for: store)

        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                MeetingTruthWorkspaceHeader()
                MeetingTruthWorkspaceFlowCard(currentStage: currentStage)

                MeetingTruthWorkspaceStageSection(
                    stage: .materials,
                    currentStage: currentStage,
                    isComplete: MeetingTruthWorkspaceStage.materials.isComplete(in: store),
                    isExpanded: expansionBinding(for: .materials, currentStage: currentStage)
                ) {
                    MeetingTruthAddMaterialsCard(
                        selectHistoricalASR: { isSelectingHistoricalASR = true },
                        previewMaterial: { previewMaterial = $0 }
                    )
                }

                MeetingTruthWorkspaceStageSection(
                    stage: .checkConflicts,
                    currentStage: currentStage,
                    isComplete: MeetingTruthWorkspaceStage.checkConflicts.isComplete(in: store),
                    isExpanded: expansionBinding(for: .checkConflicts, currentStage: currentStage)
                ) {
                    MeetingTruthCheckProblemsCard()
                }

                MeetingTruthWorkspaceStageSection(
                    stage: .confirmConflicts,
                    currentStage: currentStage,
                    isComplete: MeetingTruthWorkspaceStage.confirmConflicts.isComplete(in: store),
                    isExpanded: expansionBinding(for: .confirmConflicts, currentStage: currentStage)
                ) {
                    MeetingTruthConfirmChangesCard()
                }

                MeetingTruthWorkspaceStageSection(
                    stage: .centralReview,
                    currentStage: currentStage,
                    isComplete: MeetingTruthWorkspaceStage.centralReview.isComplete(in: store),
                    isExpanded: expansionBinding(for: .centralReview, currentStage: currentStage)
                ) {
                    MeetingTruthCentralReviewStatusCard()
                    MeetingTruthReadableErrorCard()
                }

                MeetingTruthWorkspaceStageSection(
                    stage: .generateResult,
                    currentStage: currentStage,
                    isComplete: MeetingTruthWorkspaceStage.generateResult.isComplete(in: store),
                    isExpanded: expansionBinding(for: .generateResult, currentStage: currentStage)
                ) {
                    MeetingTruthResultCard()
                }

                MeetingTruthActivityCard()
            }
            .padding(24)
        }
        .sheet(isPresented: $isSelectingHistoricalASR) {
            MeetingTruthHistoricalASRSheet()
        }
        .sheet(item: $previewMaterial) { material in
            MeetingTruthImagePreviewSheet(material: material)
        }
    }

    private func expansionBinding(
        for stage: MeetingTruthWorkspaceStage,
        currentStage: MeetingTruthWorkspaceStage
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

private enum MeetingTruthWorkspaceStage: Int, CaseIterable, Hashable {
    case materials
    case checkConflicts
    case confirmConflicts
    case centralReview
    case generateResult

    var number: String { "\(rawValue + 1)" }

    var title: String {
        switch self {
        case .materials: "添加会议材料"
        case .checkConflicts: "检查转写冲突"
        case .confirmConflicts: "查看并确认冲突结果"
        case .centralReview: "中枢复核"
        case .generateResult: "生成会议结果"
        }
    }

    var summary: String {
        switch self {
        case .materials: "导入资料、选择本地 ASR 历史"
        case .checkConflicts: "Gemma 4 比对多路转写和资料"
        case .confirmConflicts: "逐项确认、修订、暂不处理"
        case .centralReview: "统一检查证据账本和阻塞项"
        case .generateResult: "输出逐字稿、纪要、导图和待办"
        }
    }

    var systemImage: String {
        switch self {
        case .materials: "tray.and.arrow.down"
        case .checkConflicts: "magnifyingglass"
        case .confirmConflicts: "checklist.checked"
        case .centralReview: "checkmark.shield"
        case .generateResult: "shippingbox"
        }
    }

    var currentHint: String {
        switch self {
        case .materials:
            return "先准备真实输入。主要操作是导入资料和选择本地 ASR 历史，其他入口只是辅助。"
        case .checkConflicts:
            return "检查可能等待较久，运行时请看状态提示；完成后再进入逐项确认。"
        case .confirmConflicts:
            return "这里处理真正需要你判断的项目。已自动处理的内容默认折叠为审计记录。"
        case .centralReview:
            return "生成前最后检查证据链、原图理解、人工确认和阻塞项。"
        case .generateResult:
            return "前面阶段通过后生成会议结果，并可回溯处理详情。"
        }
    }

    @MainActor
    static func current(for store: LabStore) -> MeetingTruthWorkspaceStage {
        let pending = MeetingTruthUXDecisionClassifier.pendingTotalCount(store: store)
        if store.isGeneratingMeetingTruthPackage || store.meetingTruthAnalysis != nil {
            return .generateResult
        }
        if store.isReviewingMeetingTruthCentrally ||
            store.meetingTruthCentralReviewLedger == nil && store.hasDiscoveredMeetingTruthConflicts && pending == 0 ||
            !store.meetingTruthPendingCentralReviewClaims.isEmpty ||
            !store.meetingTruthCentralReviewBlockingItems.isEmpty {
            return .centralReview
        }
        if pending > 0 {
            return .confirmConflicts
        }
        if store.isDiscoveringMeetingTruthConflicts ||
            store.isResolvingMeetingTruthConflicts ||
            store.meetingTruthTranscriptSources.count >= 2 {
            return .checkConflicts
        }
        return .materials
    }

    @MainActor
    func isComplete(in store: LabStore) -> Bool {
        switch self {
        case .materials:
            return store.meetingTruthTranscriptSources.count >= 2
        case .checkConflicts:
            return store.hasDiscoveredMeetingTruthConflicts
        case .confirmConflicts:
            return store.hasDiscoveredMeetingTruthConflicts &&
                MeetingTruthUXDecisionClassifier.pendingTotalCount(store: store) == 0
        case .centralReview:
            return store.meetingTruthCentralReviewLedger != nil &&
                store.meetingTruthPendingCentralReviewClaims.isEmpty &&
                store.meetingTruthCentralReviewBlockingItems.isEmpty
        case .generateResult:
            return store.meetingTruthAnalysis != nil
        }
    }
}

private struct MeetingTruthWorkspaceHeader: View {
    @EnvironmentObject private var store: LabStore

    var body: some View {
        Surface {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 34))
                        .foregroundStyle(.blue)

                    VStack(alignment: .leading, spacing: 5) {
                        Text("会议整理")
                            .font(.title.weight(.semibold))
                        Text(stageTitle)
                            .font(.title3.weight(.medium))
                        Text(stageDetail)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 8) {
                        Button {
                            runPrimaryAction()
                        } label: {
                            Label(primaryActionTitle, systemImage: primaryActionIcon)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(store.isMeetingTruthTaskRunning ? .red : .accentColor)
                        .disabled(!canRunPrimaryAction)

                        Button {
                            store.selectedSection = .meetingTruthDetail
                        } label: {
                            Label("查看处理详情", systemImage: "list.bullet.clipboard")
                        }

                        Button {
                            store.showMeetingTruthProcessingTrace(anchor: .importMaterials)
                        } label: {
                            Label("查看处理链路", systemImage: "point.3.connected.trianglepath.dotted")
                        }
                    }
                }

                HStack(spacing: 10) {
                    MeetingTruthStatusTile(title: "会议资料", value: "\(store.meetingTruthMaterials.count)", detail: "录音、图片、文档")
                    MeetingTruthStatusTile(title: "候选转写", value: "\(store.meetingTruthTranscriptSources.count)", detail: "至少 2 份可检查")
                    MeetingTruthStatusTile(title: "待确认", value: "\(pendingDecisionCount)", detail: "需要你看一眼")
                    MeetingTruthStatusTile(title: "会议结果", value: store.meetingTruthAnalysis == nil ? "未生成" : "已生成", detail: "逐字稿、纪要、导图")
                }
            }
        }
    }

    private var stageTitle: String {
        if store.meetingTruthAnalysis != nil {
            return "会议结果已经生成"
        }
        if !store.meetingTruthConflicts.isEmpty, pendingDecisionCount == 0 {
            return "修改已确认，可以生成结果"
        }
        if pendingDecisionCount > 0 {
            return "发现了需要确认的转写问题"
        }
        if store.meetingTruthTranscriptSources.count >= 2 {
            return "资料已准备好，可以检查差异"
        }
        return "先添加会议资料和候选转写"
    }

    private var stageDetail: String {
        if store.meetingTruthAnalysis != nil {
            return "你可以查看可信逐字稿、正式纪要、思维导图和待办，也可以进入处理详情回溯原因。"
        }
        if !store.meetingTruthConflicts.isEmpty, pendingDecisionCount == 0 {
            return "所有需要确认的地方都处理完了，下一步生成会议结果。"
        }
        if pendingDecisionCount > 0 {
            return "只需要处理这些有分歧的片段，不用从头读完整逐字稿。"
        }
        if store.meetingTruthTranscriptSources.count >= 2 {
            return "系统会对照多份转写和会议资料，找出可能听错、写错或需要确认的地方。"
        }
        return "文件导入、图片粘贴、候选转写和历史 ASR 都在下面直接操作。"
    }

    private var primaryActionTitle: String {
        if store.isMeetingTruthTaskRunning {
            return "停止"
        }
        if store.meetingTruthAnalysis != nil {
            return "查看结果"
        }
        if !store.meetingTruthConflicts.isEmpty, pendingDecisionCount == 0 {
            return store.isGeneratingMeetingTruthPackage ? "生成中" : "生成会议结果"
        }
        if pendingDecisionCount > 0 {
            return "处理需要确认的内容"
        }
        return store.isDiscoveringMeetingTruthConflicts ? "检查中" : "检查转写冲突"
    }

    private var primaryActionIcon: String {
        if store.isMeetingTruthTaskRunning { return "stop.circle" }
        if store.meetingTruthAnalysis != nil { return "shippingbox" }
        if !store.meetingTruthConflicts.isEmpty, pendingDecisionCount == 0 { return "wand.and.stars" }
        if pendingDecisionCount > 0 { return "checkmark.circle" }
        return "magnifyingglass"
    }

    private var canRunPrimaryAction: Bool {
        if store.isMeetingTruthTaskRunning { return true }
        if store.meetingTruthAnalysis != nil { return true }
        if !store.meetingTruthConflicts.isEmpty, pendingDecisionCount == 0 {
            return !store.isGeneratingMeetingTruthPackage
        }
        if pendingDecisionCount > 0 { return true }
        return store.meetingTruthTranscriptSources.count >= 2 && !store.isDiscoveringMeetingTruthConflicts
    }

    private func runPrimaryAction() {
        if store.isMeetingTruthTaskRunning {
            store.cancelMeetingTruthTask()
            return
        }
        if store.meetingTruthAnalysis != nil {
            return
        }
        if !store.meetingTruthConflicts.isEmpty, pendingDecisionCount == 0 {
            store.generateMeetingTruthPackage()
            return
        }
        if pendingDecisionCount > 0 {
            return
        }
        store.discoverMeetingTruthConflictsWithGemma()
    }

    private var pendingDecisionCount: Int {
        MeetingTruthUXDecisionClassifier.pendingTotalCount(store: store)
    }
}

private struct MeetingTruthStatusTile: View {
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
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.secondary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct MeetingTruthWorkspaceFlowCard: View {
    @EnvironmentObject private var store: LabStore
    let currentStage: MeetingTruthWorkspaceStage

    var body: some View {
        Surface {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("全流程示意", systemImage: "point.3.connected.trianglepath.dotted")
                            .font(.headline)
                        Text(currentStage.currentHint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    MeetingTruthPlainStatus(text: "当前：\(currentStage.title)", color: .blue)
                }

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 178), spacing: 10)],
                    alignment: .leading,
                    spacing: 10
                ) {
                    ForEach(MeetingTruthWorkspaceStage.allCases, id: \.self) { stage in
                        MeetingTruthWorkspaceFlowStep(
                            stage: stage,
                            state: state(for: stage),
                            detail: detail(for: stage)
                        )
                    }
                }
            }
        }
    }

    private func state(for stage: MeetingTruthWorkspaceStage) -> MeetingTruthWorkspaceStepState {
        if stage == currentStage {
            return store.isMeetingTruthTaskRunning ? .running : .current
        }
        if stage.isComplete(in: store) { return .complete }
        if stage.rawValue < currentStage.rawValue { return .attention }
        return .waiting
    }

    private func detail(for stage: MeetingTruthWorkspaceStage) -> String {
        switch stage {
        case .materials:
            return "\(store.meetingTruthMaterials.count) 份资料 · \(store.meetingTruthTranscriptSources.count) 路转写"
        case .checkConflicts:
            if store.isDiscoveringMeetingTruthConflicts { return "正在检查，请等待结果" }
            return store.hasDiscoveredMeetingTruthConflicts ? "已识别 \(store.meetingTruthConflicts.count) 条" : "等待开始检查"
        case .confirmConflicts:
            let pending = MeetingTruthUXDecisionClassifier.pendingTotalCount(store: store)
            return pending == 0 ? "没有待处理项" : "\(pending) 项待你确认"
        case .centralReview:
            if store.isReviewingMeetingTruthCentrally { return "正在复核证据链" }
            if store.meetingTruthCentralReviewLedger == nil { return "等待运行复核" }
            return "\(store.meetingTruthCentralReviewBlockingItems.count) 阻塞 · \(store.meetingTruthPendingCentralReviewClaims.count) 待确认"
        case .generateResult:
            if store.isGeneratingMeetingTruthPackage { return "正在生成成果包" }
            return store.meetingTruthAnalysis == nil ? "尚未生成" : "已生成"
        }
    }
}

private enum MeetingTruthWorkspaceStepState {
    case complete
    case current
    case running
    case attention
    case waiting

    var title: String {
        switch self {
        case .complete: "已完成"
        case .current: "当前"
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

private struct MeetingTruthWorkspaceFlowStep: View {
    let stage: MeetingTruthWorkspaceStage
    let state: MeetingTruthWorkspaceStepState
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
                .fixedSize(horizontal: false, vertical: true)
            Text(detail)
                .font(.caption2.weight(.medium))
                .foregroundStyle(state.color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 124, alignment: .topLeading)
        .background(state.color.opacity(state == .waiting ? 0.06 : 0.10))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(state.color.opacity(state == .current || state == .running ? 0.34 : 0.14))
        }
    }
}

private struct MeetingTruthWorkspaceStageSection<Content: View>: View {
    let stage: MeetingTruthWorkspaceStage
    let currentStage: MeetingTruthWorkspaceStage
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
                            MeetingTruthPlainStatus(text: stateTitle, color: color)
                        }
                        Text(stage.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Text(isExpanded ? "收起本阶段" : "展开本阶段")
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
        if stage == currentStage { return "当前阶段" }
        return isComplete ? "已完成" : "未开始"
    }
}

private struct MeetingTruthAddMaterialsCard: View {
    @EnvironmentObject private var store: LabStore
    @State private var isShowingAuxiliaryInputs = false
    let selectHistoricalASR: () -> Void
    let previewMaterial: (MeetingTruthMaterial) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            MeetingTruthSectionHeader(
                title: "添加会议资料",
                subtitle: "先完成两个主输入：导入会议材料，并选择或导入至少两路候选转写。其他入口放在辅助区。"
            )

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                primaryInputButton(
                    title: "导入资料",
                    detail: "录音、PDF、PPT、截图、手写笔记、术语表",
                    systemImage: "tray.and.arrow.down",
                    disabled: false,
                    action: importMaterials
                )
                primaryInputButton(
                    title: "选择本地 ASR 历史",
                    detail: "从本地历史里选择至少两路候选转写",
                    systemImage: "clock.arrow.circlepath",
                    disabled: store.meetingTruthHistoricalASRResults.count < 2
                ) {
                    selectHistoricalASR()
                }
            }

            DisclosureGroup(isExpanded: $isShowingAuxiliaryInputs) {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    actionButton("粘贴图片", "doc.on.clipboard", disabled: false) {
                        store.importMeetingTruthImageFromClipboard()
                    }
                    actionButton("手动导入候选转写", "text.badge.plus", disabled: false, action: importTranscripts)
                    actionButton("加载示例", "sparkles", disabled: false) {
                        store.loadMeetingTruthDemo()
                    }
                    actionButton("清空项目", "trash", disabled: !store.hasMeetingTruthInput && store.meetingTruthAnalysis == nil) {
                        store.resetMeetingTruthProject()
                    }
                }
                .padding(.top, 8)
            } label: {
                Label("辅助输入与项目操作", systemImage: "slider.horizontal.3")
                    .font(.subheadline.weight(.semibold))
            }

            HStack(alignment: .top, spacing: 14) {
                MeetingTruthMaterialInventory(previewMaterial: previewMaterial)
                MeetingTruthSimpleList(
                    title: "候选转写",
                    emptyText: "还没有候选转写。至少需要两份，才能检查差异。",
                    rows: transcriptRows
                )
            }
        }
    }

    private var transcriptRows: [String] {
        var rows = store.meetingTruthTranscriptSources.map {
            "\($0.name) · \(store.meetingTruthTranscriptRoleLabel(for: $0))"
        }
        let context = store.meetingTruthConfirmedContextText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !context.isEmpty {
            rows.insert("已确认会议信息 · 已写入可信逐字稿", at: 0)
        }
        return rows
    }

    private func actionButton(_ title: String, _ systemImage: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(disabled)
    }

    private func primaryInputButton(
        title: String,
        detail: String,
        systemImage: String,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
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
            .frame(maxWidth: .infinity, minHeight: 82, alignment: .topLeading)
            .background(Color.blue.opacity(disabled ? 0.04 : 0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.blue.opacity(disabled ? 0.08 : 0.16))
            }
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private func importMaterials() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "导入"
        if panel.runModal() == .OK {
            store.importMeetingTruthMaterials(from: panel.urls)
        }
    }

    private func importTranscripts() {
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
}

private struct MeetingTruthCheckProblemsCard: View {
    @EnvironmentObject private var store: LabStore
    @State private var isShowingConflictResults = false

    var body: some View {
        Surface {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    MeetingTruthSectionHeader(
                        title: "检查转写冲突",
                        subtitle: "对照多份转写、图片识别和会议资料，找出可能影响纪要的听写冲突，并生成可信写法建议。"
                    )
                    Spacer()
                    Button {
                        if store.isDiscoveringMeetingTruthConflicts {
                            store.cancelMeetingTruthTask()
                        } else {
                            store.discoverMeetingTruthConflictsWithGemma()
                        }
                    } label: {
                        Label(
                            store.isDiscoveringMeetingTruthConflicts ? "停止" : "检查转写冲突",
                            systemImage: store.isDiscoveringMeetingTruthConflicts ? "stop.circle" : "magnifyingglass"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(store.isDiscoveringMeetingTruthConflicts ? .red : .accentColor)
                    .disabled(!store.isDiscoveringMeetingTruthConflicts && store.meetingTruthTranscriptSources.count < 2)
                    Button {
                        isShowingConflictResults = true
                    } label: {
                        Label("查看冲突结果", systemImage: "list.bullet.rectangle")
                    }
                    .disabled(store.meetingTruthConflicts.isEmpty)
                    Button {
                        store.showMeetingTruthProcessingTrace(anchor: .conflictDiscovery)
                    } label: {
                        Label("查看核验过程", systemImage: "point.3.connected.trianglepath.dotted")
                    }
                }

                HStack(spacing: 10) {
                    MeetingTruthStatusTile(title: "检查条件", value: store.meetingTruthTranscriptSources.count >= 2 ? "可以检查" : "还差转写", detail: "需要至少 2 份候选转写")
                    MeetingTruthStatusTile(title: "转写冲突", value: "\(store.meetingTruthConflicts.count)", detail: store.hasDiscoveredMeetingTruthConflicts ? "已完成检查" : "尚未检查")
                    MeetingTruthStatusTile(title: "需要你确认", value: "\(pendingDecisionCount)", detail: "确认后才能生成成果包")
                }

                if store.isDiscoveringMeetingTruthConflicts || store.isResolvingMeetingTruthConflicts {
                    HStack(alignment: .top, spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(store.isDiscoveringMeetingTruthConflicts ? "正在检查转写冲突" : "正在复查冲突证据")
                                .font(.subheadline.weight(.semibold))
                            Text(store.meetingTruthValidationStatus)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("这一步会调用 Gemma 4 对照多路转写、图片 OCR 和会议材料，长会议可能需要等待一段时间。")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                    }
                    .padding(10)
                    .background(Color.orange.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                if !store.meetingTruthConflicts.isEmpty {
                    HStack(spacing: 8) {
                        Label(conflictSummaryText, systemImage: "doc.text.magnifyingglass")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            isShowingConflictResults = true
                        } label: {
                            Label("查看核验依据", systemImage: "text.magnifyingglass")
                        }
                        .font(.caption)
                    }
                }

                if shouldShowObviousFixPanel {
                    HStack(alignment: .center, spacing: 10) {
                        Image(systemName: "checkmark.seal")
                            .foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("有些问题已经很明确")
                                .font(.subheadline.weight(.semibold))
                            Text("可以一次处理 \(obviousFixCount) 条明显问题；需要你判断的内容仍会留下来。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            applyObviousFixes()
                        } label: {
                            Label("一键处理明显问题", systemImage: "checkmark.circle")
                        }
                    }
                    .padding(10)
                    .background(Color.green.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                if !inlineReviewConflicts.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("逐条确认处理")
                                    .font(.subheadline.weight(.semibold))
                                Text("可以逐条采用建议、选择候选写法、手动修改、暂不处理或不写入成果。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                isShowingConflictResults = true
                            } label: {
                                Label("查看全部 \(store.meetingTruthConflicts.count) 条", systemImage: "list.bullet.rectangle")
                            }
                            .font(.caption)
                        }

                        ForEach(inlineReviewConflicts.prefix(5)) { conflict in
                            MeetingTruthUserConflictCard(conflict: conflict, mode: .pending)
                        }

                        if inlineReviewConflicts.count > 5 {
                            HStack {
                                Text("此处先显示 5 条，剩余 \(inlineReviewConflicts.count - 5) 条可在「查看全部」中继续逐条处理。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button {
                                    isShowingConflictResults = true
                                } label: {
                                    Label("继续处理", systemImage: "arrow.right.circle")
                                }
                                .font(.caption)
                            }
                        }
                    }
                    .padding(10)
                    .background(Color.orange.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .sheet(isPresented: $isShowingConflictResults) {
            MeetingTruthConflictResultsSheet()
                .environmentObject(store)
        }
    }

    private var conflictSummaryText: String {
        let applied = MeetingTruthUXDecisionClassifier.autoResolvedConflicts(store: store).count
        let deferred = MeetingTruthUXDecisionClassifier.excludedConflicts(store: store).count
        let lowRisk = MeetingTruthUXDecisionClassifier.lowRiskConflicts(store: store).count
        return "已识别 \(store.meetingTruthConflicts.count) 条；自动应用 \(applied) 条，后续复核/不写入 \(deferred) 条，低风险忽略 \(lowRisk) 条。"
    }

    private var obviousFixCount: Int {
        highUnresolvedConflicts.filter {
            MeetingTruthRecommendationText.isConcrete($0.recommendation)
        }.count
    }

    private var shouldShowObviousFixPanel: Bool {
        !highUnresolvedConflicts.isEmpty && highUnresolvedConflicts.count == obviousFixCount
    }

    private var inlineReviewConflicts: [MeetingTruthConflict] {
        MeetingTruthUXDecisionClassifier.pendingConflicts(store: store)
            .sorted(by: MeetingTruthConflictDisplay.sortForMainList)
    }

    private var highUnresolvedConflicts: [MeetingTruthConflict] {
        store.meetingTruthConflicts.filter { conflict in
            conflict.confidence == .high &&
            MeetingTruthConflictDisplay.needsUserDecision(
                conflict,
                confirmation: store.latestMeetingTruthConfirmation(for: conflict.id)
            )
        }
    }

    private var pendingDecisionCount: Int {
        MeetingTruthUXDecisionClassifier.pendingTotalCount(store: store)
    }

    private func applyObviousFixes() {
        for conflict in highUnresolvedConflicts where MeetingTruthRecommendationText.isConcrete(conflict.recommendation) {
            store.resolveMeetingTruthConflict(conflict.id, text: conflict.recommendation)
        }
    }
}

private struct MeetingTruthConfirmChangesCard: View {
    @EnvironmentObject private var store: LabStore
    @State private var isShowingResolvedItems = false
    @State private var isShowingExcludedItems = false
    @State private var isShowingLowRiskItems = false
    @State private var isShowingConflictResults = false

    var body: some View {
        Surface {
            VStack(alignment: .leading, spacing: 12) {
                MeetingTruthSectionHeader(
                    title: "需要你确认的高风险事项",
                    subtitle: "这里只放真正需要你判断的内容；技术日志和已处理记录默认收起。"
                )

                HStack(spacing: 10) {
                    MeetingTruthStatusTile(title: "待你处理", value: "\(pendingTotalCount)", detail: gateStatusText)
                    MeetingTruthStatusTile(title: "转写冲突", value: "\(pendingConflicts.count)", detail: pendingConflicts.isEmpty ? "无待处理转写冲突" : "需选择可信写法")
                    MeetingTruthStatusTile(title: "事实证据", value: "\(pendingQuestions.count)", detail: pendingQuestions.isEmpty ? "无事实证据待确认" : "需决定是否写入成果")
                    MeetingTruthStatusTile(title: "中枢复核", value: "\(pendingCentralClaims.count)", detail: pendingCentralClaims.isEmpty ? "暂无阻塞项" : "生成前需处理")
                }

                if store.meetingTruthConflicts.isEmpty && pendingQuestions.isEmpty && pendingCentralClaims.isEmpty {
                    EmptyStateView(
                        systemImage: "checkmark.shield",
                        title: store.hasDiscoveredMeetingTruthConflicts ? "没有发现需要确认的问题" : "等待检查转写冲突",
                        message: store.hasDiscoveredMeetingTruthConflicts
                            ? "可以直接生成会议结果。"
                            : "导入至少两份候选转写后，点击「检查转写冲突」。"
                    )
                    .frame(minHeight: 120)
                } else {
                    if pendingConflicts.isEmpty && pendingQuestions.isEmpty && pendingCentralClaims.isEmpty {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("高风险事项都处理完了")
                                    .font(.subheadline.weight(.semibold))
                                Text("可以去生成会议结果；下面仍可展开查看已处理的审计记录。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(10)
                        .background(Color.green.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }

                    MeetingTruthDecisionSection(
                        title: "转写冲突待确认",
                        subtitle: "多份转写或图片/材料核验结果不一致，需要你选择可信写法。",
                        passText: "无待处理转写冲突"
                    ) {
                        ForEach(pendingConflicts.prefix(5)) { conflict in
                            MeetingTruthUserConflictCard(conflict: conflict, mode: .pending)
                        }
                        if pendingConflicts.count > 5 {
                            Text("还有 \(pendingConflicts.count - 5) 条待处理，可到处理详情查看全部。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .showContent(!pendingConflicts.isEmpty)

                    MeetingTruthDecisionSection(
                        title: "事实证据待确认",
                        subtitle: "系统无法确认某条内容是否应写入纪要、待办或事实记录。",
                        passText: "无事实证据待确认"
                    ) {
                        ForEach(pendingQuestions.prefix(5)) { question in
                            MeetingTruthFactQuestionCard(question: question)
                        }
                        if pendingQuestions.count > 5 {
                            Text("还有 \(pendingQuestions.count - 5) 条事实证据待确认，可到处理详情查看全部。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .showContent(!pendingQuestions.isEmpty)

                    MeetingTruthDecisionSection(
                        title: "中枢复核待确认",
                        subtitle: "生成成果前的最终核验发现证据不足或冲突，需要你处理后再生成。",
                        passText: "中枢复核暂无阻塞项"
                    ) {
                        ForEach(pendingCentralClaims.prefix(5)) { claim in
                            MeetingTruthCentralReviewClaimCard(claim: claim)
                        }
                        if pendingCentralClaims.count > 5 {
                            Text("还有 \(pendingCentralClaims.count - 5) 条中枢复核事项，可到处理详情查看全部。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .showContent(!pendingCentralClaims.isEmpty)

                    if !autoResolvedConflicts.isEmpty {
                        DisclosureGroup(isExpanded: $isShowingResolvedItems) {
                            VStack(alignment: .leading, spacing: 10) {
                                Button {
                                    isShowingConflictResults = true
                                } label: {
                                    Label("查看已处理冲突", systemImage: "list.bullet.rectangle")
                                }
                                .buttonStyle(.bordered)
                                ForEach(autoResolvedConflicts.prefix(3)) { conflict in
                                    MeetingTruthUserConflictCard(conflict: conflict, mode: .audit)
                                }
                                if autoResolvedConflicts.count > 3 {
                                    Text("仅显示最近 3 条，更多可在处理详情查看。")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.top, 8)
                        } label: {
                            HStack {
                                Label("已自动修正 / 已采纳记录", systemImage: "checkmark.circle")
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Text("\(autoResolvedConflicts.count) 条")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    if !excludedConflicts.isEmpty {
                        DisclosureGroup(isExpanded: $isShowingExcludedItems) {
                            VStack(alignment: .leading, spacing: 10) {
                                Button {
                                    isShowingConflictResults = true
                                } label: {
                                    Label("查看冲突结果", systemImage: "list.bullet.rectangle")
                                }
                                .buttonStyle(.bordered)
                                ForEach(excludedConflicts.prefix(3)) { conflict in
                                    MeetingTruthUserConflictCard(conflict: conflict, mode: .audit)
                                }
                                if excludedConflicts.count > 3 {
                                    Text("仅显示最近 3 条，更多可在处理详情查看。")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.top, 8)
                        } label: {
                            HStack {
                                Label("不写入 / 暂不处理 / 误报记录", systemImage: "archivebox")
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Text("\(excludedConflicts.count) 条")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    if !lowRiskConflicts.isEmpty {
                        DisclosureGroup(isExpanded: $isShowingLowRiskItems) {
                            VStack(alignment: .leading, spacing: 10) {
                                Button {
                                    isShowingConflictResults = true
                                } label: {
                                    Label("查看核验依据", systemImage: "text.magnifyingglass")
                                }
                                .buttonStyle(.bordered)
                                ForEach(lowRiskConflicts.prefix(3)) { conflict in
                                    MeetingTruthUserConflictCard(conflict: conflict, mode: .audit)
                                }
                                if lowRiskConflicts.count > 3 {
                                    Text("仅显示最近 3 条，更多可在处理详情查看。")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.top, 8)
                        } label: {
                            HStack {
                                Label("低风险忽略记录", systemImage: "minus.circle")
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Text("\(lowRiskConflicts.count) 条")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $isShowingConflictResults) {
            MeetingTruthConflictResultsSheet()
                .environmentObject(store)
        }
    }

    private var pendingConflicts: [MeetingTruthConflict] {
        MeetingTruthUXDecisionClassifier.pendingConflicts(store: store)
    }

    private var pendingQuestions: [MeetingTruthUserQuestion] {
        store.meetingTruthPendingFactQuestions
    }

    private var pendingCentralClaims: [MeetingTruthCentralClaim] {
        store.meetingTruthPendingCentralReviewClaims
    }

    private var pendingTotalCount: Int {
        pendingConflicts.count + pendingQuestions.count + pendingCentralClaims.count
    }

    private var gateStatusText: String {
        if pendingTotalCount == 0 { return "可以生成会议成果" }
        return "处理后再生成"
    }

    private var autoResolvedConflicts: [MeetingTruthConflict] {
        MeetingTruthUXDecisionClassifier.autoResolvedConflicts(store: store)
    }

    private var excludedConflicts: [MeetingTruthConflict] {
        MeetingTruthUXDecisionClassifier.excludedConflicts(store: store)
    }

    private var lowRiskConflicts: [MeetingTruthConflict] {
        MeetingTruthUXDecisionClassifier.lowRiskConflicts(store: store)
    }
}

private struct MeetingTruthDecisionSection<Content: View>: View {
    let title: String
    let subtitle: String
    let passText: String
    let content: Content
    private var shouldShowContent = true

    init(title: String, subtitle: String, passText: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.passText = passText
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: shouldShowContent ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(shouldShowContent ? .orange : .green)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Text(shouldShowContent ? subtitle : passText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }

            if shouldShowContent {
                content
            }
        }
        .padding(10)
        .background(shouldShowContent ? Color.orange.opacity(0.06) : Color.green.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    func showContent(_ value: Bool) -> Self {
        var copy = self
        copy.shouldShowContent = value
        return copy
    }
}

private struct MeetingTruthFactQuestionCard: View {
    @EnvironmentObject private var store: LabStore
    let question: MeetingTruthUserQuestion
    @State private var answer = ""
    @State private var isShowingEvidence = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(cardTitle)
                    .font(.subheadline.weight(.semibold))
                Text(question.riskTitle ?? "需要补充确认")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                MeetingTruthPlainStatus(text: "需要确认", color: .orange)
            }

            MeetingTruthInfoBlock(title: "要确认什么", text: question.question)
            MeetingTruthInfoBlock(title: "系统建议", text: suggestedText, highlight: true)
            MeetingTruthInfoBlock(title: "为什么问你", text: reasonText)
            MeetingTruthInfoBlock(title: "会影响哪里", text: affectedOutputsText)

            VStack(alignment: .leading, spacing: 6) {
                Text("你可以怎么处理")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    TextField("选择正确写法，或手动输入", text: $answer)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(applyAnswer)
                    Button {
                        applyAnswer()
                    } label: {
                        Label("确认写入", systemImage: "checkmark.circle")
                    }
                    .disabled(trimmedAnswer.isEmpty)
                    Menu {
                        Button {
                            deferQuestion()
                        } label: {
                            Label("暂不处理", systemImage: "clock")
                        }
                        Button {
                            deferQuestion()
                        } label: {
                            Label("不写入成果", systemImage: "minus.circle")
                        }
                        Button {
                            isShowingEvidence.toggle()
                        } label: {
                            Label("查看证据", systemImage: "doc.text.magnifyingglass")
                        }
                        Button {
                            store.showMeetingTruthProcessingTrace(anchor: .humanReviewTaskGeneration)
                        } label: {
                            Label("查看处理链路", systemImage: "point.3.connected.trianglepath.dotted")
                        }
                    } label: {
                        Label("更多", systemImage: "ellipsis.circle")
                    }
                }
                Text(consequenceText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            DisclosureGroup("查看证据", isExpanded: $isShowingEvidence) {
                VStack(alignment: .leading, spacing: 8) {
                    if let context = cleanedOptionalText(question.sourceContext) {
                        reasonRow("原文片段", context)
                    }
                    if let missingEvidence = question.missingEvidence, !missingEvidence.isEmpty {
                        reasonRow("还缺什么证据", missingEvidence.joined(separator: "\n"))
                    }
                    if let evidenceDetails = question.evidenceDetails, !evidenceDetails.isEmpty {
                        ForEach(evidenceDetails.prefix(5)) { evidence in
                            reasonRow(
                                "\(evidence.channelTitle) · \(evidence.sourceName) · \(evidence.supportsClaim ? "支持" : "冲突")",
                                "\(evidenceDisplayText(evidence))\n可信度：\(Int((evidence.confidence * 100).rounded()))%"
                            )
                        }
                    } else {
                        reasonRow("系统查到的依据", question.knownEvidence.isEmpty ? "暂无稳定交叉证据。" : question.knownEvidence.joined(separator: "\n"))
                    }
                }
                .padding(.top, 6)
            }
            .font(.caption)

            DisclosureGroup("查看处理链路") {
                Button {
                    store.showMeetingTruthProcessingTrace(anchor: .humanReviewTaskGeneration)
                } label: {
                    Label("打开人工确认任务生成步骤", systemImage: "point.3.connected.trianglepath.dotted")
                }
                .padding(.top, 6)
            }
            .font(.caption)
        }
        .padding(12)
        .background(Color.orange.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onAppear(perform: resetAnswer)
        .onChange(of: question.suggestedAnswer) {
            resetAnswer()
        }
    }

    private var trimmedAnswer: String {
        answer.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var affectedOutputsText: String {
        let outputs = question.affectsOutputs ?? [.minutes]
        return outputs.map(\.title).joined(separator: "、")
    }

    private var cardTitle: String {
        if affectedOutputsText.contains("待办") { return "待办是否写入需要确认" }
        if affectedOutputsText.contains("金额") { return "金额需要确认" }
        return "事实是否写入需要确认"
    }

    private var suggestedText: String {
        let suggested = question.suggestedAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !suggested.isEmpty { return "建议采用 \(suggested)" }
        return "建议保留待确认"
    }

    private var reasonText: String {
        cleanedOptionalText(question.userVisibleReason ?? question.decisionReason)
            ?? "属于高风险事实，系统不能自动写入。"
    }

    private var consequenceText: String {
        cleanedOptionalText(question.noConfirmationConsequence)
            ?? "不处理时，这条内容不会作为已确认事实写入成果。"
    }

    private func resetAnswer() {
        answer = question.suggestedAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func applyAnswer() {
        guard !trimmedAnswer.isEmpty else { return }
        store.answerMeetingTruthUserQuestion(question.factID, answer: trimmedAnswer)
    }

    private func deferQuestion() {
        store.deferMeetingTruthUserQuestion(question.factID)
    }

    private func cleanedOptionalText(_ text: String?) -> String? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func evidenceDisplayText(_ evidence: MeetingTruthQuestionEvidence) -> String {
        let text = evidence.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let cue = evidence.visualCue.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return cue.isEmpty ? "暂无可展示原文。" : cue }
        if cue.isEmpty { return text }
        return "\(text)\n视觉依据：\(cue)"
    }

    private func reasonRow(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text.isEmpty ? "暂无" : text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct MeetingTruthCentralReviewStatusCard: View {
    @EnvironmentObject private var store: LabStore
    @State private var isShowingCentralReviewResults = false

    var body: some View {
        Surface {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    MeetingTruthSectionHeader(
                        title: "多模态中枢复核",
                        subtitle: "Gemma 4 先读原图，再把 OCR、ASR、材料、人工确认放到同一张事实账本里交叉核验。"
                    )
                    Spacer()
                    Button {
                        if store.isReviewingMeetingTruthCentrally {
                            store.cancelMeetingTruthTask()
                        } else {
                            store.runMeetingTruthCentralReviewWithGemma()
                        }
                    } label: {
                        Label(
                            store.isReviewingMeetingTruthCentrally ? "停止" : "运行复核",
                            systemImage: store.isReviewingMeetingTruthCentrally ? "stop.circle" : "checklist.checked"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(store.isReviewingMeetingTruthCentrally ? .red : .accentColor)
                    .disabled(!store.isReviewingMeetingTruthCentrally && !store.canRunMeetingTruthCentralReview)
                    Button {
                        isShowingCentralReviewResults = true
                    } label: {
                        Label("查看生成前检查", systemImage: "doc.text.magnifyingglass")
                    }
                    .disabled(store.meetingTruthCentralReviewLedger == nil)
                    Button {
                        store.showMeetingTruthProcessingTrace(anchor: .centralReviewHandoff)
                    } label: {
                        Label("查看核验过程", systemImage: "point.3.connected.trianglepath.dotted")
                    }
                }

                if let ledger = store.meetingTruthCentralReviewLedger {
                    centralConclusion(ledger)
                    centralInputSummary(ledger)
                    centralResultGroups(ledger)
                    technicalAudit(ledger)
                } else {
                    emptyCentralReviewState
                }
            }
        }
        .sheet(isPresented: $isShowingCentralReviewResults) {
            MeetingTruthCentralReviewResultsSheet()
                .environmentObject(store)
        }
    }

    private func centralConclusion(_ ledger: MeetingTruthCentralReviewLedger) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("复核结论")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: conclusionIcon(for: ledger))
                    .foregroundStyle(conclusionColor(for: ledger))
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 4) {
                    Text(conclusionTitle(for: ledger))
                        .font(.subheadline.weight(.semibold))
                    Text(conclusionDetail(for: ledger))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                MeetingTruthPlainStatus(text: conclusionBadge(for: ledger), color: conclusionColor(for: ledger))
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("为什么")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(Array(conclusionReasons(for: ledger).prefix(3).enumerated()), id: \.offset) { _, reason in
                    Text("• \(reason)")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 8) {
                Button {
                    isShowingCentralReviewResults = true
                } label: {
                    Label("查看生成前检查", systemImage: "doc.text.magnifyingglass")
                }
                .buttonStyle(.bordered)

                Button {
                    performPrimaryCentralAction(for: ledger)
                } label: {
                    Label(primaryActionTitle(for: ledger), systemImage: primaryActionIcon(for: ledger))
                }
                .buttonStyle(.borderedProminent)
                .disabled(primaryActionDisabled(for: ledger))

                Button {
                    store.runMeetingTruthCentralReviewWithGemma()
                } label: {
                    Label("重新复核", systemImage: "arrow.clockwise")
                }
                .disabled(!store.canRunMeetingTruthCentralReview)
            }
        }
        .padding(10)
        .background(conclusionColor(for: ledger).opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func centralInputSummary(_ ledger: MeetingTruthCentralReviewLedger) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("复核输入摘要")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                centralMetric("可信转写", store.meetingTruthTrustedTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未形成" : "已形成", "来自已处理的主底稿")
                centralMetric("多路 ASR", "\(store.meetingTruthTranscriptSources.count) 份", "用于转写一致性检查")
                centralMetric("会议材料", "\(store.meetingTruthMaterials.filter { $0.kind != "图片" }.count) 份", "导入文档 / PPT / 术语")
                centralMetric("图片文字识别", "\(store.meetingTruthImageMaterials.filter { !$0.extractedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count) 张", "来自 OCR")
                centralMetric("原图理解", "\(ledger.visualObservations.filter(\.hasRawVisionOnlySignal).count) 条", "来自 Gemma 多模态")
                centralMetric("人工确认", "\(store.meetingTruthProcessingRun.userActions) 条", "来自用户操作")
            }
        }
    }

    private func centralResultGroups(_ ledger: MeetingTruthCentralReviewLedger) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("复核结果摘要")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(resultGroups(for: ledger)) { group in
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(group.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        sourceImpactLabels(group)
                        ForEach(Array(group.items.prefix(6).enumerated()), id: \.offset) { _, item in
                            Text("• \(item)")
                                .font(.caption)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if group.items.isEmpty {
                            Text("暂无需要展开的明细。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    HStack(spacing: 8) {
                        Label(group.title, systemImage: group.systemImage)
                            .font(.caption.weight(.semibold))
                        Spacer()
                        MeetingTruthPlainStatus(text: group.statusText, color: group.color)
                    }
                }
                .padding(9)
                .background(group.color.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func technicalAudit(_ ledger: MeetingTruthCentralReviewLedger) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    MeetingTruthPlainStatus(text: "工具函数核验 \(ledger.toolCallRecords.count) 步", color: .blue)
                    MeetingTruthPlainStatus(text: "Gemma 主动调用 \(toolCount(.nativeToolCall, in: ledger))", color: .green)
                    MeetingTruthPlainStatus(text: "系统自动补全步骤 \(toolCount(.autoPipeline, in: ledger))", color: .orange)
                    Spacer()
                }

                toolAuditOverview(ledger)

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(workflowRows) { row in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: row.systemImage)
                                .foregroundStyle(row.color)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.title)
                                    .font(.caption.weight(.semibold))
                                Text(row.detail)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }

                if let comparison = ledger.toolCallingComparison, comparison.hasContent {
                    Text("Gemma 4 函数调用对照")
                        .font(.caption.weight(.semibold))
                    HStack(alignment: .top, spacing: 8) {
                        MeetingTruthComparisonColumn(title: comparison.baselineModeTitle, text: comparison.baselineSummary)
                        MeetingTruthComparisonColumn(title: comparison.toolCallingModeTitle, text: comparison.toolCallingSummary)
                    }
                    if !comparison.improvements.isEmpty {
                        Text(comparison.improvements.prefix(4).map { "• \($0)" }.joined(separator: "\n"))
                            .font(.caption2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if !ledger.toolCallRecords.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("工具调用详情 / 工具返回详情")
                            .font(.caption.weight(.semibold))
                        ForEach(ledger.toolCallRecords.prefix(8)) { record in
                            technicalToolRecord(record)
                        }
                    }
                }

                if let usage = ledger.tokenUsage, usage.hasContent {
                    Text("模型用量：prompt \(usage.promptTokens.map(String.init) ?? "未返回")，completion \(usage.completionTokens.map(String.init) ?? "未返回")，total \(usage.totalTokens.map(String.init) ?? "未返回")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 8)
        } label: {
            Label("技术审计 / 开发者详情", systemImage: "wrench.and.screwdriver")
                .font(.caption.weight(.semibold))
        }
    }

    private func toolAuditOverview(_ ledger: MeetingTruthCentralReviewLedger) -> some View {
        let summary = MeetingTruthToolAuditSummary.make(from: ledger.toolCallRecords)
        return VStack(alignment: .leading, spacing: 8) {
            Text("函数调用审计总览")
                .font(.caption.weight(.semibold))
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                centralMetric("总调用", "\(summary.totalCount) 次", "已执行 \(summary.executedCount) 步")
                centralMetric("原生调用", "\(summary.nativeCount) 次", summary.nativeCount > 0 ? "LM Studio 可审计" : "未观察到 native")
                centralMetric("兼容/补全", "\(summary.fallbackCount + summary.autoCount) 次", "fallback \(summary.fallbackCount) · auto \(summary.autoCount)")
                centralMetric("最后原生工具", summary.lastNativeFunctionName.map(toolDisplayName) ?? "无", summary.stopTitle)
            }
            Text(summary.stopDetail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 5) {
                ForEach(summary.rows) { row in
                    HStack(alignment: .top, spacing: 8) {
                        MeetingTruthPlainStatus(text: "\(row.count) 次", color: toolAuditRowColor(row))
                            .frame(width: 58, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(row.title)
                                    .font(.caption2.weight(.semibold))
                                MeetingTruthPlainStatus(text: row.stateText, color: toolAuditRowColor(row))
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
        .padding(9)
        .background(.blue.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var emptyCentralReviewState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("尚未形成复核记录")
                .font(.subheadline.weight(.semibold))
            Text("导入资料后可先运行复核，也可以在生成成果包前自动运行。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                store.runMeetingTruthCentralReviewWithGemma()
            } label: {
                Label("运行复核", systemImage: "checklist.checked")
            }
            .disabled(!store.canRunMeetingTruthCentralReview)
        }
        .padding(10)
        .background(.secondary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func centralMetric(_ title: String, _ value: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.semibold))
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func technicalToolRecord(_ record: MeetingTruthToolCallRecord) -> some View {
        let source = record.invocationSource ?? .unknown
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("\(record.callIndex). \(record.functionName)")
                    .font(.caption2.weight(.semibold))
                MeetingTruthPlainStatus(text: source.title, color: toolSourceColor(source))
                MeetingTruthPlainStatus(text: record.status.title, color: record.status == .executed ? .green : .orange)
            }
            Text("处理来源：\(MeetingTruthProcessingSource.toolRecord(record))")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(source.explanation)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("\(source.shouldShowToolCallLabel ? "工具调用详情" : "执行输入")：\(record.argumentsSummary)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("\(source.shouldShowToolCallLabel ? "工具返回详情" : "执行结果")：\(record.resultSummary)")
                .font(.caption2)
                .fixedSize(horizontal: false, vertical: true)
            Text(record.impactSummary)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .background(.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func conclusionTitle(for ledger: MeetingTruthCentralReviewLedger) -> String {
        if !ledger.blockingItems.isEmpty { return "有阻塞项" }
        if !store.meetingTruthPendingCentralReviewClaims.isEmpty { return "有待确认项" }
        if !ledger.advisoryItems.isEmpty { return "可生成，但有提示" }
        return "复核通过"
    }

    private func conclusionBadge(for ledger: MeetingTruthCentralReviewLedger) -> String {
        if !ledger.blockingItems.isEmpty { return "阻塞生成" }
        if !store.meetingTruthPendingCentralReviewClaims.isEmpty { return "需要你确认" }
        if !ledger.advisoryItems.isEmpty { return "生成提示 \(ledger.advisoryItems.count)" }
        return "可以生成"
    }

    private func conclusionDetail(for ledger: MeetingTruthCentralReviewLedger) -> String {
        if !ledger.blockingItems.isEmpty {
            return "生成前需要先处理会影响成果正确性的事实冲突或证据链断点。"
        }
        if !store.meetingTruthPendingCentralReviewClaims.isEmpty {
            return "仍有中枢复核项需要你确认，处理后再生成更稳。"
        }
        if !ledger.advisoryItems.isEmpty {
            return "没有硬阻塞，生成后会在结果页集中列出待确认说明，并尽量在相关内容旁标注。"
        }
        return "当前无需要人工处理的高风险事项，可以生成会议成果。"
    }

    private func conclusionReasons(for ledger: MeetingTruthCentralReviewLedger) -> [String] {
        if !ledger.blockingItems.isEmpty {
            return Array(ledger.blockingItems.prefix(3))
        }
        if !store.meetingTruthPendingCentralReviewClaims.isEmpty {
            return store.meetingTruthPendingCentralReviewClaims.prefix(3).map {
                "\($0.kind.title)：\($0.proposedCanonicalText)"
            }
        }
        if !ledger.advisoryItems.isEmpty {
            return Array(ledger.advisoryItems.prefix(3))
        }
        return ["当前无阻塞项，可以生成。", "复核记录覆盖 \(ledger.claims.count) 条关键事实和 \(ledger.visualObservations.count) 条原图观察。"]
    }

    private func conclusionIcon(for ledger: MeetingTruthCentralReviewLedger) -> String {
        if !ledger.blockingItems.isEmpty || !store.meetingTruthPendingCentralReviewClaims.isEmpty {
            return "exclamationmark.triangle.fill"
        }
        if !ledger.advisoryItems.isEmpty { return "checkmark.seal" }
        return "checkmark.seal.fill"
    }

    private func conclusionColor(for ledger: MeetingTruthCentralReviewLedger) -> Color {
        if !ledger.blockingItems.isEmpty || !store.meetingTruthPendingCentralReviewClaims.isEmpty {
            return .orange
        }
        return .green
    }

    private func primaryActionTitle(for ledger: MeetingTruthCentralReviewLedger) -> String {
        if !store.meetingTruthPendingCentralReviewClaims.isEmpty { return "处理待确认项" }
        if !ledger.blockingItems.isEmpty { return "查看阻塞原因" }
        if !ledger.advisoryItems.isEmpty { return "生成会议成果（保留提示）" }
        return "生成会议成果"
    }

    private func primaryActionIcon(for ledger: MeetingTruthCentralReviewLedger) -> String {
        if !store.meetingTruthPendingCentralReviewClaims.isEmpty { return "person.crop.circle.badge.questionmark" }
        if !ledger.blockingItems.isEmpty { return "exclamationmark.magnifyingglass" }
        return "wand.and.stars"
    }

    private func primaryActionDisabled(for ledger: MeetingTruthCentralReviewLedger) -> Bool {
        if !ledger.blockingItems.isEmpty || !store.meetingTruthPendingCentralReviewClaims.isEmpty {
            return false
        }
        return store.isMeetingTruthTaskRunning ||
            !store.hasDiscoveredMeetingTruthConflicts ||
            store.meetingTruthTrustedTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func performPrimaryCentralAction(for ledger: MeetingTruthCentralReviewLedger) {
        if !store.meetingTruthPendingCentralReviewClaims.isEmpty {
            store.showMeetingTruthProcessingTrace(anchor: .humanReviewTaskGeneration)
        } else if !ledger.blockingItems.isEmpty {
            store.showMeetingTruthProcessingTrace(anchor: .centralReviewHandoff)
        } else {
            store.generateMeetingTruthPackage()
        }
    }

    private func resultGroups(for ledger: MeetingTruthCentralReviewLedger) -> [CentralReviewResultGroup] {
        [
            transcriptionGroup(ledger),
            keyFactsGroup(ledger),
            actionItemsGroup(ledger),
            multimodalGroup(ledger),
            generationGateGroup(ledger)
        ]
    }

    private func transcriptionGroup(_ ledger: MeetingTruthCentralReviewLedger) -> CentralReviewResultGroup {
        let unresolved = store.meetingTruthConflicts.filter { !$0.isResolved && $0.requiresHumanReview }
        let replacementFailed = store.meetingTruthConflicts.filter { $0.reviewStatus == .replacementValidationFailed }
        let autoApplied = store.meetingTruthConflicts.filter { $0.reviewStatus == .suggestedApplied }
        let count = unresolved.count + replacementFailed.count
        let items = (unresolved.prefix(3).map { "\($0.kind.title)：\($0.context)" } +
            replacementFailed.prefix(3).map { "安全替换失败：\($0.replacementValidationResult?.reason ?? $0.context)" } +
            autoApplied.prefix(2).map { "自动修正已进入可信转写：\($0.recommendation)" })
        return CentralReviewResultGroup(
            title: "转写有没有互相打架",
            detail: "检查可信转写里是否还有未处理的高风险转写差异。",
            count: count,
            statusText: count == 0 ? "无阻塞" : "\(count) 项",
            color: count == 0 ? .green : .orange,
            systemImage: "waveform.and.magnifyingglass",
            sourceText: "多路 ASR + 本地规则 + 工具核验",
            impactText: "可信逐字稿、正式纪要",
            items: items
        )
    }

    private func keyFactsGroup(_ ledger: MeetingTruthCentralReviewLedger) -> CentralReviewResultGroup {
        let keyKinds: Set<MeetingTruthFactKind> = [.person, .owner, .amount, .date, .project, .term, .decision, .risk]
        let claims = ledger.claims.filter { keyKinds.contains($0.kind) }
        let issues = claims.filter(\.requiresHumanReview)
        let items = issues.prefix(6).map {
            "\($0.kind.title)：\($0.proposedCanonicalText) · \($0.status.title)"
        }
        return CentralReviewResultGroup(
            title: "关键事实是否可靠",
            detail: "检查人名、项目名、金额、时间、决策等关键事实是否有依据。",
            count: issues.count,
            statusText: issues.isEmpty ? "\(claims.count) 条已复核" : "\(issues.count) 项需确认",
            color: issues.isEmpty ? .green : .orange,
            systemImage: "checklist",
            sourceText: "会议材料 + 图片识别 + 人工确认",
            impactText: "纪要、摘要、证据备注",
            items: items
        )
    }

    private func actionItemsGroup(_ ledger: MeetingTruthCentralReviewLedger) -> CentralReviewResultGroup {
        let actionClaims = ledger.claims.filter { $0.kind == .actionItem || $0.kind == .owner || $0.kind == .date }
        let gaps = ledger.gaps.filter { $0.kind == .missingOwner || $0.kind == .missingDueDate }
        let issueCount = actionClaims.filter(\.requiresHumanReview).count + gaps.count
        let items = actionClaims.filter(\.requiresHumanReview).prefix(4).map {
            "\($0.kind.title)：\($0.proposedCanonicalText)"
        } + gaps.prefix(4).map(\.advisoryText)
        return CentralReviewResultGroup(
            title: "待办能不能写进结果",
            detail: "检查待办是否具备负责人、动作、期限和来源依据。",
            count: issueCount,
            statusText: issueCount == 0 ? "无待办阻塞" : "\(issueCount) 项",
            color: issueCount == 0 ? .green : .orange,
            systemImage: "person.text.rectangle",
            sourceText: "可信转写 + 人工确认 + 中枢复核",
            impactText: "待办事项",
            items: items
        )
    }

    private func multimodalGroup(_ ledger: MeetingTruthCentralReviewLedger) -> CentralReviewResultGroup {
        let gaps = ledger.gaps.filter { $0.kind == .ocrRawVisionMismatch || $0.kind == .noRawVision || $0.kind == .noCrossModalEvidence }
        let sourceNotes = ledger.visualObservations.prefix(4).map { observation in
            observation.hasRawVisionOnlySignal
                ? "原图理解：\(observation.materialName)"
                : "图片文字识别：\(observation.materialName)"
        }
        let items = gaps.prefix(4).map { gap in
            gap.kind == .ocrRawVisionMismatch
                ? "图片文字识别和原图理解结果不一致，已降低置信度或进入待确认。"
                : gap.advisoryText
        } + sourceNotes
        return CentralReviewResultGroup(
            title: "图片 / 材料证据",
            detail: "检查图片文字识别、原图理解、手写稿、会议通知和材料是否支持或冲突。",
            count: gaps.count,
            statusText: gaps.isEmpty ? "\(ledger.visualObservations.count) 条证据" : "\(gaps.count) 个提示",
            color: gaps.contains(where: \.blocksPackageGeneration) ? .orange : .green,
            systemImage: "photo.on.rectangle.angled",
            sourceText: "OCR + 原图理解 + 会议材料",
            impactText: "证据备注、风险提示",
            items: items
        )
    }

    private func generationGateGroup(_ ledger: MeetingTruthCentralReviewLedger) -> CentralReviewResultGroup {
        let blocking = ledger.blockingItems
        let advisories = ledger.advisoryItems
        let status: String
        let color: Color
        if !blocking.isEmpty {
            status = "阻塞生成"
            color = .orange
        } else if !advisories.isEmpty {
            status = "可生成但标记待确认"
            color = .green
        } else {
            status = "可以生成"
            color = .green
        }
        return CentralReviewResultGroup(
            title: "现在能不能生成",
            detail: "判断当前是否可以生成会议结果。",
            count: blocking.count + advisories.count,
            statusText: status,
            color: color,
            systemImage: "lock.open",
            sourceText: "中枢复核 + 门禁规则",
            impactText: "生成按钮状态",
            items: blocking + advisories
        )
    }

    private func sourceImpactLabels(_ group: CentralReviewResultGroup) -> some View {
        HStack(alignment: .top, spacing: 8) {
            MeetingTruthPlainStatus(text: "来源：\(group.sourceText)", color: .secondary)
            MeetingTruthPlainStatus(text: "影响：\(group.impactText)", color: .blue)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func toolCount(_ source: MeetingTruthToolInvocationSource, in ledger: MeetingTruthCentralReviewLedger) -> Int {
        ledger.toolCallRecords.filter { ($0.invocationSource ?? .unknown) == source }.count
    }

    private func toolSourceColor(_ source: MeetingTruthToolInvocationSource) -> Color {
        switch source {
        case .nativeToolCall: .green
        case .jsonFallback: .blue
        case .autoPipeline: .orange
        case .localRule: .purple
        case .manualConfirmation: .teal
        case .unknown: .secondary
        }
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

    private func toolDisplayName(_ name: String) -> String {
        MeetingTruthToolAuditSummary.make(from: []).rows.first { $0.functionName == name }?.title ?? name
    }

    private var workflowRows: [CentralReviewWorkflowRow] {
        let ledger = store.meetingTruthCentralReviewLedger
        let hasImages = store.meetingTruthMaterials.contains { $0.kind == "图片" }
        let hasRawVision = ledger?.visualObservations.contains(where: \.hasRawVisionOnlySignal) == true
        let hasOCRContrast = ledger?.gaps.contains { $0.kind == .ocrRawVisionMismatch } == true ||
            ledger?.visualObservations.contains { !$0.ocrContrast.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } == true
        let hasSupport = ledger?.claims.contains { !$0.supportingEvidence.isEmpty } == true
        let hasChallenge = ledger?.claims.contains { !$0.contradictingEvidence.isEmpty || !$0.missingEvidence.isEmpty } == true ||
            ledger?.gaps.isEmpty == false
        let hasVerdicts = ledger?.claims.isEmpty == false

        return [
            CentralReviewWorkflowRow(
                title: "1. 原图理解",
                detail: hasImages ? (hasRawVision ? "处理来源：原图理解。已使用图片原图形成视觉观察。" : "处理来源：原图理解。有图片输入，等待读取版式、手写、箭头和圈注。") : "处理来源：原图理解。当前没有图片，原图轮次会记录为无图输入。",
                systemImage: hasRawVision ? "checkmark.circle.fill" : "circle",
                color: hasRawVision ? .green : .secondary
            ),
            CentralReviewWorkflowRow(
                title: "2. OCR 与原图纠偏",
                detail: hasOCRContrast ? "处理来源：图片文字识别 + 原图理解。已记录图片文字和原图理解差异。" : "处理来源：图片文字识别。只作为基线，等待与原图视觉事实对比。",
                systemImage: hasOCRContrast ? "checkmark.circle.fill" : "circle",
                color: hasOCRContrast ? .green : .secondary
            ),
            CentralReviewWorkflowRow(
                title: "3. 支持证据复核",
                detail: hasSupport ? "处理来源：工具函数核验。事实已关联转写、材料、原图或人工确认支持证据。" : "处理来源：工具函数核验。等待为关键事实绑定支持证据。",
                systemImage: hasSupport ? "checkmark.circle.fill" : "circle",
                color: hasSupport ? .green : .secondary
            ),
            CentralReviewWorkflowRow(
                title: "4. 反证挑战",
                detail: hasChallenge ? "处理来源：工具函数核验 + Gemma 语义判断。已记录反证、缺失证据或跨模态缺口。" : "处理来源：Gemma 语义判断。等待主动寻找冲突、缺证据和高风险事实。",
                systemImage: hasChallenge ? "checkmark.circle.fill" : "circle",
                color: hasChallenge ? .green : .secondary
            ),
            CentralReviewWorkflowRow(
                title: "5. 最终裁决",
                detail: hasVerdicts ? "处理来源：Gemma 语义判断。已形成可追溯裁决；阻塞项会进入确认修改。" : "处理来源：Gemma 语义判断。等待生成最终裁决。",
                systemImage: hasVerdicts ? "checkmark.circle.fill" : "circle",
                color: hasVerdicts ? .green : .secondary
            )
        ]
    }
}

private struct MeetingTruthComparisonColumn: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.caption2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(8)
        .background(.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct CentralReviewWorkflowRow: Identifiable {
    var id: String { title }
    var title: String
    var detail: String
    var systemImage: String
    var color: Color
}

private struct CentralReviewResultGroup: Identifiable {
    var id: String { title }
    var title: String
    var detail: String
    var count: Int
    var statusText: String
    var color: Color
    var systemImage: String
    var sourceText: String
    var impactText: String
    var items: [String]
}

private struct MeetingTruthCentralReviewResultsSheet: View {
    @EnvironmentObject private var store: LabStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let ledger = store.meetingTruthCentralReviewLedger {
                        conclusion(ledger)
                        toolchainAuditSummary(ledger)
                        fivePartSummary(ledger)
                        riskItems(ledger)
                    } else {
                        EmptyStateView(
                            systemImage: "checklist.checked",
                            title: "尚未完成生成前检查",
                            message: "运行中枢复核后，这里会说明是否可以生成会议结果，以及还有哪些内容需要保留提示或先处理。"
                        )
                        .frame(minHeight: 260)
                    }
                }
                .padding(20)
            }
            .navigationTitle("生成前检查")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        dismiss()
                    }
                }
            }
        }
        .frame(minWidth: 860, minHeight: 680)
    }

    private func conclusion(_ ledger: MeetingTruthCentralReviewLedger) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("生成前结论", systemImage: conclusionIcon(ledger))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(conclusionColor(ledger))
                Spacer()
                MeetingTruthPlainStatus(text: conclusionTitle(ledger), color: conclusionColor(ledger))
            }
            Text(conclusionDetail(ledger))
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 5) {
                Text("系统为什么这样判断")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(Array(conclusionReasons(ledger).prefix(5).enumerated()), id: \.offset) { _, reason in
                    Text("• \(reason)")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                Button {
                    store.showMeetingTruthProcessingTrace(anchor: .centralReviewHandoff)
                    dismiss()
                } label: {
                    Label("查看处理链路", systemImage: "point.3.connected.trianglepath.dotted")
                }
                if ledger.blockingItems.isEmpty && store.meetingTruthPendingCentralReviewClaims.isEmpty {
                    Button {
                        store.generateMeetingTruthPackage()
                        dismiss()
                    } label: {
                        Label("生成会议结果", systemImage: "wand.and.stars")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isMeetingTruthTaskRunning || store.meetingTruthTrustedTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(12)
        .background(conclusionColor(ledger).opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func fivePartSummary(_ ledger: MeetingTruthCentralReviewLedger) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("系统检查了这五件事")
                .font(.headline)
            ForEach(groups(ledger)) { group in
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(group.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        sourceImpactLabels(group)
                        if group.items.isEmpty {
                            Text("没有需要额外说明的明细。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(Array(group.items.prefix(8).enumerated()), id: \.offset) { _, item in
                                Text("• \(item)")
                                    .font(.caption)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    HStack {
                        Label(group.title, systemImage: group.systemImage)
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        MeetingTruthPlainStatus(text: group.statusText, color: group.color)
                    }
                }
                .padding(10)
                .background(group.color.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func toolchainAuditSummary(_ ledger: MeetingTruthCentralReviewLedger) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("工具链审计")
                .font(.headline)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                auditMetric("Gemma 主动调用", "\(toolCount(.nativeToolCall, in: ledger)) 步", .green)
                auditMetric("系统自动补全", "\(toolCount(.autoPipeline, in: ledger)) 步", .orange)
                auditMetric("本地规则校验", "\(toolCount(.localRule, in: ledger)) 步", .purple)
                auditMetric("图片文字识别", "\(ocrObservationCount(in: ledger)) 条", .blue)
                auditMetric("原图理解", "\(rawImageObservationCount(in: ledger)) 条", .blue)
                auditMetric("人工确认引用", "\(humanEvidenceCount(in: ledger)) 条", .teal)
            }
            Text("这里只显示审计数量；详细过程请查看处理链路。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func auditMetric(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(color.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func riskItems(_ ledger: MeetingTruthCentralReviewLedger) -> some View {
        let items = riskRows(ledger)
        return VStack(alignment: .leading, spacing: 10) {
            Text("还需要注意什么")
                .font(.headline)
            if items.isEmpty {
                MeetingTruthInfoBlock(
                    title: "可以生成",
                    text: "没有发现会阻塞生成的高风险问题。系统已检查转写是否一致、关键事实是否可靠、待办是否完整、图片/原图证据是否支持，以及结果生成是否有硬阻塞。",
                    highlight: true
                )
            } else {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(item.title)
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            MeetingTruthPlainStatus(text: item.blocks ? "阻塞" : "提示", color: item.blocks ? .orange : .green)
                        }
                        MeetingTruthInfoBlock(title: "问题是什么", text: item.problem)
                        MeetingTruthInfoBlock(title: "为什么提示", text: item.reason)
                        MeetingTruthInfoBlock(title: "影响哪里", text: item.impact)
                        MeetingTruthInfoBlock(title: "下一步操作", text: item.nextStep, highlight: item.blocks)
                        HStack(spacing: 8) {
                            ForEach(item.sources.prefix(4), id: \.self) { source in
                                MeetingTruthPlainStatus(text: source, color: .blue)
                            }
                            Spacer()
                            Button {
                                store.showMeetingTruthProcessingTrace(anchor: .centralReviewHandoff)
                                dismiss()
                            } label: {
                                Label("查看处理链路", systemImage: "point.3.connected.trianglepath.dotted")
                            }
                            .font(.caption)
                        }
                    }
                    .padding(12)
                    .background((item.blocks ? Color.orange : Color.green).opacity(0.07))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private func conclusionTitle(_ ledger: MeetingTruthCentralReviewLedger) -> String {
        if !ledger.blockingItems.isEmpty { return "有阻塞项" }
        if !store.meetingTruthPendingCentralReviewClaims.isEmpty { return "有待确认项" }
        if !ledger.advisoryItems.isEmpty { return "可以生成但有提示" }
        return "可以生成"
    }

    private func conclusionDetail(_ ledger: MeetingTruthCentralReviewLedger) -> String {
        if !ledger.blockingItems.isEmpty {
            return "中枢复核发现会影响成果正确性的事实冲突或证据链断点，需要先处理。"
        }
        if !store.meetingTruthPendingCentralReviewClaims.isEmpty {
            return "有关键事实还需要人工确认，处理后再生成会更稳。"
        }
        if !ledger.advisoryItems.isEmpty {
            return "没有硬阻塞，可以生成；提示项会保留在结果说明里，方便会后追踪。"
        }
        return "转写差异、关键事实、待办、图片/材料证据和生成状态均未发现硬阻塞。"
    }

    private func conclusionReasons(_ ledger: MeetingTruthCentralReviewLedger) -> [String] {
        if !ledger.blockingItems.isEmpty { return ledger.blockingItems }
        if !store.meetingTruthPendingCentralReviewClaims.isEmpty {
            return store.meetingTruthPendingCentralReviewClaims.map { "\($0.kind.title)：\($0.proposedCanonicalText)" }
        }
        if !ledger.advisoryItems.isEmpty { return ledger.advisoryItems }
        return [
            "当前无阻塞项，可以生成。",
            "已复核 \(ledger.claims.count) 条关键事实。",
            "已纳入 \(ledger.visualObservations.count) 条图片/原图观察。"
        ]
    }

    private func conclusionIcon(_ ledger: MeetingTruthCentralReviewLedger) -> String {
        ledger.blockingItems.isEmpty && store.meetingTruthPendingCentralReviewClaims.isEmpty
            ? "checkmark.seal.fill"
            : "exclamationmark.triangle.fill"
    }

    private func conclusionColor(_ ledger: MeetingTruthCentralReviewLedger) -> Color {
        ledger.blockingItems.isEmpty && store.meetingTruthPendingCentralReviewClaims.isEmpty ? .green : .orange
    }

    private func groups(_ ledger: MeetingTruthCentralReviewLedger) -> [CentralReviewResultGroup] {
        [
            transcriptionGroup(ledger),
            keyFactsGroup(ledger),
            actionItemsGroup(ledger),
            multimodalGroup(ledger),
            generationGateGroup(ledger)
        ]
    }

    private func transcriptionGroup(_ ledger: MeetingTruthCentralReviewLedger) -> CentralReviewResultGroup {
        let unresolved = store.meetingTruthConflicts.filter { !$0.isResolved && $0.requiresHumanReview }
        let failed = store.meetingTruthConflicts.filter { $0.reviewStatus == .replacementValidationFailed }
        let applied = store.meetingTruthConflicts.filter { $0.reviewStatus == .suggestedApplied }
        let issueCount = unresolved.count + failed.count
        return CentralReviewResultGroup(
            title: "转写有没有互相打架",
            detail: "检查多路 ASR 候选里，是否还存在会影响纪要的人名、术语、系统名或行动项差异。",
            count: issueCount,
            statusText: issueCount == 0 ? "无阻塞" : "\(issueCount) 项需处理",
            color: issueCount == 0 ? .green : .orange,
            systemImage: "waveform.and.magnifyingglass",
            sourceText: "多路 ASR + 本地规则 + 工具核验",
            impactText: "可信逐字稿、正式纪要",
            items: unresolved.prefix(4).map { "\($0.kind.title)：\($0.candidates.map(\.text).joined(separator: " / "))" } +
                failed.prefix(4).map { "安全替换失败：\($0.replacementValidationResult?.reason ?? $0.context)" } +
                applied.prefix(3).map { "已自动应用：\($0.recommendation)" }
        )
    }

    private func keyFactsGroup(_ ledger: MeetingTruthCentralReviewLedger) -> CentralReviewResultGroup {
        let keyKinds: Set<MeetingTruthFactKind> = [.person, .owner, .amount, .date, .project, .term, .decision, .risk]
        let claims = ledger.claims.filter { keyKinds.contains($0.kind) }
        let issues = claims.filter(\.requiresHumanReview)
        return CentralReviewResultGroup(
            title: "关键事实是否可靠",
            detail: "检查人名、项目名、金额、时间、决策和专业术语是否有转写、材料、图片或人工确认支持。",
            count: issues.count,
            statusText: issues.isEmpty ? "\(claims.count) 条已复核" : "\(issues.count) 项需确认",
            color: issues.isEmpty ? .green : .orange,
            systemImage: "checklist",
            sourceText: "会议材料 + 图片识别 + 人工确认",
            impactText: "纪要、摘要、证据备注",
            items: issues.prefix(8).map { "\($0.kind.title)：\($0.proposedCanonicalText) · \($0.decisionReason)" }
        )
    }

    private func actionItemsGroup(_ ledger: MeetingTruthCentralReviewLedger) -> CentralReviewResultGroup {
        let actionClaims = ledger.claims.filter { $0.kind == .actionItem || $0.kind == .owner || $0.kind == .date }
        let gaps = ledger.gaps.filter { $0.kind == .missingOwner || $0.kind == .missingDueDate }
        let issues = actionClaims.filter(\.requiresHumanReview)
        let issueCount = issues.count + gaps.count
        return CentralReviewResultGroup(
            title: "待办能不能写进结果",
            detail: "检查待办是否有明确动作、负责人、期限和来源依据。",
            count: issueCount,
            statusText: issueCount == 0 ? "无待办阻塞" : "\(issueCount) 项",
            color: issueCount == 0 ? .green : .orange,
            systemImage: "person.text.rectangle",
            sourceText: "可信转写 + 人工确认 + 中枢复核",
            impactText: "待办事项",
            items: issues.prefix(4).map { "\($0.kind.title)：\($0.proposedCanonicalText)" } + gaps.prefix(4).map(\.advisoryText)
        )
    }

    private func multimodalGroup(_ ledger: MeetingTruthCentralReviewLedger) -> CentralReviewResultGroup {
        let gaps = ledger.gaps.filter { $0.kind == .ocrRawVisionMismatch || $0.kind == .noRawVision || $0.kind == .noCrossModalEvidence }
        let observations = ledger.visualObservations.prefix(5).map { observation in
            observation.hasRawVisionOnlySignal ? "原图理解：\(observation.materialName)" : "图片文字识别：\(observation.materialName)"
        }
        return CentralReviewResultGroup(
            title: "图片 / 材料证据",
            detail: "检查图片文字识别、原图理解、手写稿、会议通知和材料是否支持关键事实。",
            count: gaps.count,
            statusText: gaps.isEmpty ? "\(ledger.visualObservations.count) 条证据" : "\(gaps.count) 个提示",
            color: gaps.contains(where: \.blocksPackageGeneration) ? .orange : .green,
            systemImage: "photo.on.rectangle.angled",
            sourceText: "OCR + 原图理解 + 会议材料",
            impactText: "证据备注、风险提示",
            items: gaps.prefix(5).map(\.advisoryText) + observations
        )
    }

    private func generationGateGroup(_ ledger: MeetingTruthCentralReviewLedger) -> CentralReviewResultGroup {
        let blocking = ledger.blockingItems
        let advisory = ledger.advisoryItems
        return CentralReviewResultGroup(
            title: "现在能不能生成",
            detail: "判断当前是否可以生成会议结果，以及需要把哪些提示保留到结果说明。",
            count: blocking.count + advisory.count,
            statusText: !blocking.isEmpty ? "阻塞生成" : (!advisory.isEmpty ? "可生成但有提示" : "可以生成"),
            color: blocking.isEmpty ? .green : .orange,
            systemImage: "lock.open",
            sourceText: "中枢复核 + 门禁规则",
            impactText: "生成按钮状态",
            items: blocking + advisory
        )
    }

    private func sourceImpactLabels(_ group: CentralReviewResultGroup) -> some View {
        HStack(alignment: .top, spacing: 8) {
            MeetingTruthPlainStatus(text: "来源：\(group.sourceText)", color: .secondary)
            MeetingTruthPlainStatus(text: "影响：\(group.impactText)", color: .blue)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func toolCount(_ source: MeetingTruthToolInvocationSource, in ledger: MeetingTruthCentralReviewLedger) -> Int {
        ledger.toolCallRecords.filter { ($0.invocationSource ?? .unknown) == source }.count
    }

    private func ocrObservationCount(in ledger: MeetingTruthCentralReviewLedger) -> Int {
        ledger.visualObservations.filter {
            !$0.ocrBaseline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count
    }

    private func rawImageObservationCount(in ledger: MeetingTruthCentralReviewLedger) -> Int {
        ledger.visualObservations.filter(\.hasRawVisionOnlySignal).count
    }

    private func humanEvidenceCount(in ledger: MeetingTruthCentralReviewLedger) -> Int {
        ledger.claims.reduce(0) { count, claim in
            count + (claim.supportingEvidence + claim.contradictingEvidence).filter { $0.channel == .human }.count
        }
    }

    private func riskRows(_ ledger: MeetingTruthCentralReviewLedger) -> [CentralReviewRiskRow] {
        let claimRows = (store.meetingTruthPendingCentralReviewClaims + ledger.claims.filter(\.requiresHumanReview))
            .reduce(into: [UUID: MeetingTruthCentralClaim]()) { result, claim in
                result[claim.id] = claim
            }
            .values
            .map { claim in
                CentralReviewRiskRow(
                    title: claim.kind.title,
                    problem: claim.humanQuestion ?? claim.claim,
                    reason: claim.decisionReason,
                    impact: impactText(for: claim.kind),
                    blocks: claim.requiresHumanReview,
                    nextStep: claim.requiresHumanReview ? "请确认最终可信说法，或暂不写入成果。" : "生成时保留提示。",
                    sources: sourceLabels(for: claim)
                )
            }

        let gapRows = ledger.gaps.filter(\.requiresHumanReview).map { gap in
            CentralReviewRiskRow(
                title: gap.kind.title,
                problem: gap.title,
                reason: gap.detail,
                impact: gap.kind == .packageTraceability ? "成果包证据说明" : "会议纪要、待办事项或证据备注",
                blocks: gap.blocksPackageGeneration,
                nextStep: gap.blocksPackageGeneration ? "请补充证据或人工确认后再生成。" : "可以生成，但建议在结果说明中保留该提示。",
                sources: sourceLabels(for: gap)
            )
        }

        return Array(claimRows + gapRows)
    }

    private func impactText(for kind: MeetingTruthFactKind) -> String {
        switch kind {
        case .person, .owner:
            return "参会人、待办事项、会议纪要"
        case .amount, .date:
            return "会议纪要、待办事项"
        case .project, .term:
            return "项目名、会议纪要"
        case .decision:
            return "会议纪要"
        case .actionItem:
            return "待办事项、会议纪要"
        case .risk:
            return "风险清单、会议纪要"
        }
    }

    private func sourceLabels(for claim: MeetingTruthCentralClaim) -> [String] {
        let evidence = claim.supportingEvidence + claim.contradictingEvidence
        var labels = Set<String>()
        for item in evidence {
            labels.insert(sourceLabel(for: item.channel))
        }
        if labels.isEmpty {
            labels.insert("系统自动补全步骤")
        }
        return Array(labels).sorted()
    }

    private func sourceLabels(for gap: MeetingTruthReviewGap) -> [String] {
        switch gap.kind {
        case .ocrRawVisionMismatch:
            return ["图片文字识别", "原图理解"]
        case .noRawVision:
            return ["原图理解"]
        case .noCrossModalEvidence:
            return ["会议材料", "原图理解"]
        case .missingOwner, .missingDueDate, .unsupportedHighRiskFact, .packageTraceability:
            return ["系统自动补全步骤", "本地规则校验"]
        }
    }

    private func sourceLabel(for channel: MeetingTruthCentralEvidenceChannel) -> String {
        switch channel {
        case .asr: "ASR 候选"
        case .imageOCR: "图片文字识别"
        case .rawVision: "原图理解"
        case .material: "会议材料"
        case .conflict: "本地规则校验"
        case .human: "人工确认"
        case .generatedPackage: "生成结果"
        }
    }
}

private struct CentralReviewRiskRow: Identifiable {
    var id = UUID()
    var title: String
    var problem: String
    var reason: String
    var impact: String
    var blocks: Bool
    var nextStep: String
    var sources: [String]
}

private struct MeetingTruthCentralReviewClaimCard: View {
    @EnvironmentObject private var store: LabStore
    let claim: MeetingTruthCentralClaim
    @State private var answer = ""
    @State private var isShowingEvidence = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(cardTitle)
                    .font(.subheadline.weight(.semibold))
                Text(claim.kind.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                MeetingTruthPlainStatus(text: "需要确认", color: .orange)
            }

            MeetingTruthInfoBlock(title: "要确认什么", text: claim.humanQuestion ?? "请确认这条事实是否可以写入最终结果。")
            MeetingTruthInfoBlock(title: "系统建议", text: suggestedText, highlight: true)
            MeetingTruthInfoBlock(title: "为什么问你", text: claim.decisionReason)
            MeetingTruthInfoBlock(title: "会影响哪里", text: affectedOutputsText)

            VStack(alignment: .leading, spacing: 6) {
                Text("你可以怎么处理")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    TextField("填写最终可信说法", text: $answer)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(applyAnswer)
                    Button {
                        applyAnswer()
                    } label: {
                        Label("确认写入", systemImage: "checkmark.shield")
                    }
                    .disabled(trimmedAnswer.isEmpty)
                    Menu {
                        Button {
                            isShowingEvidence.toggle()
                        } label: {
                            Label("查看证据", systemImage: "doc.text.magnifyingglass")
                        }
                        Button {
                            store.showMeetingTruthProcessingTrace(anchor: .centralReviewHandoff)
                        } label: {
                            Label("查看处理链路", systemImage: "point.3.connected.trianglepath.dotted")
                        }
                        Button {
                            answer = ""
                        } label: {
                            Label("暂不处理", systemImage: "clock")
                        }
                    } label: {
                        Label("更多", systemImage: "ellipsis.circle")
                    }
                }
                Text("不处理时，生成前仍会把这条视为高风险未决项。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            DisclosureGroup("查看证据", isExpanded: $isShowingEvidence) {
                VStack(alignment: .leading, spacing: 8) {
                    evidenceSection(title: "支持证据", evidence: claim.supportingEvidence)
                    evidenceSection(title: "反证或冲突", evidence: claim.contradictingEvidence)
                    if !claim.missingEvidence.isEmpty {
                        MeetingTruthInfoBlock(title: "还缺什么", text: claim.missingEvidence.joined(separator: "\n"))
                    }
                }
                .padding(.top, 6)
            }
            .font(.caption)

            DisclosureGroup("查看处理链路") {
                Button {
                    store.showMeetingTruthProcessingTrace(anchor: .centralReviewHandoff)
                } label: {
                    Label("打开输出给中枢复核步骤", systemImage: "point.3.connected.trianglepath.dotted")
                }
                .padding(.top, 6)
            }
            .font(.caption)
        }
        .padding(12)
        .background(Color.orange.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onAppear(perform: resetAnswer)
        .onChange(of: claim.proposedCanonicalText) {
            resetAnswer()
        }
    }

    private var trimmedAnswer: String {
        answer.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func resetAnswer() {
        answer = LabStore.writableMeetingTruthConfirmationText(claim.proposedCanonicalText)
    }

    private var affectedOutputsText: String {
        switch claim.kind {
        case .person, .owner:
            return "参会人、待办事项、会议纪要"
        case .amount, .date:
            return "会议纪要、待办事项"
        case .project, .term:
            return "项目名、会议纪要"
        case .decision:
            return "会议纪要"
        case .actionItem:
            return "待办事项、会议纪要"
        case .risk:
            return "风险清单、会议纪要"
        }
    }

    private var cardTitle: String {
        switch claim.kind {
        case .person, .owner: return "负责人或人名需要确认"
        case .amount: return "金额需要确认"
        case .date: return "时间需要确认"
        case .project, .term: return "项目名称或术语需要确认"
        case .actionItem: return "待办是否写入需要确认"
        case .decision: return "会议决策是否成立需要确认"
        case .risk: return "风险记录需要确认"
        }
    }

    private var suggestedText: String {
        let text = LabStore.writableMeetingTruthConfirmationText(claim.proposedCanonicalText)
        return text.isEmpty ? "建议保留待确认" : "建议采用 \(text)"
    }

    private func applyAnswer() {
        guard !trimmedAnswer.isEmpty else { return }
        store.answerMeetingTruthCentralReviewClaim(
            claim.id,
            answer: LabStore.writableMeetingTruthConfirmationText(trimmedAnswer)
        )
    }

    private func evidenceSection(title: String, evidence: [MeetingTruthCentralEvidence]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if evidence.isEmpty {
                Text("暂无")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(evidence.prefix(4)) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(MeetingTruthProcessingSource.centralEvidence(item.channel)) · \(item.sourceName)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(evidenceText(item))
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    private func evidenceText(_ item: MeetingTruthCentralEvidence) -> String {
        let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let visualCue = item.visualCue.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return visualCue.isEmpty ? "暂无细节" : visualCue }
        if visualCue.isEmpty { return text }
        return "\(text)\n视觉依据：\(visualCue)"
    }
}

private struct MeetingTruthUserConflictCard: View {
    enum Mode {
        case pending
        case audit
    }

    @EnvironmentObject private var store: LabStore
    let conflict: MeetingTruthConflict
    var mode: Mode = .pending
    @State private var manualText = ""
    @State private var isShowingEvidence = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(summaryTitle)
                    .font(.subheadline.weight(.semibold))
                Text(conflict.timestamp)
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                Text(conflict.kind.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                MeetingTruthPlainStatus(text: statusText, color: statusColor)
            }

            MeetingTruthInfoBlock(title: "要确认什么", text: summaryText)
            MeetingTruthInfoBlock(title: "系统建议", text: recommendationText, highlight: true)
            MeetingTruthInfoBlock(title: "为什么问你", text: oneLineBasis)
            MeetingTruthInfoBlock(title: "会影响哪里", text: affectedOutputsText)

            if isFinalized {
                VStack(alignment: .leading, spacing: 8) {
                    if let validation = conflict.replacementValidationResult, !validation.isValid {
                        MeetingTruthSafeReplacementCard(
                            validation: validation,
                            spans: conflict.replacementSpans ?? [],
                            selectedText: selectedText
                        )
                    } else if !selectedText.isEmpty {
                        MeetingTruthInfoBlock(title: "已应用到可信转写", text: selectedText, highlight: true)
                    } else {
                        MeetingTruthInfoBlock(title: "处理状态", text: statusText)
                    }
                    if mode == .pending {
                        manualEditSection(title: "修改写法", actionTitle: "保存人工确认")
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    if selectedNeedsRepair {
                        MeetingTruthInfoBlock(
                            title: "这条还没确认清楚",
                            text: "之前保存的是系统提醒，不是最终可写入文本。请从下面选一句，或手动输入正确结果。"
                        )
                    }

                    manualEditSection(title: "修改写法", actionTitle: "保存人工确认")
                }
            }

            if mode == .pending {
                HStack(spacing: 8) {
                    if !isFinalized, recommendationIsConcrete {
                        Button {
                            store.resolveMeetingTruthConflict(conflict.id, text: conflict.recommendation)
                        } label: {
                            Label("采用建议", systemImage: "checkmark.circle")
                        }
                    }
                    Button {
                        applyManualText()
                    } label: {
                        Label("手动修改", systemImage: "pencil")
                    }
                    .disabled(!canApplyManualText)
                    Menu {
                        ForEach(conflict.candidates) { candidate in
                            Button {
                                store.resolveMeetingTruthConflict(conflict.id, text: candidate.text)
                            } label: {
                                Text("选择：\(candidate.text)")
                            }
                        }
                        Button {
                            store.updateMeetingTruthConflictAction(conflict.id, action: .deferForReview)
                        } label: {
                            Label("暂不处理", systemImage: "clock")
                        }
                        Button {
                            store.updateMeetingTruthConflictAction(conflict.id, action: .ignoreLowRisk)
                        } label: {
                            Label("不写入成果", systemImage: "minus.circle")
                        }
                        Button {
                            store.updateMeetingTruthConflictAction(conflict.id, action: .markIrrelevant)
                        } label: {
                            Label("标记无关", systemImage: "xmark.circle")
                        }
                        Button {
                            isShowingEvidence.toggle()
                        } label: {
                            Label("查看证据", systemImage: "doc.text.magnifyingglass")
                        }
                        Button {
                            store.showMeetingTruthProcessingTrace(anchor: traceAnchor)
                        } label: {
                            Label("查看处理链路", systemImage: "point.3.connected.trianglepath.dotted")
                        }
                        if isFinalized {
                            Button {
                                store.updateMeetingTruthConflictAction(conflict.id, action: .clearSelection)
                            } label: {
                                Label("撤销应用", systemImage: "arrow.uturn.backward")
                            }
                        }
                    } label: {
                        Label("更多", systemImage: "ellipsis.circle")
                    }
                    Spacer()
                }
                .font(.caption)
            }

            DisclosureGroup("查看证据", isExpanded: $isShowingEvidence) {
                VStack(alignment: .leading, spacing: 8) {
                    reasonRow(recommendationIsConcrete ? "系统建议" : "系统提醒", conflict.recommendation)
                    reasonRow("各路转写写法", conflict.candidates.map { "\($0.source)：\($0.text)" }.joined(separator: "\n"))
                    reasonRow("参考依据", conflict.evidence)
                    if let evidence = conflict.evidenceChain, !evidence.isEmpty {
                        reasonRow("核验依据", evidence.prefix(8).map { "\(MeetingTruthProcessingSource.evidence($0.sourceType))：\($0.candidate) · \($0.supportType.title) · \(Int(($0.confidence * 100).rounded()))%\n\($0.matchedText)" }.joined(separator: "\n\n"))
                    }
                    if let scores = conflict.candidateScores, !scores.isEmpty {
                        reasonRow("候选可信度", scores.map { "\($0.candidate) · \(Int(($0.score * 100).rounded()))% · \($0.recommendedDecision.title)\n\($0.reason)" }.joined(separator: "\n\n"))
                    }
                    reasonRow("是否需要你确认", confirmationStateText)
                }
                .padding(.top, 6)
            }
            .font(.caption)

            DisclosureGroup("查看处理链路") {
                Button {
                    store.showMeetingTruthProcessingTrace(anchor: traceAnchor)
                } label: {
                    Label("打开对应处理步骤", systemImage: "point.3.connected.trianglepath.dotted")
                }
                .padding(.top, 6)
            }
            .font(.caption)

            DisclosureGroup("开发者详情") {
                VStack(alignment: .leading, spacing: 8) {
                    if let trace = conflict.developerTrace, !trace.isEmpty {
                        reasonRow("Gemma function calling / tool_call -> tool_response", trace.prefix(6).map { "\($0.callIndex). \($0.functionName) · \($0.status.title)\n处理来源：\(MeetingTruthProcessingSource.toolRecord($0))\ntool_call：\($0.argumentsSummary)\ntool_response：\($0.resultSummary)" }.joined(separator: "\n\n"))
                    } else {
                        reasonRow("本条没有单独工具调用", "这一步是本地安全校验，用来防止误改正文，不需要调用模型。")
                        DisclosureGroup("开发者字段") {
                            VStack(alignment: .leading, spacing: 8) {
                                reasonRow("gemma_function_calling_used", "false")
                                reasonRow("tool_call", "null")
                                reasonRow("tool_response", "null")
                            }
                            .padding(.top, 6)
                        }
                    }
                }
                .padding(.top, 6)
            }
            .font(.caption)
        }
        .padding(12)
        .background(isFinalized ? Color.green.opacity(0.07) : Color.orange.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onAppear {
            resetManualText()
        }
        .onChange(of: conflict.selectedText) {
            resetManualText()
        }
    }

    private var statusText: String {
        if let reviewStatus = conflict.reviewStatus { return reviewStatus.title }
        if isFinalized { return "已处理" }
        if requiresUserDecision { return "需要确认" }
        return "建议使用"
    }

    private var statusColor: Color {
        if conflict.reviewStatus == .replacementValidationFailed || conflict.reviewStatus == .evidenceConflicted { return .orange }
        if conflict.reviewStatus == .ignoredLowRisk || conflict.reviewStatus == .markedIrrelevant { return .secondary }
        if isFinalized { return .green }
        if requiresUserDecision { return .orange }
        return .blue
    }

    private var summaryTitle: String {
        switch conflict.kind {
        case .person: "人名可能听错"
        case .project: "项目名可能听错"
        case .system: "系统名可能听错"
        case .terminology: "术语可能听错"
        case .amount: "金额可能听错"
        case .date: "时间可能听错"
        case .actionItem: "行动项可能有误"
        case .decision: "决策表述需核验"
        case .ordinaryExpression: "普通表达差异"
        }
    }

    private var summaryText: String {
        let candidates = conflict.candidates.map(\.text).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if candidates.count > 1 {
            return "系统在多份转写或材料中发现 \(candidates.prefix(4).joined(separator: " / ")) 等写法，需要你确认最终写法。"
        }
        if let first = candidates.first {
            return "系统需要确认「\(first)」是否可信。"
        }
        return "系统发现一处会影响成果的转写问题，需要你确认。"
    }

    private var recommendationText: String {
        recommendationIsConcrete ? "建议采用 \(conflict.recommendation)" : "建议保留待确认"
    }

    private var oneLineBasis: String {
        if let basis = conflict.oneLineBasis, !basis.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return basis
        }
        return conflict.evidence.isEmpty ? "系统将多路转写和会议资料放在同一位置核验。" : conflict.evidence
    }

    private var affectedOutputsText: String {
        if conflict.reviewStatus == .replacementValidationFailed {
            return "可信逐字稿、正式纪要"
        }
        switch conflict.kind {
        case .person:
            return "可信逐字稿、正式纪要、参会人、待办事项"
        case .amount:
            return "金额/时间、正式纪要、待办事项"
        case .date:
            return "金额/时间、正式纪要、待办事项"
        case .project, .system, .terminology:
            return "可信逐字稿、正式纪要、项目名/系统名"
        case .actionItem:
            return "待办事项、正式纪要"
        case .decision:
            return "正式纪要、摘要/要点"
        case .ordinaryExpression:
            return "仅证据备注"
        }
    }

    private var traceAnchor: MeetingTruthProcessingAnchorKind {
        if conflict.reviewStatus == .replacementValidationFailed { return .safeReplacementValidation }
        return .conflictAdjudication
    }

    private var selectedText: String {
        MeetingTruthConflictDisplay.selectedText(for: conflict)
    }

    private var recommendationIsConcrete: Bool {
        MeetingTruthRecommendationText.isConcrete(conflict.recommendation)
    }

    private var requiresUserDecision: Bool {
        MeetingTruthConflictDisplay.needsUserDecision(conflict, confirmation: latestConfirmation) ||
        conflict.requiresHumanReview ||
        !recommendationIsConcrete
    }

    private var isFinalized: Bool {
        !MeetingTruthConflictDisplay.needsUserDecision(conflict, confirmation: latestConfirmation)
    }

    private var selectedNeedsRepair: Bool {
        conflict.isResolved && MeetingTruthConflictDisplay.needsUserDecision(conflict, confirmation: latestConfirmation)
    }

    private var selectedSourceSummary: String {
        if recommendationIsConcrete && sameText(selectedText, conflict.recommendation) {
            return "系统建议"
        }
        if let candidate = conflict.candidates.first(where: { sameText($0.text, selectedText) }) {
            return "来自 \(candidate.source) 的说法"
        }
        return "手动输入"
    }

    private var trimmedManualText: String {
        manualText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var latestConfirmation: MeetingTruthManualConfirmation? {
        store.latestMeetingTruthConfirmation(for: conflict.id)
    }

    private var defaultManualText: String {
        if !selectedText.isEmpty, !selectedNeedsRepair {
            return selectedText
        }
        if recommendationIsConcrete {
            return conflict.recommendation
        }
        return conflict.candidates.first?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var canApplyManualText: Bool {
        guard !trimmedManualText.isEmpty else { return false }
        if isFinalized, sameText(trimmedManualText, selectedText) {
            return false
        }
        return true
    }

    private var confirmationStateText: String {
        if isFinalized {
            return "已确认写入；如果自动填充仍不准确，可以在上方改完再保存。"
        }
        if requiresUserDecision {
            return "需要你确认后才会写入结果。"
        }
        return "可以直接使用系统建议；你仍然可以改。"
    }

    private func applyManualText() {
        guard !trimmedManualText.isEmpty else { return }
        store.resolveMeetingTruthConflict(conflict.id, text: trimmedManualText)
    }

    private func resetManualText() {
        manualText = defaultManualText
    }

    private func sameText(_ lhs: String, _ rhs: String) -> Bool {
        lhs.trimmingCharacters(in: .whitespacesAndNewlines) == rhs.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func manualEditSection(title: String, actionTitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField("输入你确认后的正确说法", text: $manualText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(applyManualText)
                Button {
                    applyManualText()
                } label: {
                    Label(actionTitle, systemImage: "checkmark.circle")
                }
                .disabled(!canApplyManualText)
            }
            if isFinalized, sameText(trimmedManualText, selectedText) {
                Text("当前内容已确认；修改文字后可再次保存。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func reasonRow(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text.isEmpty ? "暂无" : text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct MeetingTruthConflictResultsSheet: View {
    @EnvironmentObject private var store: LabStore
    @Environment(\.dismiss) private var dismiss
    @State private var expandedGroups: Set<MeetingTruthConflictResultGroup.Kind> = [.all]
    @State private var selectedGroup: MeetingTruthConflictResultGroup.Kind?
    @State private var selectedConflictID: UUID?

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        summary

                        if store.meetingTruthConflicts.isEmpty {
                            EmptyStateView(
                                systemImage: "checkmark.shield",
                                title: "当前没有冲突结果",
                                message: "返回主界面点击“检查转写冲突”后，这里会显示每一条识别出的差异、建议写法和处理按钮。"
                            )
                            .frame(minHeight: 220)
                        } else {
                            ForEach(resultGroups) { group in
                                MeetingTruthConflictResultGroupView(
                                    group: group,
                                    isExpanded: expandedGroups.contains(group.kind),
                                    selectedConflictID: selectedGroup == group.kind ? selectedConflictID : nil,
                                    onToggle: {
                                        toggleGroup(group.kind)
                                    },
                                    onSelect: { conflict in
                                        selectedGroup = group.kind
                                        selectedConflictID = conflict.id
                                        expandedGroups.insert(group.kind)
                                        scrollToDetail(proxy: proxy, group: group.kind)
                                    },
                                    onSelectPrevious: {
                                        selectNeighbor(in: group, direction: -1, proxy: proxy)
                                    },
                                    onSelectNext: {
                                        selectNeighbor(in: group, direction: 1, proxy: proxy)
                                    },
                                    onActionCompleted: {
                                        if group.kind == .all {
                                            selectNeighbor(in: group, direction: 1, proxy: proxy)
                                        } else {
                                            selectNextPending(proxy: proxy)
                                        }
                                    },
                                    onOpenTrace: { anchor in
                                        store.showMeetingTruthProcessingTrace(anchor: anchor)
                                        dismiss()
                                    }
                                )
                                .id(group.detailID)
                            }
                        }
                    }
                    .padding(20)
                }
            }
            .navigationTitle("冲突结果")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        dismiss()
                    }
                }
            }
        }
        .frame(minWidth: 860, minHeight: 680)
        .onAppear {
            ensureInitialSelection()
        }
        .onChange(of: store.meetingTruthConflicts) {
            ensureSelectionStillVisible()
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("检查转写冲突结果", systemImage: "doc.text.magnifyingglass")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button {
                    store.showMeetingTruthProcessingTrace(anchor: .conflictDiscovery)
                    dismiss()
                } label: {
                    Label("查看处理链路", systemImage: "point.3.connected.trianglepath.dotted")
                }
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                MeetingTruthStatusTile(title: "总冲突", value: "\(store.meetingTruthConflicts.count)", detail: "系统识别出的差异")
                MeetingTruthStatusTile(title: "需要确认", value: "\(MeetingTruthUXDecisionClassifier.pendingConflicts(store: store).count)", detail: "需人工判断")
                MeetingTruthStatusTile(title: "替换未应用", value: "\(replacementFailedConflicts.count)", detail: "需后续复核")
                MeetingTruthStatusTile(title: "已处理/忽略", value: "\(MeetingTruthUXDecisionClassifier.autoResolvedConflicts(store: store).count + MeetingTruthUXDecisionClassifier.excludedConflicts(store: store).count + MeetingTruthUXDecisionClassifier.lowRiskConflicts(store: store).count)", detail: "默认折叠")
            }
        }
        .padding(12)
        .background(.secondary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var resultGroups: [MeetingTruthConflictResultGroup] {
        [
            MeetingTruthConflictResultGroup(kind: .all, conflicts: allConflicts),
            MeetingTruthConflictResultGroup(kind: .pending, conflicts: pendingOnlyConflicts),
            MeetingTruthConflictResultGroup(kind: .replacementFailed, conflicts: replacementFailedConflicts),
            MeetingTruthConflictResultGroup(kind: .applied, conflicts: appliedConflicts),
            MeetingTruthConflictResultGroup(kind: .lowRisk, conflicts: lowRiskConflicts),
            MeetingTruthConflictResultGroup(kind: .excluded, conflicts: excludedConflicts)
        ]
    }

    private var allConflicts: [MeetingTruthConflict] {
        store.meetingTruthConflicts
            .sorted(by: MeetingTruthConflictDisplay.sortForMainList)
    }

    private var replacementFailedConflicts: [MeetingTruthConflict] {
        store.meetingTruthConflicts
            .filter { conflict in
                conflict.reviewStatus == .replacementValidationFailed ||
                    (conflict.replacementValidationResult?.isValid == false && conflict.reviewStatus != .suggestedApplied)
            }
            .sorted(by: MeetingTruthConflictDisplay.sortForMainList)
    }

    private var pendingOnlyConflicts: [MeetingTruthConflict] {
        let failedIDs = Set(replacementFailedConflicts.map(\.id))
        return MeetingTruthUXDecisionClassifier.pendingConflicts(store: store)
            .filter { !failedIDs.contains($0.id) }
    }

    private var appliedConflicts: [MeetingTruthConflict] {
        let failedIDs = Set(replacementFailedConflicts.map(\.id))
        return MeetingTruthUXDecisionClassifier.autoResolvedConflicts(store: store)
            .filter { !failedIDs.contains($0.id) }
    }

    private var excludedConflicts: [MeetingTruthConflict] {
        MeetingTruthUXDecisionClassifier.excludedConflicts(store: store)
    }

    private var lowRiskConflicts: [MeetingTruthConflict] {
        MeetingTruthUXDecisionClassifier.lowRiskConflicts(store: store)
    }

    private func toggleGroup(_ kind: MeetingTruthConflictResultGroup.Kind) {
        if expandedGroups.contains(kind) {
            expandedGroups.remove(kind)
        } else {
            expandedGroups.insert(kind)
            if selectedGroup == nil, let first = resultGroups.first(where: { $0.kind == kind })?.conflicts.first {
                selectedGroup = kind
                selectedConflictID = first.id
            }
        }
    }

    private func ensureInitialSelection() {
        guard selectedConflictID == nil else { return }
        for group in resultGroups where !group.conflicts.isEmpty {
            if expandedGroups.contains(group.kind) || selectedGroup == nil {
                selectedGroup = group.kind
                selectedConflictID = group.conflicts.first?.id
                expandedGroups.insert(group.kind)
                return
            }
        }
    }

    private func ensureSelectionStillVisible() {
        guard let selectedGroup, let selectedConflictID else {
            ensureInitialSelection()
            return
        }
        if resultGroups.first(where: { $0.kind == selectedGroup })?.conflicts.contains(where: { $0.id == selectedConflictID }) == true {
            return
        }
        ensureInitialSelection()
    }

    private func selectNeighbor(in group: MeetingTruthConflictResultGroup, direction: Int, proxy: ScrollViewProxy) {
        guard let selectedConflictID,
              let currentIndex = group.conflicts.firstIndex(where: { $0.id == selectedConflictID }),
              !group.conflicts.isEmpty else { return }
        let nextIndex = min(max(currentIndex + direction, 0), group.conflicts.count - 1)
        self.selectedGroup = group.kind
        self.selectedConflictID = group.conflicts[nextIndex].id
        scrollToDetail(proxy: proxy, group: group.kind)
    }

    private func selectNextPending(proxy: ScrollViewProxy) {
        let pendingGroups: [MeetingTruthConflictResultGroup.Kind] = [.pending, .replacementFailed]
        let freshGroups = resultGroups
        for kind in pendingGroups {
            guard let group = freshGroups.first(where: { $0.kind == kind }),
                  let next = group.conflicts.first else { continue }
            selectedGroup = kind
            selectedConflictID = next.id
            expandedGroups.insert(kind)
            scrollToDetail(proxy: proxy, group: kind)
            return
        }
        selectedGroup = nil
        selectedConflictID = nil
    }

    private func scrollToDetail(proxy: ScrollViewProxy, group: MeetingTruthConflictResultGroup.Kind) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo(group.detailID, anchor: .bottom)
            }
        }
    }
}

private struct MeetingTruthConflictResultGroup: Identifiable {
    enum Kind: String, Hashable {
        case all
        case pending
        case applied
        case excluded
        case lowRisk
        case replacementFailed

        var title: String {
            switch self {
            case .all: "全部冲突"
            case .pending: "待处理"
            case .applied: "已自动修正 / 已采纳记录"
            case .excluded: "不写入 / 暂不处理 / 误报记录"
            case .lowRisk: "低风险忽略"
            case .replacementFailed: "替换校验失败"
            }
        }

        var systemImage: String {
            switch self {
            case .all: "list.bullet.rectangle"
            case .pending: "exclamationmark.circle"
            case .applied: "checkmark.circle"
            case .excluded: "minus.circle"
            case .lowRisk: "leaf"
            case .replacementFailed: "exclamationmark.triangle"
            }
        }

        var color: Color {
            switch self {
            case .all: .blue
            case .pending, .replacementFailed: .orange
            case .applied: .green
            case .excluded, .lowRisk: .secondary
            }
        }

        var detailID: String { "conflict-detail-\(rawValue)" }
    }

    var id: Kind { kind }
    let kind: Kind
    let conflicts: [MeetingTruthConflict]

    var detailID: String { kind.detailID }
}

private struct MeetingTruthConflictResultGroupView: View {
    @EnvironmentObject private var store: LabStore
    let group: MeetingTruthConflictResultGroup
    let isExpanded: Bool
    let selectedConflictID: UUID?
    let onToggle: () -> Void
    let onSelect: (MeetingTruthConflict) -> Void
    let onSelectPrevious: () -> Void
    let onSelectNext: () -> Void
    let onActionCompleted: () -> Void
    let onOpenTrace: (MeetingTruthProcessingAnchorKind) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onToggle) {
                HStack(spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                    Label(group.kind.title, systemImage: group.kind.systemImage)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(group.kind.color)
                    Spacer()
                    Text("\(group.conflicts.count) 条")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                if group.conflicts.isEmpty {
                    Text(group.kind == .all ? "当前没有冲突记录" : (group.kind == .pending ? "当前无待处理冲突" : "本组暂无记录"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    VStack(spacing: 8) {
                        ForEach(group.conflicts) { conflict in
                            MeetingTruthConflictSummaryListItem(
                                conflict: conflict,
                                isSelected: conflict.id == selectedConflictID,
                                onSelect: {
                                    onSelect(conflict)
                                }
                            )
                        }
                    }

                    if let selected = selectedConflict {
                        MeetingTruthConflictBottomDetailPanel(
                            conflict: selected,
                            index: selectedIndex + 1,
                            total: group.conflicts.count,
                            canGoPrevious: selectedIndex > 0,
                            canGoNext: selectedIndex < group.conflicts.count - 1,
                            onPrevious: onSelectPrevious,
                            onNext: onSelectNext,
                            onActionCompleted: onActionCompleted,
                            onOpenTrace: onOpenTrace
                        )
                        .id(group.detailID)
                        .padding(.top, 4)
                    }
                }
            }
        }
        .padding(12)
        .background(group.kind.color.opacity(isExpanded ? 0.08 : 0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var selectedConflict: MeetingTruthConflict? {
        guard let selectedConflictID else { return group.conflicts.first }
        return group.conflicts.first(where: { $0.id == selectedConflictID }) ?? group.conflicts.first
    }

    private var selectedIndex: Int {
        guard let selectedConflict else { return 0 }
        return group.conflicts.firstIndex(where: { $0.id == selectedConflict.id }) ?? 0
    }
}

private struct MeetingTruthConflictSummaryListItem: View {
    @EnvironmentObject private var store: LabStore
    let conflict: MeetingTruthConflict
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(problemTitle)
                            .font(.subheadline.weight(.semibold))
                        Text(conflict.timestamp)
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Text(summaryText)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        MeetingTruthPlainStatus(text: statusText, color: statusColor)
                        MeetingTruthPlainStatus(text: impactSummary, color: .blue)
                        ForEach(sourceLabels.prefix(3), id: \.self) { label in
                            MeetingTruthPlainStatus(text: label, color: .secondary)
                        }
                    }
                }
                Spacer()
                Image(systemName: "chevron.down.circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(10)
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor.opacity(0.55) : Color.clear, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var problemTitle: String {
        MeetingTruthConflictText.problemTitle(for: conflict)
    }

    private var summaryText: String {
        let candidates = conflict.candidates.map(\.text).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let left = candidates.prefix(2).joined(separator: " / ")
        let recommendation = MeetingTruthConflictText.recommendationText(for: conflict)
        if !left.isEmpty {
            return "\(left) -> 建议 \(recommendation)"
        }
        return "建议 \(recommendation)"
    }

    private var impactSummary: String {
        MeetingTruthConflictText.affectedOutputsText(for: conflict)
    }

    private var sourceLabels: [String] {
        MeetingTruthConflictText.sourceLabels(for: conflict, store: store)
    }

    private var statusText: String {
        MeetingTruthConflictText.statusText(for: conflict, store: store)
    }

    private var statusColor: Color {
        MeetingTruthConflictText.statusColor(for: conflict, store: store)
    }
}

private struct MeetingTruthConflictBottomDetailPanel: View {
    @EnvironmentObject private var store: LabStore
    let conflict: MeetingTruthConflict
    let index: Int
    let total: Int
    let canGoPrevious: Bool
    let canGoNext: Bool
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onActionCompleted: () -> Void
    let onOpenTrace: (MeetingTruthProcessingAnchorKind) -> Void
    @State private var manualText = ""
    @State private var evidenceExpanded = false
    @State private var developerExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("正在查看第 \(index) / \(total) 条")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(MeetingTruthConflictText.problemTitle(for: conflict))
                        .font(.title3.weight(.semibold))
                }
                Spacer()
                Button(action: onPrevious) {
                    Label("上一条", systemImage: "chevron.up")
                }
                .disabled(!canGoPrevious)
                Button(action: onNext) {
                    Label("下一条", systemImage: "chevron.down")
                }
                .disabled(!canGoNext)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 10) {
                MeetingTruthInfoBlock(title: "这是什么问题", text: MeetingTruthConflictText.problemTitle(for: conflict))
                MeetingTruthInfoBlock(title: "系统建议", text: "建议采用 \(MeetingTruthConflictText.recommendationText(for: conflict))", highlight: true)
                MeetingTruthInfoBlock(title: "为什么这样建议", text: MeetingTruthConflictText.userBasisText(for: conflict))
                MeetingTruthInfoBlock(title: "当前处理结果", text: MeetingTruthConflictText.currentResultText(for: conflict, store: store))
                MeetingTruthInfoBlock(title: "会影响哪里", text: MeetingTruthConflictText.affectedOutputsText(for: conflict))
                MeetingTruthInfoBlock(title: "下一步建议", text: MeetingTruthConflictText.nextStepText(for: conflict, store: store), highlight: MeetingTruthConflictText.needsFollowUp(conflict, store: store))
            }

            if !conflict.candidates.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("候选写法")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
                        ForEach(conflict.candidates) { candidate in
                            Button {
                                store.resolveMeetingTruthConflict(conflict.id, text: candidate.text)
                                manualText = candidate.text
                                onActionCompleted()
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(candidate.source)
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    Text(candidate.text)
                                        .font(.subheadline.weight(.medium))
                                        .lineLimit(2)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    if MeetingTruthConflictDisplay.sameTextForUI(candidate.text, MeetingTruthConflictDisplay.selectedText(for: conflict)) {
                                        Label("已采用", systemImage: "checkmark.circle.fill")
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(.green)
                                    }
                                }
                                .padding(9)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(MeetingTruthConflictDisplay.sameTextForUI(candidate.text, MeetingTruthConflictDisplay.selectedText(for: conflict)) ? Color.green.opacity(0.12) : Color.secondary.opacity(0.07))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            if showsManualInput {
                HStack(spacing: 8) {
                    TextField("输入确认后的写法", text: $manualText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(applyManualText)
                    Button {
                        applyManualText()
                        onActionCompleted()
                    } label: {
                        Label("保存修改", systemImage: "checkmark.circle")
                    }
                    .disabled(manualText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            evidenceDisclosure
            traceButton
            developerDisclosure

            Divider()

            actionBar
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.accentColor.opacity(0.35), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onAppear(perform: resetManualText)
        .onChange(of: conflict.id) {
            resetManualText()
            evidenceExpanded = false
            developerExpanded = false
        }
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            ForEach(primaryActions) { action in
                primaryActionButton(action)
            }

            Menu {
                ForEach(moreActions) { action in
                    Button {
                        perform(action)
                    } label: {
                        Label(action.title, systemImage: action.systemImage)
                    }
                }
            } label: {
                Label("更多", systemImage: "ellipsis.circle")
            }
            .menuStyle(.button)

            Spacer()
        }
    }

    @ViewBuilder
    private func primaryActionButton(_ action: MeetingTruthConflictDetailAction) -> some View {
        if action.isProminent {
            Button {
                perform(action)
            } label: {
                Label(action.title, systemImage: action.systemImage)
            }
            .buttonStyle(.borderedProminent)
            .disabled(action == .manualEdit && manualText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } else {
            Button {
                perform(action)
            } label: {
                Label(action.title, systemImage: action.systemImage)
            }
            .buttonStyle(.bordered)
            .disabled(action == .manualEdit && manualText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var evidenceDisclosure: some View {
        DisclosureGroup("查看核验依据", isExpanded: $evidenceExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                detailRow("各路 ASR 识别结果", conflict.candidates.map { "\($0.source)：\($0.text)" }.joined(separator: "\n"))
                detailRow("图片文字识别", evidenceText(sourceTypes: [.imageOCR]))
                detailRow("原图理解", evidenceText(sourceTypes: [.rawVision]))
                detailRow("会议材料", evidenceText(sourceTypes: [.material, .glossary, .meetingNotice, .handwrittenNote, .slideOrPPT, .whiteboard, .screenshot]))
                detailRow("人工确认", latestConfirmationText)
                detailRow("可信度摘要", confidenceSummary)
            }
            .padding(.top, 6)
        }
        .font(.caption)
    }

    private var traceButton: some View {
        Button {
            onOpenTrace(MeetingTruthConflictText.traceAnchor(for: conflict))
        } label: {
            Label("查看处理链路", systemImage: "point.3.connected.trianglepath.dotted")
        }
        .font(.caption)
    }

    private var developerDisclosure: some View {
        DisclosureGroup("开发者详情", isExpanded: $developerExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                detailRow("replacement_validation_result", developerValidationText)
                detailRow("span", developerSpanText)
                detailRow("support_type", developerSupportText)
                detailRow("candidate_score", developerScoreText)
                detailRow("tool_call", developerToolCallText)
                detailRow("tool_response", developerToolResponseText)
                detailRow("raw JSON", rawJSONText)
            }
            .padding(.top, 6)
        }
        .font(.caption)
    }

    private var primaryActions: [MeetingTruthConflictDetailAction] {
        switch MeetingTruthConflictText.actionState(for: conflict, store: store) {
        case .needsReview, .replacementFailed:
            return [.adoptSuggestion, .manualEdit]
        case .applied:
            return [.clearSelection, .manualEdit]
        case .ignored:
            return [.restoreProcessing]
        case .pending:
            return [.adoptSuggestion, .manualEdit]
        }
    }

    private var moreActions: [MeetingTruthConflictDetailAction] {
        switch MeetingTruthConflictText.actionState(for: conflict, store: store) {
        case .needsReview, .replacementFailed:
            return [.deferForReview, .markIrrelevant, .showEvidence, .showTrace]
        case .applied:
            return [.showEvidence, .showTrace]
        case .ignored:
            return [.showEvidence, .markIrrelevant]
        case .pending:
            return [.ignoreLowRisk, .deferForReview, .showEvidence]
        }
    }

    private var showsManualInput: Bool {
        primaryActions.contains(.manualEdit)
    }

    private var latestConfirmationText: String {
        guard let confirmation = store.latestMeetingTruthConfirmation(for: conflict.id) else {
            return "暂无人工确认。"
        }
        let text = confirmation.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? "已人工确认：\(text!)" : "用户选择：\(decisionTitle(confirmation.decision))"
    }

    private var confidenceSummary: String {
        if let scores = conflict.candidateScores, !scores.isEmpty {
            return scores.prefix(4).map { "\($0.candidate)：\(Int(($0.score * 100).rounded()))%，判断为 \($0.recommendedDecision.title)。\($0.reason)" }.joined(separator: "\n")
        }
        return "系统置信度：\(conflict.confidence.title)。\(MeetingTruthConflictText.userBasisText(for: conflict))"
    }

    private var developerValidationText: String {
        guard let validation = conflict.replacementValidationResult else {
            return "not_run"
        }
        let targetFound = validation.isValid ? "true" : "false"
        let checks = validation.pollutionChecks.isEmpty ? "pollution_checks=[]" : "pollution_checks=\(validation.pollutionChecks.joined(separator: " / "))"
        return "target_span_found = \(targetFound)\napplied_span_count = \(validation.appliedSpanCount)\nreason = \(validation.reason)\n\(checks)"
    }

    private var developerSpanText: String {
        guard let spans = conflict.replacementSpans, !spans.isEmpty else {
            return "[]"
        }
        return spans.map { "\($0.spanID)：\($0.originalText) -> \($0.replacementText) [\($0.rangeStart), \($0.rangeEnd)]" }.joined(separator: "\n")
    }

    private var developerSupportText: String {
        guard let chain = conflict.evidenceChain, !chain.isEmpty else {
            return "[]"
        }
        return chain.map { "\($0.candidate)：support_type=\($0.supportType.rawValue)，source=\($0.sourceType.rawValue)，confidence=\($0.confidence)" }.joined(separator: "\n")
    }

    private var developerScoreText: String {
        guard let scores = conflict.candidateScores, !scores.isEmpty else {
            return "[]"
        }
        return scores.map { "\($0.candidate)：candidate_score=\($0.score)，decision=\($0.recommendedDecision.rawValue)" }.joined(separator: "\n")
    }

    private var developerToolCallText: String {
        guard let trace = conflict.developerTrace, !trace.isEmpty else {
            return "null"
        }
        return trace.prefix(8).map { "\($0.callIndex). \($0.functionName)：\($0.argumentsSummary)" }.joined(separator: "\n")
    }

    private var developerToolResponseText: String {
        guard let trace = conflict.developerTrace, !trace.isEmpty else {
            return "null"
        }
        return trace.prefix(8).map { "\($0.callIndex). \($0.functionName)：\($0.resultSummary)" }.joined(separator: "\n")
    }

    private var rawJSONText: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(conflict),
              let text = String(data: data, encoding: .utf8) else {
            return "无法序列化本条记录。"
        }
        return text
    }

    private func evidenceText(sourceTypes: Set<MeetingTruthEvidenceSupport.SourceType>) -> String {
        let rows = (conflict.evidenceChain ?? [])
            .filter { sourceTypes.contains($0.sourceType) }
            .prefix(6)
            .map { "\($0.sourceType.title)：\($0.candidate) · \($0.supportType.title)\n\($0.matchedText)" }
        if !rows.isEmpty {
            return rows.joined(separator: "\n\n")
        }
        return "暂无对应证据。"
    }

    private func detailRow(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "暂无" : text)
                .font(.caption)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func perform(_ action: MeetingTruthConflictDetailAction) {
        switch action {
        case .adoptSuggestion:
            store.resolveMeetingTruthConflict(conflict.id, text: conflict.recommendation)
            onActionCompleted()
        case .manualEdit:
            applyManualText()
            onActionCompleted()
        case .clearSelection, .restoreProcessing:
            store.updateMeetingTruthConflictAction(conflict.id, action: .clearSelection)
            onActionCompleted()
        case .deferForReview:
            store.updateMeetingTruthConflictAction(conflict.id, action: .deferForReview)
            onActionCompleted()
        case .ignoreLowRisk:
            store.updateMeetingTruthConflictAction(conflict.id, action: .ignoreLowRisk)
            onActionCompleted()
        case .markIrrelevant:
            store.updateMeetingTruthConflictAction(conflict.id, action: .markIrrelevant)
            onActionCompleted()
        case .showEvidence:
            evidenceExpanded = true
        case .showTrace:
            onOpenTrace(MeetingTruthConflictText.traceAnchor(for: conflict))
        }
    }

    private func applyManualText() {
        let trimmed = manualText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        store.resolveMeetingTruthConflict(conflict.id, text: trimmed)
    }

    private func resetManualText() {
        let selected = MeetingTruthConflictDisplay.selectedText(for: conflict)
        if !selected.isEmpty {
            manualText = selected
        } else if MeetingTruthRecommendationText.isConcrete(conflict.recommendation) {
            manualText = conflict.recommendation
        } else {
            manualText = conflict.candidates.first?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
    }

    private func decisionTitle(_ decision: MeetingTruthManualConfirmation.Decision) -> String {
        switch decision {
        case .acceptedRecommendation:
            return "采用建议"
        case .selectedCandidate:
            return "选择候选"
        case .manualEdit:
            return "手动修改"
        case .ignoredSuggestion:
            return "不写入 / 暂不处理"
        case .clearedSelection:
            return "撤销应用"
        }
    }
}

private enum MeetingTruthConflictDetailAction: String, Identifiable {
    case adoptSuggestion
    case manualEdit
    case clearSelection
    case deferForReview
    case ignoreLowRisk
    case markIrrelevant
    case restoreProcessing
    case showEvidence
    case showTrace

    var id: String { rawValue }

    var title: String {
        switch self {
        case .adoptSuggestion: "采用建议"
        case .manualEdit: "手动修改"
        case .clearSelection: "撤销应用"
        case .deferForReview: "暂不处理"
        case .ignoreLowRisk: "不写入成果"
        case .markIrrelevant: "标记无关"
        case .restoreProcessing: "恢复处理"
        case .showEvidence: "查看证据"
        case .showTrace: "查看处理链路"
        }
    }

    var systemImage: String {
        switch self {
        case .adoptSuggestion: "checkmark.circle"
        case .manualEdit: "pencil"
        case .clearSelection: "arrow.uturn.backward"
        case .deferForReview: "clock"
        case .ignoreLowRisk: "minus.circle"
        case .markIrrelevant: "xmark.circle"
        case .restoreProcessing: "arrow.counterclockwise"
        case .showEvidence: "doc.text.magnifyingglass"
        case .showTrace: "point.3.connected.trianglepath.dotted"
        }
    }

    var isProminent: Bool {
        self == .adoptSuggestion || self == .restoreProcessing
    }
}

@MainActor
private enum MeetingTruthConflictText {
    enum ActionState {
        case needsReview
        case replacementFailed
        case applied
        case ignored
        case pending
    }

    static func actionState(for conflict: MeetingTruthConflict, store: LabStore) -> ActionState {
        if conflict.reviewStatus == .suggestedApplied {
            return .applied
        }
        if conflict.reviewStatus == .replacementValidationFailed || conflict.replacementValidationResult?.isValid == false {
            return .replacementFailed
        }
        if conflict.reviewStatus == .ignoredLowRisk || conflict.reviewStatus == .markedIrrelevant || conflict.reviewStatus == .deferredForCentralReview {
            return .ignored
        }
        if MeetingTruthConflictDisplay.needsUserDecision(conflict, confirmation: store.latestMeetingTruthConfirmation(for: conflict.id)) || conflict.requiresHumanReview {
            return .needsReview
        }
        if !MeetingTruthConflictDisplay.selectedText(for: conflict).isEmpty {
            return .applied
        }
        return .pending
    }

    static func problemTitle(for conflict: MeetingTruthConflict) -> String {
        switch conflict.kind {
        case .person: "人名不确定"
        case .amount: "金额冲突"
        case .ordinaryExpression: "低风险表达"
        case .terminology, .project, .system: "术语可能听错"
        case .date: "日期不确定"
        case .actionItem: "待办表述需确认"
        case .decision: "决策表述需确认"
        }
    }

    static func recommendationText(for conflict: MeetingTruthConflict) -> String {
        MeetingTruthRecommendationText.isConcrete(conflict.recommendation) ? conflict.recommendation : "保留待确认"
    }

    static func userBasisText(for conflict: MeetingTruthConflict) -> String {
        if let basis = conflict.oneLineBasis?.trimmingCharacters(in: .whitespacesAndNewlines), !basis.isEmpty {
            return basis
        }
        let evidence = conflict.evidence.trimmingCharacters(in: .whitespacesAndNewlines)
        if !evidence.isEmpty {
            return evidence
        }
        if let support = conflict.evidenceChain?.first {
            return "\(support.sourceType.title)中出现相关依据，判断为\(support.supportType.title)。"
        }
        return "系统将多路转写、图片识别、原图理解和会议材料放在同一位置核验。"
    }

    static func currentResultText(for conflict: MeetingTruthConflict, store: LabStore) -> String {
        switch actionState(for: conflict, store: store) {
        case .replacementFailed:
            return "自动修正未应用。系统没有找到可安全替换的原文位置，为避免误改，本次没有修改正文。"
        case .applied:
            let selected = MeetingTruthConflictDisplay.selectedText(for: conflict)
            let text = selected.isEmpty ? recommendationText(for: conflict) : selected
            return "已应用：\(text)。可信逐字稿和后续成果会优先使用该写法。"
        case .ignored:
            return "当前记录已暂不处理、低风险忽略或标记无关，不会打断成果生成。"
        case .needsReview, .pending:
            return "当前尚未确认写法。系统会保留待处理状态，避免把不确定内容直接写入成果。"
        }
    }

    static func affectedOutputsText(for conflict: MeetingTruthConflict) -> String {
        if let outputs = conflict.affectedOutputs, !outputs.isEmpty {
            return outputs.map(\.title).joined(separator: "、")
        }
        switch conflict.kind {
        case .person:
            return "可信逐字稿、纪要、待办、参会人"
        case .amount, .date:
            return "可信逐字稿、纪要、待办"
        case .project, .system, .terminology:
            return "可信逐字稿、纪要"
        case .actionItem:
            return "纪要、待办"
        case .decision:
            return "纪要"
        case .ordinaryExpression:
            return "不进入成果"
        }
    }

    static func nextStepText(for conflict: MeetingTruthConflict, store: LabStore) -> String {
        switch actionState(for: conflict, store: store) {
        case .replacementFailed:
            return "请手动确认是否采用 \(recommendationText(for: conflict))，或进入后续复核。"
        case .applied:
            return "如写法不对，可以撤销应用或重新修改。"
        case .ignored:
            return "需要重新处理时，可恢复处理。"
        case .needsReview, .pending:
            return "请采用建议、手动修改，或选择暂不处理。"
        }
    }

    static func needsFollowUp(_ conflict: MeetingTruthConflict, store: LabStore) -> Bool {
        switch actionState(for: conflict, store: store) {
        case .needsReview, .replacementFailed, .pending:
            return true
        case .applied, .ignored:
            return false
        }
    }

    static func sourceLabels(for conflict: MeetingTruthConflict, store: LabStore) -> [String] {
        var labels: [String] = []
        let chain = conflict.evidenceChain ?? []
        if chain.contains(where: { $0.sourceType == .imageOCR || $0.sourceType == .screenshot || $0.sourceType == .whiteboard }) {
            labels.append("图片识别")
        }
        if chain.contains(where: { [.material, .glossary, .meetingNotice, .handwrittenNote, .slideOrPPT].contains($0.sourceType) }) {
            labels.append("会议材料")
        }
        if chain.contains(where: { $0.sourceType == .human }) || store.latestMeetingTruthConfirmation(for: conflict.id) != nil {
            labels.append("人工确认")
        }
        if conflict.replacementValidationResult != nil {
            labels.append("本地校验")
        }
        if conflict.developerTrace?.isEmpty == false || !conflict.evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            labels.append("Gemma 判断")
        }
        if labels.isEmpty {
            labels.append("本地校验")
        }
        return Array(Set(labels)).sorted { lhs, rhs in
            sourceOrder(lhs) < sourceOrder(rhs)
        }
    }

    static func statusText(for conflict: MeetingTruthConflict, store: LabStore) -> String {
        switch actionState(for: conflict, store: store) {
        case .replacementFailed:
            return "未应用，需后续复核"
        case .applied:
            return "已应用"
        case .ignored:
            if conflict.reviewStatus == .ignoredLowRisk { return "已忽略" }
            if conflict.reviewStatus == .markedIrrelevant { return "已忽略" }
            return "未应用，需后续复核"
        case .needsReview, .pending:
            return "待确认"
        }
    }

    static func statusColor(for conflict: MeetingTruthConflict, store: LabStore) -> Color {
        switch actionState(for: conflict, store: store) {
        case .applied:
            return .green
        case .ignored:
            return .secondary
        case .replacementFailed, .needsReview, .pending:
            return .orange
        }
    }

    static func traceAnchor(for conflict: MeetingTruthConflict) -> MeetingTruthProcessingAnchorKind {
        if conflict.reviewStatus == .replacementValidationFailed || conflict.replacementValidationResult?.isValid == false {
            return .safeReplacementValidation
        }
        if conflict.evidenceChain?.isEmpty == false {
            return .evidenceRetrieval
        }
        return .conflictAdjudication
    }

    private static func sourceOrder(_ label: String) -> Int {
        switch label {
        case "图片识别": 0
        case "会议材料": 1
        case "人工确认": 2
        case "本地校验": 3
        case "Gemma 判断": 4
        default: 9
        }
    }
}

private struct MeetingTruthResultCard: View {
    @EnvironmentObject private var store: LabStore

    var body: some View {
        Surface {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    MeetingTruthSectionHeader(
                        title: "生成会议结果",
                        subtitle: generationSubtitle
                    )
                    Spacer()
                    Button {
                        if store.isGeneratingMeetingTruthPackage {
                            store.cancelMeetingTruthTask()
                        } else {
                            store.generateMeetingTruthPackage()
                        }
                    } label: {
                        Label(
                            store.isGeneratingMeetingTruthPackage ? "停止" : "生成会议结果",
                            systemImage: store.isGeneratingMeetingTruthPackage ? "stop.circle" : "wand.and.stars"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(store.isGeneratingMeetingTruthPackage ? .red : .accentColor)
                    .disabled(
                        !store.isGeneratingMeetingTruthPackage &&
                        (blockingDecisionCount > 0 ||
                         !store.hasDiscoveredMeetingTruthConflicts ||
                         store.meetingTruthTrustedTranscript.isEmpty)
                    )
                }

                MeetingTruthGenerationGateNotice(
                    pendingCount: pendingDecisionCount,
                    blockingCount: blockingDecisionCount,
                    hasDiscoveredConflicts: store.hasDiscoveredMeetingTruthConflicts,
                    hasTrustedTranscript: !store.meetingTruthTrustedTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )

                if let analysis = store.meetingTruthAnalysis {
                    VStack(alignment: .leading, spacing: 10) {
                        MeetingTruthPostReviewStatusPanel()
                        MeetingTruthTrustSummaryPanel()
                        trustedTranscriptBlock()
                        if !participantEvidenceSummary.isEmpty {
                            resultBlock("人名/参会人员证据", participantEvidenceSummary)
                        }
                        minutesBlock(analysis.minutes)
                        mindMapBlock(analysis.mindMap)
                        resultBlock("4. 会后一页纸", analysis.summary)
                        resultBlock("5. 关键要点", bulletSummary(analysis.keyPoints))
                        actionItemsBlock(analysis.actionItems)
                        MeetingTruthEvidenceNotesPanel(notes: analysis.evidenceNotes)
                        MeetingTruthPendingAndExcludedPanel()
                    }
                } else {
                    pendingGenerationState
                }
            }
        }
    }

    private var generationSubtitle: String {
        if blockingDecisionCount > 0 {
            return "还有高风险事项需要处理，处理后才能生成可信成果。"
        }
        if pendingDecisionCount > 0 {
            return "还有未确认内容，结果页会集中列出待确认说明。"
        }
        return "当前无需要人工处理的高风险事项，可以生成会议成果。"
    }

    private var pendingGenerationState: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: pendingGenerationIcon)
                    .foregroundStyle(pendingGenerationColor)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 4) {
                    Text(pendingGenerationTitle)
                        .font(.subheadline.weight(.semibold))
                    Text(pendingGenerationDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                MeetingTruthStatusTile(title: "候选转写", value: "\(store.meetingTruthTranscriptSources.count)", detail: "当前项目导入")
                MeetingTruthStatusTile(title: "冲突检查", value: store.hasDiscoveredMeetingTruthConflicts ? "已检查" : "未检查", detail: store.hasDiscoveredMeetingTruthConflicts ? "\(store.meetingTruthConflicts.count) 条记录" : "先运行检查")
                MeetingTruthStatusTile(title: "可信逐字稿", value: store.meetingTruthTrustedTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未形成" : "已形成", detail: "生成后展示正文")
            }

            HStack(spacing: 8) {
                Button {
                    store.discoverMeetingTruthConflictsWithGemma()
                } label: {
                    Label("检查转写冲突", systemImage: "magnifyingglass")
                }
                .disabled(store.meetingTruthTranscriptSources.count < 2 || store.isMeetingTruthTaskRunning)

                Button {
                    store.showMeetingTruthProcessingTrace(anchor: .centralReviewHandoff)
                } label: {
                    Label("查看处理链路", systemImage: "point.3.connected.trianglepath.dotted")
                }
            }
            .font(.caption)
        }
        .padding(12)
        .background(pendingGenerationColor.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var pendingGenerationTitle: String {
        if store.meetingTruthTranscriptSources.count < 2 { return "等待候选转写" }
        if !store.hasDiscoveredMeetingTruthConflicts { return "请先检查转写冲突" }
        if blockingDecisionCount > 0 { return "还有高风险事项未处理" }
        if store.meetingTruthTrustedTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "等待形成可信逐字稿" }
        return "可以生成会议结果"
    }

    private var pendingGenerationDetail: String {
        if store.meetingTruthTranscriptSources.count < 2 {
            return "导入至少两份候选转写后，系统才能比较差异。这里不会提前显示旧项目或缓存正文。"
        }
        if !store.hasDiscoveredMeetingTruthConflicts {
            return "当前只显示本项目状态。运行检查后，可进入冲突结果列表查看各路 ASR、建议写法和核验依据。"
        }
        if blockingDecisionCount > 0 {
            return "处理需要确认的冲突或复核项后，再生成正式纪要、待办和证据说明。"
        }
        if store.meetingTruthTrustedTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "冲突检查已完成，但可信逐字稿尚未形成。请查看冲突结果或处理链路确认当前状态。"
        }
        return "正式结果还没有生成。点击右上角按钮后，才会在这里显示逐字稿、纪要和待办正文。"
    }

    private var pendingGenerationIcon: String {
        if store.meetingTruthTranscriptSources.count < 2 || !store.hasDiscoveredMeetingTruthConflicts { return "exclamationmark.triangle.fill" }
        if blockingDecisionCount > 0 { return "exclamationmark.triangle.fill" }
        return "checkmark.seal.fill"
    }

    private var pendingGenerationColor: Color {
        if store.meetingTruthTranscriptSources.count < 2 || !store.hasDiscoveredMeetingTruthConflicts || blockingDecisionCount > 0 {
            return .orange
        }
        return .green
    }

    private func trustedTranscriptBlock() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("1. 可信逐字稿")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    copyTrustedTranscriptForDebug()
                } label: {
                    Label("复制逐字稿", systemImage: "doc.on.doc")
                }
                .controlSize(.small)
                .disabled(formattedTrustedTranscriptParagraphs.isEmpty)
                Button {
                    store.showMeetingTruthProcessingTrace(anchor: .safeReplacementValidation)
                } label: {
                    Label("查看处理链路", systemImage: "point.3.connected.trianglepath.dotted")
                }
                .controlSize(.small)
            }

            if !trustedTranscriptSourceLabels.isEmpty {
                HStack(spacing: 6) {
                    ForEach(trustedTranscriptSourceLabels, id: \.self) { label in
                        MeetingTruthPlainStatus(text: label, color: .secondary)
                    }
                }
            }

            let paragraphs = formattedTrustedTranscriptParagraphs
            if paragraphs.isEmpty {
                Text("暂无")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                        Text(paragraph)
                            .font(.caption)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            MeetingTruthTranscriptCorrectionsDisclosure()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(.secondary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func copyTrustedTranscriptForDebug() {
        let labels = trustedTranscriptSourceLabels.joined(separator: "\n")
        let body = formattedTrustedTranscriptParagraphs.joined(separator: "\n\n")
        let text = [labels, body]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func resultBlock(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text.isEmpty ? "暂无" : text)
                .font(.caption)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(.secondary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func minutesBlock(_ minutes: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("2. 正式会议纪要")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if minutes.isEmpty {
                Text("暂无")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(minutes.enumerated()), id: \.offset) { _, minute in
                    VStack(alignment: .leading, spacing: 5) {
                        Text("• \(minute)")
                            .font(.caption)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        let tags = sourceTags(for: minute)
                        if !tags.isEmpty {
                            MeetingTruthSourceTagRow(tags: tags)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(.secondary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func mindMapBlock(_ nodes: [MindMapNode]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("3. 思维导图")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            MeetingMindMapCanvas(nodes: nodes, rootTitle: "会议结果")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(.secondary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func actionItemsBlock(_ items: [MeetingActionItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("6. 待办事项")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    store.showMeetingTruthProcessingTrace(anchor: .centralReviewHandoff)
                } label: {
                    Label("查看处理链路", systemImage: "point.3.connected.trianglepath.dotted")
                }
                .controlSize(.small)
            }

            if items.isEmpty {
                Text("暂无明确待办")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 5) {
                        Text("• \(item.task)")
                            .font(.caption)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        MeetingTruthSourceTagRow(tags: actionTags(for: item))
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(.secondary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var trustedTranscriptSourceLabels: [String] {
        [
            store.meetingTruthPrimaryTranscriptSource.map { "主底稿：\($0.name)" },
            store.meetingTruthTimestampAnchorSource.map { "定位锚点：\($0.name)" }
        ]
        .compactMap { $0 }
    }

    private var formattedTrustedTranscriptParagraphs: [String] {
        formattedTranscriptParagraphs(from: store.meetingTruthTrustedTranscript)
    }

    private func formattedTranscriptParagraphs(from transcript: String) -> [String] {
        let repairedTranscript = repairTranscriptSeamNoise(transcript)
        let rawLines = repairedTranscript
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var paragraphs: [String] = []
        for line in rawLines {
            if line.hasPrefix("已确认会议信息：") || line.hasPrefix("- ") {
                paragraphs.append(line)
            } else {
                paragraphs.append(line)
            }
        }
        return repairingAdjacentTranscriptSegments(paragraphs)
    }

    private func repairTranscriptSeamNoise(_ transcript: String) -> String {
        transcript
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: #"等[。\.]\s*方面"#, with: "等方面", options: .regularExpression)
            .replacingOccurrences(of: #"第二个感受[。\.]\s*第二个感受呢[，,]"#, with: "第二个感受呢，", options: .regularExpression)
            .replacingOccurrences(of: #"后续不能只依赖AI[。\.]\s*后续不能只依赖ASR原文"#, with: "后续不能只依赖ASR原文", options: .regularExpression)
            .replacingOccurrences(of: #"要比较多么[。\.]\s*这东西是一个结果[，,]?\s*要比较多模态输入"#, with: "要比较多模态输入", options: .regularExpression)
            .replacingOccurrences(of: #"希望会后大家按照\s+今天的思路"#, with: "希望会后大家按照今天的思路", options: .regularExpression)
            .replacingOccurrences(of: "准确度、准确度和准确率", with: "准确度和准确率")
            .replacingOccurrences(of: "会议通知知", with: "会议通知")
            .replacingOccurrences(of: "一份正、正式的通知", with: "一份正式的通知")
            .replacingOccurrences(of: "OCR 负责手识别手写", with: "OCR 负责识别手写")
            .replacingOccurrences(of: "OCR负责手识别手写", with: "OCR负责识别手写")
    }

    private func repairingAdjacentTranscriptSegments(_ paragraphs: [String]) -> [String] {
        var result: [String] = []
        for paragraph in paragraphs {
            let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard let previous = result.last else {
                result.append(trimmed)
                continue
            }

            let overlap = leadingOverlapLengthIgnoringPunctuation(previous: previous, current: trimmed)
            var cleaned = overlap > 0
                ? String(trimmed.dropFirst(overlap)).trimmingCharacters(in: .whitespacesAndNewlines)
                : trimmed
            if shouldMergeTranscriptSegment(previous: previous, current: cleaned) {
                cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleaned.isEmpty else { continue }
                let glue = needsSpaceBetween(previous, cleaned) ? " " : ""
                result[result.count - 1] = previous + glue + cleaned
                continue
            }
            if !cleaned.isEmpty {
                result.append(cleaned)
            }
        }
        return result
    }

    private func leadingOverlapLengthIgnoringPunctuation(previous: String, current: String) -> Int {
        let previousUnits = normalizedOverlapUnits(previous)
        let currentUnits = normalizedOverlapUnits(current)
        let maximum = min(previousUnits.count, currentUnits.count, 80)
        guard maximum >= 6 else { return 0 }

        for length in stride(from: maximum, through: 6, by: -1) {
            let previousSuffix = previousUnits.suffix(length).map(\.normalized).joined()
            let currentPrefix = currentUnits.prefix(length).map(\.normalized).joined()
            if previousSuffix == currentPrefix,
               let lastOriginalEnd = currentUnits.prefix(length).last?.originalEnd {
                return lastOriginalEnd
            }
        }
        return 0
    }

    private func normalizedOverlapUnits(_ text: String) -> [(normalized: String, originalEnd: Int)] {
        var units: [(String, Int)] = []
        var offset = 0
        for character in text {
            offset += 1
            let normalized = normalizedOverlapCharacter(character)
            if !normalized.isEmpty {
                units.append((normalized, offset))
            }
        }
        return units
    }

    private func normalizedOverlapCharacter(_ character: Character) -> String {
        let text = String(character).lowercased()
        if " \n\t\r，,。；;：:“”\"'‘’、（）()[]【】《》<>！？!?·".contains(character) {
            return ""
        }
        return text
    }

    private func shouldMergeTranscriptSegment(previous: String, current: String) -> Bool {
        guard !current.isEmpty else { return false }
        if previous.hasPrefix("已确认会议信息：") || current.hasPrefix("- ") { return false }
        if hasStrongParagraphStart(current) { return false }
        if !endsLikeCompletedThought(previous) { return true }
        if startsLikeContinuationFragment(current) { return true }
        return false
    }

    private func endsLikeCompletedThought(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else { return false }
        return "。！？!?".contains(last)
    }

    private func hasStrongParagraphStart(_ text: String) -> Bool {
        let starts = [
            "第一个", "第二个", "第三个", "第一，", "第二，", "第三，",
            "第一是", "第二是", "第三是", "下一步", "总的来说", "今天的思路"
        ]
        return starts.contains { text.hasPrefix($0) }
    }

    private func startsLikeContinuationFragment(_ text: String) -> Bool {
        let starts = [
            "方面", "内容", "识别成", "后续", "这东西", "今天", "以及", "并且", "同时"
        ]
        return starts.contains { text.hasPrefix($0) }
    }

    private func needsSpaceBetween(_ previous: String, _ current: String) -> Bool {
        guard let lhs = previous.last, let rhs = current.first else { return false }
        return isASCIILetterOrNumber(lhs) && isASCIILetterOrNumber(rhs)
    }

    private func isASCIILetterOrNumber(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
              let scalar = character.unicodeScalars.first,
              scalar.isASCII else {
            return false
        }
        return CharacterSet.alphanumerics.contains(scalar)
    }

    private var participantEvidenceSummary: String {
        let participants = store.meetingTruthVisualEvidence.flatMap { evidence in
            evidence.participants.map { participant in
                "\(participant.displayText) · \(participant.confidence.title) · \(evidence.materialName)"
            }
        }
        return participants.isEmpty ? "" : participants.joined(separator: "\n")
    }

    private func bulletSummary(_ items: [String]) -> String {
        if items.isEmpty { return "暂无" }
        return items.map { "• \($0)" }.joined(separator: "\n")
    }

    private func sourceTags(for text: String) -> [MeetingTruthSourceTag] {
        var tags: [MeetingTruthSourceTag] = []
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.contains("待确认") || trimmed.contains("需补充") {
            tags.append(.pending)
        }

        if MeetingTruthUXDecisionClassifier.autoResolvedConflicts(store: store).contains(where: { textMatches(trimmed, conflict: $0) }) {
            tags.append(.autoCorrection)
        }

        if MeetingTruthUXDecisionClassifier.manuallyConfirmedConflicts(store: store).contains(where: { textMatches(trimmed, conflict: $0) }) {
            tags.append(.manualConfirmation)
        }

        if let analysis = store.meetingTruthAnalysis {
            let notes = analysis.evidenceNotes.filter { relatedEvidenceNote($0, to: trimmed) }
            if notes.contains(where: { $0.contains("材料") || $0.contains("通知") || $0.contains("文档") || $0.contains("PPT") }) {
                tags.append(.materialSupport)
            }
            if notes.contains(where: { $0.contains("图片") || $0.contains("截图") || $0.contains("手写") || $0.contains("OCR") || $0.contains("原图") }) {
                tags.append(.imageSupport)
            }
        }

        return deduplicatedTags(tags)
    }

    private func actionTags(for item: MeetingActionItem) -> [MeetingTruthSourceTag] {
        var tags = sourceTags(for: item.task)
        let owner = item.owner?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let due = item.due?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if owner.isEmpty {
            tags.append(.ownerPending)
        } else {
            tags.append(.ownerConfirmed(owner))
        }

        if due.isEmpty {
            tags.append(.duePending)
        } else {
            tags.append(.dueConfirmed(due))
        }

        if tags.contains(.manualConfirmation) {
            tags.append(.userConfirmed)
        }

        return deduplicatedTags(tags)
    }

    private func textMatches(_ text: String, conflict: MeetingTruthConflict) -> Bool {
        let selected = MeetingTruthConflictDisplay.selectedText(for: conflict)
        let candidates = conflict.candidates.map(\.text) + [conflict.recommendation, selected]
        return candidates.contains { candidate in
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty && text.localizedCaseInsensitiveContains(trimmed)
        }
    }

    private func relatedEvidenceNote(_ note: String, to text: String) -> Bool {
        let keyTerms = text
            .split { character in
                character.isWhitespace || "，。；：、,.:-[]【】()（）".contains(character)
            }
            .map(String.init)
            .filter { $0.count >= 2 }
        guard !keyTerms.isEmpty else { return false }
        return keyTerms.prefix(6).contains { note.localizedCaseInsensitiveContains($0) }
    }

    private func deduplicatedTags(_ tags: [MeetingTruthSourceTag]) -> [MeetingTruthSourceTag] {
        var seen = Set<String>()
        var result: [MeetingTruthSourceTag] = []
        for tag in tags {
            guard !seen.contains(tag.title) else { continue }
            seen.insert(tag.title)
            result.append(tag)
        }
        return result
    }

    private var pendingDecisionCount: Int {
        MeetingTruthUXDecisionClassifier.pendingTotalCount(store: store)
    }

    private var blockingDecisionCount: Int {
        MeetingTruthUXDecisionClassifier.blockingTotalCount(store: store)
    }
}

private enum MeetingTruthSourceTag: Hashable {
    case autoCorrection
    case manualConfirmation
    case materialSupport
    case imageSupport
    case pending
    case ownerPending
    case duePending
    case ownerConfirmed(String)
    case dueConfirmed(String)
    case userConfirmed

    var title: String {
        switch self {
        case .autoCorrection: "自动修正"
        case .manualConfirmation: "人工确认"
        case .materialSupport: "材料支持"
        case .imageSupport: "图片支持"
        case .pending: "待确认"
        case .ownerPending: "负责人待确认"
        case .duePending: "截止时间待确认"
        case let .ownerConfirmed(owner): "负责人：\(owner)"
        case let .dueConfirmed(due): "截止：\(due)"
        case .userConfirmed: "用户确认"
        }
    }

    var color: Color {
        switch self {
        case .autoCorrection, .materialSupport, .imageSupport:
            return .green
        case .manualConfirmation, .userConfirmed, .ownerConfirmed, .dueConfirmed:
            return .blue
        case .pending, .ownerPending, .duePending:
            return .orange
        }
    }
}

private struct MeetingTruthSourceTagRow: View {
    let tags: [MeetingTruthSourceTag]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(tags.enumerated()), id: \.offset) { _, tag in
                    Text(tag.title)
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(tag.color.opacity(0.12))
                        .foregroundStyle(tag.color)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }
}

private struct MeetingTruthPostReviewStatusPanel: View {
    @EnvironmentObject private var store: LabStore

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button {
                store.showMeetingTruthProcessingTrace(anchor: .centralReviewHandoff)
            } label: {
                Label("查看处理链路", systemImage: "point.3.connected.trianglepath.dotted")
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(color.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var blockingItems: [String] {
        store.meetingTruthCentralReviewLedger?.blockingItems ?? []
    }

    private var advisoryItems: [String] {
        store.meetingTruthCentralReviewLedger?.advisoryItems ?? []
    }

    private var title: String {
        if !blockingItems.isEmpty {
            return "成果已生成，但复检发现高风险问题，建议先处理后重新生成。"
        }
        if !advisoryItems.isEmpty {
            return "成果已生成，存在 \(advisoryItems.count) 条提示，已在结果页标记。"
        }
        return "成果已生成，复检通过。"
    }

    private var detail: String {
        if !blockingItems.isEmpty {
            return blockingItems.prefix(2).joined(separator: "；")
        }
        if !advisoryItems.isEmpty {
            return advisoryItems.prefix(2).joined(separator: "；")
        }
        return "中枢复核没有发现会阻塞成果使用的高风险问题。"
    }

    private var systemImage: String {
        blockingItems.isEmpty ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
    }

    private var color: Color {
        blockingItems.isEmpty ? .green : .orange
    }
}

private struct MeetingTruthEvidenceNotesPanel: View {
    @EnvironmentObject private var store: LabStore
    let notes: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("证据备注 / 来源说明")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("这里汇总本次会议成果中使用到的关键证据、修正依据和待确认提示。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button {
                    store.showMeetingTruthProcessingTrace(anchor: .evidenceRetrieval)
                } label: {
                    Label("查看处理链路", systemImage: "point.3.connected.trianglepath.dotted")
                }
                .controlSize(.small)
            }

            if cleanNotes.isEmpty {
                Text("暂无额外证据备注")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(cleanNotes.prefix(5).enumerated()), id: \.offset) { _, note in
                    Text("• \(note)")
                        .font(.caption)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if cleanNotes.count > 5 {
                    DisclosureGroup("查看全部证据备注") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(cleanNotes.dropFirst(5).enumerated()), id: \.offset) { _, note in
                                Text("• \(note)")
                                    .font(.caption)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.top, 6)
                    }
                    .font(.caption)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(.secondary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var cleanNotes: [String] {
        notes
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

private struct MeetingTruthTranscriptCorrectionsDisclosure: View {
    @EnvironmentObject private var store: LabStore

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(displayRows.prefix(5)) { row in
                    MeetingTruthAuditRowView(row: row)
                }
                if displayRows.isEmpty {
                    Text("暂无可展示的修正记录。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button {
                    store.showMeetingTruthProcessingTrace(anchor: .safeReplacementValidation)
                } label: {
                    Label("查看全部处理链路", systemImage: "point.3.connected.trianglepath.dotted")
                }
                .controlSize(.small)
            }
            .padding(.top, 6)
        } label: {
            Text(summaryText)
                .font(.caption.weight(.semibold))
        }
    }

    private var summaryText: String {
        "查看本次修正：应用 \(autoRows.count + manualRows.count) 处，其中 \(autoRows.count) 处来自系统自动核验，\(manualRows.count) 处来自人工确认。"
    }

    private var displayRows: [MeetingTruthAuditDisplayRow] {
        autoRows + manualRows + failedRows + lowRiskRows
    }

    private var autoRows: [MeetingTruthAuditDisplayRow] {
        MeetingTruthUXDecisionClassifier.autoResolvedConflicts(store: store).map { conflict in
            MeetingTruthAuditDisplayRow(
                title: "自动修正",
                detail: "\(candidateSummary(conflict)) -> \(resolvedText(conflict))",
                affectedOutputs: affectedOutputsText(conflict),
                systemImage: "wand.and.stars",
                color: .green,
                anchor: .safeReplacementValidation
            )
        }
    }

    private var manualRows: [MeetingTruthAuditDisplayRow] {
        MeetingTruthUXDecisionClassifier.manuallyConfirmedConflicts(store: store).map { conflict in
            MeetingTruthAuditDisplayRow(
                title: "人工确认",
                detail: "\(conflict.kind.title) 由用户确认为 \(resolvedText(conflict))",
                affectedOutputs: affectedOutputsText(conflict),
                systemImage: "person.crop.circle.badge.checkmark",
                color: .blue,
                anchor: .humanReviewTaskGeneration
            )
        }
    }

    private var failedRows: [MeetingTruthAuditDisplayRow] {
        store.meetingTruthConflicts
            .filter { $0.reviewStatus == .replacementValidationFailed || $0.replacementValidationResult?.isValid == false }
            .map { conflict in
                MeetingTruthAuditDisplayRow(
                    title: "安全替换未应用",
                    detail: "\(candidateSummary(conflict)) 未自动改写，避免误改可信逐字稿。",
                    affectedOutputs: affectedOutputsText(conflict),
                    systemImage: "exclamationmark.triangle",
                    color: .orange,
                    anchor: .safeReplacementValidation
                )
            }
    }

    private var lowRiskRows: [MeetingTruthAuditDisplayRow] {
        MeetingTruthUXDecisionClassifier.lowRiskConflicts(store: store).map { conflict in
            MeetingTruthAuditDisplayRow(
                title: "低风险忽略",
                detail: candidateSummary(conflict),
                affectedOutputs: "证据备注",
                systemImage: "minus.circle",
                color: .secondary,
                anchor: .humanReviewTaskGeneration
            )
        }
    }

    private func candidateSummary(_ conflict: MeetingTruthConflict) -> String {
        let text = conflict.candidates.map(\.text).prefix(3).joined(separator: " / ")
        return text.isEmpty ? conflict.kind.title : text
    }

    private func resolvedText(_ conflict: MeetingTruthConflict) -> String {
        let selected = MeetingTruthConflictDisplay.selectedText(for: conflict)
        return selected.isEmpty ? conflict.recommendation : selected
    }

    private func affectedOutputsText(_ conflict: MeetingTruthConflict) -> String {
        let outputs = conflict.affectedOutputs ?? [.minutes]
        return outputs.map(\.title).joined(separator: "、")
    }
}

private struct MeetingTruthPendingAndExcludedPanel: View {
    @EnvironmentObject private var store: LabStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !pendingRows.isEmpty {
                DisclosureGroup("待确认内容") {
                    auditRows(
                        rows: pendingRows,
                        emptyText: "当前没有集中列出的待确认内容。"
                    )
                }
                .font(.caption)
            }
            if !excludedRows.isEmpty {
                DisclosureGroup("未写入内容") {
                    auditRows(
                        rows: excludedRows,
                        emptyText: "当前没有未写入内容。"
                    )
                }
                .font(.caption)
            }
        }
    }

    private func auditRows(rows: [MeetingTruthAuditDisplayRow], emptyText: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(rows.first?.title == "待确认" ? "以下内容证据不足或仍需用户确认，已在结果页集中列出，并尽量在相关内容旁标注待确认。" : "以下内容因低置信、证据不足或用户选择不写入，未进入正式成果。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(rows.prefix(5)) { row in
                MeetingTruthAuditRowView(row: row)
            }
            if rows.isEmpty {
                Text(emptyText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                store.showMeetingTruthProcessingTrace(anchor: .humanReviewTaskGeneration)
            } label: {
                Label("查看处理链路", systemImage: "point.3.connected.trianglepath.dotted")
            }
            .controlSize(.small)
        }
        .padding(.top, 6)
    }

    private var pendingRows: [MeetingTruthAuditDisplayRow] {
        let factRows = store.meetingTruthPendingFactQuestions.map { question in
            MeetingTruthAuditDisplayRow(
                title: "待确认",
                detail: question.currentClaim,
                affectedOutputs: (question.affectsOutputs ?? [.minutes]).map(\.title).joined(separator: "、"),
                systemImage: "questionmark.circle",
                color: .orange,
                anchor: .humanReviewTaskGeneration
            )
        }
        let centralRows = store.meetingTruthPendingCentralReviewClaims.map { claim in
            MeetingTruthAuditDisplayRow(
                title: "中枢待确认",
                detail: claim.proposedCanonicalText,
                affectedOutputs: claim.kind.title,
                systemImage: "exclamationmark.triangle",
                color: .orange,
                anchor: .centralReviewHandoff
            )
        }
        return factRows + centralRows
    }

    private var excludedRows: [MeetingTruthAuditDisplayRow] {
        MeetingTruthUXDecisionClassifier.excludedConflicts(store: store).map { conflict in
            MeetingTruthAuditDisplayRow(
                title: "未写入内容",
                detail: conflict.candidates.map(\.text).prefix(3).joined(separator: " / "),
                affectedOutputs: conflict.affectedOutputs?.map(\.title).joined(separator: "、") ?? "正式成果",
                systemImage: "minus.circle",
                color: .secondary,
                anchor: .humanReviewTaskGeneration
            )
        }
    }
}

private struct MeetingTruthAuditDisplayRow: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    let affectedOutputs: String
    let systemImage: String
    let color: Color
    let anchor: MeetingTruthProcessingAnchorKind
}

private struct MeetingTruthAuditRowView: View {
    @EnvironmentObject private var store: LabStore
    let row: MeetingTruthAuditDisplayRow

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: row.systemImage)
                .foregroundStyle(row.color)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.caption.weight(.semibold))
                Text(row.detail.isEmpty ? "暂无明细" : row.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !row.affectedOutputs.isEmpty {
                    Text("影响：\(row.affectedOutputs)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                store.showMeetingTruthProcessingTrace(anchor: row.anchor)
            } label: {
                Image(systemName: "point.3.connected.trianglepath.dotted")
            }
            .buttonStyle(.borderless)
            .help("查看处理链路")
        }
    }
}

private struct MeetingTruthGenerationGateNotice: View {
    let pendingCount: Int
    let blockingCount: Int
    let hasDiscoveredConflicts: Bool
    let hasTrustedTranscript: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(10)
        .background(color.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var title: String {
        if !hasDiscoveredConflicts { return "请先检查转写冲突" }
        if !hasTrustedTranscript { return "还没有可信逐字稿" }
        if blockingCount > 0 { return "还有 \(blockingCount) 项高风险事项需要处理，处理后才能生成成果。" }
        if pendingCount > 0 { return "还有 \(pendingCount) 项未确认，结果页会集中列出待确认说明。" }
        return "当前无需要人工处理的高风险事项，可以生成会议成果。"
    }

    private var detail: String {
        if !hasDiscoveredConflicts { return "导入至少两份候选转写后，先运行检查。"}
        if !hasTrustedTranscript { return "系统需要先得到可用于生成的可信逐字稿。"}
        if blockingCount > 0 { return "阻塞项包括关键人名、金额/时间、责任人、项目名冲突、中枢复核阻塞和安全替换失败。"}
        if pendingCount > 0 { return "未确认内容会在结果页的待确认说明中集中列出，系统也会尽量在相关内容旁标注。"}
        return "你可以生成逐字稿、纪要、摘要、要点、思维导图和待办。"
    }

    private var systemImage: String {
        blockingCount > 0 || !hasDiscoveredConflicts || !hasTrustedTranscript ? "exclamationmark.triangle.fill" : "checkmark.seal.fill"
    }

    private var color: Color {
        blockingCount > 0 || !hasDiscoveredConflicts || !hasTrustedTranscript ? .orange : .green
    }
}

private struct MeetingTruthTrustSummaryPanel: View {
    @EnvironmentObject private var store: LabStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("可信说明 / 修正记录", systemImage: "checkmark.shield")
                    .font(.caption.weight(.semibold))
                Spacer()
                Button {
                    store.showMeetingTruthProcessingTrace(anchor: .centralReviewHandoff)
                } label: {
                    Label("查看处理链路", systemImage: "point.3.connected.trianglepath.dotted")
                }
                .controlSize(.small)
            }

            ForEach(summaryRows.prefix(5)) { row in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: row.systemImage)
                        .foregroundStyle(row.color)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title)
                            .font(.caption.weight(.semibold))
                        Text(row.detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button {
                        store.showMeetingTruthProcessingTrace(anchor: row.anchor)
                    } label: {
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                    }
                    .buttonStyle(.borderless)
                    .help("查看处理链路")
                }
            }

            if summaryRows.count > 5 {
                DisclosureGroup("查看更多说明") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(summaryRows.dropFirst(5)) { row in
                            Text("\(row.title)：\(row.detail)")
                                .font(.caption2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.top, 6)
                }
                .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.green.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var summaryRows: [MeetingTruthTrustSummaryRow] {
        var rows: [MeetingTruthTrustSummaryRow] = []

        rows += MeetingTruthUXDecisionClassifier.autoResolvedConflicts(store: store).prefix(3).map { conflict in
            MeetingTruthTrustSummaryRow(
                title: "已自动修正",
                detail: "已将 \(conflict.candidates.map(\.text).prefix(3).joined(separator: " / ")) 修正为 \(MeetingTruthConflictDisplay.selectedText(for: conflict).isEmpty ? conflict.recommendation : MeetingTruthConflictDisplay.selectedText(for: conflict))，依据是材料、图片或多路转写核验。",
                systemImage: "wand.and.stars",
                color: .green,
                anchor: .safeReplacementValidation
            )
        }

        rows += MeetingTruthUXDecisionClassifier.manuallyConfirmedConflicts(store: store).prefix(2).map { conflict in
            MeetingTruthTrustSummaryRow(
                title: "人工确认",
                detail: "\(conflict.kind.title) 已由用户确认为 \(MeetingTruthConflictDisplay.selectedText(for: conflict))，优先级高于模型和材料判断。",
                systemImage: "person.crop.circle.badge.checkmark",
                color: .blue,
                anchor: .humanReviewTaskGeneration
            )
        }

        rows += store.meetingTruthPendingFactQuestions.prefix(2).map { question in
            MeetingTruthTrustSummaryRow(
                title: "待确认标记",
                detail: "\(question.currentClaim) 仍缺少足够证据，成果中不能作为已确认事实。",
                systemImage: "questionmark.circle",
                color: .orange,
                anchor: .humanReviewTaskGeneration
            )
        }

        rows += MeetingTruthUXDecisionClassifier.excludedConflicts(store: store).prefix(2).map { conflict in
            MeetingTruthTrustSummaryRow(
                title: "未写入内容",
                detail: "\(conflict.kind.title) 已被标记为暂不处理、无关或不写入成果。",
                systemImage: "minus.circle",
                color: .secondary,
                anchor: .humanReviewTaskGeneration
            )
        }

        if rows.isEmpty {
            rows.append(
                MeetingTruthTrustSummaryRow(
                    title: "证据支持",
                    detail: "当前成果已通过转写、材料、图片证据和中枢复核生成；暂无需要单独说明的修正或人工确认。",
                    systemImage: "checkmark.seal",
                    color: .green,
                    anchor: .centralReviewHandoff
                )
            )
        }
        return rows
    }
}

private struct MeetingTruthTrustSummaryRow: Identifiable {
    var id = UUID()
    let title: String
    let detail: String
    let systemImage: String
    let color: Color
    let anchor: MeetingTruthProcessingAnchorKind
}

private struct MeetingTruthReadableErrorCard: View {
    @EnvironmentObject private var store: LabStore
    @State private var isShowingRawError = false

    var body: some View {
        if let error = store.meetingTruthError {
            Surface {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("有一步没完成", systemImage: "exclamationmark.triangle.fill")
                            .font(.headline)
                            .foregroundStyle(.red)
                        Spacer()
                        Button("关闭") {
                            store.dismissMeetingTruthError()
                        }
                    }

                    errorLine("出错位置", latestFailureStageTitle)
                    errorLine("可能原因", readableReason(for: error))
                    errorLine("你可以怎么做", readableSuggestion(for: error))

                    DisclosureGroup("原始错误详情", isExpanded: $isShowingRawError) {
                        Text(error)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 4)
                    }
                    .font(.caption)
                }
            }
        }
    }

    private var latestFailureStageTitle: String {
        guard let record = store.meetingTruthActivityLog.first(where: { $0.title == "操作失败" }) else {
            return "当前操作"
        }
        switch record.stage {
        case .importMaterials: return "添加会议资料"
        case .importTranscripts: return "添加候选转写"
        case .discoverConflicts: return "检查转写冲突"
        case .resolveConflicts: return "更新修改建议"
        case .manualConfirmation: return "确认修改"
        case .generatePackage: return "生成会议结果"
        case .multimodalEvidence: return "读取图片资料"
        case .restore: return "恢复项目"
        }
    }

    private func readableReason(for error: String) -> String {
        if error.contains("剪贴板") { return "当前剪贴板里没有可用图片，或者图片格式无法保存。" }
        if error.contains("两份") || error.contains("至少") { return "候选转写数量不够，系统无法对照差异。" }
        if error.contains("UTF-8") { return "导入的转写文件可能不是可读取的文本格式。" }
        if error.contains("冲突") { return "还没有完成转写冲突检查，或仍有内容没有确认。" }
        return "这一步没有拿到可继续处理的输入，或外部模型调用返回失败。"
    }

    private func readableSuggestion(for error: String) -> String {
        if error.contains("剪贴板") { return "先复制一张截图或图片，再点「粘贴图片」。" }
        if error.contains("两份") || error.contains("至少") { return "请导入至少两份候选转写，或从本地 ASR 历史选择同一段录音的多条结果。" }
        if error.contains("UTF-8") { return "换成 txt、md、json 或 csv 文本文件后重试。" }
        if error.contains("冲突") { return "先点「检查转写冲突」，再确认每条需要处理的内容。" }
        return "检查资料和候选转写是否完整；如果仍失败，展开原始错误详情排查。"
    }

    private func errorLine(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct MeetingTruthActivityCard: View {
    @EnvironmentObject private var store: LabStore
    @State private var isExpanded = false

    var body: some View {
        Surface {
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: 10) {
                    Divider()
                    if store.meetingTruthActivityLog.isEmpty {
                        Text("还没有操作记录。开始导入资料后，这里会自动记录每一步。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(store.meetingTruthActivityLog.prefix(8)) { record in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Label(userTitle(for: record), systemImage: icon(for: record.stage))
                                        .font(.caption.weight(.semibold))
                                    Spacer()
                                    Text(Self.dateFormatter.string(from: record.recordedAt))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Text(userMessage(for: record))
                                    .font(.caption)
                                    .fixedSize(horizontal: false, vertical: true)
                                if let details = record.details, !details.isEmpty {
                                    Text(userDetails(details))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            .padding(8)
                            .background(.secondary.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
                .padding(.top, 4)
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text("操作记录")
                                .font(.headline)
                            MeetingTruthPlainStatus(text: "\(store.meetingTruthActivityLog.count) 条", color: .secondary)
                        }
                        Text("回看导入、检查、修改、生成和失败记录。默认收起，不影响主流程。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(isExpanded ? "收起记录" : "展开记录")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func userTitle(for record: MeetingTruthActivityRecord) -> String {
        if record.title.contains("高置信") { return "已处理明显问题" }
        if record.title.contains("冲突") { return "已检查转写冲突" }
        if record.title.contains("Gemma") { return record.title.replacingOccurrences(of: "Gemma 4", with: "系统").replacingOccurrences(of: "Gemma", with: "系统") }
        return record.title
    }

    private func userMessage(for record: MeetingTruthActivityRecord) -> String {
        record.message
            .replacingOccurrences(of: "高置信建议", with: "明显问题")
            .replacingOccurrences(of: "高置信", with: "明显")
            .replacingOccurrences(of: "冲突", with: "差异")
            .replacingOccurrences(of: "Gemma 4", with: "系统")
            .replacingOccurrences(of: "Gemma", with: "系统")
    }

    private func userDetails(_ details: String) -> String {
        details
            .replacingOccurrences(of: "高置信建议", with: "明显问题")
            .replacingOccurrences(of: "高置信", with: "明显")
            .replacingOccurrences(of: "冲突", with: "差异")
            .replacingOccurrences(of: "Gemma 4", with: "系统")
            .replacingOccurrences(of: "Gemma", with: "系统")
    }

    private func icon(for stage: MeetingTruthActivityRecord.Stage) -> String {
        switch stage {
        case .importMaterials: "tray.and.arrow.down"
        case .importTranscripts: "text.badge.plus"
        case .discoverConflicts: "magnifyingglass"
        case .resolveConflicts: "sparkles"
        case .manualConfirmation: "checkmark.circle"
        case .generatePackage: "shippingbox"
        case .multimodalEvidence: "photo"
        case .restore: "arrow.counterclockwise"
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()
}

private struct MeetingTruthSectionHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct MeetingTruthSimpleList: View {
    let title: String
    let emptyText: String
    let rows: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            if rows.isEmpty {
                Text(emptyText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(rows.prefix(5).enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 7) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                        Text(row)
                            .font(.caption)
                            .lineLimit(1)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(10)
        .background(.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct MeetingTruthMaterialInventory: View {
    @EnvironmentObject private var store: LabStore
    let previewMaterial: (MeetingTruthMaterial) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("会议资料")
                .font(.subheadline.weight(.semibold))

            if store.meetingTruthMaterials.isEmpty {
                Text("还没有资料。可以导入文件，或直接粘贴截图。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.meetingTruthMaterials) { material in
                    HStack(spacing: 9) {
                        materialPreviewIcon(for: material)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(material.name)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                            Text("\(material.kind) · \(material.detail)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 8)

                        if canPreview(material) {
                            Button {
                                previewMaterial(material)
                            } label: {
                                Label("预览", systemImage: "eye")
                                    .labelStyle(.iconOnly)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help("预览这张图片")
                        }

                        Button(role: .destructive) {
                            store.removeMeetingTruthMaterial(material.id)
                        } label: {
                            Label("删除", systemImage: "trash")
                                .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("删除这份资料")
                    }
                    .padding(8)
                    .background(.background.opacity(0.45))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(10)
        .background(.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func materialPreviewIcon(for material: MeetingTruthMaterial) -> some View {
        if material.kind == "图片",
           let localPath = material.localPath,
           let image = NSImage(contentsOfFile: localPath) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 38, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(.secondary.opacity(0.18), lineWidth: 1)
                )
        } else {
            Image(systemName: icon(for: material.kind))
                .font(.body)
                .foregroundStyle(.blue)
                .frame(width: 38, height: 30)
                .background(Color.blue.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
    }

    private func canPreview(_ material: MeetingTruthMaterial) -> Bool {
        material.kind == "图片" && material.localPath != nil
    }

    private func icon(for kind: String) -> String {
        if kind == "会议录音" { return "waveform" }
        if kind == "图片" { return "photo" }
        if kind == "术语表" { return "textformat.abc" }
        return "doc.text"
    }
}

private struct MeetingTruthInfoBlock: View {
    let title: String
    let text: String
    var highlight = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text.isEmpty ? "暂无" : text)
                .font(highlight ? .body.weight(.semibold) : .caption)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(highlight ? 10 : 0)
                .background(highlight ? Color.green.opacity(0.09) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

private struct MeetingTruthSafeReplacementCard: View {
    let validation: MeetingTruthReplacementValidationResult
    let spans: [MeetingTruthReplacementSpan]
    let selectedText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MeetingTruthInfoBlock(
                title: "自动修正未应用",
                text: "系统原本想修正这处转写，但没有在原文中找到可安全替换的位置。为避免误改，本次没有修改正文。"
            )
            MeetingTruthInfoBlock(title: "状态", text: "未应用，需后续复核")
            MeetingTruthInfoBlock(title: "影响", text: "可信转写未修改")
            if !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                MeetingTruthInfoBlock(title: "已保存的确认", text: selectedText, highlight: true)
            }
            HStack(spacing: 8) {
                Label("手动确认", systemImage: "checkmark.circle")
                Label("后续复核", systemImage: "clock")
                Label("查看详情", systemImage: "chevron.down.circle")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)

            DisclosureGroup("查看详情") {
                VStack(alignment: .leading, spacing: 8) {
                    MeetingTruthInfoBlock(
                        title: "为什么没有自动修改？",
                        text: "系统需要先定位原文中的具体片段，再做替换。本次没有找到匹配位置，所以没有执行替换。"
                    )
                    MeetingTruthInfoBlock(
                        title: "安全检查结果",
                        text: userSafetySummary
                    )
                    MeetingTruthInfoBlock(
                        title: "处理方式",
                        text: "处理来源：本地安全校验\n本次由本地安全校验完成，没有单独调用 Gemma 工具函数。"
                    )

                    DisclosureGroup("开发者详情") {
                        VStack(alignment: .leading, spacing: 8) {
                            developerRow("source", "swift_local_rule")
                            developerRow("gemma_function_calling_used", "false")
                            developerRow("tool_call", "null")
                            developerRow("tool_response", "null")
                            developerRow("replacement_validation_result", validation.reason)
                            developerRow("target_span_found", validation.appliedSpanCount > 0 ? "true" : "false")
                            developerRow("applied_span_count", "\(validation.appliedSpanCount)")
                            developerRow("pollution_checks", developerPollutionChecks.joined(separator: "\n"))
                            if spans.isEmpty {
                                developerRow("span_records", "[]")
                            } else {
                                developerRow("span_records", spans.map(developerSpanText).joined(separator: "\n\n"))
                            }
                        }
                        .padding(.top, 6)
                    }
                    .font(.caption)
                }
                .padding(.top, 6)
            }
            .font(.caption)
        }
        .padding(10)
        .background(Color.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var userSafetySummary: String {
        if validation.pollutionChecks.contains(where: { $0.contains("失败") }) {
            return "发现可能的替换污染风险，例如重复缩写、粘连词或错误拼接。为避免误改，未修改正文。"
        }
        return "未发现明显替换污染风险，例如重复缩写、粘连词或错误拼接。"
    }

    private var developerPollutionChecks: [String] {
        let labels: [(pattern: String, clearText: String, dirtyText: String)] = [
            ("AASR", "未检测到 AASR 污染", "检测到 AASR 污染"),
            ("aasr", "未检测到 aasr 污染", "检测到 aasr 污染"),
            ("ASR ASR", "未检测到 ASR ASR 重复", "检测到 ASR ASR 重复"),
            ("JSONON", "未检测到 JSONON 拼接", "检测到 JSONON 拼接"),
            ("OpenClawaw", "未检测到 OpenClawaw 拼接", "检测到 OpenClawaw 拼接")
        ]
        return labels.map { item in
            let raw = validation.pollutionChecks.first { $0.localizedCaseInsensitiveContains(item.pattern) } ?? "\(item.pattern)：通过"
            return raw.contains("失败") ? item.dirtyText : item.clearText
        }
    }

    private func developerSpanText(_ span: MeetingTruthReplacementSpan) -> String {
        """
        span_id = \(span.spanID)
        window_id = \(span.windowID)
        original_text = \(span.originalText)
        replacement_text = \(span.replacementText)
        range = [\(span.rangeStart), \(span.rangeEnd)]
        pre_context = \(span.preContext)
        post_context = \(span.postContext)
        """
    }

    private func developerRow(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text.isEmpty ? "暂无" : text)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct MeetingTruthCandidateList: View {
    let title: String
    let candidates: [MeetingTruthCandidate]
    let selectedText: String
    let actionTitle: String?
    let select: ((String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if candidates.isEmpty {
                Text("暂无可选说法。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(candidates) { candidate in
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(candidate.source)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                if isSelected(candidate.text) {
                                    Label("当前写入", systemImage: "checkmark.circle.fill")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.green)
                                }
                            }
                            Text(candidate.text)
                                .font(.caption.weight(.medium))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 8)

                        if let actionTitle, let select {
                            Button {
                                select(candidate.text)
                            } label: {
                                Label(actionTitle, systemImage: "checkmark.circle")
                            }
                            .controlSize(.small)
                        }
                    }
                    .padding(8)
                    .background(isSelected(candidate.text) ? Color.green.opacity(0.1) : Color.secondary.opacity(0.07))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private func isSelected(_ text: String) -> Bool {
        !selectedText.isEmpty &&
        selectedText.trimmingCharacters(in: .whitespacesAndNewlines) == text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct MeetingTruthRecommendationChoice: View {
    let title: String
    let text: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(text)
                    .font(.caption.weight(.medium))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(action: action) {
                Label(actionTitle, systemImage: "sparkles")
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(Color.blue.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct MeetingTruthPlainStatus: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.14))
            .foregroundStyle(color)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private enum MeetingTruthProcessingSource {
    static func evidence(_ sourceType: MeetingTruthEvidenceSupport.SourceType) -> String {
        switch sourceType {
        case .asr:
            return "工具函数核验 / 转写候选对齐"
        case .imageOCR:
            return "图片文字识别"
        case .rawVision:
            return "原图理解"
        case .material:
            return "工具函数核验 / 会议材料检索"
        case .glossary:
            return "工具函数核验 / 术语表检索"
        case .context:
            return "工具函数核验 / 上下文窗口"
        case .human:
            return "人工确认"
        case .meetingNotice:
            return "工具函数核验 / 会议通知证据"
        case .handwrittenNote:
            return "图片文字识别或原图理解 / 手写纪要证据"
        case .slideOrPPT:
            return "工具函数核验 / PPT 或正式材料证据"
        case .whiteboard:
            return "原图理解 / 白板板书理解"
        case .screenshot:
            return "图片文字识别或原图理解 / 系统截图证据"
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

    static func centralEvidence(_ channel: MeetingTruthCentralEvidenceChannel) -> String {
        switch channel {
        case .asr:
            return "工具函数核验 / 转写候选"
        case .imageOCR:
            return "图片文字识别"
        case .rawVision:
            return "原图理解"
        case .material:
            return "工具函数核验 / 文本或 PDF 材料"
        case .conflict:
            return "工具函数核验 / 转写冲突复核"
        case .human:
            return "人工确认"
        case .generatedPackage:
            return "Gemma 语义判断 / 成果包草稿"
        }
    }
}

private enum MeetingTruthRecommendationText {
    static func isConcrete(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let reminderPhrases = [
            "需要确认",
            "需要核实",
            "确认正确",
            "待确认",
            "应采信",
            "应采用",
            "应该采信",
            "应该采用",
            "是否",
            "请",
            "请核实"
        ]
        if reminderPhrases.contains(where: { trimmed.contains($0) }) {
            return false
        }

        if trimmed.contains("还是") {
            return false
        }

        if trimmed.contains("参考"), trimmed.contains("材料") || trimmed.contains("依据") {
            return false
        }

        if trimmed.contains("名单"), trimmed.contains("列出") || trimmed.contains("材料") {
            return false
        }

        let instructionMarks = ["。", "；", "？", "?", "：", ":"]
        if trimmed.count > 55 && instructionMarks.contains(where: { trimmed.contains($0) }) {
            return false
        }

        return true
    }
}

@MainActor
private enum MeetingTruthUXDecisionClassifier {
    static func pendingTotalCount(store: LabStore) -> Int {
        pendingConflicts(store: store).count +
        store.meetingTruthPendingFactQuestions.count +
        store.meetingTruthPendingCentralReviewClaims.count
    }

    static func blockingTotalCount(store: LabStore) -> Int {
        pendingConflicts(store: store).filter(isBlockingConflict).count +
        excludedConflicts(store: store).filter(isBlockingConflict).count +
        store.meetingTruthPendingFactQuestions.count +
        store.meetingTruthPendingCentralReviewClaims.count
    }

    static func pendingConflicts(store: LabStore) -> [MeetingTruthConflict] {
        store.meetingTruthConflicts
            .filter { conflict in
                isMainPendingConflict(
                    conflict,
                    confirmation: store.latestMeetingTruthConfirmation(for: conflict.id)
                )
            }
            .sorted(by: MeetingTruthConflictDisplay.sortForMainList)
    }

    static func autoResolvedConflicts(store: LabStore) -> [MeetingTruthConflict] {
        store.meetingTruthConflicts
            .filter { conflict in
                guard !isMainPendingConflict(conflict, confirmation: store.latestMeetingTruthConfirmation(for: conflict.id)) else {
                    return false
                }
                if conflict.reviewStatus == .suggestedApplied { return true }
                if let confirmation = store.latestMeetingTruthConfirmation(for: conflict.id) {
                    return confirmation.decision == .acceptedRecommendation || confirmation.decision == .selectedCandidate
                }
                return false
            }
            .sorted(by: MeetingTruthConflictDisplay.sortForMainList)
    }

    static func manuallyConfirmedConflicts(store: LabStore) -> [MeetingTruthConflict] {
        store.meetingTruthConflicts
            .filter { conflict in
                guard let confirmation = store.latestMeetingTruthConfirmation(for: conflict.id) else { return false }
                return confirmation.decision == .manualEdit || confirmation.decision == .selectedCandidate
            }
            .sorted(by: MeetingTruthConflictDisplay.sortForMainList)
    }

    static func excludedConflicts(store: LabStore) -> [MeetingTruthConflict] {
        store.meetingTruthConflicts
            .filter { conflict in
                conflict.reviewStatus == .deferredForCentralReview ||
                conflict.reviewStatus == .markedIrrelevant ||
                (store.latestMeetingTruthConfirmation(for: conflict.id)?.decision == .ignoredSuggestion && conflict.reviewStatus != .ignoredLowRisk)
            }
            .sorted(by: MeetingTruthConflictDisplay.sortForMainList)
    }

    static func lowRiskConflicts(store: LabStore) -> [MeetingTruthConflict] {
        store.meetingTruthConflicts
            .filter { $0.reviewStatus == .ignoredLowRisk || $0.kind == .ordinaryExpression && $0.confidence != .low }
            .sorted(by: MeetingTruthConflictDisplay.sortForMainList)
    }

    private static func isMainPendingConflict(_ conflict: MeetingTruthConflict, confirmation: MeetingTruthManualConfirmation?) -> Bool {
        guard conflict.kind != .ordinaryExpression else { return false }
        guard MeetingTruthConflictDisplay.needsUserDecision(conflict, confirmation: confirmation) else {
            return false
        }

        if conflict.reviewStatus == .needsHumanReview ||
            conflict.reviewStatus == .evidenceConflicted ||
            conflict.reviewStatus == .replacementValidationFailed {
            return true
        }

        if let validation = conflict.replacementValidationResult,
           !validation.isValid,
           affectsCoreTranscript(conflict) {
            return true
        }

        return isHighRiskInsufficientEvidence(conflict)
    }

    private static func isHighRiskInsufficientEvidence(_ conflict: MeetingTruthConflict) -> Bool {
        guard conflict.confidence == .low else { return false }
        switch conflict.kind {
        case .person, .amount, .date, .project, .system, .terminology, .actionItem, .decision:
            return true
        case .ordinaryExpression:
            return false
        }
    }

    private static func isBlockingConflict(_ conflict: MeetingTruthConflict) -> Bool {
        if conflict.reviewStatus == .replacementValidationFailed { return true }
        if let validation = conflict.replacementValidationResult, !validation.isValid, affectsCoreTranscript(conflict) {
            return true
        }
        switch conflict.kind {
        case .person, .amount, .date, .project, .system, .actionItem:
            return true
        case .terminology, .decision:
            return conflict.confidence == .low || conflict.reviewStatus == .evidenceConflicted
        case .ordinaryExpression:
            return false
        }
    }

    private static func affectsCoreTranscript(_ conflict: MeetingTruthConflict) -> Bool {
        let outputs = conflict.affectedOutputs ?? [.minutes]
        return outputs.contains(.minutes) ||
            outputs.contains(.actionItems) ||
            outputs.contains(.participants) ||
            outputs.contains(.projectNames)
    }
}

private enum MeetingTruthConflictDisplay {
    static func pendingDecisionCount(in conflicts: [MeetingTruthConflict]) -> Int {
        conflicts.filter { needsUserDecision($0, confirmation: nil) }.count
    }

    static func needsUserDecision(
        _ conflict: MeetingTruthConflict,
        confirmation: MeetingTruthManualConfirmation? = nil
    ) -> Bool {
        switch conflict.reviewStatus {
        case .ignoredLowRisk, .markedIrrelevant, .deferredForCentralReview, .suggestedApplied:
            return false
        case .replacementValidationFailed, .evidenceConflicted, .needsHumanReview:
            return true
        case .pending, .none:
            break
        }
        if !conflict.isResolved { return true }
        let selected = selectedText(for: conflict)
        guard !selected.isEmpty else { return true }

        if let confirmation,
           sameText(confirmation.selectedText ?? "", selected) {
            switch confirmation.decision {
            case .manualEdit, .selectedCandidate:
                return false
            case .acceptedRecommendation:
                return !MeetingTruthRecommendationText.isConcrete(conflict.recommendation)
            case .ignoredSuggestion:
                return false
            case .clearedSelection:
                return true
            }
        }

        if conflict.candidates.contains(where: { sameText($0.text, selected) }) {
            return false
        }

        if sameText(selected, conflict.recommendation),
           !MeetingTruthRecommendationText.isConcrete(conflict.recommendation) {
            return true
        }

        return !MeetingTruthRecommendationText.isConcrete(selected)
    }

    static func selectedText(for conflict: MeetingTruthConflict) -> String {
        (conflict.selectedText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func sameTextForUI(_ lhs: String, _ rhs: String) -> Bool {
        sameText(lhs, rhs)
    }

    static func sortForMainList(_ lhs: MeetingTruthConflict, _ rhs: MeetingTruthConflict) -> Bool {
        priority(lhs) < priority(rhs)
    }

    private static func priority(_ conflict: MeetingTruthConflict) -> Int {
        switch conflict.reviewStatus {
        case .needsHumanReview: return 0
        case .evidenceConflicted: return 1
        case .replacementValidationFailed: return 2
        case .suggestedApplied: return 5
        case .ignoredLowRisk: return 6
        case .markedIrrelevant: return 7
        case .deferredForCentralReview: return 3
        case .pending, .none:
            break
        }
        switch conflict.kind {
        case .terminology, .person, .amount, .date, .project, .system, .actionItem, .decision:
            return 4
        case .ordinaryExpression:
            return 6
        }
    }

    private static func sameText(_ lhs: String, _ rhs: String) -> Bool {
        lhs.trimmingCharacters(in: .whitespacesAndNewlines) == rhs.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
