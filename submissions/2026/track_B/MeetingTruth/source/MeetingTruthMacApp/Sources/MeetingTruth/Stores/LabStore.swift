import AVFoundation
import AppKit
import Foundation
import PDFKit
import Vision

@MainActor
final class LabStore: ObservableObject {
    private static let defaultASRModelIDs: Set<String> = [
        "qwen3-asr-1.7b-timestamps",
        "glm-asr-nano-2512",
        "mimo-v2-5-asr-mlx"
    ]
    private static let defaultSelectedASRModelIDs: Set<String> = [
        "qwen3-asr-1.7b-timestamps"
    ]
    private static let primaryDefaultASRModelID = "qwen3-asr-1.7b-timestamps"
    private static let cleanASRModelOrder = [
        "qwen3-asr-1.7b-timestamps",
        "glm-asr-nano-2512",
        "mimo-v2-5-asr-mlx"
    ]
    private static let cleanUnsupportedRuntimeMessage = "当前 clean 版未包含该 ASR runtime。请使用三路推荐 ASR，或导入候选转写体验 MeetingTruth。"
    private let hfEngine = HuggingFaceASRAdapter()
    private let meetingAIService = MeetingAIService()
    private let meetingTruthArbitrationEngine = MeetingTruthArbitrationEngine()
    private let meetingTruthFactReviewEngine = MeetingTruthFactReviewEngine()
    private let meetingTruthCentralReviewEngine = MeetingTruthCentralReviewEngine()
    private var currentComparisonTask: Task<Void, Never>?
    private var currentModelPreparationTask: Task<Void, Never>?
    private var currentMeetingAnalysisTask: Task<Void, Never>?
    private var currentHistoryLoadTask: Task<Void, Never>?
    private var currentMeetingTruthTask: Task<Void, Never>?
    private var currentMeetingTruthTaskGeneration = 0
    private var meetingTruthProjectID = UUID()
    private var meetingTruthProjectCreatedAt = Date()
    private var meetingTruthManualConfirmations: [MeetingTruthManualConfirmation] = []
    private var meetingTruthLastFailure: MeetingTruthFailureRecord?

    private static func cleanASRModelSortIndex(_ id: String) -> Int {
        cleanASRModelOrder.firstIndex(of: id) ?? cleanASRModelOrder.count
    }

    @Published var selectedSection: LabSection = .meetingTruth
    @Published var meetingTruthProcessingTraceFocus: MeetingTruthProcessingAnchorKind = .importMaterials
    @Published var selectedModelID: String = LabStore.primaryDefaultASRModelID
    @Published var selectedModelIDs: Set<String> = LabStore.defaultSelectedASRModelIDs
    @Published var selectedAudioPath: String = ""
    @Published var runs: [ComparisonRun] = []
    @Published var runHistory: [RunHistoryEntry] = []
    @Published var selectedHistoryID: UUID?
    @Published var isLoadingHistory = false
    @Published var hotwordSets: [HotwordSet] = [
        HotwordSet(
            id: UUID(),
            name: "会议高频词",
            words: ["ASR", "本地离线", "会议纪要", "苹果芯片", "模型下载"],
            weight: 1.4,
            isEnabled: false
        ),
        HotwordSet(
            id: UUID(),
            name: "行业术语",
            words: ["风控", "授信", "贷后", "尽调"],
            weight: 1.2,
            isEnabled: false
        )
    ]

    @Published private(set) var models: [ASRModelSpec] = ModelRegistry.initialModels
    @Published var activeTaskTitle = "等待音频和模型选择"
    @Published var activeTaskProgress = 0.0
    @Published var isRunning = false
    @Published var lastError: String?
    @Published var modelPreparationFailures: [String: ModelPreparationFailure] = [:]
    @Published var liveTranscript = ""
    @Published var currentStage = "空闲"
    @Published var elapsedTimeLabel = "--"
    @Published var remainingTimeLabel = "--"
    @Published var preferAccuracy = true
    @Published var useVAD = true
    @Published var runDiarization = false
    @Published var useTerminologyPostProcessing = true
    @Published var compareTerminologyPostProcessing = false
    @Published var longAudioCacheEnabled = true
    @Published var longAudioChunkSeconds = 120
    @Published var compareMiMoAccelerators = false
    @Published var modelCachePath = MeetingTruthConfig.defaultModelCachePath {
        didSet { saveAppSettings() }
    }
    @Published var externalModelConfigurations: [String: ExternalModelConfiguration] = [:]
    @Published var meetingAISettings = MeetingAISettings() {
        didSet { saveMeetingAISettings() }
    }
    @Published var isGeneratingMeetingAnalysis = false
    @Published var isValidatingMeetingAI = false
    @Published var meetingAnalysisStatus = "等待生成会议整理"
    @Published var meetingTruthMaterials: [MeetingTruthMaterial] = []
    @Published var meetingTruthTranscriptSources: [MeetingTruthTranscriptSource] = []
    @Published var meetingTruthConflicts: [MeetingTruthConflict] = []
    @Published var isResolvingMeetingTruthConflicts = false
    @Published var isDiscoveringMeetingTruthConflicts = false
    @Published var isGeneratingMeetingTruthPackage = false
    @Published var isExtractingMeetingTruthVisualEvidence = false
    @Published var isReviewingMeetingTruthCentrally = false
    @Published var isRunningMeetingTruthToolAB = false
    @Published var hasDiscoveredMeetingTruthConflicts = false
    @Published var meetingTruthMultimodalMode: MeetingTruthMultimodalMode = .fusedMultimodal
    @Published var meetingTruthArbitrationConfig = MeetingTruthArbitrationConfig()
    @Published private(set) var meetingTruthVisualEvidence: [MeetingTruthVisualEvidence] = []
    @Published private(set) var meetingTruthMultimodalComparisons: [MeetingTruthMultimodalComparison] = []
    @Published private(set) var meetingTruthFactCandidates: [MeetingTruthFactCandidate] = []
    @Published private(set) var meetingTruthEvidenceAtoms: [MeetingTruthEvidenceAtom] = []
    @Published private(set) var meetingTruthFactDecisions: [MeetingTruthFactDecision] = []
    @Published private(set) var meetingTruthUserQuestions: [MeetingTruthUserQuestion] = []
    @Published private(set) var meetingTruthCentralReviewLedger: MeetingTruthCentralReviewLedger?
    @Published private(set) var meetingTruthToolCallingABResult: MeetingTruthToolCallingABResult?
    @Published var meetingTruthValidationStatus = "请先导入真实会议资料和至少两份候选转写"
    @Published var meetingTruthAnalysis: MeetingAnalysis?
    @Published var meetingTruthError: String?
    @Published private(set) var meetingTruthActivityLog: [MeetingTruthActivityRecord] = []
    @Published private(set) var meetingTruthHistory: [MeetingTruthHistoryEntry] = []

    init() {
        RuntimePaths.prepareBundledWorkspace()
        loadAppSettings()
        loadMeetingAISettings()
        loadExternalModelConfigurations()
        loadRunHistory()
        loadMeetingTruthProjects()
        applyExternalModelConfigurations()
        refreshLocalModelCache()
        configureDefaultTestRun()
        refreshMeetingTruthMultimodalComparisons()
    }

    var selectedModel: ASRModelSpec? {
        models.first { $0.id == selectedModelID }
    }

    var runnableModels: [ASRModelSpec] {
        models.filter(isRunnableModel)
    }

    var activeLibraryModels: [ASRModelSpec] {
        cleanASRModels
    }

    var cleanASRModels: [ASRModelSpec] {
        Self.defaultASRModelIDs
            .sorted { lhs, rhs in
                Self.cleanASRModelSortIndex(lhs) < Self.cleanASRModelSortIndex(rhs)
            }
            .compactMap { id in models.first { $0.id == id } }
    }

    var experimentModels: [ASRModelSpec] {
        cleanASRModels
    }

    var completedRuns: [ComparisonRun] {
        runs.filter {
            !$0.cleanTranscriptPreview.isEmpty &&
            $0.reviewerVerdict != .missed &&
            $0.passesAutomaticQualityCheck
        }
    }

    var meetingTruthHistoricalASRResults: [MeetingTruthHistoricalASRResult] {
        runHistory.flatMap { entry in
            entry.runs.compactMap { run in
                let text = run.cleanTranscriptPreview
                guard !text.isEmpty else { return nil }
                return MeetingTruthHistoricalASRResult(
                    historyID: entry.id,
                    runID: run.id,
                    createdAt: entry.createdAt,
                    audioPath: entry.audioPath,
                    modelName: run.modelName,
                    status: run.status,
                    text: text
                )
            }
        }
    }

    var primaryTranscriptRun: ComparisonRun? {
        completedRuns.first { $0.reviewerVerdict == .best }
            ?? completedRuns.first { $0.reviewerVerdict == .sameGood }
            ?? completedRuns.first
    }

    var reviewSummary: String {
        guard !runs.isEmpty else {
            return "还没有可评分的转写结果。"
        }

        let completed = runs.filter { !$0.cleanTranscriptPreview.isEmpty }
        let missed = runs.filter { $0.reviewerVerdict == .missed || $0.status == "无文本" || $0.status == "失败" }
        let best = runs.filter { $0.reviewerVerdict == .best }
        let sameGood = runs.filter { $0.reviewerVerdict == .sameGood }
        let autoGroups = Dictionary(grouping: completed.compactMap(\.equivalenceGroup), by: { $0 })
            .filter { $0.value.count > 1 }

        if completed.isEmpty {
            return "这次所有模型都没有输出可比较的文本。"
        }
        if !best.isEmpty {
            return "你标记的最佳结果：\(best.map(\.modelName).joined(separator: "、"))。"
        }
        if !sameGood.isEmpty {
            return "你标记为识别效果一样好的模型：\(sameGood.map(\.modelName).joined(separator: "、"))。"
        }
        if !autoGroups.isEmpty {
            return "系统检测到 \(autoGroups.count) 组文本几乎一致的结果，可直接标记为“一样好”。"
        }
        if missed.count == runs.count {
            return "这次所有模型都没有识别出有效文本。"
        }
        return "请根据你说的原话主观标记最好、一样好或没识别出；耗时已经自动记录。"
    }

    var enabledHotwords: [String] {
        hotwordSets
            .filter(\.isEnabled)
            .flatMap(\.words)
    }

    var resolvedModelCacheURL: URL {
        let expanded = NSString(string: modelCachePath).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }

    var modelStorage: ModelStorage {
        ModelStorage(root: resolvedModelCacheURL)
    }

    var sharedModelCacheURL: URL {
        modelStorage.sharedAssetDirectory(repoID: "cstr/mimo-tokenizer-GGUF")
    }

    var meetingTruthResolvedCount: Int {
        meetingTruthConflicts.filter(\.isResolved).count
    }

    var meetingTruthReviewCount: Int {
        meetingTruthConflicts.filter { $0.requiresHumanReview && !$0.isResolved }.count
    }

    var meetingTruthUnresolvedCount: Int {
        meetingTruthConflicts.filter { !$0.isResolved }.count
    }

    var meetingTruthPendingFactQuestions: [MeetingTruthUserQuestion] {
        meetingTruthUserQuestions.filter { question in
            guard !Self.isSystemMeetingTruthFactText(question.currentClaim),
                  !Self.isSystemMeetingTruthFactText(question.question) else {
                return false
            }
            return meetingTruthFactDecisions.contains {
                $0.factID == question.factID && $0.requiresUserInput
            }
        }
    }

    var meetingTruthCentralReviewBlockingItems: [String] {
        meetingTruthCentralReviewLedger.map { reconciledMeetingTruthCentralReviewLedger($0).blockingItems } ?? []
    }

    var meetingTruthPendingCentralReviewClaims: [MeetingTruthCentralClaim] {
        meetingTruthCentralReviewLedger.map { reconciledMeetingTruthCentralReviewLedger($0).claims.filter(\.requiresHumanReview) } ?? []
    }

    var isMeetingTruthTaskRunning: Bool {
        isResolvingMeetingTruthConflicts ||
            isDiscoveringMeetingTruthConflicts ||
            isGeneratingMeetingTruthPackage ||
            isExtractingMeetingTruthVisualEvidence ||
            isReviewingMeetingTruthCentrally ||
            isRunningMeetingTruthToolAB
    }

    var canRunMeetingTruthCentralReview: Bool {
        !isMeetingTruthTaskRunning &&
            (!meetingTruthTranscriptSources.isEmpty || !meetingTruthMaterials.isEmpty)
    }

    func cancelMeetingTruthTask() {
        currentMeetingTruthTaskGeneration += 1
        currentMeetingTruthTask?.cancel()
        currentMeetingTruthTask = nil
        isResolvingMeetingTruthConflicts = false
        isDiscoveringMeetingTruthConflicts = false
        isGeneratingMeetingTruthPackage = false
        isExtractingMeetingTruthVisualEvidence = false
        isReviewingMeetingTruthCentrally = false
        isRunningMeetingTruthToolAB = false
        meetingTruthValidationStatus = "已停止当前 MeetingTruth 任务"
        meetingTruthError = nil
        lastError = nil
        recordMeetingTruthActivity(
            stage: .resolveConflicts,
            title: "已停止当前任务",
            message: "用户手动停止了正在运行的检查、复核或生成任务。"
        )
    }

    func latestMeetingTruthConfirmation(for conflictID: UUID) -> MeetingTruthManualConfirmation? {
        meetingTruthManualConfirmations.first { $0.conflictID == conflictID }
    }

    var meetingTruthProgress: Double {
        guard !meetingTruthConflicts.isEmpty else { return 0 }
        return Double(meetingTruthResolvedCount) / Double(meetingTruthConflicts.count)
    }

    var meetingTruthOverallProgress: Double {
        if meetingTruthAnalysis != nil { return 1 }
        if !meetingTruthConflicts.isEmpty, meetingTruthUnresolvedCount == 0 { return 0.75 }
        if hasDiscoveredMeetingTruthConflicts { return 0.5 }
        if meetingTruthTranscriptSources.count >= 2 { return 0.25 }
        return 0
    }

    var hasMeetingTruthInput: Bool {
        !meetingTruthMaterials.isEmpty || !meetingTruthTranscriptSources.isEmpty
    }

    var meetingTruthContextMaterials: [MeetingTruthMaterial] {
        meetingTruthContextMaterials(for: meetingTruthMultimodalMode)
    }

    var meetingTruthImageMaterials: [MeetingTruthMaterial] {
        meetingTruthMaterials.filter { $0.kind == "图片" && $0.localPath != nil }
    }

    var meetingTruthMultimodalModeSummary: String {
        meetingTruthMultimodalMode.shortDescription
    }

    var meetingTruthASRIterationTerms: [String] {
        Self.uniqueTerms(
            meetingTruthVisualEvidence
                .filter(\.useForASRIteration)
                .flatMap(\.iterationTerms)
        )
    }

    var meetingTruthMultimodalImpactRows: [MeetingTruthMultimodalImpactRow] {
        buildMeetingTruthMultimodalImpactRows()
    }

    var meetingTruthMultimodalImpactFindings: [MeetingTruthMultimodalImpactFinding] {
        buildMeetingTruthMultimodalImpactFindings()
    }

    var meetingTruthDecisionOverview: MeetingTruthDecisionOverview {
        buildMeetingTruthDecisionOverview()
    }

    var meetingTruthMultimodalSubjectComparisons: [MeetingTruthMultimodalSubjectComparison] {
        buildMeetingTruthMultimodalSubjectComparisons()
    }

    var meetingTruthOCRValueComparisons: [MeetingTruthOCRValueComparison] {
        buildMeetingTruthOCRValueComparisons()
    }

    var meetingTruthCorrectionLedger: [MeetingTruthCorrectionLedgerRow] {
        buildMeetingTruthCorrectionLedger()
    }

    var meetingTruthMultimodalCallStatus: MeetingTruthMultimodalCallStatus {
        buildMeetingTruthMultimodalCallStatus()
    }

    var meetingTruthMultimodalProof: MeetingTruthMultimodalProof {
        buildMeetingTruthMultimodalProof()
    }

    var meetingTruthInputRoutes: [MeetingTruthInputRoute] {
        buildMeetingTruthInputRoutes()
    }

    var meetingTruthEvidenceChannelStatuses: [MeetingTruthEvidenceChannelStatus] {
        buildMeetingTruthEvidenceChannelStatuses()
    }

    var meetingTruthConclusionEvidence: [MeetingTruthConclusionEvidence] {
        buildMeetingTruthConclusionEvidence()
    }

    var meetingTruthArbitrationWorkflowNodes: [MeetingTruthArbitrationWorkflowNode] {
        meetingTruthArbitrationEngine.workflowNodes(
            transcriptSources: meetingTruthTranscriptSources,
            imageMaterials: meetingTruthImageMaterials,
            visualEvidence: meetingTruthVisualEvidence,
            conflicts: meetingTruthConflicts,
            factCandidates: meetingTruthFactCandidates,
            factDecisions: meetingTruthFactDecisions,
            userQuestions: meetingTruthUserQuestions,
            conclusionEvidence: meetingTruthConclusionEvidence
        )
    }

    var meetingTruthArbitrationDecisions: [MeetingTruthArbitrationDecision] {
        meetingTruthArbitrationEngine.decisions(
            conflicts: meetingTruthConflicts,
            transcriptSources: meetingTruthTranscriptSources,
            imageMaterials: meetingTruthImageMaterials,
            visualEvidence: meetingTruthVisualEvidence,
            materials: meetingTruthMaterials,
            confirmations: meetingTruthManualConfirmations,
            factCandidates: meetingTruthFactCandidates,
            evidenceAtoms: meetingTruthEvidenceAtoms,
            factDecisions: meetingTruthFactDecisions,
            config: meetingTruthArbitrationConfig
        )
    }

    private func meetingTruthContextMaterials(for mode: MeetingTruthMultimodalMode) -> [MeetingTruthMaterial] {
        var materials: [MeetingTruthMaterial]
        switch mode {
        case .textOnly, .audioTextSeparate:
            materials = meetingTruthMaterials.filter { $0.kind != "图片" }
        case .visionSeparate:
            materials = meetingTruthMaterials.filter { $0.kind != "图片" }
            if let evidenceMaterial = meetingTruthVisualEvidenceMaterial() {
                materials.append(evidenceMaterial)
            }
        case .fusedMultimodal:
            materials = meetingTruthMaterials
            if let evidenceMaterial = meetingTruthVisualEvidenceMaterial() {
                materials.append(evidenceMaterial)
            }
        }

        guard !enabledHotwords.isEmpty else { return materials }
        return materials + [
            MeetingTruthMaterial(
                name: "已启用关键词与术语",
                kind: "术语表",
                detail: "\(enabledHotwords.count) 个关键词 · 来自热词库",
                extractedText: enabledHotwords.joined(separator: "\n")
            )
        ]
    }

    private func meetingTruthVisualEvidenceMaterial() -> MeetingTruthMaterial? {
        let sections = meetingTruthVisualEvidence.map { evidence in
            """
            【\(evidence.materialName)】
            摘要：\(evidence.summary)
            数字/编号：\(evidence.extractedNumbers.isEmpty ? "无" : evidence.extractedNumbers.joined(separator: "、"))
            关键词：\(evidence.keywords.isEmpty ? "无" : evidence.keywords.joined(separator: "、"))
            参会人员/人名：\(evidence.participants.isEmpty ? "无" : evidence.participants.map(\.displayText).joined(separator: "、"))
            疑似待办：\(evidence.actionHints.isEmpty ? "无" : evidence.actionHints.joined(separator: "、"))
            版式结构：\(evidence.layoutCues.isEmpty ? "无" : evidence.layoutCues.joined(separator: "、"))
            圈注/箭头/提示框：\(evidence.visualMarks.isEmpty ? "无" : evidence.visualMarks.joined(separator: "、"))
            OCR 对比：\(evidence.ocrContrast.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "无" : evidence.ocrContrast)
            置信度：\(evidence.confidence.title)
            原图证据应用：\(evidence.useForASRIteration ? "已确认可用于热词/重跑或人工校验" : "仅作为原图证据候选，不直接改写 ASR")
            原图证据词：\(evidence.iterationTerms.isEmpty ? "无" : evidence.iterationTerms.joined(separator: "、"))
            """
        }
        guard !sections.isEmpty else { return nil }
        return MeetingTruthMaterial(
            name: "Gemma 4 图片视觉证据摘要",
            kind: "Gemma 4 图片证据",
            detail: "\(meetingTruthVisualEvidence.count) 张图片 · Gemma 4 读图结果",
            extractedText: sections.joined(separator: "\n\n")
        )
    }

    @discardableResult
    private func refreshMeetingTruthParticipantEvidenceConflicts() -> Int {
        let evidenceConflicts = participantEvidenceConflicts()
        guard !evidenceConflicts.isEmpty else { return 0 }

        var added = 0
        for conflict in evidenceConflicts where !hasEquivalentParticipantConflict(conflict) {
            meetingTruthConflicts.append(conflict)
            added += 1
        }
        return added
    }

    private func participantEvidenceConflicts() -> [MeetingTruthConflict] {
        guard let primarySource = meetingTruthPrimaryTranscriptSource else { return [] }
        let primaryText = primarySource.text
        guard !primaryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }

        var conflicts: [MeetingTruthConflict] = []
        let participants = meetingTruthVisualEvidence.flatMap { evidence in
            evidence.participants.map { participant in
                (evidence: evidence, participant: participant)
            }
        }

        for item in participants {
            let name = item.participant.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.count >= 2 else { continue }

            let primaryVariants = suspectedPersonNameVariants(for: name, in: primaryText)
            guard !primaryVariants.isEmpty else { continue }

            var candidates: [MeetingTruthCandidate] = []
            for variant in primaryVariants.prefix(3) {
                candidates.append(MeetingTruthCandidate(source: "\(primarySource.name) · 主底稿疑似写法", text: variant))
            }

            candidates.append(MeetingTruthCandidate(source: "图片证据 · \(item.evidence.materialName)", text: name))

            for source in meetingTruthTranscriptSources where source.id != primarySource.id {
                if Self.text(source.text, contains: name) {
                    candidates.append(MeetingTruthCandidate(source: "\(source.name) · 候选转写", text: name))
                }
                for variant in suspectedPersonNameVariants(for: name, in: source.text).prefix(2) {
                    candidates.append(MeetingTruthCandidate(source: "\(source.name) · 疑似异写", text: variant))
                }
            }

            candidates = deduplicatedCandidates(candidates)
            guard let original = candidates.first?.text,
                  !sameText(original, name) else {
                continue
            }

            let displayName = item.participant.displayText
            let evidenceLine = [
                "图片 \(item.evidence.materialName) 识别到参会人员：\(displayName)",
                item.participant.evidence.isEmpty ? nil : "图片依据：\(item.participant.evidence)",
                "主底稿疑似写作：\(primaryVariants.prefix(3).joined(separator: "、"))"
            ]
            .compactMap { $0 }
            .joined(separator: "；")

            conflicts.append(
                MeetingTruthConflict(
                    timestamp: "图片证据",
                    kind: .person,
                    context: "图片材料识别到参会人员「\(name)」，但主底稿中可能写成「\(primaryVariants.prefix(3).joined(separator: "、"))」。请确认最终写入逐字稿的人名。",
                    candidates: candidates,
                    recommendation: name,
                    confidence: item.participant.confidence == .high ? .medium : .low,
                    evidence: evidenceLine
                )
            )
        }

        return deduplicatedParticipantConflicts(conflicts)
    }

    private func hasEquivalentParticipantConflict(_ newConflict: MeetingTruthConflict) -> Bool {
        meetingTruthConflicts.contains { existing in
            guard existing.kind == .person else { return false }
            if sameText(existing.recommendation, newConflict.recommendation) {
                return true
            }
            let existingTexts = Set(existing.candidates.map { normalizedComparableText($0.text) })
            let newTexts = Set(newConflict.candidates.map { normalizedComparableText($0.text) })
            return !existingTexts.intersection(newTexts).isEmpty &&
                existingTexts.contains(normalizedComparableText(newConflict.recommendation))
        }
    }

    private func deduplicatedParticipantConflicts(_ conflicts: [MeetingTruthConflict]) -> [MeetingTruthConflict] {
        var result: [MeetingTruthConflict] = []
        for conflict in conflicts {
            let key = normalizedComparableText(conflict.recommendation)
            guard !key.isEmpty else { continue }
            if result.contains(where: { normalizedComparableText($0.recommendation) == key }) {
                continue
            }
            result.append(conflict)
        }
        return result
    }

    private func deduplicatedCandidates(_ candidates: [MeetingTruthCandidate]) -> [MeetingTruthCandidate] {
        var seen: Set<String> = []
        var result: [MeetingTruthCandidate] = []
        for candidate in candidates {
            let key = normalizedComparableText(candidate.text)
            guard !key.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(candidate)
        }
        return result
    }

    var meetingTruthTrustedTranscript: String {
        let transcript = meetingTruthResolvedTranscriptBody
        let context = confirmedMeetingTruthContextText(missingFrom: transcript)
        guard !context.isEmpty else { return transcript }
        guard !transcript.isEmpty else { return context }
        return "\(context)\n\n\(transcript)"
    }

    var meetingTruthConfirmedContextText: String {
        confirmedMeetingTruthContextText(missingFrom: meetingTruthResolvedTranscriptBody)
    }

    private var meetingTruthResolvedTranscriptBody: String {
        guard let primarySource = meetingTruthPrimaryTranscriptSource else {
            let fallback = meetingTruthConflicts.map { conflict in
                let resolved = conflict.selectedText.map(writableConfirmationText) ?? "[待确认：\(conflict.recommendation)]"
                return resolved
            }
            .joined(separator: "\n")
            return Self.cleanedMeetingTranscript(fallback)
        }
        var transcript = primarySource.text
        for conflict in meetingTruthConflicts {
            transcript = applyingConflictResolution(
                conflict,
                to: transcript,
                primarySourceName: primarySource.name
            )
        }
        let factsByID = Dictionary(uniqueKeysWithValues: meetingTruthFactCandidates.map { ($0.id, $0) })
        for decision in meetingTruthFactDecisions where decision.status == .confirmed {
            let replacement = decision.chosenText.trimmingCharacters(in: .whitespacesAndNewlines)
            let fact = factsByID[decision.factID]
            transcript = applyingConfirmedReplacement(
                originals: [fact?.sourceSpan, decision.claim].compactMap { $0 },
                replacement: replacement,
                to: transcript
            )
        }
        if let ledger = meetingTruthCentralReviewLedger {
            for claim in ledger.claims where shouldApplyCentralVerdictToTranscript(claim) {
                let replacement = claim.proposedCanonicalText.trimmingCharacters(in: .whitespacesAndNewlines)
                transcript = applyingConfirmedReplacement(
                    originals: [claim.sourceSpan, claim.claim],
                    replacement: replacement,
                    to: transcript
                )
            }
        }
        return Self.cleanedMeetingTranscript(transcript)
    }

    private func confirmedMeetingTruthContextText(missingFrom transcript: String) -> String {
        let lines = confirmedMeetingTruthContextLines(missingFrom: transcript)
        guard !lines.isEmpty else { return "" }
        return (["已确认会议信息："] + lines.map { "- \($0)" }).joined(separator: "\n")
    }

    private func confirmedMeetingTruthContextLines(missingFrom transcript: String) -> [String] {
        let confirmedTexts = meetingTruthConflicts.compactMap { conflict -> String? in
            guard let selected = conflict.selectedText.map(writableConfirmationText)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !selected.isEmpty,
                  !transcript.contains(selected) else {
                return nil
            }
            return selected
        }
        .sorted { $0.count > $1.count }

        var accepted: [String] = []
        var acceptedKeys: [String] = []
        for text in confirmedTexts {
            let key = normalizedComparableText(text)
            guard !key.isEmpty else { continue }
            if acceptedKeys.contains(where: { existing in
                existing.contains(key) || key.contains(existing)
            }) {
                continue
            }
            accepted.append(text)
            acceptedKeys.append(key)
        }
        return accepted
    }

    private func shouldApplyCentralVerdictToTranscript(_ claim: MeetingTruthCentralClaim) -> Bool {
        guard !claim.requiresHumanReview, claim.confidence >= 0.78 else { return false }
        switch claim.status {
        case .corrected:
            let sourceSpan = claim.sourceSpan.trimmingCharacters(in: .whitespacesAndNewlines)
            let claimText = claim.claim.trimmingCharacters(in: .whitespacesAndNewlines)
            let replacement = claim.proposedCanonicalText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !replacement.isEmpty,
                  !sourceSpan.isEmpty || !claimText.isEmpty else {
                return false
            }
            let original = sourceSpan.isEmpty ? claimText : sourceSpan
            return isSafeCentralTranscriptCorrection(original: original, replacement: replacement)
        case .accepted, .conflicted, .missing, .needsHumanReview, .rejected:
            return false
        }
    }

    private func isSafeCentralTranscriptCorrection(original: String, replacement: String) -> Bool {
        let originalKey = normalizedComparableText(original)
        let replacementKey = normalizedComparableText(replacement)
        guard !originalKey.isEmpty,
              !replacementKey.isEmpty,
              originalKey != replacementKey else {
            return false
        }
        if original.count > max(replacement.count * 3, 24) {
            return false
        }
        return true
    }

    private func applyingConflictResolution(
        _ conflict: MeetingTruthConflict,
        to transcript: String,
        primarySourceName: String
    ) -> String {
        let replacement = (conflict.selectedText.map(writableConfirmationText) ?? "[待确认：\(conflict.recommendation)]")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !replacement.isEmpty else { return transcript }
        let originals = replacementOriginalTexts(
            for: conflict,
            in: transcript,
            primarySourceName: primarySourceName,
            replacement: replacement
        )
        let result = applyingConfirmedReplacementWithValidation(
            originals: originals,
            replacement: replacement,
            to: transcript,
            windowID: conflict.timestamp
        )
        return result.validation.isValid ? result.text : transcript
    }

    private func replacementOriginalTexts(
        for conflict: MeetingTruthConflict,
        in transcript: String,
        primarySourceName: String,
        replacement: String
    ) -> [String] {
        let normalizedPrimary = primarySourceName.lowercased()
        var seen: Set<String> = []
        let matches = conflict.candidates.compactMap { candidate -> (text: String, primaryMatch: Bool, length: Int)? in
            let text = candidate.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text != replacement, transcript.contains(text) else { return nil }
            let key = normalizedComparableText(text)
            guard !key.isEmpty, !seen.contains(key) else { return nil }
            seen.insert(key)
            let source = candidate.source.lowercased()
            let primaryMatch = !source.isEmpty &&
                (normalizedPrimary.contains(source) || source.contains(normalizedPrimary))
            return (text, primaryMatch, text.count)
        }

        return matches
            .sorted {
                if $0.primaryMatch != $1.primaryMatch {
                    return $0.primaryMatch && !$1.primaryMatch
                }
                return $0.length > $1.length
            }
            .map(\.text)
    }

    private func applyingConfirmedReplacement(
        originals: [String],
        replacement: String,
        to transcript: String
    ) -> String {
        let trimmedReplacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedReplacement.isEmpty else { return transcript }

        var seen: Set<String> = []
        let texts = originals.compactMap { original -> String? in
            let text = original.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text != trimmedReplacement, transcript.contains(text) else { return nil }
            let key = normalizedComparableText(text)
            guard !key.isEmpty, !seen.contains(key) else { return nil }
            seen.insert(key)
            return text
        }
        .sorted { $0.count > $1.count }

        guard !texts.isEmpty else { return transcript }
        let result = applyingConfirmedReplacementWithValidation(
            originals: texts,
            replacement: trimmedReplacement,
            to: transcript,
            windowID: "confirmed"
        )
        return result.validation.isValid ? result.text : transcript
    }

    private func applyingConfirmedReplacementWithValidation(
        originals: [String],
        replacement: String,
        to transcript: String,
        windowID: String
    ) -> (text: String, validation: MeetingTruthReplacementValidationResult, spans: [MeetingTruthReplacementSpan]) {
        let trimmedReplacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedReplacement.isEmpty else {
            return (transcript, .notRun, [])
        }
        var spans: [MeetingTruthReplacementSpan] = []
        var updated = transcript
        for original in originals.sorted(by: { $0.count > $1.count }) {
            let target = original.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !target.isEmpty, target != trimmedReplacement else { continue }
            guard let range = updated.range(of: target) else { continue }
            guard replacementBoundaryLooksSafe(text: updated, range: range, replacement: trimmedReplacement) else {
                return (
                    transcript,
                    MeetingTruthReplacementValidationResult(
                        isValid: false,
                        reason: "自动修正未应用，原因是替换校验未通过：替换会和前后字符拼接成异常词。",
                        appliedSpanCount: 0,
                        pollutionChecks: replacementPollutionChecks(in: transcript)
                    ),
                    []
                )
            }
            let start = updated.distance(from: updated.startIndex, to: range.lowerBound)
            let end = updated.distance(from: updated.startIndex, to: range.upperBound)
            spans.append(MeetingTruthReplacementSpan(
                windowID: windowID,
                spanID: "\(windowID)-\(spans.count + 1)",
                originalText: target,
                replacementText: trimmedReplacement,
                rangeStart: start,
                rangeEnd: end,
                preContext: contextBefore(range.lowerBound, in: updated),
                postContext: contextAfter(range.upperBound, in: updated)
            ))
            updated.replaceSubrange(range, with: trimmedReplacement)
        }
        guard !spans.isEmpty else {
            return (
                transcript,
                MeetingTruthReplacementValidationResult(
                    isValid: false,
                    reason: "自动修正未应用，原因是没有找到仍匹配原文的目标 span。",
                    appliedSpanCount: 0,
                    pollutionChecks: replacementPollutionChecks(in: transcript)
                ),
                []
            )
        }
        let pollution = replacementPollutionChecks(in: updated)
        guard pollution.allSatisfy({ $0.hasSuffix("通过") }) else {
            return (
                transcript,
                MeetingTruthReplacementValidationResult(
                    isValid: false,
                    reason: "自动修正未应用，原因是替换后出现疑似拼接污染。",
                    appliedSpanCount: 0,
                    pollutionChecks: pollution
                ),
                spans
            )
        }
        return (
            updated,
            MeetingTruthReplacementValidationResult(
                isValid: true,
                reason: "已基于 span/range 完成安全替换。",
                appliedSpanCount: spans.count,
                pollutionChecks: pollution
            ),
            spans
        )
    }

    private func replacementBoundaryLooksSafe(text: String, range: Range<String.Index>, replacement: String) -> Bool {
        let before = range.lowerBound > text.startIndex ? text[text.index(before: range.lowerBound)] : nil
        let after = range.upperBound < text.endIndex ? text[range.upperBound] : nil
        if replacement.range(of: #"^[A-Za-z0-9+#.\-]+$"#, options: .regularExpression) != nil {
            if before?.isASCIIWord == true || after?.isASCIIWord == true {
                return false
            }
        }
        return true
    }

    private func replacementPollutionChecks(in text: String) -> [String] {
        let patterns = ["AASR", "aasr", "ASR ASR", "JSONON", "OpenClawaw"]
        return patterns.map { pattern in
            text.localizedCaseInsensitiveContains(pattern) ? "\(pattern)：失败" : "\(pattern)：通过"
        }
    }

    private func contextBefore(_ index: String.Index, in text: String) -> String {
        let lower = text.index(index, offsetBy: -18, limitedBy: text.startIndex) ?? text.startIndex
        return String(text[lower..<index])
    }

    private func contextAfter(_ index: String.Index, in text: String) -> String {
        let upper = text.index(index, offsetBy: 18, limitedBy: text.endIndex) ?? text.endIndex
        return String(text[index..<upper])
    }

    private func writableConfirmationText(_ text: String) -> String {
        Self.writableMeetingTruthConfirmationText(text)
    }

    static func writableMeetingTruthConfirmationText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let quoted = quotedTextFragments(in: trimmed)
        if quoted.count == 1,
           let value = quoted.first?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty,
           value.count < trimmed.count,
           trimmed.contains("使用") ||
           trimmed.contains("采用") ||
           trimmed.contains("写入") ||
           trimmed.contains("正式通知") ||
           trimmed.contains("建议确认") ||
           trimmed.contains("建议使用") ||
           trimmed.contains("确认") ||
           trimmed.contains("正确称谓") ||
           trimmed.contains("保持一致") {
            return value
        }
        if let value = suggestedCentralConfirmationText(from: trimmed) {
            return value
        }
        return trimmed
    }

    private static func isSystemMeetingTruthFactText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == "已确认会议信息" ||
            trimmed == "已确认会议信息：" ||
            trimmed == "已确认会议信息:"
    }

    private static func suggestedCentralConfirmationText(from text: String) -> String? {
        let separators = ["或相关人员", "或相关负责人", "或相关称谓", "或其正确称谓"]
        for separator in separators {
            guard let range = text.range(of: separator) else { continue }
            let prefix = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if isLikelyWritableShortConfirmation(prefix) {
                return prefix
            }
        }
        return nil
    }

    private static func isLikelyWritableShortConfirmation(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 12 else { return false }
        let blocked = ["建议", "确认", "保持", "注意", "称谓", "描述", "一致", "相关", "人员", "正确"]
        return !blocked.contains { trimmed.contains($0) }
    }

    private struct MeetingTruthConfirmationCoverage {
        var confirmedText: String
        var originalTexts: [String]
    }

    private func reconciledMeetingTruthCentralReviewLedger(_ ledger: MeetingTruthCentralReviewLedger) -> MeetingTruthCentralReviewLedger {
        var updated = ledger
        updated.claims = ledger.claims.map { claim in
            guard claim.requiresHumanReview,
                  let coverage = confirmationCoverage(for: claim) else {
                return claim
            }
            var accepted = claim
            accepted.proposedCanonicalText = coverage.confirmedText
            accepted.status = .accepted
            accepted.confidence = max(accepted.confidence, 0.96)
            accepted.missingEvidence = []
            accepted.humanQuestion = nil
            accepted.decisionReason = "用户已人工确认该中枢事实，后续复核不再重复阻塞。"
            accepted.supportingEvidence.removeAll { $0.channel == .human }
            accepted.supportingEvidence.append(
                MeetingTruthCentralEvidence(
                    channel: .human,
                    sourceName: "人工确认",
                    text: coverage.confirmedText,
                    visualCue: "",
                    supportsClaim: true,
                    confidence: 0.98,
                    priority: 100
                )
            )
            return accepted
        }
        updated.gaps = ledger.gaps.filter { gap in
            !(gap.requiresHumanReview && isReviewGapCoveredByConfirmation(gap))
        }
        return updated
    }

    private func confirmationCoverage(for claim: MeetingTruthCentralClaim) -> MeetingTruthConfirmationCoverage? {
        let target = [
            claim.claim,
            claim.proposedCanonicalText,
            claim.sourceSpan,
            claim.missingEvidence.joined(separator: " "),
            claim.decisionReason,
            claim.humanQuestion ?? ""
        ]
        .joined(separator: " ")
        return meetingTruthConfirmationCoverages().first { coverage in
            confirmationCoverage(coverage, matches: target)
        }
    }

    private func isReviewGapCoveredByConfirmation(_ gap: MeetingTruthReviewGap) -> Bool {
        let target = [gap.title, gap.detail].joined(separator: " ")
        return meetingTruthConfirmationCoverages().contains { coverage in
            confirmationCoverage(coverage, matches: target)
        }
    }

    private func confirmationCoverage(
        _ coverage: MeetingTruthConfirmationCoverage,
        matches target: String
    ) -> Bool {
        let targetKeys = comparableVariants(for: target)
        guard !targetKeys.isEmpty else { return false }
        let needles = [coverage.confirmedText] + coverage.originalTexts
        return needles
            .flatMap(comparableVariants)
            .contains { needle in
                needle.count >= 2 && targetKeys.contains { key in
                    key.contains(needle) || needle.contains(key)
                }
            }
    }

    private func meetingTruthConfirmationCoverages() -> [MeetingTruthConfirmationCoverage] {
        meetingTruthManualConfirmations.compactMap { confirmation in
            guard let selected = confirmation.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !selected.isEmpty else {
                return nil
            }
            var originals: [String] = []
            if let conflict = meetingTruthConflicts.first(where: { $0.id == confirmation.conflictID }) {
                originals.append(conflict.recommendation)
                originals.append(conflict.context)
                originals.append(contentsOf: conflict.candidates.map(\.text))
            }
            if let decision = meetingTruthFactDecisions.first(where: { $0.factID == confirmation.conflictID }) {
                originals.append(decision.claim)
                originals.append(decision.chosenText)
            }
            if let claim = meetingTruthCentralReviewLedger?.claims.first(where: { $0.id == confirmation.conflictID }) {
                originals.append(claim.claim)
                originals.append(claim.proposedCanonicalText)
                originals.append(claim.sourceSpan)
                originals.append(claim.decisionReason)
                originals.append(contentsOf: claim.missingEvidence)
            }
            return MeetingTruthConfirmationCoverage(
                confirmedText: writableConfirmationText(selected),
                originalTexts: originals
            )
        }
    }

    private func comparableVariants(for text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var variants = [normalizedComparableText(trimmed)]
        variants.append(contentsOf: Self.quotedTextFragments(in: trimmed).map(normalizedComparableText))
        variants.append(contentsOf: dateFragments(in: trimmed).map(normalizedComparableText))
        var seen: Set<String> = []
        return variants.filter { variant in
            guard !variant.isEmpty, !seen.contains(variant) else { return false }
            seen.insert(variant)
            return true
        }
    }

    private static func quotedTextFragments(in text: String) -> [String] {
        let pattern = #"[“"']([^”"']{2,})[”"']"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: nsRange).compactMap { match in
            guard match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: text) else {
                return nil
            }
            return String(text[range])
        }
    }

    private func dateFragments(in text: String) -> [String] {
        var fragments: [String] = []
        let patterns = [
            #"\d{4}年(\d{1,2}月\d{1,2}日)"#,
            #"(\d{1,2}月\d{1,2}日)"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in regex.matches(in: text, range: nsRange) {
                let rangeIndex = match.numberOfRanges > 1 ? 1 : 0
                guard let range = Range(match.range(at: rangeIndex), in: text) else { continue }
                fragments.append(String(text[range]))
            }
        }
        return fragments
    }

    var meetingTruthPrimaryTranscriptSource: MeetingTruthTranscriptSource? {
        meetingTruthTranscriptSources.max { lhs, rhs in
            Self.transcriptSourceQualityScore(lhs) < Self.transcriptSourceQualityScore(rhs)
        }
    }

    var meetingTruthTimestampAnchorSource: MeetingTruthTranscriptSource? {
        meetingTruthTranscriptSources
            .filter(\.hasTimestamp)
            .max { lhs, rhs in
                Self.timestampAnchorScore(lhs) < Self.timestampAnchorScore(rhs)
            }
    }

    func meetingTruthTranscriptRoleLabel(for source: MeetingTruthTranscriptSource) -> String {
        var labels: [String] = []
        if source.id == meetingTruthPrimaryTranscriptSource?.id {
            labels.append("主底稿")
        }
        if source.id == meetingTruthTimestampAnchorSource?.id {
            labels.append("定位锚点")
        }
        if labels.isEmpty {
            labels.append("交叉对照")
        }
        labels.append(source.hasTimestamp ? "含时间" : "无时间")
        return labels.joined(separator: " · ")
    }

    func meetingTruthReplacementPreview(for conflict: MeetingTruthConflict) -> MeetingTruthReplacementPreview? {
        let primarySource = meetingTruthPrimaryTranscriptSource
        let resolved = (conflict.selectedText.map(writableConfirmationText) ?? "[待确认：\(conflict.recommendation)]")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolved.isEmpty else { return nil }
        let primaryText = primarySource?.text ?? meetingTruthTranscriptSources.first?.text ?? ""
        let original = replacementOriginalTexts(
            for: conflict,
            in: primaryText,
            primarySourceName: primarySource?.name ?? "",
            replacement: resolved
        )
        .first ?? conflict.candidates.first?.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let original, !original.isEmpty else { return nil }

        return MeetingTruthReplacementPreview(
            originalText: original,
            resolvedText: resolved,
            originalContexts: previewContexts(for: original, in: primaryText),
            resolvedContexts: previewContexts(for: resolved, in: meetingTruthTrustedTranscript)
        )
    }

    func resolveMeetingTruthConflict(_ conflictID: UUID, text: String) {
        guard let index = meetingTruthConflicts.firstIndex(where: { $0.id == conflictID }) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        meetingTruthConflicts[index].selectedText = trimmed.isEmpty ? nil : trimmed
        let decision: MeetingTruthManualConfirmation.Decision
        if trimmed.isEmpty {
            decision = .clearedSelection
        } else if trimmed == meetingTruthConflicts[index].recommendation {
            decision = .acceptedRecommendation
        } else if meetingTruthConflicts[index].candidates.contains(where: { $0.text == trimmed }) {
            decision = .selectedCandidate
        } else {
            decision = .manualEdit
        }
        let action = meetingTruthConflictAction(for: decision)
        meetingTruthConflicts[index].lastUserAction = action
        if trimmed.isEmpty {
            meetingTruthConflicts[index].reviewStatus = .pending
            meetingTruthConflicts[index].replacementValidationResult = nil
            meetingTruthConflicts[index].replacementSpans = nil
        } else {
            let validation = validateMeetingTruthConflictReplacement(meetingTruthConflicts[index], resolvedText: trimmed)
            meetingTruthConflicts[index].replacementValidationResult = validation.validation
            meetingTruthConflicts[index].replacementSpans = validation.spans
            if validation.validation.isValid {
                meetingTruthConflicts[index].reviewStatus = decision == .acceptedRecommendation ? .suggestedApplied : .suggestedApplied
            } else {
                meetingTruthConflicts[index].reviewStatus = .deferredForCentralReview
            }
        }
        recordMeetingTruthConfirmation(for: conflictID, decision: decision, selectedText: trimmed.isEmpty ? nil : trimmed)
        if !meetingTruthFactCandidates.isEmpty || !meetingTruthFactDecisions.isEmpty {
            refreshMeetingTruthFactReviewLedger()
        } else {
            refreshMeetingTruthCentralReviewLedger()
        }
        meetingTruthAnalysis = nil
        meetingTruthValidationStatus = meetingTruthUnresolvedCount == 0 && !meetingTruthConflicts.isEmpty
            ? "全部冲突已确认，可以生成可信成果包"
            : "已更新人工确认，请继续处理剩余冲突"
        meetingTruthError = nil
        lastError = nil
        recordMeetingTruthActivity(
            stage: .manualConfirmation,
            title: "人工确认已更新",
            message: "片段 \(meetingTruthConflicts[index].timestamp) 已保存确认结果",
            details: trimmed.isEmpty ? "已清空该片段的确认文本" : "确认文本：\(trimmed)"
        )
        saveMeetingTruthProjects()
    }

    func updateMeetingTruthConflictAction(_ conflictID: UUID, action: MeetingTruthConflictUserAction) {
        guard let index = meetingTruthConflicts.firstIndex(where: { $0.id == conflictID }) else { return }
        meetingTruthConflicts[index].lastUserAction = action
        switch action {
        case .adoptSuggestion:
            resolveMeetingTruthConflict(conflictID, text: meetingTruthConflicts[index].recommendation)
            return
        case .manualRewrite:
            return
        case .ignoreLowRisk:
            meetingTruthConflicts[index].selectedText = nil
            meetingTruthConflicts[index].reviewStatus = .ignoredLowRisk
            recordMeetingTruthConfirmation(for: conflictID, decision: .ignoredSuggestion, selectedText: nil)
        case .deferForReview:
            meetingTruthConflicts[index].selectedText = nil
            meetingTruthConflicts[index].reviewStatus = .deferredForCentralReview
            recordMeetingTruthConfirmation(for: conflictID, decision: .ignoredSuggestion, selectedText: nil)
        case .markIrrelevant:
            meetingTruthConflicts[index].selectedText = nil
            meetingTruthConflicts[index].reviewStatus = .markedIrrelevant
            recordMeetingTruthConfirmation(for: conflictID, decision: .ignoredSuggestion, selectedText: nil)
        case .clearSelection:
            meetingTruthConflicts[index].selectedText = nil
            meetingTruthConflicts[index].reviewStatus = .pending
            meetingTruthConflicts[index].replacementValidationResult = nil
            meetingTruthConflicts[index].replacementSpans = nil
            recordMeetingTruthConfirmation(for: conflictID, decision: .clearedSelection, selectedText: nil)
        }
        meetingTruthAnalysis = nil
        meetingTruthValidationStatus = "已更新转写冲突处理状态"
        saveMeetingTruthProjects()
    }

    private func meetingTruthConflictAction(for decision: MeetingTruthManualConfirmation.Decision) -> MeetingTruthConflictUserAction {
        switch decision {
        case .acceptedRecommendation: .adoptSuggestion
        case .selectedCandidate, .manualEdit: .manualRewrite
        case .ignoredSuggestion: .ignoreLowRisk
        case .clearedSelection: .clearSelection
        }
    }

    private func validateMeetingTruthConflictReplacement(
        _ conflict: MeetingTruthConflict,
        resolvedText: String
    ) -> (validation: MeetingTruthReplacementValidationResult, spans: [MeetingTruthReplacementSpan]) {
        let primarySource = meetingTruthPrimaryTranscriptSource
        let primaryText = primarySource?.text ?? meetingTruthTranscriptSources.first?.text ?? ""
        let originals = replacementOriginalTexts(
            for: conflict,
            in: primaryText,
            primarySourceName: primarySource?.name ?? "",
            replacement: resolvedText
        )
        let result = applyingConfirmedReplacementWithValidation(
            originals: originals,
            replacement: resolvedText,
            to: primaryText,
            windowID: conflict.timestamp
        )
        return (result.validation, result.spans)
    }

    func applyHighConfidenceMeetingTruthRecommendations() {
        for index in meetingTruthConflicts.indices where meetingTruthConflicts[index].confidence == .high {
            meetingTruthConflicts[index].selectedText = meetingTruthConflicts[index].recommendation
            meetingTruthConflicts[index].lastUserAction = .adoptSuggestion
            let validation = validateMeetingTruthConflictReplacement(
                meetingTruthConflicts[index],
                resolvedText: meetingTruthConflicts[index].recommendation
            )
            meetingTruthConflicts[index].replacementValidationResult = validation.validation
            meetingTruthConflicts[index].replacementSpans = validation.spans
            meetingTruthConflicts[index].reviewStatus = validation.validation.isValid ? .suggestedApplied : .replacementValidationFailed
            recordMeetingTruthConfirmation(
                for: meetingTruthConflicts[index].id,
                decision: .acceptedRecommendation,
                selectedText: meetingTruthConflicts[index].recommendation
            )
        }
        if !meetingTruthFactCandidates.isEmpty || !meetingTruthFactDecisions.isEmpty {
            refreshMeetingTruthFactReviewLedger()
        } else {
            refreshMeetingTruthCentralReviewLedger()
        }
        meetingTruthAnalysis = nil
        meetingTruthValidationStatus = meetingTruthUnresolvedCount == 0 && !meetingTruthConflicts.isEmpty
            ? "高置信建议已采纳，可以生成可信成果包"
            : "已采纳高置信建议，请继续确认剩余冲突"
        meetingTruthError = nil
        lastError = nil
        recordMeetingTruthActivity(
            stage: .manualConfirmation,
            title: "已批量采用高置信建议",
            message: "已保存 \(meetingTruthConflicts.filter { $0.confidence == .high }.count) 条高置信建议"
        )
        saveMeetingTruthProjects()
    }

    @discardableResult
    func refreshMeetingTruthFactReviewLedger() -> [MeetingTruthUserQuestion] {
        let transcript = meetingTruthTrustedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
            resetMeetingTruthFactLedger()
            return []
        }

        let facts = meetingTruthFactReviewEngine.extractFacts(
            from: transcript,
            sources: meetingTruthTranscriptSources
        )
        let evidence = meetingTruthFactReviewEngine.collectEvidence(
            for: facts,
            transcriptSources: meetingTruthTranscriptSources,
            materials: meetingTruthMaterials,
            visualEvidence: meetingTruthVisualEvidence,
            conflicts: meetingTruthConflicts,
            confirmations: meetingTruthManualConfirmations
        )
        var decisions = meetingTruthFactReviewEngine.decide(
            facts: facts,
            evidence: evidence,
            config: meetingTruthArbitrationConfig
        )
        decisions = applyManualFactConfirmations(to: decisions)
        let questions = meetingTruthFactReviewEngine.questions(
            for: decisions,
            facts: facts,
            evidence: evidence
        )

        meetingTruthFactCandidates = facts
        meetingTruthEvidenceAtoms = evidence
        meetingTruthFactDecisions = decisions
        meetingTruthUserQuestions = questions
        refreshMeetingTruthCentralReviewLedger()
        return meetingTruthPendingFactQuestions
    }

    @discardableResult
    func refreshMeetingTruthCentralReviewLedger() -> MeetingTruthCentralReviewLedger? {
        guard !meetingTruthTranscriptSources.isEmpty || !meetingTruthMaterials.isEmpty else {
            meetingTruthCentralReviewLedger = nil
            return nil
        }
        let ledger = meetingTruthCentralReviewEngine.buildLedger(
            model: meetingAISettings.model,
            transcriptSources: meetingTruthTranscriptSources,
            materials: meetingTruthMaterials,
            visualEvidence: meetingTruthVisualEvidence,
            conflicts: meetingTruthConflicts,
            confirmations: meetingTruthManualConfirmations,
            factCandidates: meetingTruthFactCandidates,
            evidenceAtoms: meetingTruthEvidenceAtoms,
            factDecisions: meetingTruthFactDecisions,
            analysis: meetingTruthAnalysis
        )
        let reconciled = reconciledMeetingTruthCentralReviewLedger(ledger)
        meetingTruthCentralReviewLedger = reconciled
        return reconciled
    }

    @discardableResult
    private func refreshMeetingTruthCentralReviewWithGemma() async throws -> MeetingTruthCentralReviewLedger {
        let fallbackLedger = refreshMeetingTruthCentralReviewLedger()
        let ledger = try await meetingAIService.reviewMeetingTruthCentrally(
            transcriptSources: meetingTruthTranscriptSources,
            materials: meetingTruthMaterials,
            visualEvidence: meetingTruthVisualEvidence,
            conflicts: meetingTruthConflicts,
            factDecisions: meetingTruthFactDecisions,
            manualConfirmations: meetingTruthManualConfirmations,
            currentLedger: fallbackLedger,
            analysis: meetingTruthAnalysis,
            settings: meetingAISettings
        )
        let reconciled = reconciledMeetingTruthCentralReviewLedger(ledger)
        meetingTruthCentralReviewLedger = reconciled
        recordMeetingTruthActivity(
            stage: .resolveConflicts,
            title: "Gemma 4 中枢复核完成",
            message: reconciled.blockingItems.isEmpty
                ? (reconciled.advisoryItems.isEmpty
                    ? "固定多模态复核通过，可以进入成果包生成"
                    : "固定多模态复核通过，另有 \(reconciled.advisoryItems.count) 个提示缺口将写入成果包")
                : "发现 \(reconciled.blockingItems.count) 个需要处理的中枢复核问题",
            details: (reconciled.blockingItems + reconciled.advisoryItems).prefix(6).joined(separator: "\n")
        )
        return reconciled
    }

    func runMeetingTruthCentralReviewWithGemma() {
        guard !isMeetingTruthTaskRunning else { return }
        guard !meetingTruthTranscriptSources.isEmpty || !meetingTruthMaterials.isEmpty else {
            setMeetingTruthError("请先导入会议资料或候选转写，再运行多模态中枢复核。", stage: .resolveConflicts)
            return
        }
        currentMeetingTruthTask?.cancel()
        currentMeetingTruthTaskGeneration += 1
        let taskGeneration = currentMeetingTruthTaskGeneration
        isReviewingMeetingTruthCentrally = true
        meetingTruthValidationStatus = "Gemma 4 正在运行多模态中枢复核"
        meetingTruthError = nil
        lastError = nil

        currentMeetingTruthTask = Task { @MainActor in
            defer {
                if currentMeetingTruthTaskGeneration == taskGeneration {
                    isReviewingMeetingTruthCentrally = false
                    currentMeetingTruthTask = nil
                }
            }
            do {
                if !meetingTruthTrustedTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    _ = refreshMeetingTruthFactReviewLedger()
                } else {
                    _ = refreshMeetingTruthCentralReviewLedger()
                }
                let ledger = try await refreshMeetingTruthCentralReviewWithGemma()
                guard !Task.isCancelled else { return }
                meetingTruthValidationStatus = ledger.blockingItems.isEmpty
                    ? (ledger.advisoryItems.isEmpty
                        ? "Gemma 4 中枢复核通过，可以继续生成成果包"
                        : "Gemma 4 中枢复核通过，\(ledger.advisoryItems.count) 个提示缺口会作为待确认信息写入成果包")
                    : "Gemma 4 中枢复核发现 \(ledger.blockingItems.count) 个需要确认的问题"
                meetingTruthLastFailure = nil
                meetingTruthError = nil
                lastError = nil
                saveMeetingTruthProjects()
            } catch {
                guard !Task.isCancelled else { return }
                meetingTruthValidationStatus = "Gemma 4 中枢复核失败"
                setMeetingTruthError(error.localizedDescription, stage: .resolveConflicts)
            }
        }
    }

    func runMeetingTruthToolCallingABTest() {
        guard !isMeetingTruthTaskRunning else { return }
        guard !meetingTruthTranscriptSources.isEmpty || !meetingTruthMaterials.isEmpty else {
            setMeetingTruthError("请先导入会议资料或候选转写，再运行可信度 AB。", stage: .resolveConflicts)
            return
        }
        currentMeetingTruthTask?.cancel()
        currentMeetingTruthTaskGeneration += 1
        let taskGeneration = currentMeetingTruthTaskGeneration
        isRunningMeetingTruthToolAB = true
        meetingTruthValidationStatus = "正在运行 AB 复核：直接生成分支"
        meetingTruthError = nil
        lastError = nil

        currentMeetingTruthTask = Task { @MainActor in
            defer {
                if currentMeetingTruthTaskGeneration == taskGeneration {
                    isRunningMeetingTruthToolAB = false
                    currentMeetingTruthTask = nil
                }
            }

            if !meetingTruthTrustedTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                _ = refreshMeetingTruthFactReviewLedger()
            } else {
                _ = refreshMeetingTruthCentralReviewLedger()
            }
            let fallbackLedger = meetingTruthCentralReviewLedger

            let promptOnly = await runMeetingTruthABBranch(
                title: "直接生成",
                modeDescription: "速度更快、token 更少，适合低风险简单会议；但不主动拆解多路 ASR 差异，也没有稳定证据链。",
                fallbackLedger: fallbackLedger,
                useToolCalling: false
            )
            guard !Task.isCancelled else { return }

            meetingTruthValidationStatus = "正在运行 AB 复核：证据核验分支"
            let toolCalling = await runMeetingTruthABBranch(
                title: "证据核验后生成",
                modeDescription: "耗时更长、token 更多；Gemma 4 原生 tool_call 触发 Swift 执行 ASR 差异检测、证据检索、候选评分和事实裁决。",
                fallbackLedger: fallbackLedger,
                useToolCalling: true
            )
            guard !Task.isCancelled else { return }

            let result = MeetingTruthToolCallingABResult(
                model: meetingAISettings.model,
                promptOnly: promptOnly,
                toolCalling: toolCalling,
                resultDifferences: meetingTruthABResultDifferences(promptOnly: promptOnly, toolCalling: toolCalling),
                effectDifferences: meetingTruthABEffectDifferences(promptOnly: promptOnly, toolCalling: toolCalling),
                timingSummary: meetingTruthABTimingSummary(promptOnly: promptOnly, toolCalling: toolCalling),
                nativeToolCallingObserved: toolCalling.ledger?.toolCallRecords.contains { $0.status == .executed } == true
            )
            meetingTruthToolCallingABResult = result
            if let ledger = toolCalling.ledger {
                meetingTruthCentralReviewLedger = reconciledMeetingTruthCentralReviewLedger(ledger)
            } else if let ledger = promptOnly.ledger {
                meetingTruthCentralReviewLedger = reconciledMeetingTruthCentralReviewLedger(ledger)
            }
            meetingTruthValidationStatus = "AB 复核完成：\(result.outcomeKind.title)；\(result.timingSummary)"
            meetingTruthLastFailure = nil
            meetingTruthError = nil
            lastError = nil
            recordMeetingTruthActivity(
                stage: .resolveConflicts,
                title: "AB 复核完成：\(result.outcomeKind.title)",
                message: result.timingSummary,
                details: ([result.outcomeDetail] + result.resultDifferences + result.effectDifferences).prefix(9).joined(separator: "\n")
            )
            saveMeetingTruthProjects()
        }
    }

    func loadMeetingTruthOpenClawEvidenceDemo() {
        let materialID = UUID()
        meetingTruthTranscriptSources = [
            MeetingTruthTranscriptSource(name: "ASR A", text: "我们下阶段要接入 OpenClaw，并用 Gemma 4 做交叉校验。"),
            MeetingTruthTranscriptSource(name: "ASR B", text: "我们下阶段要接入 OpenCloud，并用 Gemma 4 做交叉校验。"),
            MeetingTruthTranscriptSource(name: "ASR C", text: "我们下阶段要接入 OpenCL，并用 Gemma 4 做交叉校验。")
        ]
        meetingTruthMaterials = [
            MeetingTruthMaterial(
                id: materialID,
                name: "项目方案",
                kind: "text",
                detail: "术语表 / 项目方案",
                extractedText: "项目方案写的是 OpenClaw。"
            ),
            MeetingTruthMaterial(
                name: "PPT 手写图",
                kind: "image",
                detail: "PPT / 手写图 / OCR 中出现 OpenClaw。",
                extractedText: "PPT / 手写图 / OCR 中出现 OpenClaw。"
            )
        ]
        let imageMaterialID = meetingTruthMaterials[1].id
        meetingTruthVisualEvidence = [
            MeetingTruthVisualEvidence(
                materialID: imageMaterialID,
                materialName: "PPT 手写图",
                summary: "原图视觉结果显示术语写法为 OpenClaw。",
                extractedNumbers: [],
                keywords: ["OpenClaw", "Gemma 4", "交叉校验"],
                actionHints: ["下阶段接入 OpenClaw"],
                layoutCues: ["PPT 标题和手写标注均指向 OpenClaw"],
                visualMarks: ["手写圈注 OpenClaw"],
                ocrContrast: "OCR 与原图理解均支持 OpenClaw。",
                confidence: .high,
                asrCandidateTerms: ["OpenClaw", "OpenCloud", "OpenCL"],
                model: "Gemma 4 demo"
            )
        ]
        meetingTruthConflicts = [
            MeetingTruthConflict(
                timestamp: "样例片段",
                kind: .terminology,
                context: "我们下阶段要接入 OpenClaw/OpenCloud/OpenCL，并用 Gemma 4 做交叉校验。",
                candidates: [
                    MeetingTruthCandidate(source: "ASR A", text: "OpenClaw"),
                    MeetingTruthCandidate(source: "ASR B", text: "OpenCloud"),
                    MeetingTruthCandidate(source: "ASR C", text: "OpenCL")
                ],
                recommendation: "OpenClaw",
                confidence: .high,
                evidence: "材料和原图视觉结果均支持 OpenClaw。"
            )
        ]
        hasDiscoveredMeetingTruthConflicts = true
        meetingTruthManualConfirmations = []
        resetMeetingTruthFactLedger()

        let finding = MeetingTruthASRConflictFinding(
            conflictID: "asr-1",
            conflictType: "系统名/技术术语",
            candidates: ["OpenClaw", "OpenCloud", "OpenCL"],
            sourceTexts: [
                "ASR A：我们下阶段要接入 OpenClaw，并用 Gemma 4 做交叉校验。",
                "ASR B：我们下阶段要接入 OpenCloud，并用 Gemma 4 做交叉校验。",
                "ASR C：我们下阶段要接入 OpenCL，并用 Gemma 4 做交叉校验。"
            ],
            riskLevel: .high,
            impactsMinutes: true,
            reason: "多路 ASR 在同一位置出现 OpenClaw / OpenCloud / OpenCL 变体，属于会影响纪要的系统名/技术术语差异。",
            relatedWindow: "我们下阶段要接入 OpenClaw/OpenCloud/OpenCL，并用 Gemma 4 做交叉校验。"
        )
        let evidence: [MeetingTruthEvidenceSupport] = [
            .init(sourceType: .asr, sourceID: "ASR A", matchedText: "ASR A：OpenClaw", candidate: "OpenClaw", supportsCandidate: true, supportType: .partialSupport, confidence: 0.45),
            .init(sourceType: .asr, sourceID: "ASR B", matchedText: "ASR B：OpenCloud", candidate: "OpenCloud", supportsCandidate: true, supportType: .partialSupport, confidence: 0.45),
            .init(sourceType: .asr, sourceID: "ASR C", matchedText: "ASR C：OpenCL", candidate: "OpenCL", supportsCandidate: true, supportType: .partialSupport, confidence: 0.45),
            .init(sourceType: .material, sourceID: materialID.uuidString, matchedText: "项目方案写的是 OpenClaw。", candidate: "OpenClaw", supportsCandidate: true, supportType: .supports, confidence: 0.82),
            .init(sourceType: .rawVision, sourceID: imageMaterialID.uuidString, matchedText: "PPT / 手写图 / OCR 中出现 OpenClaw。", candidate: "OpenClaw", supportsCandidate: true, supportType: .supports, confidence: 0.90),
            .init(sourceType: .material, sourceID: materialID.uuidString, matchedText: "项目方案出现近似写法 OpenClaw，不是 OpenCloud。", candidate: "OpenCloud", supportsCandidate: false, supportType: .contradicts, confidence: 0.72),
            .init(sourceType: .rawVision, sourceID: imageMaterialID.uuidString, matchedText: "PPT/手写图出现近似写法 OpenClaw，不是 OpenCloud。", candidate: "OpenCloud", supportsCandidate: false, supportType: .contradicts, confidence: 0.76),
            .init(sourceType: .material, sourceID: materialID.uuidString, matchedText: "项目方案出现近似写法 OpenClaw，不是 OpenCL。", candidate: "OpenCL", supportsCandidate: false, supportType: .contradicts, confidence: 0.72),
            .init(sourceType: .rawVision, sourceID: imageMaterialID.uuidString, matchedText: "PPT/手写图出现近似写法 OpenClaw，不是 OpenCL。", candidate: "OpenCL", supportsCandidate: false, supportType: .contradicts, confidence: 0.76),
            .init(sourceType: .context, sourceID: materialID.uuidString, matchedText: "材料和图片支持 OpenClaw，削弱 OpenCloud。", candidate: "OpenCloud", supportsCandidate: false, supportType: .contradicts, confidence: 0.62),
            .init(sourceType: .context, sourceID: materialID.uuidString, matchedText: "材料和图片支持 OpenClaw，削弱 OpenCL。", candidate: "OpenCL", supportsCandidate: false, supportType: .contradicts, confidence: 0.62)
        ]
        let scores: [MeetingTruthCandidateScore] = [
            .init(candidate: "OpenClaw", score: 1.0, supportingSources: ["ASR A", "项目方案", "PPT 手写图"], conflictingSources: [], reason: "ASR A、材料和原图视觉结果均支持 OpenClaw。", recommendedValue: "OpenClaw", recommendedDecision: .corrected),
            .init(candidate: "OpenCloud", score: 0.0, supportingSources: ["ASR B"], conflictingSources: ["项目方案", "PPT 手写图"], reason: "仅 ASR B 部分支持；材料和图片都出现近似但不同的 OpenClaw，直接反驳 OpenCloud。", recommendedValue: "OpenClaw", recommendedDecision: .rejected),
            .init(candidate: "OpenCL", score: 0.0, supportingSources: ["ASR C"], conflictingSources: ["项目方案", "PPT 手写图"], reason: "仅 ASR C 部分支持；材料和图片都出现近似但不同的 OpenClaw，直接反驳 OpenCL。", recommendedValue: "OpenClaw", recommendedDecision: .rejected)
        ]
        let decision = MeetingTruthFactDecisionTrace(
            finalText: "OpenClaw",
            status: .corrected,
            confidence: 1.0,
            enterMinutes: true,
            evidenceChain: [
                "material：项目方案写的是 OpenClaw。",
                "rawVision：PPT / 手写图 / OCR 中出现 OpenClaw。"
            ],
            explanation: "多路 ASR 存在 OpenClaw / OpenCloud / OpenCL 分歧；材料和图片证据更支持 OpenClaw，因此自动修正。",
            correctedFrom: ["OpenCloud", "OpenCL"]
        )
        var records: [MeetingTruthToolCallRecord] = [
            MeetingTruthToolCallRecord(callIndex: 1, functionName: "detect_asr_conflicts", argumentsSummary: "OpenClaw 样例：扫描三路 ASR", resultSummary: "发现系统名/技术术语差异：OpenClaw / OpenCloud / OpenCL。", impactSummary: "该差异会影响最终纪要中的系统名写法。", status: .executed, asrConflicts: [finding]),
            MeetingTruthToolCallRecord(callIndex: 2, functionName: "retrieve_supporting_evidence", argumentsSummary: "检索 OpenClaw / OpenCloud / OpenCL 的材料和图片证据", resultSummary: "材料和原图视觉结果均支持 OpenClaw，并直接反驳 OpenCloud / OpenCL。", impactSummary: "OpenCloud / OpenCL 被材料和图片证据链削弱。", status: .executed, asrConflicts: [finding], evidenceChain: evidence),
            MeetingTruthToolCallRecord(callIndex: 3, functionName: "score_fact_candidates", argumentsSummary: "按 ASR、材料、图片证据评分", resultSummary: "OpenClaw 100 分；OpenCloud 0 分；OpenCL 0 分。", impactSummary: "OpenClaw 是唯一可自动写入纪要的候选。", status: .executed, asrConflicts: [finding], evidenceChain: evidence, candidateScores: scores),
            MeetingTruthToolCallRecord(callIndex: 4, functionName: "make_fact_decision", argumentsSummary: "输出标准事实裁决", resultSummary: "corrected：final_text=OpenClaw，enter_minutes=yes。", impactSummary: "最终纪要将 OpenCloud / OpenCL 修正为 OpenClaw。", status: .executed, asrConflicts: [finding], evidenceChain: evidence, candidateScores: scores, factDecision: decision, affectedMinutesText: "我们下阶段要接入 OpenClaw，并用 Gemma 4 做交叉校验。"),
            MeetingTruthToolCallRecord(callIndex: 5, functionName: "create_human_review_task", argumentsSummary: "检查是否需要人工确认", resultSummary: "证据充足，无需人工确认。", impactSummary: "不会增加人工确认队列。", status: .skipped, asrConflicts: [finding], evidenceChain: evidence, candidateScores: scores, factDecision: decision)
        ]
        records = records.map {
            var record = $0
            record.invocationSource = .autoPipeline
            return record
        }
        let centralClaim = MeetingTruthCentralClaim(
            kind: .term,
            claim: "系统名候选：OpenClaw / OpenCloud / OpenCL",
            proposedCanonicalText: "OpenClaw",
            sourceSpan: finding.relatedWindow,
            status: .corrected,
            confidence: 1.0,
            importance: .high,
            riskLevel: .high,
            supportingEvidence: [
                MeetingTruthCentralEvidence(channel: .material, sourceName: "项目方案", text: "项目方案写的是 OpenClaw。", visualCue: "", supportsClaim: true, confidence: 0.82, priority: 90),
                MeetingTruthCentralEvidence(channel: .rawVision, sourceName: "PPT 手写图", text: "PPT / 手写图 / OCR 中出现 OpenClaw。", visualCue: "手写/PPT 中出现 OpenClaw", supportsClaim: true, confidence: 0.90, priority: 95)
            ],
            contradictingEvidence: [
                MeetingTruthCentralEvidence(channel: .asr, sourceName: "ASR B", text: "OpenCloud", visualCue: "", supportsClaim: false, confidence: 0.45, priority: 35),
                MeetingTruthCentralEvidence(channel: .asr, sourceName: "ASR C", text: "OpenCL", visualCue: "", supportsClaim: false, confidence: 0.45, priority: 35)
            ],
            missingEvidence: [],
            humanQuestion: nil,
            decisionReason: decision.explanation
        )
        let ledger = MeetingTruthCentralReviewLedger(
            model: "OpenClaw evidence demo",
            inputSummary: ["3 路 ASR", "1 份项目方案", "1 张 PPT/手写图"],
            visualObservations: [
                MeetingTruthVisualObservation(
                    materialID: imageMaterialID,
                    materialName: "PPT 手写图",
                    materialRole: "图片证据",
                    summary: "原图视觉结果显示术语写法为 OpenClaw。",
                    layoutCues: ["PPT 标题和手写标注均指向 OpenClaw"],
                    visualMarks: ["手写圈注 OpenClaw"],
                    participantEvidence: [],
                    actionHints: ["下阶段接入 OpenClaw"],
                    ocrBaseline: "PPT / 手写图 / OCR 中出现 OpenClaw。",
                    ocrContrast: "OCR 与原图理解均支持 OpenClaw。",
                    confidence: .high
                )
            ],
            claims: [centralClaim],
            gaps: [],
            packageAuditNotes: ["最终纪要中系统名应写 OpenClaw。"],
            completionStandard: ["OpenCloud / OpenCL 已被材料和图片证据修正为 OpenClaw。"],
            toolCallRecords: records,
            toolCallingComparison: MeetingTruthToolCallingComparison(
                baselineModeTitle: "直接生成",
                toolCallingModeTitle: "证据核验后生成",
                baselineSummary: "直接生成可能把系统名写成 OpenCloud / OpenCL，缺少工具级证据链说明为什么选 OpenClaw。",
                toolCallingSummary: "证据核验发现 OpenClaw / OpenCloud / OpenCL 差异，检索材料和图片证据，评分后输出 corrected 裁决。",
                improvements: ["系统将 OpenCloud / OpenCL 修正为 OpenClaw，依据是项目方案和 PPT/手写图证据。"],
                limitations: ["短样例中证据核验没有节省 token；它用更多 token 换来证据链、自动修正和可解释裁决。"],
                invokedToolCount: 4,
                impactedClaimCount: 1
            ),
            tokenUsage: MeetingTruthTokenUsage(promptTokens: 2635, completionTokens: 199, totalTokens: 2834)
        )
        let promptClaim = MeetingTruthCentralClaim(
            kind: .term,
            claim: "系统名候选：OpenClaw / OpenCloud / OpenCL",
            proposedCanonicalText: "OpenClaw / OpenCloud / OpenCL 待确认",
            sourceSpan: finding.relatedWindow,
            status: .needsHumanReview,
            confidence: 0.52,
            importance: .high,
            riskLevel: .high,
            supportingEvidence: [
                MeetingTruthCentralEvidence(channel: .asr, sourceName: "ASR A", text: "OpenClaw", visualCue: "", supportsClaim: true, confidence: 0.45, priority: 40),
                MeetingTruthCentralEvidence(channel: .asr, sourceName: "ASR B", text: "OpenCloud", visualCue: "", supportsClaim: true, confidence: 0.45, priority: 40),
                MeetingTruthCentralEvidence(channel: .asr, sourceName: "ASR C", text: "OpenCL", visualCue: "", supportsClaim: true, confidence: 0.45, priority: 40)
            ],
            contradictingEvidence: [],
            missingEvidence: ["直接生成分支没有执行材料/图片检索工具，无法说明哪一个候选更可靠。"],
            humanQuestion: "系统名应写 OpenClaw、OpenCloud 还是 OpenCL？",
            decisionReason: "仅靠 prompt 可以看到三路 ASR 写法冲突，但没有工具返回的材料证据、图片证据和候选评分，因此高风险术语不应自动写入纪要。"
        )
        let promptLedger = MeetingTruthCentralReviewLedger(
            model: "OpenClaw prompt-only demo",
            inputSummary: ["3 路 ASR", "未执行工具检索"],
            visualObservations: [],
            claims: [promptClaim],
            gaps: [
                MeetingTruthReviewGap(
                    kind: .unsupportedHighRiskFact,
                    title: "高风险术语缺少工具级证据",
                    detail: "OpenClaw / OpenCloud / OpenCL 三个候选只来自 ASR，不调用工具时没有材料或原图证据链。",
                    relatedClaimID: promptClaim.id,
                    requiresHumanReview: true
                )
            ],
            packageAuditNotes: ["直接生成分支不应把该系统名自动写入最终纪要。"],
            completionStandard: ["需要人工确认或重新运行函数调用证据链。"],
            toolCallRecords: [],
            toolCallingComparison: MeetingTruthToolCallingComparison(
                baselineModeTitle: "直接生成",
                toolCallingModeTitle: "证据核验后生成",
                baselineSummary: "直接生成速度更快、token 更少，但这里只能看到 ASR 文本冲突，缺少工具执行证据。",
                toolCallingSummary: "证据核验能检索材料和图片证据并输出 corrected 裁决。",
                improvements: [],
                limitations: ["直接生成没有 tool_call -> tool_response -> final decision 链路。"],
                invokedToolCount: 0,
                impactedClaimCount: 1
            ),
            tokenUsage: MeetingTruthTokenUsage(promptTokens: 151, completionTokens: 27, totalTokens: 178)
        )
        let now = Date()
        let promptBranch = MeetingTruthABBranchResult(
            title: "直接生成",
            modeDescription: "速度更快、token 更少；可能写成 OpenCloud / OpenCL，且不会主动拆解多路 ASR 差异或留下稳定证据链。",
            durationSeconds: 1.292,
            startedAt: now,
            finishedAt: now.addingTimeInterval(1.292),
            ledger: promptLedger,
            errorMessage: nil,
            tokenUsage: MeetingTruthTokenUsage(promptTokens: 151, completionTokens: 27, totalTokens: 178)
        )
        let toolBranch = MeetingTruthABBranchResult(
            title: "证据核验后生成",
            modeDescription: "耗时更长、token 更多；Gemma 4 原生 tool_call 触发 Swift 执行 ASR 差异检测、证据检索、候选评分和事实裁决。",
            durationSeconds: 4.829,
            startedAt: now,
            finishedAt: now.addingTimeInterval(4.829),
            ledger: ledger,
            errorMessage: nil,
            tokenUsage: MeetingTruthTokenUsage(promptTokens: 2635, completionTokens: 199, totalTokens: 2834)
        )
        meetingTruthCentralReviewLedger = ledger
        meetingTruthToolCallingABResult = MeetingTruthToolCallingABResult(
            model: "OpenClaw evidence demo",
            promptOnly: promptBranch,
            toolCalling: toolBranch,
            resultDifferences: [
                "直接生成更快、token 更少，但可能把高风险系统名写成 OpenCloud / OpenCL。",
                "证据核验发现 OpenClaw / OpenCloud / OpenCL 差异。",
                "材料和图片均支持 OpenClaw，并反驳 OpenCloud / OpenCL。",
                "系统自动修正为 OpenClaw，最终纪要写入 OpenClaw，无需人工确认。"
            ],
            effectDifferences: [
                "最终纪要写为：我们下阶段要接入 OpenClaw，并用 Gemma 4 做交叉校验。",
                "短样例中证据核验 token 和耗时更高，但换来了证据链、自动修正和可解释裁决。",
                "长会议 token 优化需要后续用长会议样本验证。"
            ],
            timingSummary: "OpenClaw 短样例：直接生成 1.29s / 178 token；证据核验 4.83s / 2834 token。证据核验更慢更贵，但能发现并修正高风险转写错误。",
            nativeToolCallingObserved: true
        )
        meetingTruthValidationStatus = "OpenClaw 证据裁决样例已加载"
        meetingTruthError = nil
        meetingTruthLastFailure = nil
        recordMeetingTruthActivity(
            stage: .resolveConflicts,
            title: "OpenClaw 证据裁决样例已加载",
            message: "OpenCloud / OpenCL 已根据材料和图片证据修正为 OpenClaw"
        )
        saveMeetingTruthProjects()
    }

    private func runMeetingTruthABBranch(
        title: String,
        modeDescription: String,
        fallbackLedger: MeetingTruthCentralReviewLedger?,
        useToolCalling: Bool
    ) async -> MeetingTruthABBranchResult {
        let startedAt = Date()
        do {
            let ledger = try await meetingAIService.reviewMeetingTruthCentrally(
                transcriptSources: meetingTruthTranscriptSources,
                materials: meetingTruthMaterials,
                visualEvidence: meetingTruthVisualEvidence,
                conflicts: meetingTruthConflicts,
                factDecisions: meetingTruthFactDecisions,
                manualConfirmations: meetingTruthManualConfirmations,
                currentLedger: fallbackLedger,
                analysis: meetingTruthAnalysis,
                settings: meetingAISettings,
                useToolCalling: useToolCalling
            )
            let finishedAt = Date()
            return MeetingTruthABBranchResult(
                title: title,
                modeDescription: modeDescription,
                durationSeconds: finishedAt.timeIntervalSince(startedAt),
                startedAt: startedAt,
                finishedAt: finishedAt,
                ledger: reconciledMeetingTruthCentralReviewLedger(ledger),
                errorMessage: nil,
                tokenUsage: ledger.tokenUsage
            )
        } catch {
            let finishedAt = Date()
            return MeetingTruthABBranchResult(
                title: title,
                modeDescription: modeDescription,
                durationSeconds: finishedAt.timeIntervalSince(startedAt),
                startedAt: startedAt,
                finishedAt: finishedAt,
                ledger: nil,
                errorMessage: error.localizedDescription
            )
        }
    }

    private func meetingTruthABTimingSummary(
        promptOnly: MeetingTruthABBranchResult,
        toolCalling: MeetingTruthABBranchResult
    ) -> String {
        let prompt = Self.durationText(promptOnly.durationSeconds)
        let tools = Self.durationText(toolCalling.durationSeconds)
        let delta = toolCalling.durationSeconds - promptOnly.durationSeconds
        if abs(delta) < 0.05 {
            return "直接生成 \(prompt)，证据核验 \(tools)，耗时基本相同；短样例不宣传 token 节省。"
        }
        if toolCalling.verificationAnomalyCount > 0 {
            return "直接生成 \(prompt)，证据核验 \(tools)；本轮工具裁决与最终 ledger 不一致，先按核验异常处理。"
        }
        let sameFinalTexts = !promptOnly.finalCanonicalTextKeys.isEmpty &&
            promptOnly.finalCanonicalTextKeys == toolCalling.finalCanonicalTextKeys
        if sameFinalTexts,
           toolCalling.unhandledRiskItemCount >= promptOnly.unhandledRiskItemCount,
           toolCalling.automaticCorrectionCount <= promptOnly.automaticCorrectionCount {
            return "直接生成 \(prompt)，证据核验 \(tools)；本轮最终结论无明显变化，不宣传可信度收益。"
        }
        return delta > 0
            ? "直接生成 \(prompt)，证据核验 \(tools)，证据核验多用 \(Self.durationText(delta))；换来证据链、自动修正和可解释裁决。"
            : "直接生成 \(prompt)，证据核验 \(tools)，本轮证据核验更快；但展示重点仍是高风险事实是否有证据链。"
    }

    private func meetingTruthABResultDifferences(
        promptOnly: MeetingTruthABBranchResult,
        toolCalling: MeetingTruthABBranchResult
    ) -> [String] {
        var differences: [String] = []
        differences.append("耗时：\(promptOnly.title) \(Self.durationText(promptOnly.durationSeconds))；\(toolCalling.title) \(Self.durationText(toolCalling.durationSeconds))。")
        differences.append("Token：\(promptOnly.title) \(tokenUsageText(promptOnly.tokenUsage))；\(toolCalling.title) \(tokenUsageText(toolCalling.tokenUsage))。")
        differences.append("阻塞项：\(promptOnly.blockingCount) -> \(toolCalling.blockingCount)。")
        differences.append("提示缺口：\(promptOnly.advisoryCount) -> \(toolCalling.advisoryCount)。")
        differences.append("事实裁决：\(promptOnly.claimCount) -> \(toolCalling.claimCount)。")
        differences.append("发现转写差异：\(promptOnly.asrDifferenceCount) -> \(toolCalling.asrDifferenceCount)。")
        differences.append("自动修正：\(promptOnly.automaticCorrectionCount) -> \(toolCalling.automaticCorrectionCount)；需要确认：\(promptOnly.confirmationNeededCount) -> \(toolCalling.confirmationNeededCount)。")
        differences.append("证据链：\(promptOnly.evidenceChainCount) -> \(toolCalling.evidenceChainCount)；最终纪要变化：\(promptOnly.finalMinutesChangeCount) -> \(toolCalling.finalMinutesChangeCount)。")
        differences.append("工具函数步骤：\(promptOnly.toolFunctionStepCount) -> \(toolCalling.toolFunctionStepCount)；多模态证据：\(promptOnly.multimodalEvidenceCount) -> \(toolCalling.multimodalEvidenceCount)。")
        if toolCalling.verificationAnomalyCount > 0 {
            differences.append("核验异常：工具裁决出现冲突/拒绝/人工确认信号，但最终 ledger 没有一致阻塞或解释。")
        }
        if promptOnly.finalCanonicalTextKeys == toolCalling.finalCanonicalTextKeys,
           !promptOnly.finalCanonicalTextKeys.isEmpty {
            differences.append("最终采信文本一致：本轮不能仅凭工具步骤数说明证据核验更有用。")
        }
        if let error = promptOnly.errorMessage {
            differences.append("直接生成失败：\(error)")
        }
        if let error = toolCalling.errorMessage {
            differences.append("证据核验分支失败：\(error)")
        }
        differences.append("短样例中证据核验不节省 token；长会议 token 优化需要后续用长会议样本验证。")
        return differences
    }

    private func meetingTruthABEffectDifferences(
        promptOnly: MeetingTruthABBranchResult,
        toolCalling: MeetingTruthABBranchResult
    ) -> [String] {
        var effects: [String] = []
        let promptBlocks = Set(promptOnly.ledger?.blockingItems ?? [])
        let toolBlocks = Set(toolCalling.ledger?.blockingItems ?? [])
        let addedBlocks = toolBlocks.subtracting(promptBlocks)
        let removedBlocks = promptBlocks.subtracting(toolBlocks)
        if toolCalling.verificationAnomalyCount > 0 {
            effects.append("核验异常：先修正工具裁决与最终 ledger 的一致性，再谈可信度提升。")
        }
        if promptOnly.finalCanonicalTextKeys == toolCalling.finalCanonicalTextKeys,
           !promptOnly.finalCanonicalTextKeys.isEmpty,
           toolCalling.verificationAnomalyCount == 0 {
            effects.append("本轮无明显收益：最终采信文本相同，证据核验没有改变高风险事实。")
        }
        if !addedBlocks.isEmpty {
            effects.append("证据核验新增阻塞项：\(addedBlocks.prefix(3).joined(separator: "；"))")
        }
        if !removedBlocks.isEmpty {
            effects.append("证据核验解除阻塞项：\(removedBlocks.prefix(3).joined(separator: "；"))")
        }
        let toolImpacts = toolCalling.ledger?.toolCallRecords
            .filter { $0.status == .executed }
            .map(\.impactSummary)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? []
        effects.append(contentsOf: toolImpacts.prefix(5))
        if effects.isEmpty {
            effects.append("两条路线当前没有产生可见结论差异；如果 endpoint 没有返回原生 tool_calls，请查看证据核验分支的工具执行流水。")
        }
        return effects
    }

    private func tokenUsageText(_ usage: MeetingTruthTokenUsage?) -> String {
        guard let usage, usage.hasContent else { return "endpoint 未返回" }
        if let total = usage.totalTokens {
            return "\(total)"
        }
        let prompt = usage.promptTokens.map(String.init) ?? "?"
        let completion = usage.completionTokens.map(String.init) ?? "?"
        return "\(prompt)+\(completion)"
    }

    private static func durationText(_ seconds: Double) -> String {
        if seconds < 1 {
            return "\(Int((seconds * 1000).rounded()))ms"
        }
        return "\(String(format: "%.2f", seconds))s"
    }

    func answerMeetingTruthUserQuestion(_ factID: UUID, answer: String) {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            setMeetingTruthError("请先填写你确认后的真实信息，再保存。")
            return
        }
        recordMeetingTruthConfirmation(for: factID, decision: .manualEdit, selectedText: trimmed)
        if let index = meetingTruthFactDecisions.firstIndex(where: { $0.factID == factID }) {
            meetingTruthFactDecisions[index].chosenText = trimmed
            meetingTruthFactDecisions[index].status = .confirmed
            meetingTruthFactDecisions[index].confidence = max(meetingTruthFactDecisions[index].confidence, 0.96)
            meetingTruthFactDecisions[index].reason = "用户已人工确认该事实。"
            meetingTruthFactDecisions[index].missingEvidence = []
            meetingTruthFactDecisions[index].requiresUserInput = false
        }
        if let fact = meetingTruthFactCandidates.first(where: { $0.id == factID }) {
            let atom = MeetingTruthEvidenceAtom(
                factID: factID,
                channel: .human,
                sourceName: "人工确认",
                supportsClaim: true,
                text: trimmed,
                visualCue: "",
                confidence: 0.98,
                weight: 0.45
            )
            meetingTruthEvidenceAtoms.removeAll {
                $0.factID == factID && $0.channel == .human && $0.sourceName == "人工确认"
            }
            meetingTruthEvidenceAtoms.append(atom)
            meetingTruthUserQuestions.removeAll { $0.factID == factID }
            refreshMeetingTruthCentralReviewLedger()
            meetingTruthAnalysis = nil
            meetingTruthValidationStatus = meetingTruthPendingFactQuestions.isEmpty
                ? "事实确认已完成，可以生成会议成果包"
                : "事实确认已保存，请继续处理剩余问题"
            meetingTruthError = nil
            lastError = nil
            recordMeetingTruthActivity(
                stage: .manualConfirmation,
                title: "事实确认已保存",
                message: "\(fact.kind.title)：\(trimmed)",
                details: "原始结论：\(fact.claim)"
            )
        }
        saveMeetingTruthProjects()
    }

    func deferMeetingTruthUserQuestion(_ factID: UUID) {
        guard let index = meetingTruthFactDecisions.firstIndex(where: { $0.factID == factID }) else { return }
        let fallbackText = meetingTruthFactDecisions[index].chosenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? meetingTruthFactDecisions[index].claim
            : meetingTruthFactDecisions[index].chosenText
        recordMeetingTruthConfirmation(for: factID, decision: .ignoredSuggestion, selectedText: fallbackText)
        meetingTruthFactDecisions[index].status = .lowConfidence
        meetingTruthFactDecisions[index].confidence = min(meetingTruthFactDecisions[index].confidence, 0.66)
        meetingTruthFactDecisions[index].reason = "用户选择暂不确认；该项保留为待确认提示，不阻塞成果包生成。"
        meetingTruthFactDecisions[index].missingEvidence = []
        meetingTruthFactDecisions[index].requiresUserInput = false
        meetingTruthUserQuestions.removeAll { $0.factID == factID }
        refreshMeetingTruthCentralReviewLedger()
        meetingTruthAnalysis = nil
        meetingTruthValidationStatus = meetingTruthPendingFactQuestions.isEmpty
            ? "未确认事实已标为待确认，可以生成会议成果包"
            : "已跳过该问题，请继续处理剩余问题"
        meetingTruthError = nil
        lastError = nil
        recordMeetingTruthActivity(
            stage: .manualConfirmation,
            title: "事实问题已标为待确认",
            message: fallbackText,
            details: "该项不会阻塞成果包生成"
        )
        saveMeetingTruthProjects()
    }

    func answerMeetingTruthCentralReviewClaim(_ claimID: UUID, answer: String) {
        let trimmed = Self.writableMeetingTruthConfirmationText(answer)
        guard !trimmed.isEmpty else {
            setMeetingTruthError("请先填写你确认后的真实信息，再保存。")
            return
        }
        guard var ledger = meetingTruthCentralReviewLedger,
              let index = ledger.claims.firstIndex(where: { $0.id == claimID }) else {
            setMeetingTruthError("没有找到这条中枢复核问题，请重新运行复核。")
            return
        }
        var claim = ledger.claims[index]
        claim.proposedCanonicalText = trimmed
        claim.status = .accepted
        claim.confidence = max(claim.confidence, 0.96)
        claim.missingEvidence = []
        claim.humanQuestion = nil
        claim.decisionReason = "用户已在多模态中枢复核中人工确认。"
        claim.supportingEvidence.removeAll { $0.channel == .human }
        claim.supportingEvidence.append(
            MeetingTruthCentralEvidence(
                channel: .human,
                sourceName: "人工确认",
                text: trimmed,
                visualCue: "",
                supportsClaim: true,
                confidence: 0.98,
                priority: 100
            )
        )
        recordMeetingTruthConfirmation(for: claimID, decision: .manualEdit, selectedText: trimmed)
        ledger.claims[index] = claim
        meetingTruthCentralReviewLedger = reconciledMeetingTruthCentralReviewLedger(ledger)
        meetingTruthAnalysis = nil
        meetingTruthValidationStatus = meetingTruthPendingCentralReviewClaims.isEmpty
            ? "中枢复核确认已完成，可以生成会议成果包"
            : "中枢复核确认已保存，请继续处理剩余问题"
        meetingTruthError = nil
        lastError = nil
        recordMeetingTruthActivity(
            stage: .manualConfirmation,
            title: "中枢复核确认已保存",
            message: "\(claim.kind.title)：\(trimmed)",
            details: claim.claim
        )
        saveMeetingTruthProjects()
    }

    func loadMeetingTruthDemo() {
        resetMeetingTruthProjectIdentity()
        meetingTruthMaterials = Self.demoMeetingTruthMaterials
        meetingTruthTranscriptSources = Self.demoMeetingTruthTranscriptSources
        meetingTruthConflicts = Self.demoMeetingTruthConflicts
        meetingTruthManualConfirmations = []
        resetMeetingTruthFactLedger()
        meetingTruthLastFailure = nil
        hasDiscoveredMeetingTruthConflicts = true
        meetingTruthValidationStatus = "已加载示例数据，可体验完整流程"
        meetingTruthAnalysis = nil
        meetingTruthError = nil
        lastError = nil
        meetingTruthActivityLog = []
        recordMeetingTruthActivity(stage: .restore, title: "已加载示例数据", message: "MeetingTruth 示例项目已载入")
        saveMeetingTruthProjects()
    }

    func clearMeetingTruthResults() {
        meetingTruthConflicts = []
        meetingTruthManualConfirmations = []
        resetMeetingTruthFactLedger()
        hasDiscoveredMeetingTruthConflicts = false
        meetingTruthAnalysis = nil
        meetingTruthVisualEvidence = []
        refreshMeetingTruthMultimodalComparisons()
        meetingTruthError = nil
        meetingTruthLastFailure = nil
        lastError = nil
        recordMeetingTruthActivity(stage: .generatePackage, title: "已清空成果", message: "冲突、确认结果和成果包已清空")
        meetingTruthValidationStatus = meetingTruthTranscriptSources.count >= 2
            ? "成果已清空，请重新运行冲突发现"
            : "成果已清空，请先导入至少两份候选转写"
        saveMeetingTruthProjects()
    }

    func resetMeetingTruthProject() {
        resetMeetingTruthProjectIdentity()
        meetingTruthMaterials = []
        meetingTruthTranscriptSources = []
        meetingTruthConflicts = []
        meetingTruthManualConfirmations = []
        resetMeetingTruthFactLedger()
        hasDiscoveredMeetingTruthConflicts = false
        meetingTruthValidationStatus = "请先导入真实会议资料和至少两份候选转写"
        meetingTruthAnalysis = nil
        meetingTruthError = nil
        meetingTruthLastFailure = nil
        lastError = nil
        meetingTruthActivityLog = []
        meetingTruthVisualEvidence = []
        meetingTruthMultimodalComparisons = []
        meetingTruthMultimodalMode = .fusedMultimodal
        meetingTruthArbitrationConfig = MeetingTruthArbitrationConfig()
        selectedAudioPath = ""
        recordMeetingTruthActivity(stage: .restore, title: "项目已清空", message: "MeetingTruth 项目状态已重置")
        saveMeetingTruthProjects()
    }

    func importMeetingTruthMaterials(from sourceURLs: [URL]) {
        guard !sourceURLs.isEmpty else { return }
        var importedMaterials: [MeetingTruthMaterial] = []
        var importedTranscripts: [MeetingTruthTranscriptSource] = []

        for sourceURL in sourceURLs {
            if let transcriptSource = meetingTruthTranscriptSource(from: sourceURL, requireTranscriptSignature: true) {
                importedTranscripts.append(transcriptSource)
            } else {
                if Self.isAudioMaterial(sourceURL) {
                    importAudioForTesting(from: sourceURL)
                }
                importedMaterials.append(extractedMeetingTruthMaterial(from: sourceURL))
            }
        }

        guard !importedMaterials.isEmpty || !importedTranscripts.isEmpty else {
            setMeetingTruthError("没有读取到可导入的会议资料或候选转写。", stage: .importMaterials)
            return
        }

        meetingTruthMaterials = importedMaterials
        if !importedTranscripts.isEmpty {
            meetingTruthTranscriptSources = importedTranscripts
        }
        if importedTranscripts.isEmpty {
            meetingTruthValidationStatus = "资料已导入，请继续导入至少两份候选转写"
        } else if meetingTruthTranscriptSources.count >= 2 {
            meetingTruthValidationStatus = importedMaterials.isEmpty
                ? "已自动识别 \(importedTranscripts.count) 份候选转写，请让 Gemma 4 发现冲突"
                : "已导入 \(importedMaterials.count) 份资料，并自动识别 \(importedTranscripts.count) 份候选转写"
        } else {
            meetingTruthValidationStatus = "已自动识别 1 份候选转写，还需要至少 1 份候选转写"
        }
        meetingTruthConflicts = []
        meetingTruthManualConfirmations = []
        resetMeetingTruthFactLedger()
        hasDiscoveredMeetingTruthConflicts = false
        meetingTruthAnalysis = nil
        meetingTruthVisualEvidence = []
        refreshMeetingTruthMultimodalComparisons()
        meetingTruthError = nil
        meetingTruthLastFailure = nil
        lastError = nil
        if !importedMaterials.isEmpty {
            recordMeetingTruthActivity(
                stage: .importMaterials,
                title: "已导入会议资料",
                message: "共导入 \(importedMaterials.count) 份资料",
                details: importedMaterials.map(\.name).joined(separator: "、")
            )
        }
        if !importedTranscripts.isEmpty {
            recordMeetingTruthActivity(
                stage: .importTranscripts,
                title: "已自动识别候选转写",
                message: "共导入 \(importedTranscripts.count) 份候选转写",
                details: importedTranscripts.map(\.name).joined(separator: "、")
            )
        }
        saveMeetingTruthProjects()
    }

    func importMeetingTruthImageFromClipboard() {
        guard let image = NSImage(pasteboard: .general) else {
            setMeetingTruthError("剪贴板中没有可导入的图片。请先复制截图或图片，再重试。", stage: .importMaterials)
            return
        }
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            setMeetingTruthError("剪贴板图片无法转换为 PNG，请尝试重新复制图片。", stage: .importMaterials)
            return
        }
        do {
            let directory = try meetingTruthClipboardDirectory()
            let url = directory.appendingPathComponent("剪贴板图片-\(Int(Date().timeIntervalSince1970)).png")
            try pngData.write(to: url, options: .atomic)
            meetingTruthMaterials.append(extractedMeetingTruthMaterial(from: url))
            meetingTruthConflicts = []
            meetingTruthManualConfirmations = []
            resetMeetingTruthFactLedger()
            hasDiscoveredMeetingTruthConflicts = false
            meetingTruthAnalysis = nil
            meetingTruthVisualEvidence = []
            refreshMeetingTruthMultimodalComparisons()
            meetingTruthValidationStatus = "已导入剪贴板图片，请继续导入候选转写或运行冲突发现"
            meetingTruthError = nil
            meetingTruthLastFailure = nil
            lastError = nil
            recordMeetingTruthActivity(stage: .importMaterials, title: "已导入剪贴板图片", message: "已从剪贴板保存 1 张图片资料", details: url.lastPathComponent)
            saveMeetingTruthProjects()
        } catch {
            setMeetingTruthError("剪贴板图片保存失败：\(error.localizedDescription)", stage: .importMaterials)
        }
    }

    func removeMeetingTruthMaterial(_ materialID: UUID) {
        guard let index = meetingTruthMaterials.firstIndex(where: { $0.id == materialID }) else { return }
        let removed = meetingTruthMaterials.remove(at: index)
        if removed.kind == "会议录音", selectedAudioPath == removed.localPath {
            selectedAudioPath = ""
        }
        meetingTruthConflicts = []
        meetingTruthManualConfirmations = []
        resetMeetingTruthFactLedger()
        hasDiscoveredMeetingTruthConflicts = false
        meetingTruthAnalysis = nil
        meetingTruthVisualEvidence.removeAll { $0.materialID == removed.id }
        refreshMeetingTruthMultimodalComparisons()
        meetingTruthError = nil
        meetingTruthLastFailure = nil
        lastError = nil
        meetingTruthValidationStatus = meetingTruthMaterials.isEmpty
            ? "资料已清空，请重新导入会议资料和至少两份候选转写"
            : "资料已更新，请重新运行冲突发现"
        recordMeetingTruthActivity(
            stage: .importMaterials,
            title: "已删除会议资料",
            message: "已删除 1 份资料：\(removed.name)"
        )
        saveMeetingTruthProjects()
    }

    func importMeetingTruthTranscriptSources(from sourceURLs: [URL]) {
        let sources = sourceURLs.compactMap { sourceURL -> MeetingTruthTranscriptSource? in
            meetingTruthTranscriptSource(from: sourceURL, requireTranscriptSignature: false)
        }
        guard !sources.isEmpty else {
            setMeetingTruthError("没有读取到候选转写文本。请导入 UTF-8 编码的 txt、md、json 或 csv 文件。", stage: .importTranscripts)
            return
        }
        meetingTruthTranscriptSources = sources
        meetingTruthConflicts = []
        meetingTruthManualConfirmations = []
        resetMeetingTruthFactLedger()
        hasDiscoveredMeetingTruthConflicts = false
        meetingTruthAnalysis = nil
        refreshMeetingTruthMultimodalComparisons()
        meetingTruthValidationStatus = "候选转写已导入，请让 Gemma 4 发现冲突"
        meetingTruthError = nil
        meetingTruthLastFailure = nil
        lastError = nil
        recordMeetingTruthActivity(
            stage: .importTranscripts,
            title: "已导入候选转写",
            message: "共导入 \(sources.count) 份候选转写",
            details: sources.map(\.name).joined(separator: "、")
        )
        saveMeetingTruthProjects()
    }

    func useLocalASRRunsForMeetingTruth() {
        let sources = completedRuns.map {
            MeetingTruthTranscriptSource(name: $0.modelName, text: $0.cleanTranscriptPreview)
        }
        guard sources.count >= 2 else {
            setMeetingTruthError("至少需要两条有效的本地 ASR 结果。请先到实验台选择多个模型完成转写。", stage: .importTranscripts)
            return
        }
        meetingTruthTranscriptSources = sources
        meetingTruthConflicts = []
        meetingTruthManualConfirmations = []
        resetMeetingTruthFactLedger()
        hasDiscoveredMeetingTruthConflicts = false
        meetingTruthAnalysis = nil
        refreshMeetingTruthMultimodalComparisons()
        meetingTruthValidationStatus = "已载入本地 ASR 结果，请让 Gemma 4 发现冲突"
        meetingTruthError = nil
        meetingTruthLastFailure = nil
        lastError = nil
        recordMeetingTruthActivity(
            stage: .importTranscripts,
            title: "已载入本地 ASR 结果",
            message: "共载入 \(sources.count) 条当前结果",
            details: sources.map(\.name).joined(separator: "、")
        )
        saveMeetingTruthProjects()
    }

    @discardableResult
    func importMeetingTruthHistoricalASRResults(ids: Set<String>) -> Bool {
        let selectedResults = meetingTruthHistoricalASRResults.filter { ids.contains($0.id) }
        guard selectedResults.count >= 2 else {
            setMeetingTruthError("请至少选择两条本地 ASR 历史结果。", stage: .importTranscripts)
            return false
        }

        let audioPaths = Set(selectedResults.map(\.audioPath))
        guard audioPaths.count == 1, let audioPath = audioPaths.first else {
            setMeetingTruthError("一次语义校验只能使用同一段会议录音的 ASR 结果。请重新选择。", stage: .importTranscripts)
            return false
        }

        meetingTruthTranscriptSources = selectedResults.map {
            let timestampLabel = Self.historyDateFormatter.string(from: $0.createdAt)
            return MeetingTruthTranscriptSource(
                name: "\($0.modelName) · \(timestampLabel)",
                text: $0.text
            )
        }
        selectedAudioPath = audioPath
        meetingTruthConflicts = []
        meetingTruthManualConfirmations = []
        resetMeetingTruthFactLedger()
        hasDiscoveredMeetingTruthConflicts = false
        meetingTruthAnalysis = nil
        refreshMeetingTruthMultimodalComparisons()
        meetingTruthValidationStatus = "已载入 \(selectedResults.count) 条本地 ASR 历史结果，请让 Gemma 4 发现冲突"
        meetingTruthError = nil
        meetingTruthLastFailure = nil
        lastError = nil
        recordMeetingTruthActivity(
            stage: .importTranscripts,
            title: "已载入本地 ASR 历史",
            message: "共载入 \(selectedResults.count) 条历史转写",
            details: selectedResults.map(\.modelName).joined(separator: "、")
        )
        saveMeetingTruthProjects()
        return true
    }

    func setMeetingTruthMultimodalMode(_ mode: MeetingTruthMultimodalMode) {
        meetingTruthMultimodalMode = mode
        meetingTruthAnalysis = nil
        meetingTruthValidationStatus = "已切换到「\(mode.title)」：\(mode.shortDescription)"
        refreshMeetingTruthMultimodalComparisons()
        saveMeetingTruthProjects()
    }

    func updateMeetingTruthArbitrationConfig(_ update: (inout MeetingTruthArbitrationConfig) -> Void) {
        update(&meetingTruthArbitrationConfig)
        meetingTruthArbitrationConfig.asrConsensusWeight = min(max(meetingTruthArbitrationConfig.asrConsensusWeight, 0), 1)
        meetingTruthArbitrationConfig.visualEvidenceWeight = min(max(meetingTruthArbitrationConfig.visualEvidenceWeight, 0), 1)
        meetingTruthArbitrationConfig.ocrEvidenceWeight = min(max(meetingTruthArbitrationConfig.ocrEvidenceWeight, 0), 1)
        meetingTruthArbitrationConfig.textMaterialWeight = min(max(meetingTruthArbitrationConfig.textMaterialWeight, 0), 1)
        meetingTruthArbitrationConfig.humanReviewThreshold = min(max(meetingTruthArbitrationConfig.humanReviewThreshold, 0.3), 0.95)
        meetingTruthArbitrationConfig.highRiskPenalty = min(max(meetingTruthArbitrationConfig.highRiskPenalty, 0), 0.5)
        if !meetingTruthFactCandidates.isEmpty || !meetingTruthFactDecisions.isEmpty {
            refreshMeetingTruthFactReviewLedger()
        }
        meetingTruthValidationStatus = "仲裁参数已更新，决策账本已按新权重重算"
        saveMeetingTruthProjects()
    }

    func resetMeetingTruthArbitrationConfig() {
        meetingTruthArbitrationConfig = MeetingTruthArbitrationConfig()
        if !meetingTruthFactCandidates.isEmpty || !meetingTruthFactDecisions.isEmpty {
            refreshMeetingTruthFactReviewLedger()
        }
        meetingTruthValidationStatus = "仲裁参数已恢复默认"
        saveMeetingTruthProjects()
    }

    func extractMeetingTruthVisualEvidenceWithGemma() {
        guard !isMeetingTruthTaskRunning else { return }
        guard !meetingTruthImageMaterials.isEmpty else {
            setMeetingTruthError("当前没有可供 Gemma 4 读取的图片材料。", stage: .importMaterials)
            return
        }
        currentMeetingTruthTask?.cancel()
        currentMeetingTruthTaskGeneration += 1
        let taskGeneration = currentMeetingTruthTaskGeneration
        isExtractingMeetingTruthVisualEvidence = true
        meetingTruthValidationStatus = "Gemma 4 正在读取图片并生成视觉证据"
        meetingTruthError = nil
        lastError = nil

        let materials = meetingTruthMaterials
        let sources = meetingTruthTranscriptSources
        let settings = meetingAISettings
        currentMeetingTruthTask = Task { @MainActor in
            defer {
                if currentMeetingTruthTaskGeneration == taskGeneration {
                    isExtractingMeetingTruthVisualEvidence = false
                    currentMeetingTruthTask = nil
                }
            }
            do {
                meetingTruthVisualEvidence = try await meetingAIService.extractVisualEvidence(
                    materials: materials,
                    transcriptHints: sources,
                    settings: settings
                )
                guard !Task.isCancelled else { return }
                let addedPersonConflicts = refreshMeetingTruthParticipantEvidenceConflicts()
                if !meetingTruthFactCandidates.isEmpty || !meetingTruthFactDecisions.isEmpty {
                    refreshMeetingTruthFactReviewLedger()
                } else {
                    refreshMeetingTruthCentralReviewLedger()
                }
                refreshMeetingTruthMultimodalComparisons()
                meetingTruthLastFailure = nil
                if meetingTruthVisualEvidence.isEmpty {
                    meetingTruthValidationStatus = "Gemma 4 未从图片中提取到稳定视觉证据"
                } else if addedPersonConflicts > 0 {
                    meetingTruthValidationStatus = "Gemma 4 已提取图片证据，并生成 \(addedPersonConflicts) 条人名修正待确认"
                } else {
                    meetingTruthValidationStatus = "Gemma 4 已提取 \(meetingTruthVisualEvidence.count) 条图片视觉证据"
                }
                recordMeetingTruthActivity(
                    stage: .multimodalEvidence,
                    title: "Gemma 4 图片证据已生成",
                    message: addedPersonConflicts > 0
                        ? "已生成 \(addedPersonConflicts) 条可确认人名修正"
                        : (meetingTruthVisualEvidence.isEmpty
                        ? "未提取到稳定图片证据"
                        : "已生成 \(meetingTruthVisualEvidence.count) 条可展示视觉证据"),
                    details: meetingTruthVisualEvidence.map(\.materialName).joined(separator: "、")
                )
                saveMeetingTruthProjects()
            } catch {
                guard !Task.isCancelled else { return }
                meetingTruthValidationStatus = "Gemma 4 图片证据提取失败"
                setMeetingTruthError(error.localizedDescription, stage: .importMaterials)
            }
        }
    }

    func setMeetingTruthVisualEvidenceForASR(_ evidenceID: UUID, enabled: Bool) {
        guard let index = meetingTruthVisualEvidence.firstIndex(where: { $0.id == evidenceID }) else { return }
        meetingTruthVisualEvidence[index].useForASRIteration = enabled
        refreshMeetingTruthMultimodalComparisons()
        refreshMeetingTruthCentralReviewLedger()
        saveMeetingTruthProjects()
    }

    @discardableResult
    func applyMeetingTruthVisualEvidenceToASRHotwords() -> Bool {
        let terms = meetingTruthASRIterationTerms
        guard !terms.isEmpty else {
            setMeetingTruthError("没有已确认可用于 ASR 迭代的图片证据。请先打开高可信证据，或人工确认中/低可信证据。", stage: .importMaterials)
            return false
        }

        let setName = "Gemma 4 多模态证据热词"
        if let index = hotwordSets.firstIndex(where: { $0.name == setName }) {
            hotwordSets[index].words = terms
            hotwordSets[index].weight = max(hotwordSets[index].weight, 1.5)
            hotwordSets[index].isEnabled = true
        } else {
            hotwordSets.append(
                HotwordSet(
                    id: UUID(),
                    name: setName,
                    words: terms,
                    weight: 1.5,
                    isEnabled: true
                )
            )
        }
        meetingTruthValidationStatus = "已将 \(terms.count) 个多模态证据词写入 ASR 热词，可用于下一轮转写"
        recordMeetingTruthActivity(
            stage: .multimodalEvidence,
            title: "多模态证据已写入 ASR 热词",
            message: "已启用 \(terms.count) 个证据词用于 ASR 迭代",
            details: terms.joined(separator: "、")
        )
        saveMeetingTruthProjects()
        return true
    }

    func applyMeetingTruthVisualEvidenceAndRerunASR() {
        guard applyMeetingTruthVisualEvidenceToASRHotwords() else { return }
        guard !selectedAudioPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            setMeetingTruthError("没有关联录音，已生成热词但无法自动重跑 ASR。", stage: .importTranscripts)
            return
        }
        guard !isRunning else {
            setMeetingTruthError("ASR 正在运行，请结束当前任务后再重跑。", stage: .importTranscripts)
            return
        }
        meetingTruthValidationStatus = "正在用多模态证据热词重跑 ASR"
        runComparison()
    }

    func resolveMeetingTruthConflictsWithGemma() {
        guard !isMeetingTruthTaskRunning else { return }
        guard !meetingTruthConflicts.isEmpty else {
            setMeetingTruthError("当前没有可校验的冲突。请先导入候选转写并运行冲突发现。", stage: .resolveConflicts)
            return
        }
        currentMeetingTruthTask?.cancel()
        currentMeetingTruthTaskGeneration += 1
        let taskGeneration = currentMeetingTruthTaskGeneration
        isResolvingMeetingTruthConflicts = true
        meetingTruthValidationStatus = "Gemma 4 正在交叉验证材料和转写"
        meetingTruthError = nil
        lastError = nil

        let conflicts = meetingTruthConflicts
        let materials = meetingTruthContextMaterials
        let settings = meetingAISettings
        currentMeetingTruthTask = Task { @MainActor in
            defer {
                if currentMeetingTruthTaskGeneration == taskGeneration {
                    isResolvingMeetingTruthConflicts = false
                    currentMeetingTruthTask = nil
                }
            }
            do {
                meetingTruthConflicts = try await meetingAIService.resolveConflicts(
                    conflicts: conflicts,
                    materials: materials,
                    settings: settings
                )
                guard !Task.isCancelled else { return }
                if !meetingTruthFactCandidates.isEmpty || !meetingTruthFactDecisions.isEmpty {
                    refreshMeetingTruthFactReviewLedger()
                } else {
                    refreshMeetingTruthCentralReviewLedger()
                }
                meetingTruthLastFailure = nil
                meetingTruthValidationStatus = "Gemma 4 校验完成，请确认低置信片段"
                recordMeetingTruthActivity(
                    stage: .resolveConflicts,
                    title: "Gemma 校验完成",
                    message: "已更新 \(meetingTruthConflicts.count) 条冲突建议"
                )
                saveMeetingTruthProjects()
            } catch {
                guard !Task.isCancelled else { return }
                meetingTruthValidationStatus = "Gemma 4 校验失败"
                setMeetingTruthError(error.localizedDescription, stage: .resolveConflicts)
            }
        }
    }

    func discoverMeetingTruthConflictsWithGemma() {
        guard !isMeetingTruthTaskRunning else { return }
        guard meetingTruthTranscriptSources.count >= 2 else {
            setMeetingTruthError("至少需要导入两份候选转写，才能发现多源冲突。", stage: .discoverConflicts)
            return
        }
        currentMeetingTruthTask?.cancel()
        currentMeetingTruthTaskGeneration += 1
        let taskGeneration = currentMeetingTruthTaskGeneration
        isDiscoveringMeetingTruthConflicts = true
        meetingTruthValidationStatus = "Gemma 4 正在比对候选转写，随后会带冲突回看全文"
        meetingTruthError = nil
        lastError = nil

        let sources = meetingTruthTranscriptSources
        let settings = meetingAISettings
        let mode = meetingTruthMultimodalMode
        currentMeetingTruthTask = Task { @MainActor in
            defer {
                if currentMeetingTruthTaskGeneration == taskGeneration {
                    isDiscoveringMeetingTruthConflicts = false
                    currentMeetingTruthTask = nil
                }
            }
            do {
                if (mode == .visionSeparate || mode == .fusedMultimodal),
                   !meetingTruthImageMaterials.isEmpty,
                   meetingTruthVisualEvidence.isEmpty {
                    meetingTruthValidationStatus = "Gemma 4 正在先读取图片参会人员和视觉证据"
                    isExtractingMeetingTruthVisualEvidence = true
                    defer { isExtractingMeetingTruthVisualEvidence = false }
                    meetingTruthVisualEvidence = try await meetingAIService.extractVisualEvidence(
                        materials: meetingTruthMaterials,
                        transcriptHints: sources,
                        settings: settings
                    )
                    guard !Task.isCancelled else { return }
                    refreshMeetingTruthMultimodalComparisons()
                }
                let materials = meetingTruthContextMaterials(for: mode)
                meetingTruthConflicts = try await meetingAIService.discoverConflicts(
                    sources: sources,
                    materials: materials,
                    settings: settings,
                    progress: { progress in
                        await MainActor.run {
                            self.meetingTruthValidationStatus = progress.statusText
                        }
                    }
                )
                guard !Task.isCancelled else { return }
                let addedPersonConflicts = refreshMeetingTruthParticipantEvidenceConflicts()
                meetingTruthManualConfirmations = []
                resetMeetingTruthFactLedger()
                refreshMeetingTruthCentralReviewLedger()
                meetingTruthAnalysis = nil
                meetingTruthLastFailure = nil
                hasDiscoveredMeetingTruthConflicts = true
                meetingTruthValidationStatus = meetingTruthConflicts.isEmpty
                    ? "Gemma 4 未发现需要确认的冲突"
                    : (addedPersonConflicts > 0
                        ? "Gemma 4 已发现并全文复核冲突，另根据图片人名证据生成 \(addedPersonConflicts) 条待确认修正"
                        : "Gemma 4 已发现并全文复核 \(meetingTruthConflicts.count) 个冲突，请确认剩余低置信项")
                recordMeetingTruthActivity(
                    stage: .discoverConflicts,
                    title: "Gemma 冲突发现与全文复核完成",
                    message: meetingTruthConflicts.isEmpty
                        ? "未发现需要确认的冲突"
                        : (addedPersonConflicts > 0
                            ? "共识别并复核 \(meetingTruthConflicts.count) 个冲突片段，其中 \(addedPersonConflicts) 个来自图片人名证据"
                            : "共识别并复核 \(meetingTruthConflicts.count) 个冲突片段")
                )
                saveMeetingTruthProjects()
            } catch {
                guard !Task.isCancelled else { return }
                meetingTruthValidationStatus = "Gemma 4 冲突发现失败"
                setMeetingTruthError(error.localizedDescription, stage: .discoverConflicts)
            }
        }
    }

    private func meetingTruthBlockingConflictsForGeneration() -> [MeetingTruthConflict] {
        meetingTruthConflicts.filter { conflict in
            guard conflict.kind != .ordinaryExpression else { return false }
            switch conflict.reviewStatus {
            case .suggestedApplied, .ignoredLowRisk, .markedIrrelevant, .deferredForCentralReview:
                return false
            case .replacementValidationFailed:
                return meetingTruthConflictAffectsCoreOutput(conflict)
            case .evidenceConflicted, .needsHumanReview:
                return true
            case .pending, .none:
                break
            }
            if let validation = conflict.replacementValidationResult,
               !validation.isValid,
               meetingTruthConflictAffectsCoreOutput(conflict) {
                return true
            }
            if conflict.isResolved { return false }
            if conflict.requiresHumanReview { return true }
            guard conflict.confidence == .low else { return false }
            switch conflict.kind {
            case .person, .amount, .date, .project, .system, .actionItem:
                return true
            case .terminology, .decision:
                return meetingTruthConflictAffectsCoreOutput(conflict)
            case .ordinaryExpression:
                return false
            }
        }
    }

    private func meetingTruthConflictAffectsCoreOutput(_ conflict: MeetingTruthConflict) -> Bool {
        let outputs = conflict.affectedOutputs ?? [.minutes]
        return outputs.contains(.minutes) ||
            outputs.contains(.actionItems) ||
            outputs.contains(.participants) ||
            outputs.contains(.projectNames)
    }

    func generateMeetingTruthPackage() {
        guard !isMeetingTruthTaskRunning else { return }
        guard hasDiscoveredMeetingTruthConflicts else {
            setMeetingTruthError("请先运行冲突发现，再生成会议成果包。", stage: .generatePackage)
            return
        }
        currentMeetingTruthTask?.cancel()
        currentMeetingTruthTaskGeneration += 1
        let taskGeneration = currentMeetingTruthTaskGeneration
        isGeneratingMeetingTruthPackage = true
        meetingTruthValidationStatus = "Gemma 4 正在生成会议成果包"
        meetingTruthError = nil
        lastError = nil

        let settings = meetingAISettings
        let mode = meetingTruthMultimodalMode
        currentMeetingTruthTask = Task { @MainActor in
            defer {
                if currentMeetingTruthTaskGeneration == taskGeneration {
                    isGeneratingMeetingTruthPackage = false
                    currentMeetingTruthTask = nil
                }
            }
            do {
                if (mode == .visionSeparate || mode == .fusedMultimodal),
                   !meetingTruthImageMaterials.isEmpty,
                   meetingTruthVisualEvidence.isEmpty {
                    meetingTruthValidationStatus = "Gemma 4 正在先读取图片证据"
                    meetingTruthVisualEvidence = try await meetingAIService.extractVisualEvidence(
                        materials: meetingTruthMaterials,
                        transcriptHints: meetingTruthTranscriptSources,
                        settings: settings
                    )
                    guard !Task.isCancelled else { return }
                    refreshMeetingTruthMultimodalComparisons()
                }
                let addedPersonConflicts = refreshMeetingTruthParticipantEvidenceConflicts()
                if addedPersonConflicts > 0 {
                    refreshMeetingTruthMultimodalComparisons()
                    meetingTruthValidationStatus = "图片人名证据生成了 \(addedPersonConflicts) 条修正，请先确认后再生成"
                    setMeetingTruthError("图片中识别到的人名和主底稿疑似不一致，已生成 \(addedPersonConflicts) 条人名修正卡。请先确认这些修正，再生成会议成果包。", stage: .generatePackage)
                    return
                }
                let blockingConflicts = meetingTruthBlockingConflictsForGeneration()
                guard blockingConflicts.isEmpty else {
                    let preview = blockingConflicts.prefix(3).map { conflict in
                        "\(conflict.kind.title)：\(conflict.candidates.map(\.text).prefix(3).joined(separator: " / "))"
                    }.joined(separator: "\n")
                    meetingTruthValidationStatus = "还有 \(blockingConflicts.count) 个高风险事项需要确认"
                    setMeetingTruthError("请先在「需要你确认的高风险事项」里处理这些问题，再生成会议成果包。\n\(preview)", stage: .generatePackage)
                    return
                }
                let transcript = meetingTruthTrustedTranscript
                guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    setMeetingTruthError("没有可用于生成成果包的可信逐字稿。", stage: .generatePackage)
                    return
                }
                meetingTruthValidationStatus = "正在进行事实级多模态复核"
                let pendingFactQuestions = refreshMeetingTruthFactReviewLedger()
                guard pendingFactQuestions.isEmpty else {
                    let preview = pendingFactQuestions.prefix(3).map(\.question).joined(separator: "\n")
                    meetingTruthValidationStatus = "事实复核发现 \(pendingFactQuestions.count) 个问题需要确认"
                    setMeetingTruthError("事实复核发现 \(pendingFactQuestions.count) 个高风险或重要事实证据不足。请先在「确认修改」里回答这些问题，再生成会议成果包。\n\(preview)", stage: .generatePackage)
                    return
                }
                meetingTruthValidationStatus = "Gemma 4 正在执行多模态中枢复核"
                let centralLedger = try await refreshMeetingTruthCentralReviewWithGemma()
                guard !Task.isCancelled else { return }
                let centralBlocks = centralLedger.blockingItems
                guard centralBlocks.isEmpty else {
                    let preview = centralBlocks.prefix(4).joined(separator: "\n")
                    meetingTruthValidationStatus = "多模态中枢复核发现 \(centralBlocks.count) 个阻塞项"
                    setMeetingTruthError("多模态中枢复核尚未通过。请先处理这些会影响成果包正确性的事实冲突或证据链断点，再生成会议成果包。\n\(preview)", stage: .generatePackage)
                    return
                }
                let centralAdvisories = centralLedger.advisoryItems
                let materials = meetingTruthContextMaterials(for: mode)
                let primarySourceName = meetingTruthPrimaryTranscriptSource?.name ?? "自动选择的主底稿"
                let anchorSourceName = meetingTruthTimestampAnchorSource?.name ?? "无可用时间戳锚点"
                let acceptedFactLedger = meetingTruthAcceptedFactLedgerText()
                let rejectedFactLedger = meetingTruthRejectedFactLedgerText()
                let confirmedContext = meetingTruthConfirmedContextText.trimmingCharacters(in: .whitespacesAndNewlines)
                let generatedAnalysis = try await meetingAIService.analyze(
                    transcript: transcript,
                    materials: materials,
                    settings: settings,
                    refinementInstructions: """
                    当前参赛多模态模式：\(mode.title)。
                    \(mode.shortDescription)
                    转写证据角色：\(primarySourceName) 是主底稿；\(anchorSourceName) 只作为定位锚点或交叉对照，不要把时间戳写入逐字稿正文。
                    系统会把当前可信逐字稿作为成果包第 1 部分直接保留；你不要重写逐字稿，也不要把后续成果压成短摘要。
                    图片中提取的参会人员/人名是高优先级实体证据。人名、角色、组织、项目名必须和图片参会人员、OCR、文本材料及 ASR 候选交叉核对；证据不足时明确写入 evidenceNotes 或保持待确认，不要猜。
                    以下“已确认会议信息”来自用户确认或正式材料，不是 ASR 猜测。它是用于校对人名、角色、会议背景和证据来源的事实证据库，不是必须全量写入正文的清单。只在与纪要、摘要、要点、待办直接相关时引用相关项；多人名只引用本条结论实际涉及的人，不要把整份名单硬塞进无关段落：
                    \(confirmedContext.isEmpty ? "无" : confirmedContext)

                    这次多模态不是“图片 OCR 转文字后再汇总”。图片 OCR 只能作为基线对照；只有直接依赖 image_url 原图中的版式层级、表格结构、圈注/箭头/框选、手写位置、空间靠近关系或截图界面状态的结论，才能标记为“图片原图”或“多模态融合”。
                    对每条引用图片的 evidenceNotes，必须写清楚它用到的原图视觉事实，例如“箭头指向某任务”“被圈出的姓名”“表格中某列和某负责人同行”“便签位于风险区域”。如果只读到了图片里的普通文字，请标为“OCR 基线/文本”，不要伪装成多模态。
                    请生成完整的正式会议纪要、思维导图、会后一页纸、关键要点和待办事项。正式纪要和思维导图必须覆盖逐字稿中的主要议题。
                    请在 evidenceNotes 中明确说明每条重要结论分别来自：ASR 转写、Gemma 4 图片证据摘要、图片原图 image_url、文本材料，或多模态融合判断。
                    只有在多模态同时融合模式下，才能把图片原图、图片证据摘要和转写文本共同作为同一结论的依据；不得编造图片中未出现或转写中未确认的信息。

                    事实复核硬门禁已经完成。下面是本次成果包允许使用的事实白名单，只能围绕这些已采信或人工确认事实生成正式纪要、思维导图、要点和待办：
                    \(acceptedFactLedger)

                    以下事实不得作为正式结论写入成果包；低重要性无证据事实可以省略，高风险或冲突事实必须等待人工确认：
                    \(rejectedFactLedger)

                    以下是中枢复核发现但不阻塞纪要生成的提示缺口。它们不得被写成已确认事实；如果与纪要、待办或会后一页纸相关，只能标为“待确认”“需补充”或作为依据说明：
                    \(centralAdvisories.isEmpty ? "无" : centralAdvisories.joined(separator: "\n"))
                    """
                )
                guard !Task.isCancelled else { return }
                meetingTruthAnalysis = generatedAnalysis
                meetingTruthLastFailure = nil
                meetingTruthValidationStatus = "Gemma 4 正在复检成果包证据链"
                let postLedger = try await refreshMeetingTruthCentralReviewWithGemma()
                guard !Task.isCancelled else { return }
                let postBlocks = postLedger.blockingItems
                guard postBlocks.isEmpty else {
                    let preview = postBlocks.prefix(4).joined(separator: "\n")
                    meetingTruthValidationStatus = "成果包复检发现 \(postBlocks.count) 个阻塞项"
                    setMeetingTruthError("成果包已生成，但中枢复检发现仍有会影响成果包正确性的事实冲突或证据链断点。请处理后重新生成。\n\(preview)", stage: .generatePackage)
                    return
                }
                meetingTruthValidationStatus = "会议成果包已生成"
                recordMeetingTruthActivity(
                    stage: .generatePackage,
                    title: "会议成果包已生成",
                    message: "已生成可信逐字稿、正式纪要、思维导图、摘要、要点和待办"
                )
                saveMeetingTruthProjects()
            } catch {
                guard !Task.isCancelled else { return }
                meetingTruthValidationStatus = packageGenerationFailureStatus(for: error)
                setMeetingTruthError(error.localizedDescription, stage: .generatePackage)
            }
        }
    }

    func dismissMeetingTruthError() {
        meetingTruthError = nil
        lastError = nil
        saveMeetingTruthProjects()
    }

    func importAudioForTesting(from sourceURL: URL) {
        do {
            let importedURL = try copyAudioIntoAppStorage(sourceURL)
            selectedAudioPath = importedURL.path
            activeTaskTitle = "测试音频已导入"
            currentStage = "已缓存到应用目录"
            lastError = nil
        } catch {
            selectedAudioPath = sourceURL.path
            lastError = "音频导入失败，已临时使用原路径：\(error.localizedDescription)"
        }
    }

    private static let demoMeetingTruthMaterials: [MeetingTruthMaterial] = [
        MeetingTruthMaterial(name: "项目推进会录音.wav", kind: "会议录音", detail: "18:42 · 本地导入"),
        MeetingTruthMaterial(name: "数字金融战略规划.pdf", kind: "会议材料", detail: "12 页 · 已建立证据索引", extractedText: "材料标题：数字金融战略规划"),
        MeetingTruthMaterial(name: "项目术语表.txt", kind: "术语表", detail: "36 个术语 · 已启用", extractedText: "数字金融战略规划"),
        MeetingTruthMaterial(name: "群聊补充截图.png", kind: "图片", detail: "1 张 · 待 Gemma 4 读取")
    ]

    private static let demoMeetingTruthTranscriptSources: [MeetingTruthTranscriptSource] = [
        MeetingTruthTranscriptSource(name: "GLM-ASR", text: "00:03:12 我们下一阶段要推进数据金融战略规划。00:05:20 一期预算先按照 300 万元测算。00:08:45 预算测算依据由张珊补充。"),
        MeetingTruthTranscriptSource(name: "Qwen3-ASR", text: "00:03:12 我们下一阶段要推进数字金融战略规划。00:05:20 一期预算先按照 1300 万元测算。00:08:45 预算测算依据由张三补充。"),
        MeetingTruthTranscriptSource(name: "SenseVoice", text: "00:03:12 我们下一阶段要推进数字经营战略规划。00:05:20 一期预算先按照 30 万元测算。00:08:45 预算测算依据由张山补充。")
    ]

    private static func meetingTruthMaterialKind(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        if ["wav", "mp3", "m4a", "aiff", "aac", "flac"].contains(ext) {
            return "会议录音"
        }
        if ["pdf", "ppt", "pptx", "key"].contains(ext) {
            return "会议材料"
        }
        if ["png", "jpg", "jpeg", "heic", "webp"].contains(ext) {
            return "图片"
        }
        if ["txt", "md", "csv", "json"].contains(ext) {
            return "文本 / 术语表"
        }
        return "补充材料"
    }

    private static func isAudioMaterial(_ url: URL) -> Bool {
        meetingTruthMaterialKind(for: url) == "会议录音"
    }

    private func extractedMeetingTruthMaterial(from sourceURL: URL) -> MeetingTruthMaterial {
        let kind = Self.meetingTruthMaterialKind(for: sourceURL)
        let extractedText: String
        if sourceURL.pathExtension.lowercased() == "pdf" {
            extractedText = extractPDFText(from: sourceURL)
        } else if kind == "文本 / 术语表" {
            extractedText = readTextFile(from: sourceURL) ?? ""
        } else if kind == "图片" {
            extractedText = extractImageOCRText(from: sourceURL)
        } else {
            extractedText = ""
        }
        let detail: String
        if kind == "图片" {
            detail = extractedText.isEmpty
                ? "已导入 · 原图送入 Gemma 4；本机 OCR 未读出稳定文本"
                : "已导入 · 原图送入 Gemma 4；OCR 基线 \(extractedText.count) 字"
        } else {
            detail = extractedText.isEmpty ? "已导入 · 等待内容提取" : "已导入 · 已提取 \(extractedText.count) 字"
        }
        return MeetingTruthMaterial(
            name: sourceURL.lastPathComponent,
            kind: kind,
            detail: detail,
            localPath: sourceURL.path,
            extractedText: String(extractedText.prefix(12_000))
        )
    }

    private func readTextFile(from sourceURL: URL) -> String? {
        withSecurityScopedAccess(to: sourceURL) {
            try? String(contentsOf: sourceURL, encoding: .utf8)
        }
    }

    private func meetingTruthTranscriptSource(
        from sourceURL: URL,
        requireTranscriptSignature: Bool
    ) -> MeetingTruthTranscriptSource? {
        guard Self.isMeetingTruthTextFile(sourceURL),
              let rawText = readTextFile(from: sourceURL) else {
            return nil
        }
        if requireTranscriptSignature,
           !Self.isLikelyMeetingTruthTranscriptFile(sourceURL, text: rawText) {
            return nil
        }
        let transcript = Self.meetingTruthTranscriptBody(fromImportedText: rawText)
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return MeetingTruthTranscriptSource(name: sourceURL.lastPathComponent, text: transcript)
    }

    private static func isMeetingTruthTextFile(_ sourceURL: URL) -> Bool {
        ["txt", "md", "markdown", "csv", "json"].contains(sourceURL.pathExtension.lowercased())
    }

    private static func isLikelyMeetingTruthTranscriptFile(_ sourceURL: URL, text: String) -> Bool {
        guard isMeetingTruthTextFile(sourceURL) else { return false }
        let fileName = sourceURL.deletingPathExtension().lastPathComponent.lowercased()
        if fileName.contains("transcript") ||
            fileName.contains("transcription") ||
            fileName.contains("转写") ||
            fileName.contains("逐字稿") {
            return true
        }

        let sample = String(text.prefix(2_000))
        let normalized = sample.lowercased()
        let hasTranscriptHeader = sample.contains("转写结果") ||
            normalized.contains("transcript result") ||
            normalized.contains("transcription result")
        let hasASRMetadata = sample.contains("RTF") ||
            sample.contains("Runtime") ||
            sample.contains("转写耗时") ||
            sample.contains("音频时长") ||
            sample.contains("人工标签") ||
            sample.contains("缓存命中")
        return hasTranscriptHeader && hasASRMetadata
    }

    private static func meetingTruthTranscriptBody(fromImportedText text: String) -> String {
        let normalized = text
            .replacingOccurrences(of: "\u{feff}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        guard !lines.isEmpty else { return "" }

        var index = 0
        while index < lines.count, lines[index].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            index += 1
        }

        if index < lines.count, isTranscriptExportTitle(lines[index]) {
            index += 1
        }

        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || isTranscriptExportMetadataLine(trimmed) {
                index += 1
                continue
            }
            if isTranscriptBodyHeading(trimmed) {
                index += 1
            }
            break
        }

        var bodyLines = Array(lines[index...])
        if let separatorIndex = bodyLines.firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "---" }) {
            bodyLines = Array(bodyLines[..<separatorIndex])
        }

        return bodyLines
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isTranscriptExportTitle(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()
        guard trimmed.hasPrefix("#") else { return false }
        return trimmed.contains("转写结果") ||
            lowercased.contains("transcript result") ||
            lowercased.contains("transcription result")
    }

    private static func isTranscriptBodyHeading(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()
        guard trimmed.hasPrefix("#") else { return false }
        return trimmed.contains("转写正文") ||
            trimmed.contains("正文") ||
            lowercased.contains("transcript") ||
            lowercased.contains("body")
    }

    private static func isTranscriptExportMetadataLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("-") else { return false }
        let metadataKeys = [
            "状态", "runtime", "rtf", "速度", "音频时长", "转写耗时", "加速设备",
            "mps 回退", "分段数", "缓存命中", "人工标签", "人工评分", "相似分组", "备注"
        ]
        let lowercased = trimmed.lowercased()
        return metadataKeys.contains { key in
            lowercased.contains(key)
        }
    }

    private func extractPDFText(from sourceURL: URL) -> String {
        withSecurityScopedAccess(to: sourceURL) {
            PDFDocument(url: sourceURL)?.string ?? ""
        }
    }

    private func extractImageOCRText(from sourceURL: URL) -> String {
        withSecurityScopedAccess(to: sourceURL) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
            let handler = VNImageRequestHandler(url: sourceURL)
            do {
                try handler.perform([request])
                return (request.results ?? [])
                    .compactMap { $0.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
            } catch {
                return ""
            }
        }
    }

    private func meetingTruthClipboardDirectory() throws -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = root
            .appendingPathComponent(MeetingTruthConfig.supportDirectoryName, isDirectory: true)
            .appendingPathComponent("MeetingTruthClipboard", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func setMeetingTruthError(
        _ message: String,
        stage: MeetingTruthFailureRecord.Stage? = nil
    ) {
        meetingTruthError = message
        lastError = message
        if let stage {
            meetingTruthLastFailure = MeetingTruthFailureRecord(stage: stage, message: message, details: lastError)
            recordMeetingTruthActivity(
                stage: activityStage(for: stage),
                title: "操作失败",
                message: message,
                details: lastError
            )
        }
        saveMeetingTruthProjects()
    }

    private func recordMeetingTruthConfirmation(
        for conflictID: UUID,
        decision: MeetingTruthManualConfirmation.Decision,
        selectedText: String?
    ) {
        let confirmation = MeetingTruthManualConfirmation(
            conflictID: conflictID,
            decision: decision,
            selectedText: selectedText
        )
        if let index = meetingTruthManualConfirmations.firstIndex(where: { $0.conflictID == conflictID }) {
            meetingTruthManualConfirmations[index] = confirmation
        } else {
            meetingTruthManualConfirmations.append(confirmation)
        }
    }

    private func applyManualFactConfirmations(to decisions: [MeetingTruthFactDecision]) -> [MeetingTruthFactDecision] {
        decisions.map { decision in
            guard let confirmed = meetingTruthManualConfirmations.first(where: { $0.conflictID == decision.factID }),
                  let selected = confirmed.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !selected.isEmpty else {
                return decision
            }
            var updated = decision
            if confirmed.decision == .ignoredSuggestion {
                updated.chosenText = selected
                updated.status = .lowConfidence
                updated.confidence = min(updated.confidence, 0.66)
                updated.reason = "用户选择暂不确认；该项保留为待确认提示，不阻塞成果包生成。"
                updated.missingEvidence = []
                updated.requiresUserInput = false
                return updated
            }
            updated.chosenText = selected
            updated.status = .confirmed
            updated.confidence = max(updated.confidence, 0.96)
            updated.reason = "用户已人工确认该事实。"
            updated.missingEvidence = []
            updated.requiresUserInput = false
            return updated
        }
    }

    private func resetMeetingTruthFactLedger() {
        meetingTruthFactCandidates = []
        meetingTruthEvidenceAtoms = []
        meetingTruthFactDecisions = []
        meetingTruthUserQuestions = []
        meetingTruthCentralReviewLedger = nil
    }

    private func meetingTruthAcceptedFactLedgerText() -> String {
        let accepted = meetingTruthFactDecisions.filter {
            $0.status == .accepted || $0.status == .confirmed
        }
        guard !accepted.isEmpty else {
            return "暂无已采信事实。"
        }
        return accepted.prefix(60).map { decision in
            let evidence = meetingTruthEvidenceAtoms
                .filter { $0.factID == decision.factID && $0.supportsClaim }
                .prefix(4)
                .map { atom in
                    let cue = atom.visualCue.trimmingCharacters(in: .whitespacesAndNewlines)
                    let cueText = cue.isEmpty ? "" : "；视觉线索：\(cue)"
                    return "\(atom.channel.title)/\(atom.sourceName)：\(atom.text)\(cueText)"
                }
                .joined(separator: " | ")
            let evidenceText = evidence.isEmpty ? "证据：无" : "证据：\(evidence)"
            return "- [\(decision.status.title)] \(decision.kind.title)：\(decision.chosenText)；置信度 \(Int((decision.confidence * 100).rounded()))%；\(evidenceText)"
        }
        .joined(separator: "\n")
    }

    private func meetingTruthRejectedFactLedgerText() -> String {
        let rejected = meetingTruthFactDecisions.filter {
            $0.status == .unsupported || $0.status == .lowConfidence || $0.status == .conflicted || $0.status == .needsUserInput
        }
        guard !rejected.isEmpty else {
            return "无。"
        }
        return rejected.prefix(30).map { decision in
            "- [\(decision.status.title)] \(decision.kind.title)：\(decision.chosenText)；原因：\(decision.reason)"
        }
        .joined(separator: "\n")
    }

    private func resetMeetingTruthProjectIdentity() {
        meetingTruthProjectID = UUID()
        meetingTruthProjectCreatedAt = Date()
    }

    func showMeetingTruthProcessingTrace(anchor: MeetingTruthProcessingAnchorKind = .importMaterials) {
        meetingTruthProcessingTraceFocus = anchor
        selectedSection = .meetingTruthProcessingTrace
    }

    var meetingTruthProcessingRun: MeetingTruthProcessingRun {
        let anchors = meetingTruthProcessingAnchors()
        let warnings = anchors.flatMap(\.issues).filter { $0.kind == .warning }
        let errors = anchors.flatMap(\.issues).filter { $0.kind == .error }
        let tokenUsage = meetingTruthProcessingTokenUsage()
        let toolRecords = meetingTruthProcessingToolRecords()
        let endTime = isMeetingTruthTaskRunning ? nil : (meetingTruthActivityLog.first?.recordedAt ?? meetingTruthProjectCreatedAt)
        let modelCallCount = meetingTruthProcessingModelCallCount(toolRecords: toolRecords)
        let multimodalCallCount = meetingTruthVisualEvidence.count
        let ocrCallCount = meetingTruthMaterials.filter {
            $0.kind == "图片" && !$0.extractedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count
        let userActionCount = meetingTruthManualConfirmations.count
        let finalStatus = meetingTruthProcessingFinalStatus(errors: errors, warnings: warnings)

        return MeetingTruthProcessingRun(
            runID: meetingTruthProjectID.uuidString,
            startTime: meetingTruthProjectCreatedAt,
            endTime: endTime,
            durationLabel: Self.processingDurationLabel(from: meetingTruthProjectCreatedAt, to: endTime ?? Date()),
            inputSummary: meetingTruthProcessingInputSummary(),
            outputSummary: meetingTruthProcessingOutputSummary(),
            currentStage: meetingTruthValidationStatus,
            stageStatus: meetingTruthProcessingOverallStatus(errors: errors, warnings: warnings),
            warnings: warnings,
            errors: errors,
            tokenUsage: tokenUsage,
            toolUsage: "\(toolRecords.filter { $0.status == .executed }.count)/\(toolRecords.count) 已执行",
            modelCalls: modelCallCount,
            multimodalCalls: multimodalCallCount,
            ocrCalls: ocrCallCount,
            userActions: userActionCount,
            finalStatus: finalStatus,
            summaryMetrics: meetingTruthProcessingSummaryMetrics(
                tokenUsage: tokenUsage,
                toolRecords: toolRecords,
                modelCalls: modelCallCount,
                multimodalCalls: multimodalCallCount,
                ocrCalls: ocrCallCount,
                warningCount: warnings.count,
                errorCount: errors.count
            ),
            anchors: anchors,
            toolTimeline: meetingTruthProcessingToolTimeline(toolRecords: toolRecords, tokenUsage: tokenUsage)
        )
    }

    private func meetingTruthProcessingAnchors() -> [MeetingTruthProcessingAnchor] {
        MeetingTruthProcessingAnchorKind.allCases.map { kind in
            switch kind {
            case .importMaterials:
                return processingImportMaterialsAnchor()
            case .ocrAndRawVision:
                return processingOCRAndRawVisionAnchor()
            case .timelineSegmentation:
                return processingTimelineSegmentationAnchor()
            case .transcriptAlignment:
                return processingTranscriptAlignmentAnchor()
            case .conflictDiscovery:
                return processingConflictDiscoveryAnchor()
            case .candidateGrouping:
                return processingCandidateGroupingAnchor()
            case .evidenceRetrieval:
                return processingEvidenceRetrievalAnchor()
            case .candidateScoring:
                return processingCandidateScoringAnchor()
            case .conflictAdjudication:
                return processingConflictAdjudicationAnchor()
            case .safeReplacementValidation:
                return processingSafeReplacementAnchor()
            case .humanReviewTaskGeneration:
                return processingHumanReviewTaskAnchor()
            case .centralReviewHandoff:
                return processingCentralReviewHandoffAnchor()
            }
        }
    }

    private func processingImportMaterialsAnchor() -> MeetingTruthProcessingAnchor {
        let imageCount = meetingTruthMaterials.filter { $0.kind == "图片" }.count
        let textMaterialCount = meetingTruthMaterials.count - imageCount
        let issues = meetingTruthTranscriptSources.isEmpty && meetingTruthMaterials.isEmpty
            ? [processingIssue(.warning, "还没有导入会议资料或候选转写。", .nonBlocking)]
            : []
        return processingAnchor(
            .importMaterials,
            status: meetingTruthMaterials.isEmpty && meetingTruthTranscriptSources.isEmpty ? .notStarted : .completed,
            inputs: ["候选转写 \(meetingTruthTranscriptSources.count) 份", "图片 \(imageCount) 张", "文本/PDF/术语材料 \(textMaterialCount) 份"],
            processing: ["读取文件或剪贴板图片", "清理转写导出元数据", "登记资料来源和本地路径", "为后续证据链保留名称、类型和文本摘要"],
            outputs: ["TranscriptSource x \(meetingTruthTranscriptSources.count)", "Material x \(meetingTruthMaterials.count)", "ImageEvidence 输入 x \(imageCount)"],
            nextStep: MeetingTruthProcessingAnchorKind.ocrAndRawVision.title,
            triggers: [.swiftRules],
            issues: issues,
            technicalDetails: meetingTruthMaterials.prefix(8).map { "\($0.kind)：\($0.name)" },
            rawDetails: rawEncoded([
                "transcript_sources": meetingTruthTranscriptSources.map(\.name),
                "materials": meetingTruthMaterials.map { "\($0.kind):\($0.name)" }
            ])
        )
    }

    private func processingOCRAndRawVisionAnchor() -> MeetingTruthProcessingAnchor {
        let imageMaterials = meetingTruthMaterials.filter { $0.kind == "图片" }
        let ocrCount = imageMaterials.filter { !$0.extractedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
        var issues: [MeetingTruthProcessingIssue] = []
        if !imageMaterials.isEmpty && meetingTruthVisualEvidence.isEmpty {
            issues.append(processingIssue(.warning, "有图片输入，但还没有 Gemma 原图理解结果。", .lowersConfidence))
        }
        if let ledger = meetingTruthCentralReviewLedger {
            issues.append(contentsOf: ledger.gaps.filter { $0.kind == .ocrRawVisionMismatch }.map {
                processingIssue(.warning, $0.detail, .lowersConfidence)
            })
        }
        return processingAnchor(
            .ocrAndRawVision,
            status: isExtractingMeetingTruthVisualEvidence ? .running : (issues.isEmpty ? (imageMaterials.isEmpty ? .notStarted : .completed) : .warning),
            inputs: ["图片 \(imageMaterials.count) 张", "OCR 基线 \(ocrCount) 条", "候选转写提示 \(meetingTruthTranscriptSources.count) 份"],
            processing: ["OCR 提取图片文字", "Gemma 多模态读取原图版式和重点", "区分会议通知、手写稿、PPT、截图和其他材料", "保留 OCR 与原图理解差异"],
            outputs: ["VisualEvidence x \(meetingTruthVisualEvidence.count)", "OCR 文本 x \(ocrCount)", "EvidenceProfile x \(meetingTruthProcessingEvidenceProfileCount())"],
            nextStep: "\(MeetingTruthProcessingAnchorKind.timelineSegmentation.title) / \(MeetingTruthProcessingAnchorKind.evidenceRetrieval.title)",
            triggers: [.ocr, .gemmaMultimodal, .swiftRules],
            issues: issues,
            technicalDetails: meetingTruthVisualEvidence.prefix(6).map { "\($0.materialName)：\($0.summary)" },
            rawDetails: rawEncoded(meetingTruthVisualEvidence)
        )
    }

    private func processingTimelineSegmentationAnchor() -> MeetingTruthProcessingAnchor {
        let timestampSources = meetingTruthTranscriptSources.filter(\.hasTimestamp)
        let windows = meetingTruthProcessingAlignmentWindows()
        let issues = timestampSources.isEmpty && !meetingTruthTranscriptSources.isEmpty
            ? [processingIssue(.warning, "当前没有带时间戳的 Qwen3 ASR 锚点，时间轴切分只能降级为文本片段。", .lowersConfidence)]
            : []
        return processingAnchor(
            .timelineSegmentation,
            status: timestampSources.isEmpty ? (meetingTruthTranscriptSources.isEmpty ? .notStarted : .warning) : .completed,
            inputs: ["Qwen3/时间戳候选 \(timestampSources.count) 份", "候选转写 \(meetingTruthTranscriptSources.count) 份"],
            processing: ["识别时间戳锚点", "按时间窗口准备 TranscriptWindow", "为多路 ASR 对齐保留 start_time / end_time"],
            outputs: ["TranscriptWindow x \(max(windows.count, timestampSources.isEmpty ? 0 : 1))", "start_time / end_time \(windows.isEmpty ? "待生成" : "已记录")"],
            nextStep: MeetingTruthProcessingAnchorKind.transcriptAlignment.title,
            triggers: [.swiftRules],
            issues: issues,
            technicalDetails: windows.prefix(8).map { "\($0.windowID)：\($0.startTime)-\($0.endTime)，score \(Self.percentText($0.alignmentScore))" },
            rawDetails: rawEncoded(windows)
        )
    }

    private func processingTranscriptAlignmentAnchor() -> MeetingTruthProcessingAnchor {
        let windows = meetingTruthProcessingAlignmentWindows()
        let warnings = windows.flatMap(\.alignmentWarnings)
        let issues = warnings.map { processingIssue(.warning, $0, .lowersConfidence) }
        return processingAnchor(
            .transcriptAlignment,
            status: isDiscoveringMeetingTruthConflicts ? .running : (meetingTruthConflicts.isEmpty ? .notStarted : (issues.isEmpty ? .completed : .warning)),
            inputs: ["TranscriptWindow x \(max(windows.count, meetingTruthConflicts.count))", "MiMo 主底稿候选", "GLM 辅助参考候选"],
            processing: ["文本相似度匹配", "关键词锚点匹配", "句子顺序对齐", "记录 alignment_score 和失败段落"],
            outputs: ["对齐窗口 x \(windows.count)", "冲突上下文 x \(meetingTruthConflicts.count)", "对齐警告 x \(warnings.count)"],
            nextStep: MeetingTruthProcessingAnchorKind.conflictDiscovery.title,
            triggers: [.swiftRules, .localToolFunction],
            issues: issues,
            technicalDetails: meetingTruthConflicts.prefix(6).map { "\($0.timestamp)：\($0.context)" },
            rawDetails: rawEncoded(windows)
        )
    }

    private func processingConflictDiscoveryAnchor() -> MeetingTruthProcessingAnchor {
        var issues: [MeetingTruthProcessingIssue] = []
        if meetingTruthLastFailure?.stage == .discoverConflicts, let error = meetingTruthError {
            issues.append(processingIssue(.error, error, .blocksNextStep))
        } else if hasDiscoveredMeetingTruthConflicts && meetingTruthConflicts.isEmpty {
            issues.append(processingIssue(.warning, "已完成检查，但未发现需要确认的冲突。", .nonBlocking))
        }
        return processingAnchor(
            .conflictDiscovery,
            status: isDiscoveringMeetingTruthConflicts ? .running : statusFromContent(hasContent: !meetingTruthConflicts.isEmpty || hasDiscoveredMeetingTruthConflicts, issues: issues),
            inputs: ["对齐后的多路转写", "候选转写 \(meetingTruthTranscriptSources.count) 份", "材料上下文 \(meetingTruthContextMaterials(for: meetingTruthMultimodalMode).count) 份"],
            processing: ["比较候选文本", "过滤口语、重复和轻微表达差异", "保留可能影响纪要的高风险差异"],
            outputs: ["保留冲突 \(meetingTruthConflicts.count) 个", "低风险忽略 \(meetingTruthIgnoredLowRiskCount()) 个", "需确认 \(meetingTruthReviewCount) 个"],
            nextStep: MeetingTruthProcessingAnchorKind.candidateGrouping.title,
            triggers: [.gemmaText, .gemmaMultimodal, .swiftRules],
            issues: issues,
            technicalDetails: meetingTruthConflicts.prefix(8).map { "\($0.kind.title)：\($0.candidates.map(\.text).joined(separator: " / "))" },
            rawDetails: rawEncoded(meetingTruthConflicts)
        )
    }

    private func processingCandidateGroupingAnchor() -> MeetingTruthProcessingAnchor {
        let candidateCount = meetingTruthConflicts.reduce(0) { $0 + $1.candidates.count }
        let groupWarnings = meetingTruthProcessingToolRecords()
            .flatMap { $0.asrConflicts ?? [] }
            .flatMap { $0.alignmentWarnings ?? [] }
        return processingAnchor(
            .candidateGrouping,
            status: meetingTruthConflicts.isEmpty ? .notStarted : (groupWarnings.isEmpty ? .completed : .warning),
            inputs: ["冲突窗口 \(meetingTruthConflicts.count) 个", "候选文本 \(candidateCount) 个"],
            processing: ["聚合同义、近音和同位置候选", "分离不同类型冲突", "避免 OpenAI/open/token 一类无关词混入术语组"],
            outputs: ["ConflictGroup x \(meetingTruthConflicts.count)", "候选项 x \(candidateCount)", "混杂警告 x \(groupWarnings.count)"],
            nextStep: MeetingTruthProcessingAnchorKind.evidenceRetrieval.title,
            triggers: [.swiftRules, .localToolFunction],
            issues: groupWarnings.map { processingIssue(.warning, $0, .lowersConfidence) },
            technicalDetails: meetingTruthConflicts.prefix(8).map { "示例：\($0.candidates.map(\.text).joined(separator: " / "))" },
            rawDetails: rawEncoded(meetingTruthProcessingToolRecords().flatMap { $0.asrConflicts ?? [] })
        )
    }

    private func processingEvidenceRetrievalAnchor() -> MeetingTruthProcessingAnchor {
        let evidenceSupports = meetingTruthProcessingToolRecords().flatMap { $0.evidenceChain ?? [] }
        let issues = evidenceSupports.isEmpty && !meetingTruthConflicts.isEmpty
            ? [processingIssue(.warning, "已有冲突，但还没有结构化 EvidenceMatch 记录。", .routesToHumanReview)]
            : []
        return processingAnchor(
            .evidenceRetrieval,
            status: statusFromContent(hasContent: !evidenceSupports.isEmpty || !meetingTruthEvidenceAtoms.isEmpty, issues: issues),
            inputs: ["ConflictGroup x \(meetingTruthConflicts.count)", "EvidenceProfile x \(meetingTruthProcessingEvidenceProfileCount())", "事实候选 x \(meetingTruthFactCandidates.count)"],
            processing: ["检索会议通知、手写稿、PPT/材料", "检索 OCR 与 Gemma 原图理解摘要", "检索术语表、上下文和人工确认"],
            outputs: ["EvidenceMatch x \(evidenceSupports.count)", "FactEvidenceAtom x \(meetingTruthEvidenceAtoms.count)", "source_type 覆盖 \(Set(evidenceSupports.map(\.sourceType)).count) 类"],
            nextStep: MeetingTruthProcessingAnchorKind.candidateScoring.title,
            triggers: [.localToolFunction, .swiftRules, .gemmaFunctionCalling],
            issues: issues,
            technicalDetails: evidenceSupports.prefix(8).map { "\($0.sourceType.title)：\($0.matchedText) -> \($0.supportType.title)" },
            rawDetails: rawEncoded(evidenceSupports)
        )
    }

    private func processingCandidateScoringAnchor() -> MeetingTruthProcessingAnchor {
        let scores = meetingTruthProcessingToolRecords().flatMap { $0.candidateScores ?? [] }
        return processingAnchor(
            .candidateScoring,
            status: scores.isEmpty && meetingTruthFactDecisions.isEmpty ? .notStarted : .completed,
            inputs: ["ConflictGroup x \(meetingTruthConflicts.count)", "EvidenceMatch x \(meetingTruthProcessingToolRecords().flatMap { $0.evidenceChain ?? [] }.count)", "ASR 来源角色"],
            processing: ["按证据类型和事实类型加权", "正式材料、术语表、原图视觉和人工确认权重更高", "ASR 作为现场语音线索，但不是唯一强证据"],
            outputs: ["CandidateScore x \(scores.count)", "FactDecision x \(meetingTruthFactDecisions.count)", "支持/反证来源已分离"],
            nextStep: MeetingTruthProcessingAnchorKind.conflictAdjudication.title,
            triggers: [.localToolFunction, .swiftRules, .gemmaFunctionCalling],
            issues: [],
            technicalDetails: scores.prefix(8).map { "\($0.candidate)：\(Self.percentText($0.score)) · \($0.recommendedDecision.title)" },
            rawDetails: rawEncoded(scores)
        )
    }

    private func processingConflictAdjudicationAnchor() -> MeetingTruthProcessingAnchor {
        let decisionTraces = meetingTruthProcessingToolRecords().compactMap(\.factDecision)
        let needsReview = meetingTruthPendingFactQuestions.count + meetingTruthPendingCentralReviewClaims.count + meetingTruthReviewCount
        var issues: [MeetingTruthProcessingIssue] = []
        if needsReview > 0 {
            issues.append(processingIssue(.warning, "\(needsReview) 个事项需要人工确认或中枢复核。", .routesToHumanReview))
        }
        return processingAnchor(
            .conflictAdjudication,
            status: statusFromContent(hasContent: !decisionTraces.isEmpty || !meetingTruthFactDecisions.isEmpty || !meetingTruthConflicts.isEmpty, issues: issues),
            inputs: ["CandidateScore x \(meetingTruthProcessingToolRecords().flatMap { $0.candidateScores ?? [] }.count)", "risk_level", "support_type"],
            processing: ["高置信且证据充分则自动应用", "证据不足或冲突则进入人工确认", "低风险差异忽略", "替换风险高则进入后续复核"],
            outputs: ["自动应用 \(meetingTruthAutoAppliedCount()) 个", "需要确认 \(needsReview) 个", "低风险忽略 \(meetingTruthIgnoredLowRiskCount()) 个"],
            nextStep: MeetingTruthProcessingAnchorKind.safeReplacementValidation.title,
            triggers: [.swiftRules, .localToolFunction, .gemmaFunctionCalling],
            issues: issues,
            technicalDetails: (decisionTraces.map { "\($0.status.title)：\($0.finalText)" } + meetingTruthFactDecisions.map { "\($0.status.title)：\($0.chosenText)" }).prefix(10).map { $0 },
            rawDetails: rawEncoded(decisionTraces)
        )
    }

    private func processingSafeReplacementAnchor() -> MeetingTruthProcessingAnchor {
        let validations = meetingTruthConflicts.compactMap(\.replacementValidationResult) +
            meetingTruthProcessingToolRecords().compactMap(\.replacementValidationResult)
        let failed = validations.filter { !$0.isValid }
        let issues = failed.map {
            processingIssue(.warning, "替换校验失败：\($0.reason)", .routesToHumanReview)
        }
        return processingAnchor(
            .safeReplacementValidation,
            status: validations.isEmpty ? .notStarted : (failed.isEmpty ? .completed : .warning),
            inputs: ["建议替换项 \(meetingTruthConflicts.filter { !$0.recommendation.isEmpty }.count) 个", "原始 span/range \(meetingTruthConflicts.flatMap { $0.replacementSpans ?? [] }.count) 个"],
            processing: ["只替换指定位置", "检查英文词边界和大小写", "检查 AASR、aasr、ASR ASR、JSONON、OpenClawaw 污染", "替换后重新 diff"],
            outputs: ["替换成功 \(validations.filter(\.isValid).count) 个", "替换失败 \(failed.count) 个", "污染检查 \(Set(validations.flatMap(\.pollutionChecks)).count) 类"],
            nextStep: "成功项写入可信转写；失败项进入后续复核或人工确认。",
            triggers: [.swiftRules, .localToolFunction],
            issues: issues,
            technicalDetails: validations.prefix(8).map { "\($0.isValid ? "通过" : "失败")：\($0.reason)" },
            rawDetails: rawEncoded(validations)
        )
    }

    private func processingHumanReviewTaskAnchor() -> MeetingTruthProcessingAnchor {
        let toolTasks = meetingTruthProcessingToolRecords().compactMap(\.humanReviewTask)
        let pending = meetingTruthPendingFactQuestions.count + meetingTruthPendingCentralReviewClaims.count + meetingTruthReviewCount
        let issues = pending > 0
            ? [processingIssue(.warning, "\(pending) 个问题等待用户确认。", .routesToHumanReview)]
            : []
        return processingAnchor(
            .humanReviewTaskGeneration,
            status: statusFromContent(hasContent: !toolTasks.isEmpty || pending > 0 || !meetingTruthManualConfirmations.isEmpty, issues: issues),
            inputs: ["needsHumanReview \(meetingTruthReviewCount)", "conflicted \(meetingTruthConflicts.filter { $0.reviewStatus == .evidenceConflicted }.count)", "replacement_failed \(meetingTruthReplacementFailureCount())"],
            processing: ["生成为什么问你", "标注影响哪里", "列出候选写法", "说明不处理会怎样"],
            outputs: ["HumanReviewTask x \(toolTasks.count + meetingTruthPendingFactQuestions.count + meetingTruthPendingCentralReviewClaims.count)", "用户已确认 \(meetingTruthManualConfirmations.count) 条"],
            nextStep: MeetingTruthProcessingAnchorKind.centralReviewHandoff.title,
            triggers: [.swiftRules, .localToolFunction, .userConfirmation, .gemmaFunctionCalling],
            issues: issues,
            technicalDetails: (toolTasks.map(\.question) + meetingTruthPendingFactQuestions.map(\.question) + meetingTruthPendingCentralReviewClaims.map(\.humanQuestion).compactMap { $0 }).prefix(8).map { $0 },
            rawDetails: rawEncoded(toolTasks)
        )
    }

    private func processingCentralReviewHandoffAnchor() -> MeetingTruthProcessingAnchor {
        let ledger = meetingTruthCentralReviewLedger
        var issues: [MeetingTruthProcessingIssue] = []
        if let ledger {
            issues.append(contentsOf: ledger.blockingItems.map {
                processingIssue(.error, $0, .blocksNextStep)
            })
            issues.append(contentsOf: ledger.advisoryItems.map {
                processingIssue(.warning, $0, .lowersConfidence)
            })
        }
        return processingAnchor(
            .centralReviewHandoff,
            status: isReviewingMeetingTruthCentrally ? .running : statusFromContent(hasContent: ledger != nil, issues: issues),
            inputs: ["可信逐字稿 \(meetingTruthTrustedTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未生成" : "已生成")", "EvidenceChain \(meetingTruthEvidenceAtoms.count) 条", "HumanReviewTask \(meetingTruthPendingFactQuestions.count + meetingTruthPendingCentralReviewClaims.count) 条"],
            processing: ["汇总已修正可信转写", "交付证据链、人工确认任务和低风险忽略记录", "Gemma 4 中枢复核检查输出边界"],
            outputs: ["CentralReviewClaim x \(ledger?.claims.count ?? 0)", "ReviewGap x \(ledger?.gaps.count ?? 0)", "ToolCallRecord x \(ledger?.toolCallRecords.count ?? 0)"],
            nextStep: "多模态中枢复核 / 成果包生成",
            triggers: [.swiftRules, .gemmaText, .gemmaMultimodal, .gemmaFunctionCalling],
            issues: issues,
            technicalDetails: (ledger?.inputSummary ?? []) + (ledger?.packageAuditNotes ?? []),
            rawDetails: rawEncoded(ledger)
        )
    }

    private func processingAnchor(
        _ kind: MeetingTruthProcessingAnchorKind,
        status: MeetingTruthProcessingStageStatus,
        inputs: [String],
        processing: [String],
        outputs: [String],
        nextStep: String,
        triggers: [MeetingTruthProcessingTrigger],
        issues: [MeetingTruthProcessingIssue],
        technicalDetails: [String],
        rawDetails: String?
    ) -> MeetingTruthProcessingAnchor {
        MeetingTruthProcessingAnchor(
            kind: kind,
            status: status,
            durationLabel: "未单独记录",
            inputs: inputs,
            processing: processing,
            outputs: outputs,
            nextStep: nextStep,
            triggers: triggers,
            issues: issues,
            technicalDetails: technicalDetails,
            rawDetails: rawDetails
        )
    }

    private func processingIssue(
        _ kind: MeetingTruthProcessingIssue.Kind,
        _ message: String,
        _ impact: MeetingTruthProcessingIssueImpact
    ) -> MeetingTruthProcessingIssue {
        MeetingTruthProcessingIssue(kind: kind, message: message, impact: impact)
    }

    private func statusFromContent(
        hasContent: Bool,
        issues: [MeetingTruthProcessingIssue]
    ) -> MeetingTruthProcessingStageStatus {
        if issues.contains(where: { $0.kind == .error }) {
            return .failed
        }
        if issues.contains(where: { $0.kind == .warning }) {
            return .warning
        }
        return hasContent ? .completed : .notStarted
    }

    private func meetingTruthProcessingOverallStatus(
        errors: [MeetingTruthProcessingIssue],
        warnings: [MeetingTruthProcessingIssue]
    ) -> MeetingTruthProcessingStageStatus {
        if isMeetingTruthTaskRunning { return .running }
        if !errors.isEmpty { return .failed }
        if !warnings.isEmpty { return .warning }
        return hasMeetingTruthInput ? .completed : .notStarted
    }

    private func meetingTruthProcessingFinalStatus(
        errors: [MeetingTruthProcessingIssue],
        warnings: [MeetingTruthProcessingIssue]
    ) -> String {
        if isMeetingTruthTaskRunning {
            return "处理中"
        }
        if !errors.isEmpty {
            return "存在阻塞项，需要处理后继续"
        }
        if meetingTruthAnalysis != nil {
            return "成果包已生成"
        }
        if !warnings.isEmpty {
            return "可继续，但有 \(warnings.count) 个警告需要留意"
        }
        return hasMeetingTruthInput ? "当前链路可审计" : "等待输入"
    }

    private func meetingTruthProcessingInputSummary() -> [String] {
        [
            "候选转写 \(meetingTruthTranscriptSources.count) 份，其中 \(meetingTruthTranscriptSources.filter(\.hasTimestamp).count) 份含时间戳",
            "会议资料 \(meetingTruthMaterials.count) 份，图片 \(meetingTruthMaterials.filter { $0.kind == "图片" }.count) 张",
            "视觉证据 \(meetingTruthVisualEvidence.count) 条",
            "人工确认 \(meetingTruthManualConfirmations.count) 条"
        ]
    }

    private func meetingTruthProcessingOutputSummary() -> [String] {
        [
            "冲突 \(meetingTruthConflicts.count) 个，已解决 \(meetingTruthResolvedCount) 个",
            "事实候选 \(meetingTruthFactCandidates.count) 个，事实裁决 \(meetingTruthFactDecisions.count) 条",
            "中枢复核 claims \(meetingTruthCentralReviewLedger?.claims.count ?? 0) 条，gaps \(meetingTruthCentralReviewLedger?.gaps.count ?? 0) 条",
            meetingTruthAnalysis == nil ? "成果包未生成" : "成果包已生成"
        ]
    }

    private func meetingTruthProcessingSummaryMetrics(
        tokenUsage: MeetingTruthTokenUsage?,
        toolRecords: [MeetingTruthToolCallRecord],
        modelCalls: Int,
        multimodalCalls: Int,
        ocrCalls: Int,
        warningCount: Int,
        errorCount: Int
    ) -> [MeetingTruthProcessingSummaryMetric] {
        [
            MeetingTruthProcessingSummaryMetric(title: "运行状态", value: meetingTruthProcessingOverallStatus(errors: [], warnings: []).title, detail: meetingTruthValidationStatus),
            MeetingTruthProcessingSummaryMetric(title: "总耗时", value: Self.processingDurationLabel(from: meetingTruthProjectCreatedAt, to: Date()), detail: "项目运行记录时间"),
            MeetingTruthProcessingSummaryMetric(title: "输入资料", value: "\(meetingTruthMaterials.count)", detail: "转写 \(meetingTruthTranscriptSources.count) 份"),
            MeetingTruthProcessingSummaryMetric(title: "转写窗口", value: "\(meetingTruthProcessingAlignmentWindows().count)", detail: "无窗口时显示为 0"),
            MeetingTruthProcessingSummaryMetric(title: "发现冲突", value: "\(meetingTruthConflicts.count)", detail: "自动应用 \(meetingTruthAutoAppliedCount())"),
            MeetingTruthProcessingSummaryMetric(title: "需要确认", value: "\(meetingTruthPendingFactQuestions.count + meetingTruthPendingCentralReviewClaims.count + meetingTruthReviewCount)", detail: "低风险忽略 \(meetingTruthIgnoredLowRiskCount())"),
            MeetingTruthProcessingSummaryMetric(title: "替换失败", value: "\(meetingTruthReplacementFailureCount())", detail: "安全校验失败数"),
            MeetingTruthProcessingSummaryMetric(title: "Gemma 调用", value: "\(modelCalls)", detail: "多模态 \(multimodalCalls) 次"),
            MeetingTruthProcessingSummaryMetric(title: "工具函数", value: "\(toolRecords.count)", detail: "已执行 \(toolRecords.filter { $0.status == .executed }.count)"),
            MeetingTruthProcessingSummaryMetric(title: "OCR", value: "\(ocrCalls)", detail: "有 OCR 文本的图片"),
            MeetingTruthProcessingSummaryMetric(title: "Token", value: tokenUsageText(tokenUsage), detail: "端点未返回时显示未返回"),
            MeetingTruthProcessingSummaryMetric(title: "告警/错误", value: "\(warningCount)/\(errorCount)", detail: "按锚点聚合")
        ]
    }

    private func meetingTruthProcessingToolTimeline(
        toolRecords: [MeetingTruthToolCallRecord],
        tokenUsage: MeetingTruthTokenUsage?
    ) -> [MeetingTruthToolTimelineItem] {
        if !toolRecords.isEmpty {
            return toolRecords.map { record in
                let source = record.invocationSource ?? .unknown
                return MeetingTruthToolTimelineItem(
                    stepName: record.functionName,
                    explanation: toolExplanation(for: record.functionName),
                    triggers: processingTriggers(for: source),
                    inputSummary: record.argumentsSummary,
                    outputSummary: record.resultSummary,
                    status: record.status == .executed ? .completed : (record.status == .failed ? .failed : .warning),
                    durationLabel: "未单独记录",
                    modelUsage: tokenUsageText(tokenUsage),
                    rawJSON: rawEncoded(record)
                )
            }
        }
        return meetingTruthActivityLog.prefix(12).map { record in
            MeetingTruthToolTimelineItem(
                stepName: record.title,
                explanation: record.message,
                triggers: [trigger(for: record.stage)],
                inputSummary: record.stage.rawValue,
                outputSummary: record.details ?? record.message,
                status: record.title == "操作失败" ? .failed : .completed,
                durationLabel: Self.processingDurationLabel(from: record.recordedAt, to: Date()),
                modelUsage: tokenUsageText(tokenUsage),
                rawJSON: rawEncoded(record)
            )
        }
    }

    private func processingTriggers(for source: MeetingTruthToolInvocationSource) -> [MeetingTruthProcessingTrigger] {
        switch source {
        case .nativeToolCall, .jsonFallback:
            return [.gemmaFunctionCalling, .localToolFunction]
        case .autoPipeline:
            return [.localToolFunction]
        case .localRule:
            return [.swiftRules, .localToolFunction]
        case .manualConfirmation:
            return [.userConfirmation]
        case .unknown:
            return [.localToolFunction]
        }
    }

    private func meetingTruthProcessingToolRecords() -> [MeetingTruthToolCallRecord] {
        let ledgerRecords = meetingTruthCentralReviewLedger?.toolCallRecords ?? []
        let conflictRecords = meetingTruthConflicts.flatMap { $0.developerTrace ?? [] }
        let abRecords = (meetingTruthToolCallingABResult?.promptOnly.ledger?.toolCallRecords ?? []) +
            (meetingTruthToolCallingABResult?.toolCalling.ledger?.toolCallRecords ?? [])
        var seen = Set<UUID>()
        var records: [MeetingTruthToolCallRecord] = []
        for record in ledgerRecords + conflictRecords + abRecords {
            guard seen.insert(record.id).inserted else { continue }
            records.append(record)
        }
        return records.sorted { $0.callIndex < $1.callIndex }
    }

    private func meetingTruthProcessingTokenUsage() -> MeetingTruthTokenUsage? {
        var usage = meetingTruthCentralReviewLedger?.tokenUsage
        usage = usage?.merged(with: meetingTruthToolCallingABResult?.promptOnly.tokenUsage)
            ?? meetingTruthToolCallingABResult?.promptOnly.tokenUsage
            ?? usage
        usage = usage?.merged(with: meetingTruthToolCallingABResult?.toolCalling.tokenUsage)
            ?? meetingTruthToolCallingABResult?.toolCalling.tokenUsage
            ?? usage
        return usage
    }

    private func meetingTruthProcessingModelCallCount(toolRecords: [MeetingTruthToolCallRecord]) -> Int {
        var count = 0
        if !meetingTruthVisualEvidence.isEmpty { count += 1 }
        if meetingTruthCentralReviewLedger != nil { count += 1 }
        if meetingTruthToolCallingABResult != nil { count += 2 }
        if !meetingTruthConflicts.isEmpty && hasDiscoveredMeetingTruthConflicts { count += 1 }
        if !toolRecords.isEmpty { count += 1 }
        return count
    }

    private func meetingTruthProcessingEvidenceProfileCount() -> Int {
        let toolProfiles = meetingTruthProcessingToolRecords().flatMap { $0.evidenceProfiles ?? [] }.count
        return max(toolProfiles, meetingTruthMaterials.count)
    }

    private func meetingTruthProcessingAlignmentWindows() -> [MeetingTruthASRAlignmentWindow] {
        meetingTruthProcessingToolRecords().flatMap { $0.alignmentWindows ?? [] }
    }

    private func meetingTruthAutoAppliedCount() -> Int {
        meetingTruthConflicts.filter {
            $0.reviewStatus == .suggestedApplied || ($0.selectedText != nil && $0.lastUserAction == .adoptSuggestion)
        }.count
    }

    private func meetingTruthIgnoredLowRiskCount() -> Int {
        meetingTruthConflicts.filter { $0.reviewStatus == .ignoredLowRisk }.count
    }

    private func meetingTruthReplacementFailureCount() -> Int {
        meetingTruthConflicts.filter { $0.replacementValidationResult?.isValid == false || $0.reviewStatus == .replacementValidationFailed }.count
    }

    private func trigger(for stage: MeetingTruthActivityRecord.Stage) -> MeetingTruthProcessingTrigger {
        switch stage {
        case .importMaterials, .importTranscripts, .restore:
            return .swiftRules
        case .discoverConflicts, .resolveConflicts, .generatePackage:
            return .gemmaText
        case .manualConfirmation:
            return .userConfirmation
        case .multimodalEvidence:
            return .gemmaMultimodal
        }
    }

    private func toolExplanation(for functionName: String) -> String {
        switch functionName {
        case "detect_asr_conflicts":
            return "系统比较多路 ASR，找出可能影响纪要的识别差异。"
        case "retrieve_supporting_evidence":
            return "系统在会议通知、手写稿、图片识别和材料中查找哪个写法更可信。"
        case "score_fact_candidates":
            return "系统根据证据来源和事实类型给候选写法打分。"
        case "make_fact_decision":
            return "系统判断自动修正、接受、拒绝，还是转人工确认。"
        case "create_human_review_task":
            return "系统把证据不足但影响输出的事项组织成用户确认问题。"
        default:
            return "系统执行本地工具函数，并把结果交回核验链路。"
        }
    }

    private func rawEncoded<T: Encodable>(_ value: T?) -> String? {
        guard let value else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    nonisolated private static func processingDurationLabel(from start: Date, to end: Date) -> String {
        let seconds = max(end.timeIntervalSince(start), 0)
        if seconds < 60 {
            return String(format: "%.1fs", seconds)
        }
        if seconds < 3600 {
            return String(format: "%.1fmin", seconds / 60)
        }
        return String(format: "%.1fh", seconds / 3600)
    }

    nonisolated private static func percentText(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    private func recordMeetingTruthActivity(
        stage: MeetingTruthActivityRecord.Stage,
        title: String,
        message: String,
        details: String? = nil
    ) {
        meetingTruthActivityLog.insert(
            MeetingTruthActivityRecord(stage: stage, title: title, message: message, details: details),
            at: 0
        )
        if meetingTruthActivityLog.count > 200 {
            meetingTruthActivityLog.removeLast(meetingTruthActivityLog.count - 200)
        }
    }

    private func activityStage(for failureStage: MeetingTruthFailureRecord.Stage) -> MeetingTruthActivityRecord.Stage {
        switch failureStage {
        case .importMaterials:
            return .importMaterials
        case .importTranscripts:
            return .importTranscripts
        case .discoverConflicts:
            return .discoverConflicts
        case .resolveConflicts:
            return .resolveConflicts
        case .generatePackage:
            return .generatePackage
        case .restore:
            return .restore
        }
    }

    private func previewContexts(for needle: String, in haystack: String, limit: Int = 2, radius: Int = 24) -> [String] {
        guard !needle.isEmpty, !haystack.isEmpty else { return [] }
        var contexts: [String] = []
        var searchStart = haystack.startIndex

        while searchStart < haystack.endIndex,
              let range = haystack.range(of: needle, range: searchStart..<haystack.endIndex),
              contexts.count < limit {
            let lower = haystack.index(range.lowerBound, offsetBy: -radius, limitedBy: haystack.startIndex) ?? haystack.startIndex
            let upper = haystack.index(range.upperBound, offsetBy: radius, limitedBy: haystack.endIndex) ?? haystack.endIndex
            let prefix = lower == haystack.startIndex ? "" : "..."
            let suffix = upper == haystack.endIndex ? "" : "..."
            let snippet = String(haystack[lower..<upper]).replacingOccurrences(of: "\n", with: " ")
            contexts.append("\(prefix)\(snippet)\(suffix)")
            searchStart = range.upperBound
        }

        return contexts
    }

    private func derivedMeetingTruthPackageStatus() -> MeetingTruthPackageStatus {
        if meetingTruthAnalysis != nil {
            return MeetingTruthPackageStatus(
                state: .succeeded,
                generatedAt: meetingTruthAnalysis?.generatedAt,
                message: "会议成果包已生成"
            )
        }
        if meetingTruthValidationStatus.contains("会议成果包生成失败") {
            return MeetingTruthPackageStatus(
                state: .failed,
                generatedAt: nil,
                message: meetingTruthError
            )
        }
        if isGeneratingMeetingTruthPackage {
            return MeetingTruthPackageStatus(
                state: .generating,
                generatedAt: nil,
                message: meetingTruthValidationStatus
            )
        }
        if hasDiscoveredMeetingTruthConflicts && meetingTruthUnresolvedCount == 0 {
            return MeetingTruthPackageStatus(
                state: .readyToGenerate,
                generatedAt: nil,
                message: "可生成会议成果包"
            )
        }
        return MeetingTruthPackageStatus(
            state: .idle,
            generatedAt: nil,
            message: meetingTruthValidationStatus
        )
    }

    private func packageGenerationFailureStatus(for error: Error) -> String {
        guard let error = error as? MeetingAIError else {
            return "会议成果包生成失败"
        }
        switch error {
        case .responseTruncatedAfterRetries:
            return "会议成果包生成失败：自动压缩重试后仍被截断"
        case .chunkResponseTruncated:
            return "会议成果包生成失败：分段整理结果被截断"
        case .mergeResponseTruncated:
            return "会议成果包生成失败：最终合并结果被截断"
        default:
            return "会议成果包生成失败"
        }
    }

    private func buildMeetingTruthMultimodalImpactRows() -> [MeetingTruthMultimodalImpactRow] {
        let hasTranscript = !meetingTruthTrustedTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasAudio = !selectedAudioPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            meetingTruthMaterials.contains { $0.kind == "会议录音" }
        let hasImages = !meetingTruthImageMaterials.isEmpty
        let hasVisualEvidence = !meetingTruthVisualEvidence.isEmpty
        let hasTextMaterials = meetingTruthMaterials.contains {
            $0.kind != "图片" && !$0.extractedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let visualTerms = Self.uniqueTerms(meetingTruthVisualEvidence.flatMap(\.iterationTerms))
        let missingVisualTerms = termsMissingFromTranscripts(visualTerms)
        let imageActionHints = Self.uniqueTerms(meetingTruthVisualEvidence.flatMap(\.actionHints))
        let visualConflictCount = meetingTruthConflicts.filter(conflictUsesVisualEvidence).count

        return [
            MeetingTruthMultimodalImpactRow(
                mode: .textOnly,
                isReady: hasTranscript,
                inputChannels: hasTranscript ? ["ASR 候选转写"] : [],
                visibleEffect: hasTranscript
                    ? "得到基线纪要和冲突候选，但无法看到手写图片中的补充信息。"
                    : "缺少候选转写，无法形成文本基线。",
                effectItems: missingVisualTerms.isEmpty
                    ? ["当前未发现图片中有明显超出转写的关键词。"]
                    : missingVisualTerms.prefix(4).map { "不用图片会漏掉：\($0)" },
                limitation: "不能用图片纠正 ASR 误听的术语、数字或待办。"
            ),
            MeetingTruthMultimodalImpactRow(
                mode: .visionSeparate,
                isReady: hasImages,
                inputChannels: hasImages ? ["图片原图 image_url", "Gemma 4 视觉证据摘要"] : [],
                visibleEffect: hasVisualEvidence
                    ? "Gemma 4 已从图片提取可核查证据，可看到图片单独贡献。"
                    : (hasImages ? "已有图片，但还没运行 Gemma 4 读图，差异暂时不可见。" : "没有图片材料，无法展示视觉通道。"),
                effectItems: visualEvidenceEffectItems(
                    fallback: hasImages ? ["点击 Gemma 4 读取图片后显示图片补出的关键词、数字和待办。"] : ["请先导入手写笔记、白板或截图。"]
                ),
                limitation: "只读图片不会知道发言上下文，不能单独生成完整会议结论。"
            ),
            MeetingTruthMultimodalImpactRow(
                mode: .audioTextSeparate,
                isReady: hasAudio || hasTranscript,
                inputChannels: [
                    hasAudio ? "会议音频 -> 本地 ASR" : nil,
                    hasTranscript ? "候选转写文本" : nil,
                    !visualTerms.isEmpty ? "图片证据词 -> ASR 热词候选" : nil
                ].compactMap { $0 },
                visibleEffect: !visualTerms.isEmpty
                    ? "图片证据可转成热词参与下一轮 ASR，但 Gemma 4 仍只基于转写文本裁决。"
                    : "音频先变成 ASR 文本，Gemma 4 不直接听音频。",
                effectItems: visualTerms.isEmpty
                    ? ["暂无图片证据词可用于 ASR 迭代。"]
                    : visualTerms.prefix(5).map { "可写入 ASR 热词：\($0)" },
                limitation: "图片和文本没有在同一轮判断里融合，仍可能把图片线索当作旁路提示。"
            ),
            MeetingTruthMultimodalImpactRow(
                mode: .fusedMultimodal,
                isReady: hasTranscript && (hasImages || hasVisualEvidence || hasTextMaterials),
                inputChannels: [
                    hasTranscript ? "ASR 候选转写" : nil,
                    hasImages ? "图片原图 image_url" : nil,
                    hasVisualEvidence ? "Gemma 4 图片证据摘要" : nil,
                    hasTextMaterials ? "文本/PDF/术语材料" : nil
                ].compactMap { $0 },
                visibleEffect: hasTranscript && (hasImages || hasVisualEvidence || hasTextMaterials)
                    ? "Gemma 4 在同一轮里用转写、图片和材料互相校验，能把图片线索写入冲突裁决和成果包证据说明。"
                    : "需要候选转写，并至少有图片或文本材料，才能形成融合对照。",
                effectItems: fusedEffectItems(
                    visualConflictCount: visualConflictCount,
                    imageActionHints: imageActionHints
                ),
                limitation: "图片不完整时不能自动补全事实；低置信内容仍必须人工确认。"
            )
        ]
    }

    private func buildMeetingTruthMultimodalImpactFindings() -> [MeetingTruthMultimodalImpactFinding] {
        var findings: [MeetingTruthMultimodalImpactFinding] = []
        let visualTerms = Self.uniqueTerms(meetingTruthVisualEvidence.flatMap(\.iterationTerms))
        let missingTerms = termsMissingFromTranscripts(visualTerms)

        findings.append(contentsOf: missingTerms.prefix(5).map { term in
            MeetingTruthMultimodalImpactFinding(
                kind: .visualTerm,
                title: term,
                withoutMultimodal: "仅看 ASR 候选时没有稳定出现，纪要可能不会写入。",
                withMultimodal: "Gemma 4 从图片证据中读出，可作为术语、主题或 ASR 热词候选。",
                evidence: visualEvidenceSourceLine(containing: term),
                confidence: visualEvidenceConfidence(containing: term)
            )
        })

        findings.append(contentsOf: meetingTruthConflicts.filter(conflictUsesVisualEvidence).prefix(5).map { conflict in
            let candidates = conflict.candidates.map { "\($0.source)：\($0.text)" }.joined(separator: " / ")
            return MeetingTruthMultimodalImpactFinding(
                kind: .conflictCorrection,
                title: "\(conflict.kind.title) · \(conflict.timestamp)",
                withoutMultimodal: candidates.isEmpty ? "仅靠转写无法判断该片段。" : candidates,
                withMultimodal: conflict.selectedText ?? conflict.recommendation,
                evidence: conflict.evidence,
                confidence: conflict.confidence
            )
        })

        let actionHints = Self.uniqueTerms(meetingTruthVisualEvidence.flatMap(\.actionHints))
        findings.append(contentsOf: actionHints.prefix(4).map { hint in
            MeetingTruthMultimodalImpactFinding(
                kind: .actionHint,
                title: hint,
                withoutMultimodal: "ASR 候选里没有足够明确的待办线索。",
                withMultimodal: "图片中出现了行动线索，成果包生成时可作为疑似待办旁证。",
                evidence: visualEvidenceSourceLine(containing: hint),
                confidence: visualEvidenceConfidence(containing: hint)
            )
        })

        let enabledTerms = meetingTruthASRIterationTerms
        if !enabledTerms.isEmpty {
            findings.append(
                MeetingTruthMultimodalImpactFinding(
                    kind: .asrIteration,
                    title: "图片证据反哺 ASR",
                    withoutMultimodal: "ASR 只按原音频和原热词运行。",
                    withMultimodal: "已启用 \(enabledTerms.count) 个图片证据词：\(enabledTerms.prefix(6).joined(separator: "、"))",
                    evidence: "来自已确认用于 ASR 迭代的 Gemma 4 图片证据。",
                    confidence: .medium
                )
            )
        }

        return findings
    }

    private func buildMeetingTruthDecisionOverview() -> MeetingTruthDecisionOverview {
        let hasASR = meetingTruthTranscriptSources.count >= 2
        let hasRawImage = !meetingTruthImageMaterials.isEmpty
        let hasGemmaVision = !meetingTruthVisualEvidence.isEmpty
        let resolvedCount = meetingTruthConflicts.filter(\.isResolved).count
        let unresolvedCount = meetingTruthUnresolvedCount
        let hasPackageEvidence = !meetingTruthConclusionEvidence.isEmpty
        let title: String
        let subtitle: String
        let nextAction: String

        if !hasASR {
            title = "等待候选转写"
            subtitle = "先导入至少两路 ASR，才能做跨源冲突裁决。"
            nextAction = "导入候选转写"
        } else if hasRawImage && !hasGemmaVision {
            title = "图片已导入，等待 Gemma 4 原图读取"
            subtitle = "当前只有 OCR/文本基线，原图还没有形成视觉证据。"
            nextAction = "运行 Gemma 4 读取图片"
        } else if hasASR && meetingTruthConflicts.isEmpty {
            title = "等待冲突发现"
            subtitle = "ASR 候选已就绪，下一步需要找出不能直接采用的片段。"
            nextAction = "发现冲突"
        } else if unresolvedCount > 0 {
            title = "等待人工确认"
            subtitle = "\(unresolvedCount) 个低/中置信片段还不能进入最终纪要。"
            nextAction = "确认低置信片段"
        } else if !hasPackageEvidence {
            title = "可以生成成果包"
            subtitle = "冲突已处理，下一步生成带证据链的纪要和待办。"
            nextAction = "生成成果包"
        } else {
            title = "可信成果已形成"
            subtitle = "ASR、OCR、原图和材料已经进入可核查证据链。"
            nextAction = "查看证据链与导出成果"
        }

        return MeetingTruthDecisionOverview(
            title: title,
            subtitle: subtitle,
            metrics: [
                MeetingTruthDecisionOverview.Metric(
                    title: "ASR",
                    value: "\(meetingTruthTranscriptSources.count) 路",
                    detail: hasASR ? "可交叉比对" : "至少需要 2 路",
                    isReady: hasASR
                ),
                MeetingTruthDecisionOverview.Metric(
                    title: "原图",
                    value: "\(meetingTruthImageMaterials.count) 张",
                    detail: hasGemmaVision ? "Gemma 已读图" : (hasRawImage ? "待读图" : "未导入"),
                    isReady: hasGemmaVision
                ),
                MeetingTruthDecisionOverview.Metric(
                    title: "冲突",
                    value: "\(resolvedCount)/\(meetingTruthConflicts.count)",
                    detail: unresolvedCount == 0 && !meetingTruthConflicts.isEmpty ? "已处理" : "\(unresolvedCount) 待确认",
                    isReady: unresolvedCount == 0 && !meetingTruthConflicts.isEmpty
                ),
                MeetingTruthDecisionOverview.Metric(
                    title: "成果证据",
                    value: "\(meetingTruthConclusionEvidence.count) 条",
                    detail: hasPackageEvidence ? "可追溯" : "待生成",
                    isReady: hasPackageEvidence
                )
            ],
            nextAction: nextAction
        )
    }

    private func buildMeetingTruthMultimodalSubjectComparisons() -> [MeetingTruthMultimodalSubjectComparison] {
        var comparisons: [MeetingTruthMultimodalSubjectComparison] = []

        comparisons.append(contentsOf: meetingTruthConflicts.prefix(6).map { conflict in
            let candidateText = conflict.candidates.isEmpty
                ? "没有可用 ASR 候选。"
                : conflict.candidates.map { "\($0.source)：\($0.text)" }.joined(separator: " / ")
            let visualText = visualEvidenceLine(for: conflict)
            let fused = conflict.selectedText ?? conflict.recommendation
            let ocrBaseline = ocrBaselineLine(for: conflict)
            return MeetingTruthMultimodalSubjectComparison(
                kind: .conflict,
                subject: "\(conflict.kind.title) · \(conflict.timestamp)",
                asrOnly: candidateText,
                visionOnly: visualText,
                separateUse: "\(ocrBaseline)\n图片和 ASR 并排展示，但不自动裁决。",
                fusedUse: fused.isEmpty ? "仍需人工确认。" : "裁决：\(fused)",
                evidence: conflict.evidence.isEmpty ? "来自候选转写差异和当前多模态材料。" : conflict.evidence,
                confidence: conflict.confidence
            )
        })

        let visualTerms = Self.uniqueTerms(meetingTruthVisualEvidence.flatMap(\.iterationTerms))
        let transcriptText = meetingTruthTranscriptSources.map(\.text).joined(separator: "\n")
        comparisons.append(contentsOf: visualTerms.prefix(6).map { term in
            let asrMatches = meetingTruthTranscriptSources
                .filter { Self.text($0.text, contains: term) }
                .map(\.name)
            let asrOnly = asrMatches.isEmpty
                ? "ASR 候选未稳定出现。"
                : "ASR 中出现于：\(asrMatches.prefix(3).joined(separator: "、"))"
            let isMissing = !Self.text(transcriptText, contains: term)
            return MeetingTruthMultimodalSubjectComparison(
                kind: .term,
                subject: term,
                asrOnly: asrOnly,
                visionOnly: "\(ocrBaselineLine(containing: term))\nGemma 原图：\(visualEvidenceSourceLine(containing: term))",
                separateUse: isMissing
                    ? "图片能读出该词，但 ASR 未确认，只能作为旁证。"
                    : "ASR 和图片都提到该词，但还没有合并成最终裁决。",
                fusedUse: isMissing
                    ? "融合结果：作为低/中置信术语候选，进入人工确认或 ASR 热词迭代。"
                    : "融合结果：可作为更高置信术语写入纪要和后续校验。",
                evidence: "来自 Gemma 4 图片证据和 ASR 候选文本对照。",
                confidence: visualEvidenceConfidence(containing: term)
            )
        })

        let actionHints = Self.uniqueTerms(meetingTruthVisualEvidence.flatMap(\.actionHints))
        comparisons.append(contentsOf: actionHints.prefix(4).map { hint in
            MeetingTruthMultimodalSubjectComparison(
                kind: .action,
                subject: hint,
                asrOnly: Self.text(transcriptText, contains: hint) ? "ASR 中可找到相近待办线索。" : "ASR 中没有足够明确的待办线索。",
                visionOnly: "\(ocrBaselineLine(containing: hint))\nGemma 原图：\(visualEvidenceSourceLine(containing: hint))",
                separateUse: "图片提示待办，但缺少会议上下文时不能直接分派。",
                fusedUse: "融合结果：结合转写上下文后，作为疑似待办进入成果包或人工确认。",
                evidence: "来自 Gemma 4 图片 actionHints。",
                confidence: visualEvidenceConfidence(containing: hint)
            )
        })

        let visualStructure = Self.uniqueTerms(meetingTruthVisualEvidence.flatMap { $0.layoutCues + $0.visualMarks })
        comparisons.append(contentsOf: visualStructure.prefix(5).map { cue in
            MeetingTruthMultimodalSubjectComparison(
                kind: .term,
                subject: cue,
                asrOnly: "ASR 文本看不到图片版式、圈注、箭头或提示框。",
                visionOnly: "\(ocrBaselineLine(containing: cue))\nGemma 原图：\(visualEvidenceSourceLine(containing: cue))",
                separateUse: "图片能解释视觉强调，但和 ASR 结论仍是并排证据。",
                fusedUse: "融合结果：作为判断优先级、主题归属或待确认原因的视觉证据。",
                evidence: "来自 Gemma 4 对原图版式/视觉标记的理解。",
                confidence: visualEvidenceConfidence(containing: cue)
            )
        })

        let enabledTerms = meetingTruthASRIterationTerms
        if !enabledTerms.isEmpty {
            comparisons.append(
                MeetingTruthMultimodalSubjectComparison(
                    kind: .asrIteration,
                    subject: "图片证据词反哺 ASR",
                    asrOnly: "原 ASR 只按音频和原热词运行。",
                    visionOnly: "图片读出：\(enabledTerms.prefix(6).joined(separator: "、"))",
                    separateUse: "图片词单独存在，尚未改变转写。",
                    fusedUse: "融合结果：已写入 ASR 热词，可用于下一轮转写改善术语识别。",
                    evidence: "来自已打开“用于 ASR 迭代”的图片证据。",
                    confidence: .medium
                )
            )
        }

        return Array(comparisons.prefix(12))
    }

    private func buildMeetingTruthOCRValueComparisons() -> [MeetingTruthOCRValueComparison] {
        var comparisons: [MeetingTruthOCRValueComparison] = []

        for evidence in meetingTruthVisualEvidence {
            let ocrText = meetingTruthImageMaterials
                .first { $0.id == evidence.materialID }?
                .extractedText
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            let ocrSummary = ocrText.isEmpty
                ? "OCR 未读出稳定文字。"
                : "OCR 只得到文字：\(Self.truncatedText(ocrText.replacingOccurrences(of: "\n", with: " / "), limit: 70))"
            let visualSummary = evidence.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Gemma 4 已读取原图，但摘要为空。"
                : "Gemma 4 原图理解：\(Self.truncatedText(evidence.summary, limit: 70))"

            if !evidence.ocrContrast.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                comparisons.append(
                    MeetingTruthOCRValueComparison(
                        kind: .handwriting,
                        subject: evidence.materialName,
                        ocrOnly: ocrSummary,
                        gemmaImage: visualSummary,
                        fusedImpact: "用于判断 OCR 文本不足时哪些内容仍需依赖原图和人工确认。",
                        evidence: evidence.ocrContrast,
                        confidence: evidence.confidence
                    )
                )
            }

            comparisons.append(contentsOf: evidence.layoutCues.prefix(3).map { cue in
                MeetingTruthOCRValueComparison(
                    kind: .layout,
                    subject: cue,
                    ocrOnly: "OCR 通常只返回文字，无法说明标题、分组、层级、表格或空间关系。",
                    gemmaImage: "Gemma 4 原图读到版式结构：\(cue)",
                    fusedImpact: "影响主题归属、优先级判断和哪些内容应进入纪要。",
                    evidence: visualEvidenceSourceLine(containing: cue),
                    confidence: evidence.confidence
                )
            })

            comparisons.append(contentsOf: evidence.visualMarks.prefix(3).map { mark in
                MeetingTruthOCRValueComparison(
                    kind: .visualMark,
                    subject: mark,
                    ocrOnly: "OCR 可能读到被标注的字，但不知道它被圈出、箭头指向或放进提示框。",
                    gemmaImage: "Gemma 4 原图读到视觉标记：\(mark)",
                    fusedImpact: "作为重点、风险、待确认原因或任务优先级证据。",
                    evidence: visualEvidenceSourceLine(containing: mark),
                    confidence: evidence.confidence
                )
            })

            comparisons.append(contentsOf: evidence.actionHints.prefix(3).map { hint in
                MeetingTruthOCRValueComparison(
                    kind: .action,
                    subject: hint,
                    ocrOnly: ocrBaselineLine(containing: hint),
                    gemmaImage: "Gemma 4 从原图识别为疑似待办：\(hint)",
                    fusedImpact: "与 ASR 上下文合并后进入待办候选，避免只靠转写遗漏行动项。",
                    evidence: visualEvidenceSourceLine(containing: hint),
                    confidence: evidence.confidence
                )
            })

            comparisons.append(contentsOf: evidence.iterationTerms.prefix(3).map { term in
                MeetingTruthOCRValueComparison(
                    kind: .term,
                    subject: term,
                    ocrOnly: ocrBaselineLine(containing: term),
                    gemmaImage: "Gemma 4 原图把它识别为术语/数字/关键词：\(term)",
                    fusedImpact: "用于 ASR 冲突裁决、成果包证据说明，必要时反哺 ASR 热词。",
                    evidence: visualEvidenceSourceLine(containing: term),
                    confidence: evidence.confidence
                )
            })
        }

        if comparisons.isEmpty, !meetingTruthImageMaterials.isEmpty {
            comparisons.append(
                MeetingTruthOCRValueComparison(
                    kind: .handwriting,
                    subject: "图片原图尚未读取",
                    ocrOnly: meetingTruthImageMaterials.contains { !$0.extractedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                        ? "已有 OCR 基线，但它只是文字通道。"
                        : "OCR 暂时也没有稳定文本。",
                    gemmaImage: "点击“Gemma 4 读取图片”后，原图会作为 image_url 进入多模态模型。",
                    fusedImpact: "读图完成后才能判断 OCR 是否漏掉版式、圈注、箭头、提示框和手写重点。",
                    evidence: "当前尚无 Gemma 4 图片视觉证据。",
                    confidence: .low
                )
            )
        }

        return Array(comparisons.prefix(10))
    }

    private func buildMeetingTruthCorrectionLedger() -> [MeetingTruthCorrectionLedgerRow] {
        let rows = meetingTruthConflicts.prefix(10).map { conflict in
            let candidates = conflict.candidates.isEmpty
                ? "没有可用 ASR 候选。"
                : conflict.candidates.map { "\($0.source)：\($0.text)" }.joined(separator: " / ")
            let selected = conflict.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines)
            let conclusion = selected?.isEmpty == false ? selected! : conflict.recommendation
            let status = selected?.isEmpty == false
                ? "已确认写入可信逐字稿"
                : (conflict.confidence == .low ? "待人工确认" : "待接受建议")
            let crossCheck = [
                ocrBaselineLine(for: conflict),
                conflict.evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "Gemma 4 依据 ASR 候选差异和当前材料给出建议。"
                    : conflict.evidence
            ].joined(separator: "\n")

            return MeetingTruthCorrectionLedgerRow(
                subject: "\(conflict.kind.title) · \(conflict.timestamp)",
                asrRisk: candidates,
                selectedConclusion: conclusion.isEmpty ? "暂无稳定结论" : conclusion,
                crossCheck: crossCheck,
                visualEvidence: visualEvidenceLine(for: conflict),
                status: status,
                confidence: conflict.confidence
            )
        }
        return Array(rows)
    }

    private func buildMeetingTruthMultimodalCallStatus() -> MeetingTruthMultimodalCallStatus {
        let imageCount = meetingTruthImageMaterials.count
        let imageOCRCount = meetingTruthImageMaterials.filter { !$0.extractedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
        let visualEvidenceCount = meetingTruthVisualEvidence.count
        let modelName = meetingTruthVisualEvidence.first?.model ?? meetingAISettings.model
        let hasASR = meetingTruthTranscriptSources.count >= 2
        let hasTextMaterials = meetingTruthMaterials.contains {
            $0.kind != "图片" && !$0.extractedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let proven = visualEvidenceCount > 0
        return MeetingTruthMultimodalCallStatus(
            title: proven ? "已调用 Gemma 4 多模态读图" : (imageCount > 0 ? "图片已导入，尚未完成 Gemma 4 读图" : "尚未导入图片"),
            isMultimodalCallProven: proven,
            rawImageInput: imageCount > 0
                ? "\(imageCount) 张图片原图将通过 image_url 发送给 Gemma 4"
                : "无图片原图输入",
            ocrTextInput: imageOCRCount > 0
                ? "本机 OCR 基线：\(imageOCRCount) 张图片已提取文字，仅用于对照"
                : "本机 OCR 基线：未读出稳定图片文字；PDF/文本仍是文本通道",
            asrInput: hasASR
                ? "\(meetingTruthTranscriptSources.count) 份 ASR 候选作为文本证据"
                : "ASR 候选不足，无法交叉校验",
            fusionInput: hasASR && (imageCount > 0 || hasTextMaterials)
                ? "可进行 ASR + 原图/视觉证据 + 文本材料融合裁决"
                : "融合证据不足",
            model: modelName
        )
    }

    private func buildMeetingTruthMultimodalProof() -> MeetingTruthMultimodalProof {
        let imageMaterials = meetingTruthImageMaterials
        let ocrImageCount = imageMaterials.filter { !$0.extractedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
        let pdfTextCount = meetingTruthMaterials.filter {
            $0.kind == "会议材料" && !$0.extractedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count
        let visualEvidenceCount = meetingTruthVisualEvidence.count
        let layoutCount = meetingTruthVisualEvidence.flatMap(\.layoutCues).count
        let markCount = meetingTruthVisualEvidence.flatMap(\.visualMarks).count
        let contrastCount = meetingTruthVisualEvidence.filter {
            !$0.ocrContrast.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count
        let visualConflictCount = meetingTruthConflicts.filter(conflictUsesVisualEvidence).count
        let correctionCount = meetingTruthConflicts.filter(\.isResolved).count
        let latestCallAt = meetingTruthVisualEvidence.map(\.generatedAt).max()
        let modelName = meetingTruthVisualEvidence.first?.model ?? meetingAISettings.model

        var missing: [String] = []
        if imageMaterials.isEmpty {
            missing.append("缺图片原图输入")
        }
        if meetingTruthTranscriptSources.count < 2 {
            missing.append("缺至少两路 ASR 候选")
        }
        if meetingTruthVisualEvidence.isEmpty {
            missing.append("尚无 Gemma 4 图片视觉证据")
        }
        if meetingTruthConflicts.isEmpty {
            missing.append("尚无冲突裁决记录")
        }

        return MeetingTruthMultimodalProof(
            isProven: visualEvidenceCount > 0,
            title: visualEvidenceCount > 0 ? "Gemma 4 多模态调用已形成证据" : "Gemma 4 多模态调用尚未形成证据",
            model: modelName,
            latestCallAt: latestCallAt,
            rawImageInputs: imageMaterials.map { "\($0.name) · image_url 原图输入" },
            inputSummary: [
                "\(meetingTruthTranscriptSources.count) 路 ASR 候选",
                "\(ocrImageCount) 张图片 OCR 基线",
                "\(imageMaterials.count) 张 image_url 原图",
                "\(pdfTextCount) 份 PDF/文本材料"
            ],
            outputSummary: [
                "\(visualEvidenceCount) 条 Gemma 图片证据",
                "\(layoutCount) 条版式线索",
                "\(markCount) 条圈注/箭头/提示框线索",
                "\(contrastCount) 条 OCR 对比"
            ],
            derivedJudgementSummary: [
                "\(visualConflictCount) 个冲突引用视觉证据",
                "\(correctionCount) 个已确认修正",
                "\(meetingTruthConclusionEvidence.count) 条最终结论证据链",
                "\(meetingTruthOCRValueComparisons.count) 条 OCR vs 原图对照"
            ],
            missingRequirements: missing
        )
    }

    private func buildMeetingTruthEvidenceChannelStatuses() -> [MeetingTruthEvidenceChannelStatus] {
        let pdfTextCount = meetingTruthMaterials.filter {
            $0.kind == "会议材料" && !$0.extractedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count
        let imageOCRCount = meetingTruthImageMaterials.filter {
            !$0.extractedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count
        let layoutCount = meetingTruthVisualEvidence.flatMap(\.layoutCues).count
        let visualMarkCount = meetingTruthVisualEvidence.flatMap(\.visualMarks).count
        let conflictCount = meetingTruthConflicts.count
        return [
            MeetingTruthEvidenceChannelStatus(
                title: "ASR",
                value: "\(meetingTruthTranscriptSources.count) 路候选",
                detail: "只提供听写文本，会有误听和同音词风险。",
                isActive: meetingTruthTranscriptSources.count >= 2
            ),
            MeetingTruthEvidenceChannelStatus(
                title: "OCR / PDF 文本",
                value: "\(imageOCRCount) 张图片 OCR / \(pdfTextCount) 份 PDF 文本",
                detail: "OCR/PDF 文本只保留文字，容易丢失圈注、箭头、版式和空间关系。",
                isActive: imageOCRCount > 0 || pdfTextCount > 0
            ),
            MeetingTruthEvidenceChannelStatus(
                title: "图片原图",
                value: "\(meetingTruthImageMaterials.count) 张 image_url",
                detail: "原图直接进入 Gemma 4，用于手写、版式、圈注、箭头和提示框理解。",
                isActive: !meetingTruthImageMaterials.isEmpty
            ),
            MeetingTruthEvidenceChannelStatus(
                title: "手写/版式",
                value: "\(layoutCount + visualMarkCount) 条视觉线索",
                detail: "显示图片不是附件，而是影响判断的结构证据。",
                isActive: layoutCount + visualMarkCount > 0
            ),
            MeetingTruthEvidenceChannelStatus(
                title: "交叉校验",
                value: "\(conflictCount) 个冲突",
                detail: "Gemma 4 用 ASR 候选、原图和材料判断哪些结论不能直接采用。",
                isActive: conflictCount > 0
            )
        ]
    }

    private func buildMeetingTruthInputRoutes() -> [MeetingTruthInputRoute] {
        let imageCount = meetingTruthImageMaterials.count
        let imageOCRCount = meetingTruthImageMaterials.filter {
            !$0.extractedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count
        let textMaterialCount = meetingTruthMaterials.filter {
            $0.kind != "图片" && !$0.extractedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count
        let hasVisualEvidence = !meetingTruthVisualEvidence.isEmpty
        return [
            MeetingTruthInputRoute(
                channel: "ASR 候选",
                input: "\(meetingTruthTranscriptSources.count) 路转写文本",
                route: "音频先由 ASR 转成文本，再交给 Gemma 4 做冲突判断。",
                role: "提供会议发言上下文，但可能有同音词、数字、人名错误。",
                isMultimodal: false,
                isActive: !meetingTruthTranscriptSources.isEmpty
            ),
            MeetingTruthInputRoute(
                channel: "OCR 基线",
                input: "\(imageOCRCount) 张图片 OCR 文本",
                route: "本机 Vision OCR 只生成文字基线，不代替 Gemma 4 原图读取。",
                role: "用于判断 OCR 文本分析和原图多模态理解的差别。",
                isMultimodal: false,
                isActive: imageOCRCount > 0
            ),
            MeetingTruthInputRoute(
                channel: "图片/手写原图",
                input: "\(imageCount) 张 image_url 原图",
                route: "原图直接发送给 Gemma 4，用视觉能力读取手写、版式、圈注、箭头、提示框。",
                role: hasVisualEvidence ? "已产生视觉证据并参与校验。" : "待读图；读图后才算形成多模态证据。",
                isMultimodal: true,
                isActive: imageCount > 0
            ),
            MeetingTruthInputRoute(
                channel: "PDF/文本材料",
                input: "\(textMaterialCount) 份已提取文本",
                route: "PDF、Word、PPT 若只抽成文本，就是文本证据；页面截图/图片页才进入视觉通道。",
                role: "补充术语、背景和会议材料，不单独证明多模态。",
                isMultimodal: false,
                isActive: textMaterialCount > 0
            ),
            MeetingTruthInputRoute(
                channel: "融合裁决",
                input: "\(meetingTruthConflicts.count) 个冲突 / \(meetingTruthConclusionEvidence.count) 条结论证据",
                route: "Gemma 4 把 ASR、OCR、原图视觉证据和文本材料放到同一判断里。",
                role: "修正转写风险，并给最终纪要、待办和证据链提供依据。",
                isMultimodal: hasVisualEvidence,
                isActive: !meetingTruthConflicts.isEmpty || !meetingTruthConclusionEvidence.isEmpty
            )
        ]
    }

    private func buildMeetingTruthConclusionEvidence() -> [MeetingTruthConclusionEvidence] {
        guard let analysis = meetingTruthAnalysis else { return [] }
        var rows: [MeetingTruthConclusionEvidence] = []

        if !analysis.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            rows.append(conclusionEvidence(kind: .summary, conclusion: analysis.summary, note: analysis.evidenceNotes.first))
        }

        rows.append(contentsOf: analysis.keyPoints.prefix(6).enumerated().map { index, point in
            let note = analysis.evidenceNotes.indices.contains(index) ? analysis.evidenceNotes[index] : nil
            return conclusionEvidence(kind: .keyPoint, conclusion: point, note: note)
        })

        rows.append(contentsOf: analysis.minutes.prefix(6).enumerated().map { index, minute in
            let noteIndex = index + analysis.keyPoints.count
            let note = analysis.evidenceNotes.indices.contains(noteIndex) ? analysis.evidenceNotes[noteIndex] : nil
            return conclusionEvidence(kind: .minute, conclusion: minute, note: note)
        })

        rows.append(contentsOf: analysis.actionItems.prefix(6).map { item in
            let owner = item.owner?.trimmingCharacters(in: .whitespacesAndNewlines)
            let due = item.due?.trimmingCharacters(in: .whitespacesAndNewlines)
            let conclusion = "\(item.task) · \(owner?.isEmpty == false ? owner! : "负责人待确认") · \(due?.isEmpty == false ? due! : "时间待确认")"
            return conclusionEvidence(kind: .action, conclusion: conclusion, note: analysis.evidenceNotes.first(where: { Self.text($0, contains: item.task) }))
        })

        rows.append(contentsOf: meetingTruthConflicts.filter(\.isResolved).prefix(6).map { conflict in
            MeetingTruthConclusionEvidence(
                kind: .correction,
                conclusion: "\(conflict.kind.title)：\(conflict.selectedText ?? conflict.recommendation)",
                asrEvidence: conflict.candidates.map { "\($0.source)：\($0.text)" }.joined(separator: " / "),
                ocrEvidence: ocrBaselineLine(for: conflict),
                imageEvidence: visualEvidenceLine(for: conflict),
                fusionReason: conflict.evidence.isEmpty ? "Gemma 4 基于候选差异和材料证据给出修正。" : conflict.evidence,
                risk: conflict.confidence == .low ? "低置信，不能直接采用 ASR，需人工确认。" : "已确认后可写入可信逐字稿。",
                confidence: conflict.confidence
            )
        })

        return Array(rows.prefix(18))
    }

    private func conclusionEvidence(
        kind: MeetingTruthConclusionEvidence.Kind,
        conclusion: String,
        note: String?
    ) -> MeetingTruthConclusionEvidence {
        let matchedConflict = meetingTruthConflicts.first { conflict in
            Self.text(conclusion, contains: conflict.selectedText ?? conflict.recommendation) ||
            conflict.candidates.contains { Self.text(conclusion, contains: $0.text) }
        }
        let matchedVisual = meetingTruthVisualEvidence.first { evidence in
            visualEvidence(evidence, contains: conclusion) ||
            evidence.iterationTerms.contains { Self.text(conclusion, contains: $0) } ||
            evidence.actionHints.contains { Self.text(conclusion, contains: $0) }
        }
        let asrMatches = meetingTruthTranscriptSources
            .filter { source in Self.text(source.text, contains: conclusion) }
            .map(\.name)
        let ocrMatches = meetingTruthImageMaterials
            .filter { material in Self.text(material.extractedText, contains: conclusion) }
            .map(\.name)

        return MeetingTruthConclusionEvidence(
            kind: kind,
            conclusion: conclusion,
            asrEvidence: asrMatches.isEmpty
                ? (matchedConflict?.candidates.map { "\($0.source)：\($0.text)" }.joined(separator: " / ") ?? "未能在单一路 ASR 中完整确认。")
                : "出现于 ASR：\(asrMatches.prefix(3).joined(separator: "、"))",
            ocrEvidence: ocrMatches.isEmpty
                ? "OCR 未完整覆盖该结论。"
                : "OCR 命中：\(ocrMatches.prefix(2).joined(separator: "、"))",
            imageEvidence: matchedVisual.map { visualEvidenceSourceLine(containing: $0.summary.isEmpty ? $0.materialName : $0.summary) }
                ?? visualEvidenceSummaryLine(),
            fusionReason: note?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? note!
                : inferredFusionReason(for: conclusion, conflict: matchedConflict, visualEvidence: matchedVisual),
            risk: matchedConflict?.confidence == .low
                ? "ASR 候选存在低置信冲突，不能直接采用。"
                : (matchedVisual == nil ? "主要来自文本证据，图片未提供直接补强。" : "图片原图提供了文本外证据。"),
            confidence: matchedConflict?.confidence ?? matchedVisual?.confidence ?? .medium
        )
    }

    private func visualEvidenceSummaryLine() -> String {
        guard !meetingTruthVisualEvidence.isEmpty else {
            return "没有图片原图证据。"
        }
        let names = meetingTruthVisualEvidence.map(\.materialName).prefix(2).joined(separator: "、")
        let layoutCount = meetingTruthVisualEvidence.flatMap(\.layoutCues).count
        let markCount = meetingTruthVisualEvidence.flatMap(\.visualMarks).count
        let termCount = Self.uniqueTerms(meetingTruthVisualEvidence.flatMap(\.iterationTerms)).count
        return "Gemma 4 已读取图片原图：\(names)；提取 \(termCount) 个术语/数字、\(layoutCount) 条版式线索、\(markCount) 条圈注/箭头/提示框线索。"
    }

    private func inferredFusionReason(
        for conclusion: String,
        conflict: MeetingTruthConflict?,
        visualEvidence: MeetingTruthVisualEvidence?
    ) -> String {
        if let conflict {
            return conflict.evidence.isEmpty
                ? "Gemma 4 将多路 ASR 候选与材料证据对齐后，选择已确认结果。"
                : conflict.evidence
        }
        if let visualEvidence {
            let visualHints = Self.uniqueTerms(
                visualEvidence.keywords + visualEvidence.actionHints + visualEvidence.layoutCues + visualEvidence.visualMarks
            )
            let hint = visualHints.prefix(3).joined(separator: "、")
            return hint.isEmpty
                ? "Gemma 4 把转写文本与图片原图证据共同用于该结论。"
                : "Gemma 4 用图片原图中的“\(hint)”补强转写文本，形成该结论。"
        }
        if meetingTruthTranscriptSources.count > 1 {
            return "Gemma 4 在多路 ASR 候选之间取共识；没有图片直接证据时不把图片作为该结论依据。"
        }
        return "该结论主要来自可信逐字稿和文本材料。"
    }

    private func refreshMeetingTruthMultimodalComparisons() {
        let hasTranscript = !meetingTruthTrustedTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasAudio = !selectedAudioPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            meetingTruthMaterials.contains { $0.kind == "会议录音" }
        let hasImages = !meetingTruthImageMaterials.isEmpty
        let hasVisualEvidence = !meetingTruthVisualEvidence.isEmpty
        let iterationTerms = meetingTruthASRIterationTerms
        let hasTextMaterials = meetingTruthMaterials.contains {
            $0.kind != "图片" && !$0.extractedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        meetingTruthMultimodalComparisons = [
            MeetingTruthMultimodalComparison(
                mode: .textOnly,
                isAvailable: hasTranscript,
                result: hasTranscript
                    ? "只使用可信逐字稿/候选转写，不发送图片，也不引用图片视觉证据。"
                    : "缺少转写文本，无法形成仅文本结果。",
                evidenceSources: hasTranscript ? ["ASR 转写文本"] : []
            ),
            MeetingTruthMultimodalComparison(
                mode: .visionSeparate,
                isAvailable: hasImages,
                result: hasVisualEvidence
                    ? "Gemma 4 已单独读取图片，图片证据摘要可作为旁证展示。"
                    : (hasImages ? "已有图片，但尚未运行 Gemma 4 图片证据提取。" : "没有图片材料。"),
                evidenceSources: hasVisualEvidence
                    ? meetingTruthVisualEvidence.map { "图片：\($0.materialName)" }
                    : (hasImages ? meetingTruthImageMaterials.map { "图片待读取：\($0.name)" } : [])
            ),
            MeetingTruthMultimodalComparison(
                mode: .audioTextSeparate,
                isAvailable: hasTranscript || hasAudio,
                result: hasAudio
                    ? "音频先由本地 ASR 转写；Gemma 4 不直接接收音频，只处理转写文本。\(iterationTerms.isEmpty ? "" : "已准备 \(iterationTerms.count) 个多模态证据词用于下一轮 ASR。")"
                    : "没有关联录音；当前只体现文本链路。",
                evidenceSources: [hasAudio ? "会议录音 -> 本地 ASR 转写" : nil, hasTranscript ? "转写文本" : nil].compactMap { $0 }
            ),
            MeetingTruthMultimodalComparison(
                mode: .fusedMultimodal,
                isAvailable: hasTranscript && (hasImages || hasVisualEvidence || hasTextMaterials),
                result: hasTranscript && (hasImages || hasVisualEvidence || hasTextMaterials)
                    ? "Gemma 4 同轮融合转写文本、图片原图、图片证据摘要和文本材料。"
                    : "需要转写文本，并至少有图片或文本材料，才能展示融合链路。",
                evidenceSources: [
                    hasTranscript ? "ASR/候选转写" : nil,
                    hasImages ? "图片原图 image_url" : nil,
                    hasVisualEvidence ? "Gemma 4 图片证据摘要" : nil,
                    hasTextMaterials ? "文本/PDF/术语材料" : nil
                ].compactMap { $0 }
            )
        ]
    }

    private func visualEvidenceEffectItems(fallback: [String]) -> [String] {
        let evidenceItems = meetingTruthVisualEvidence.flatMap { evidence -> [String] in
            var items: [String] = []
            let terms = Self.uniqueTerms(evidence.iterationTerms)
            if !terms.isEmpty {
                items.append("读出关键词：\(terms.prefix(4).joined(separator: "、"))")
            }
            if !evidence.actionHints.isEmpty {
                items.append("疑似待办：\(evidence.actionHints.prefix(2).joined(separator: "、"))")
            }
            if !evidence.layoutCues.isEmpty {
                items.append("版式结构：\(evidence.layoutCues.prefix(2).joined(separator: "、"))")
            }
            if !evidence.visualMarks.isEmpty {
                items.append("视觉标记：\(evidence.visualMarks.prefix(2).joined(separator: "、"))")
            }
            if !evidence.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                items.append("图片摘要：\(Self.truncatedText(evidence.summary, limit: 44))")
            }
            return items
        }
        return evidenceItems.isEmpty ? fallback : Array(evidenceItems.prefix(4))
    }

    private func fusedEffectItems(visualConflictCount: Int, imageActionHints: [String]) -> [String] {
        var items: [String] = []
        if visualConflictCount > 0 {
            items.append("已有 \(visualConflictCount) 个冲突建议引用了图片或图片证据。")
        }
        if !imageActionHints.isEmpty {
            items.append("图片补出待办线索：\(imageActionHints.prefix(3).joined(separator: "、"))")
        }
        if let analysis = meetingTruthAnalysis, !analysis.evidenceNotes.isEmpty {
            items.append("成果包已有 \(analysis.evidenceNotes.count) 条证据来源说明。")
        }
        if items.isEmpty {
            items.append("运行图片读取、冲突发现或成果包生成后，这里会显示融合带来的修正。")
        }
        return items
    }

    private func termsMissingFromTranscripts(_ terms: [String]) -> [String] {
        let transcriptText = meetingTruthTranscriptSources.map(\.text).joined(separator: "\n")
        return terms.filter { term in
            !Self.text(transcriptText, contains: term)
        }
    }

    private func conflictUsesVisualEvidence(_ conflict: MeetingTruthConflict) -> Bool {
        let conflictText = [
            conflict.context,
            conflict.recommendation,
            conflict.evidence,
            conflict.selectedText ?? "",
            conflict.candidates.map(\.text).joined(separator: " ")
        ].joined(separator: " ")
        if Self.text(conflictText, contains: "图片") ||
            Self.text(conflictText, contains: "手写") ||
            Self.text(conflictText, contains: "视觉") ||
            Self.text(conflictText, contains: "白板") ||
            Self.text(conflictText, contains: "截图") {
            return true
        }
        let visualTerms = Self.uniqueTerms(meetingTruthVisualEvidence.flatMap(\.iterationTerms))
        return visualTerms.contains { term in
            Self.text(conflictText, contains: term)
        }
    }

    private func visualEvidenceSourceLine(containing term: String) -> String {
        guard let evidence = meetingTruthVisualEvidence.first(where: { visualEvidence($0, contains: term) }) else {
            return "来自 Gemma 4 图片视觉证据。"
        }
        let summary = Self.truncatedText(evidence.summary, limit: 52)
        if summary.isEmpty {
            return "来自 \(evidence.materialName) 的 Gemma 4 图片视觉证据。"
        }
        return "\(evidence.materialName)：\(summary)"
    }

    private func visualEvidenceLine(for conflict: MeetingTruthConflict) -> String {
        let conflictTerms = Self.uniqueTerms(
            conflict.candidates.map(\.text) + [conflict.recommendation, conflict.selectedText ?? ""]
        )
        if let matchedTerm = conflictTerms.first(where: { term in
            meetingTruthVisualEvidence.contains { visualEvidence($0, contains: term) }
        }) {
            return visualEvidenceSourceLine(containing: matchedTerm)
        }
        if conflictUsesVisualEvidence(conflict) {
            return "Gemma 4 冲突证据中已引用图片/手写/视觉线索。"
        }
        return meetingTruthVisualEvidence.isEmpty
            ? "没有图片证据。"
            : "图片未直接覆盖该冲突，只能作为上下文旁证。"
    }

    private func ocrBaselineLine(for conflict: MeetingTruthConflict) -> String {
        let conflictTerms = Self.uniqueTerms(
            conflict.candidates.map(\.text) + [conflict.recommendation, conflict.selectedText ?? ""]
        )
        if let term = conflictTerms.first(where: { term in
            meetingTruthImageMaterials.contains { Self.text($0.extractedText, contains: term) }
        }) {
            return ocrBaselineLine(containing: term)
        }
        return "OCR 基线：未覆盖该冲突。"
    }

    private func ocrBaselineLine(containing term: String) -> String {
        let matchedImages = meetingTruthImageMaterials.filter {
            Self.text($0.extractedText, contains: term)
        }
        if let image = matchedImages.first {
            return "OCR 基线：在 \(image.name) 中读到“\(term)”。"
        }
        if meetingTruthImageMaterials.contains(where: { !$0.extractedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return "OCR 基线：未读到“\(term)”。"
        }
        return "OCR 基线：没有可用图片 OCR 文本。"
    }

    private func visualEvidenceConfidence(containing term: String) -> MeetingTruthConfidence {
        meetingTruthVisualEvidence.first(where: { visualEvidence($0, contains: term) })?.confidence ?? .medium
    }

    private func visualEvidence(_ evidence: MeetingTruthVisualEvidence, contains term: String) -> Bool {
        let evidenceText = [
            evidence.summary,
            evidence.extractedNumbers.joined(separator: " "),
            evidence.keywords.joined(separator: " "),
            evidence.participants.map(\.displayText).joined(separator: " "),
            evidence.actionHints.joined(separator: " "),
            evidence.layoutCues.joined(separator: " "),
            evidence.visualMarks.joined(separator: " "),
            evidence.ocrContrast,
            evidence.iterationTerms.joined(separator: " ")
        ].joined(separator: " ")
        return Self.text(evidenceText, contains: term)
    }

    private func suspectedPersonNameVariants(for name: String, in text: String) -> [String] {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedName.count >= 2, trimmedName.count <= 12 else { return [] }

        if trimmedName.unicodeScalars.allSatisfy({ Self.isCJKScalar($0) }) {
            return Self.suspectedChineseNameVariants(for: trimmedName, in: text)
        }

        return []
    }

    private func normalizedComparableText(_ text: String) -> String {
        text.lowercased()
            .filter { !$0.isWhitespace && !$0.isPunctuation }
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sameText(_ lhs: String, _ rhs: String) -> Bool {
        normalizedComparableText(lhs) == normalizedComparableText(rhs)
    }

    nonisolated private static func text(_ text: String, contains term: String) -> Bool {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return text.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    nonisolated private static func suspectedChineseNameVariants(for name: String, in text: String) -> [String] {
        let nameCharacters = Array(name)
        guard nameCharacters.count >= 2 else { return [] }

        let textCharacters = Array(text)
        let candidateLengths = Set([nameCharacters.count - 1, nameCharacters.count, nameCharacters.count + 1].filter { $0 >= 2 && $0 <= 4 })
            .sorted()
        var scored: [(text: String, score: Int)] = []
        var seen = Set<String>()

        for length in candidateLengths {
            guard textCharacters.count >= length else { continue }
            for start in 0...(textCharacters.count - length) {
                let candidate = String(textCharacters[start..<(start + length)])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard candidate.count == length,
                      candidate != name,
                      !seen.contains(candidate),
                      candidate.unicodeScalars.allSatisfy({ isCJKScalar($0) }),
                      isLikelyPersonNameVariant(candidate),
                      !isLikelyPersonRoleAlias(candidate) else {
                    continue
                }

                let score = suspectedNameScore(candidate: candidate, target: name)
                guard score >= 3 else { continue }
                seen.insert(candidate)
                scored.append((candidate, score))
            }
        }

        return scored
            .sorted { lhs, rhs in
                if lhs.score == rhs.score { return lhs.text.count < rhs.text.count }
                return lhs.score > rhs.score
            }
            .prefix(6)
            .map(\.text)
    }

    nonisolated private static func suspectedNameScore(candidate: String, target: String) -> Int {
        let candidateCharacters = Array(candidate)
        let targetCharacters = Array(target)
        guard !candidateCharacters.isEmpty, !targetCharacters.isEmpty else { return 0 }

        var score = 0
        if candidateCharacters.first == targetCharacters.first { score += 3 }
        if candidateCharacters.last == targetCharacters.last { score += 2 }
        let overlap = Set(candidateCharacters).intersection(Set(targetCharacters)).count
        score += overlap
        let distance = editDistance(candidateCharacters, targetCharacters)
        if distance == 1 { score += 3 }
        if distance == 2 { score += 1 }
        if abs(candidateCharacters.count - targetCharacters.count) > 1 { score -= 3 }
        return score
    }

    nonisolated private static func isLikelyPersonRoleAlias(_ text: String) -> Bool {
        let characters = Array(text)
        guard characters.count == 2, let suffix = characters.last else { return false }
        return ["总", "董", "工", "师", "姐", "哥", "叔", "导"].contains(suffix)
    }

    nonisolated private static func isLikelyPersonNameVariant(_ text: String) -> Bool {
        let candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let characters = Array(candidate)
        guard (2...4).contains(characters.count) else { return false }
        let nonNameWords = [
            "说明", "也说明", "较明", "表明", "证明", "注明", "声明", "明白", "明确", "说明了",
            "会议", "通知", "图片", "材料", "记录", "介绍", "简介", "项目", "系统", "问题"
        ]
        if nonNameWords.contains(where: { candidate.contains($0) || $0.contains(candidate) }) {
            return false
        }
        if characters.count >= 3,
           let first = characters.first,
           ["也", "还", "再", "就", "较", "更", "很", "不", "已", "会", "要"].contains(first) {
            return false
        }
        if let last = characters.last,
           ["了", "的", "是", "在", "和", "与", "及"].contains(last) {
            return false
        }
        return true
    }

    nonisolated private static func editDistance(_ lhs: [Character], _ rhs: [Character]) -> Int {
        guard !lhs.isEmpty else { return rhs.count }
        guard !rhs.isEmpty else { return lhs.count }

        var previous = Array(0...rhs.count)
        var current = Array(repeating: 0, count: rhs.count + 1)
        for leftIndex in 1...lhs.count {
            current[0] = leftIndex
            for rightIndex in 1...rhs.count {
                let cost = lhs[leftIndex - 1] == rhs[rightIndex - 1] ? 0 : 1
                current[rightIndex] = min(
                    previous[rightIndex] + 1,
                    current[rightIndex - 1] + 1,
                    previous[rightIndex - 1] + cost
                )
            }
            previous = current
        }
        return previous[rhs.count]
    }

    nonisolated private static func isCJKScalar(_ scalar: UnicodeScalar) -> Bool {
        (0x4E00...0x9FFF).contains(Int(scalar.value)) ||
        (0x3400...0x4DBF).contains(Int(scalar.value)) ||
        (0xF900...0xFAFF).contains(Int(scalar.value))
    }

    nonisolated private static func transcriptSourceQualityScore(_ source: MeetingTruthTranscriptSource) -> Int {
        let normalized = source.name.lowercased()
        var score = 50
        if normalized.contains("mimo") { score += 45 }
        if normalized.contains("mlx") { score += 12 }
        if normalized.contains("glm") { score += 24 }
        if normalized.contains("qwen") || normalized.contains("千问") { score += 10 }
        if source.hasTimestamp { score -= 18 }
        if normalized.contains("timestamp") || normalized.contains("时间戳") { score -= 12 }
        score += min(source.text.count / 4_000, 12)
        return score
    }

    nonisolated private static func timestampAnchorScore(_ source: MeetingTruthTranscriptSource) -> Int {
        let normalized = source.name.lowercased()
        var score = source.hasTimestamp ? 50 : 0
        if normalized.contains("qwen") || normalized.contains("千问") { score += 35 }
        if normalized.contains("1.7") || normalized.contains("1-7") { score += 8 }
        if normalized.contains("mimo") { score += 5 }
        return score
    }

    nonisolated private static func cleanedMeetingTranscript(_ transcript: String) -> String {
        let lines = transcript
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        let cleanedLines = lines.compactMap { line -> String? in
            var cleaned = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return nil }
            cleaned = cleaned
                .replacingOccurrences(of: #"^\s*\[[0-9]{1,2}:[0-9]{2}(?::[0-9]{2})?(?:\.[0-9]+)?(?:\s*[-–~]\s*[0-9]{1,2}:[0-9]{2}(?::[0-9]{2})?(?:\.[0-9]+)?)?\]\s*"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"^\s*\(?[0-9]{1,2}:[0-9]{2}(?::[0-9]{2})?(?:\.[0-9]+)?\)?\s*[-–~>]*\s*(?:[0-9]{1,2}:[0-9]{2}(?::[0-9]{2})?(?:\.[0-9]+)?\s*)?"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"^\s*(?:Start|start|End|end)\s*[:=]\s*[0-9.]+\s*,?\s*"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #""(?:start|end|timestamp|time)"\s*:\s*[0-9.]+,?\s*"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? nil : cleaned
        }

        return cleanedLines.joined(separator: "\n")
    }

    nonisolated private static func truncatedText(_ text: String, limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return "\(trimmed.prefix(limit))..."
    }

    nonisolated private static func uniqueTerms(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for term in terms {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= 32 else { continue }
            let key = trimmed.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(trimmed)
        }
        return result
    }

    private func currentMeetingTruthProject() -> MeetingTruthProject {
        let snapshot = meetingTruthTrustedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let suggestionSummary = hasDiscoveredMeetingTruthConflicts
            ? MeetingTruthSuggestionSummary(
                totalConflicts: meetingTruthConflicts.count,
                lowConfidenceCount: meetingTruthConflicts.filter { $0.confidence == .low }.count
            )
            : nil
        return MeetingTruthProject(
            id: meetingTruthProjectID,
            createdAt: meetingTruthProjectCreatedAt,
            updatedAt: Date(),
            selectedAudioPath: selectedAudioPath.isEmpty ? nil : selectedAudioPath,
            materials: meetingTruthMaterials,
            transcriptSources: meetingTruthTranscriptSources,
            conflicts: meetingTruthConflicts,
            hasDiscoveredConflicts: hasDiscoveredMeetingTruthConflicts,
            validationStatus: meetingTruthValidationStatus,
            trustedTranscriptSnapshot: snapshot.isEmpty ? nil : snapshot,
            suggestionSummary: suggestionSummary,
            manualConfirmations: meetingTruthManualConfirmations,
            analysis: meetingTruthAnalysis,
            packageStatus: derivedMeetingTruthPackageStatus(),
            currentErrorMessage: meetingTruthError,
            lastFailure: meetingTruthLastFailure,
            activityLog: meetingTruthActivityLog,
            multimodalMode: meetingTruthMultimodalMode,
            visualEvidence: meetingTruthVisualEvidence,
            multimodalComparisons: meetingTruthMultimodalComparisons,
            arbitrationConfig: meetingTruthArbitrationConfig,
            factCandidates: meetingTruthFactCandidates,
            evidenceAtoms: meetingTruthEvidenceAtoms,
            factDecisions: meetingTruthFactDecisions,
            userQuestions: meetingTruthUserQuestions,
            centralReviewLedger: meetingTruthCentralReviewLedger,
            toolCallingABResult: meetingTruthToolCallingABResult
        )
    }

    private func applyMeetingTruthProject(_ project: MeetingTruthProject) {
        meetingTruthProjectID = project.id
        meetingTruthProjectCreatedAt = project.createdAt
        selectedAudioPath = project.selectedAudioPath ?? ""
        meetingTruthMaterials = project.materials
        meetingTruthTranscriptSources = project.transcriptSources
        meetingTruthConflicts = project.conflicts
        meetingTruthManualConfirmations = project.manualConfirmations
        hasDiscoveredMeetingTruthConflicts = project.hasDiscoveredConflicts
        meetingTruthAnalysis = project.analysis
        meetingTruthError = project.currentErrorMessage
        meetingTruthLastFailure = project.lastFailure
        meetingTruthActivityLog = project.activityLog
        meetingTruthMultimodalMode = project.multimodalMode
        meetingTruthVisualEvidence = project.visualEvidence
        meetingTruthMultimodalComparisons = project.multimodalComparisons
        meetingTruthArbitrationConfig = project.arbitrationConfig
        meetingTruthFactCandidates = project.factCandidates
        meetingTruthEvidenceAtoms = project.evidenceAtoms
        meetingTruthFactDecisions = project.factDecisions
        meetingTruthUserQuestions = project.userQuestions
        meetingTruthCentralReviewLedger = project.centralReviewLedger
        meetingTruthToolCallingABResult = project.toolCallingABResult
        refreshMeetingTruthMultimodalComparisons()
        meetingTruthValidationStatus = normalizedMeetingTruthValidationStatus(for: project)
        isResolvingMeetingTruthConflicts = false
        isDiscoveringMeetingTruthConflicts = false
        isGeneratingMeetingTruthPackage = false
        isExtractingMeetingTruthVisualEvidence = false
        isReviewingMeetingTruthCentrally = false
        isRunningMeetingTruthToolAB = false
    }

    private func archiveMeetingTruthHistorySnapshot(for project: MeetingTruthProject) {
        let latestActivity = meetingTruthActivityLog.first
        let latestFailure = project.lastFailure

        let title = latestActivity?.title
            ?? (latestFailure != nil ? "操作失败" : "MeetingTruth 状态已保存")
        let message = latestActivity?.message
            ?? latestFailure?.message
            ?? project.validationStatus
        let details = latestActivity?.details ?? latestFailure?.details
        let sourceActivityID = latestActivity?.id

        if let sourceActivityID,
           meetingTruthHistory.first?.sourceActivityID == sourceActivityID {
            return
        }

        if sourceActivityID == nil,
           let first = meetingTruthHistory.first,
           first.title == title,
           first.message == message,
           first.project.updatedAt == project.updatedAt {
            return
        }

        meetingTruthHistory.insert(
            MeetingTruthHistoryEntry(
                id: UUID(),
                sourceActivityID: sourceActivityID,
                recordedAt: project.updatedAt,
                title: title,
                message: message,
                details: details,
                project: project
            ),
            at: 0
        )
        if meetingTruthHistory.count > 80 {
            meetingTruthHistory.removeLast(meetingTruthHistory.count - 80)
        }
    }

    private func normalizedMeetingTruthValidationStatus(for project: MeetingTruthProject) -> String {
        switch project.packageStatus.state {
        case .succeeded:
            return "会议成果包已恢复"
        case .failed:
            return "上次成果包生成失败，已恢复项目状态"
        case .generating:
            break
        case .readyToGenerate, .idle:
            if !project.validationStatus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return project.validationStatus
            }
        }

        if project.analysis != nil {
            return "会议成果包已恢复"
        }
        if project.hasDiscoveredConflicts {
            return project.conflicts.isEmpty
                ? "已恢复项目状态，可直接生成可信成果包"
                : "已恢复项目状态，请继续确认冲突"
        }
        if project.transcriptSources.count >= 2 {
            return "已恢复候选转写，请继续运行冲突发现"
        }
        return "请先导入真实会议资料和至少两份候选转写"
    }

    private func withSecurityScopedAccess<T>(to sourceURL: URL, operation: () -> T) -> T {
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }
        return operation()
    }

    private static let demoMeetingTruthConflicts: [MeetingTruthConflict] = [
        MeetingTruthConflict(
            timestamp: "00:03:12",
            kind: .terminology,
            context: "我们下一阶段要推进……规划，先把建设范围明确下来。",
            candidates: [
                MeetingTruthCandidate(source: "GLM-ASR", text: "数据金融战略"),
                MeetingTruthCandidate(source: "Qwen3-ASR", text: "数字金融战略"),
                MeetingTruthCandidate(source: "SenseVoice", text: "数字经营战略")
            ],
            recommendation: "数字金融战略",
            confidence: .high,
            evidence: "会议材料标题和术语表均出现“数字金融战略规划”。"
        ),
        MeetingTruthConflict(
            timestamp: "00:05:20",
            kind: .amount,
            context: "一期预算先按照……万元测算，外采部分需要再细化。",
            candidates: [
                MeetingTruthCandidate(source: "GLM-ASR", text: "300 万"),
                MeetingTruthCandidate(source: "Qwen3-ASR", text: "1300 万"),
                MeetingTruthCandidate(source: "SenseVoice", text: "30 万")
            ],
            recommendation: "1300 万",
            confidence: .low,
            evidence: "多个 ASR 对金额识别不一致，现有材料没有对应数字，需要人工确认。"
        ),
        MeetingTruthConflict(
            timestamp: "00:08:45",
            kind: .person,
            context: "预算测算依据由……补充，下周评审前发出来。",
            candidates: [
                MeetingTruthCandidate(source: "GLM-ASR", text: "张珊"),
                MeetingTruthCandidate(source: "Qwen3-ASR", text: "张三"),
                MeetingTruthCandidate(source: "SenseVoice", text: "张山")
            ],
            recommendation: "张三",
            confidence: .high,
            evidence: "群聊补充信息中出现负责人“张三”，且与行动项上下文一致。"
        )
    ]

    func refreshLocalModelCache() {
        for index in models.indices {
            guard models[index].status != .downloading else { continue }

            if let found = existingModelAsset(for: models[index]) {
                applyReadyModel(at: found, to: index)
                modelPreparationFailures[models[index].id] = nil
            }
        }
    }

    func rescanModelAssets() {
        for index in models.indices {
            guard models[index].status != .downloading else { continue }
            models[index].localPath = nil
            models[index].sourceDescription = nil
            models[index].validationSummary = nil
            models[index].progress = 0
            models[index].status = ModelRegistry.initialModels.first(where: { $0.id == models[index].id })?.status ?? .downloadable
        }
        modelPreparationFailures.removeAll()
        applyExternalModelConfigurations()
        refreshLocalModelCache()
        activeTaskTitle = "模型目录已重新扫描"
        currentStage = "检查完成"
        activeTaskProgress = 1
    }

    func applyModelCachePathFromSettings() {
        let trimmed = modelCachePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            modelCachePath = MeetingTruthConfig.defaultModelCachePath
        }
        saveAppSettings()
        rescanModelAssets()
        loadRunHistory()
        activeTaskTitle = "模型目录设置已应用"
        currentStage = resolvedModelCacheURL.path
    }

    func externalModelConfiguration(for model: ASRModelSpec) -> ExternalModelConfiguration {
        externalModelConfigurations[model.id] ?? ExternalModelConfiguration(
            modelID: model.id,
            runtimeModelName: model.runtimeModelName ?? "",
            localPath: model.localPath ?? "",
            preferredAccelerator: model.id.contains("gguf") ? "metal" : "",
            supportsHotwords: model.hotwordCapability == .supported || model.hotwordCapability == .promptOnly,
            supportsTimestamps: model.id.contains("timestamps"),
            supportsDiarization: false,
            supportsLongAudio: model.id.contains("vibevoice") || model.id.contains("mimo") || model.id.contains("qwen3") || model.id == "funasr-nano-2512"
        )
    }

    func updateExternalModelConfiguration(_ configuration: ExternalModelConfiguration) {
        externalModelConfigurations[configuration.modelID] = configuration
        saveExternalModelConfigurations()
        applyExternalModelConfigurations()
    }

    func validateExternalModelConfiguration(for modelID: String) {
        guard let index = models.firstIndex(where: { $0.id == modelID }) else { return }
        var configuration = externalModelConfiguration(for: models[index])
        let model = models[index]
        var issues: [String] = []
        var checks: [String] = []

        if model.runtime != .externalCLI {
            issues.append("不是外部 CLI 模型")
        }
        if configuration.runtimeModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append("缺少模型引用")
        } else {
            checks.append("模型引用已配置")
        }
        if hasImplementedExternalAdapter(for: model) {
            checks.append("本机 adapter 已接入")
        } else {
            issues.append("当前没有可用 adapter")
        }
        if let setupScript = externalSetupScript(for: model) {
            checks.append("依赖脚本存在：\(setupScript.lastPathComponent)")
        } else {
            issues.append("缺少依赖安装脚本")
        }
        let configuredPath = configuration.localPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if configuredPath.isEmpty {
            checks.append("未固定本地路径，将使用模型缓存目录")
        } else {
            let url = URL(fileURLWithPath: NSString(string: configuredPath).expandingTildeInPath)
            if FileManager.default.fileExists(atPath: url.path) {
                checks.append("本地路径存在")
                if isCompleteModel(model, at: url) {
                    checks.append("必要文件校验通过")
                } else {
                    issues.append("本地路径存在，但必要文件不完整")
                }
            } else {
                issues.append("本地路径不存在")
            }
        }

        let capabilities = [
            configuration.supportsHotwords ? "热词" : nil,
            configuration.supportsTimestamps ? "时间戳" : nil,
            configuration.supportsDiarization ? "说话人" : nil,
            configuration.supportsLongAudio ? "长音频" : nil,
            configuration.preferredAccelerator.isEmpty ? nil : "加速：\(configuration.preferredAccelerator)"
        ].compactMap { $0 }
        if !capabilities.isEmpty {
            checks.append("能力：\(capabilities.joined(separator: "、"))")
        }

        configuration.lastValidatedAt = Date()
        configuration.validationPassed = issues.isEmpty
        configuration.validationSummary = issues.isEmpty
            ? "校验通过：\(checks.joined(separator: "；"))"
            : "校验失败：\(issues.joined(separator: "；"))"
        externalModelConfigurations[modelID] = configuration
        saveExternalModelConfigurations()
        applyExternalModelConfigurations()
        activeTaskTitle = configuration.validationPassed ? "\(model.name) 配置校验通过" : "\(model.name) 配置校验失败"
        lastError = configuration.validationPassed ? nil : configuration.validationSummary
    }

    private func configureDefaultTestRun() {
        if selectedAudioPath.isEmpty,
           let testAudio = RuntimePaths.projectFile("TestRuns/audio/test_20s.wav") {
            selectedAudioPath = testAudio.path
        }

        selectedModelIDs = Self.defaultSelectedASRModelIDs
        selectedModelID = Self.primaryDefaultASRModelID
    }

    private func copyAudioIntoAppStorage(_ sourceURL: URL) throws -> URL {
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let importRoot = modelStorage.systemRoot
            .appending(path: "InputAudio", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: importRoot, withIntermediateDirectories: true)

        let baseName = sourceURL.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: #"[^\p{L}\p{N}._-]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-._"))
        let safeBaseName = baseName.isEmpty ? "audio" : baseName
        let ext = sourceURL.pathExtension.isEmpty ? "audio" : sourceURL.pathExtension
        let destination = importRoot.appending(path: "\(safeBaseName)-\(UUID().uuidString.prefix(8)).\(ext)")
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        return destination
    }

    func toggleModel(_ model: ASRModelSpec) {
        if selectedModelIDs.contains(model.id), !isRunnableModel(model) {
            selectedModelIDs.remove(model.id)
            lastError = unavailableRuntimeMessage(for: model)
            return
        }

        guard model.status != .failed else {
            lastError = "\(model.name) 当前配置验证失败，暂时不加入主流程。"
            return
        }
        guard model.runtime == .externalCLI || model.localPath != nil else {
            lastError = "\(model.name) 还没有下载。请先到模型库下载，再加入对比。"
            return
        }
        guard isRunnableModel(model) else {
            lastError = unavailableRuntimeMessage(for: model)
            return
        }

        if selectedModelIDs.contains(model.id) {
            if selectedModelIDs.count > 1 {
                selectedModelIDs.remove(model.id)
            }
        } else {
            selectedModelIDs.insert(model.id)
        }
        selectedModelID = model.id
    }

    func downloadSelectedModel() {
        guard let index = models.firstIndex(where: { $0.id == selectedModelID }) else { return }
        let model = models[index]
        let shouldRetryIncompleteDownload = model.localPath != nil && model.validationSummary?.contains("不完整") == true

        if !shouldRetryIncompleteDownload, let found = existingModelAsset(for: model), model.runtime != .externalCLI {
            applyReadyModel(at: found, to: index)
            activeTaskTitle = "\(models[index].name) 已下载"
            activeTaskProgress = 1
            currentStage = "本地模型已识别"
            lastError = nil
            return
        }

        guard model.status != .planned || model.downloadURL != nil || model.runtimeModelName != nil else {
            activeTaskTitle = "\(model.name) 暂未接入下载"
            lastError = "\(model.name) 已列入模型库，但下载地址、文件清单或本机运行路线还没有确认，先不自动下载。"
            return
        }

        guard model.downloadURL != nil || model.runtime == .externalCLI else {
            activeTaskTitle = "\(model.name) 暂不可下载"
            lastError = "\(model.name) 还没有接入可验证的下载和推理流程，先不放进可用模型。"
            return
        }

        let modelID = models[index].id
        models[index].status = .downloading
        models[index].progress = 0.01
        models[index].downloadMetrics = DownloadMetrics()
        modelPreparationFailures[modelID] = nil
        activeTaskTitle = "正在下载 \(model.name)"
        activeTaskProgress = 0.01
        currentStage = "准备下载"
        elapsedTimeLabel = "--"
        remainingTimeLabel = "--"
        lastError = nil
        let downloadStartedAt = Date()

        Task {
            do {
                let localURL: URL
                if let downloadURL = model.downloadURL {
                    let downloader = ArchiveModelDownloader { [weak self] metrics in
                        Task { @MainActor in
                            guard let self, let currentIndex = self.models.firstIndex(where: { $0.id == modelID }) else { return }
                            let fraction = self.downloadFraction(for: metrics)
                            self.models[currentIndex].progress = min(fraction, 0.96)
                            self.models[currentIndex].downloadMetrics = metrics
                            self.activeTaskProgress = min(fraction, 0.96)
                            self.activeTaskTitle = self.downloadTitle(for: self.models[currentIndex])
                        }
                    }
                    localURL = try await downloader.downloadAndExtract(
                        from: downloadURL,
                        into: modelStorage.assetDirectory(for: model),
                        archiveDirectory: modelStorage.downloadsRoot
                    )
                } else if model.runtime == .externalCLI {
                    localURL = try await prepareExternalModel(model) { [weak self] metrics, title in
                        Task { @MainActor in
                            guard let self, let currentIndex = self.models.firstIndex(where: { $0.id == modelID }) else { return }
                            let metrics = Self.sanitizedDownloadMetrics(metrics)
                            let fraction = self.downloadFraction(for: metrics)
                            self.models[currentIndex].progress = fraction
                            self.models[currentIndex].downloadMetrics = metrics
                            self.activeTaskProgress = fraction
                            self.activeTaskTitle = title
                            self.currentStage = title
                            self.elapsedTimeLabel = Self.formatDuration(Date().timeIntervalSince(downloadStartedAt))
                            self.remainingTimeLabel = metrics.estimatedRemainingSeconds.map(Self.formatDuration) ?? "--"
                        }
                    }
                } else {
                    throw ASREngineError.unsupportedRuntime(model.runtime.rawValue)
                }

                if let currentIndex = models.firstIndex(where: { $0.id == modelID }) {
                    guard isCompleteModel(models[currentIndex], at: localURL) else {
                        throw ASREngineError.adapterNotImplemented(validationSummary(for: models[currentIndex], at: localURL))
                    }
                    try? writeManifest(for: models[currentIndex], localURL: localURL)
                    models[currentIndex].status = .ready
                    models[currentIndex].progress = 1
                    models[currentIndex].downloadMetrics.estimatedRemainingSeconds = 0
                    models[currentIndex].localPath = localURL.path
                    models[currentIndex].sourceDescription = modelSourceDescription(for: models[currentIndex])
                    models[currentIndex].validationSummary = validationSummary(for: models[currentIndex], at: localURL)
                    activeTaskProgress = 1
                    activeTaskTitle = "\(models[currentIndex].name) 已下载"
                }
            } catch {
                if let currentIndex = models.firstIndex(where: { $0.id == modelID }) {
                    models[currentIndex].status = .failed
                    models[currentIndex].progress = 0
                    let failure = recordModelPreparationFailure(error, for: models[currentIndex])
                    models[currentIndex].validationSummary = failure.summary
                    lastError = failure.summary
                } else {
                    lastError = userReadablePreparationFailure(from: error, modelName: model.name).summary
                }
                activeTaskTitle = "下载失败"
            }
        }
    }

    func prepareCleanASRModel(_ model: ASRModelSpec) {
        selectedModelID = model.id
        downloadSelectedModel()
    }

    func prepareAllCleanASRModels() {
        currentModelPreparationTask?.cancel()
        currentModelPreparationTask = Task { [weak self] in
            guard let self else { return }
            for modelID in Self.cleanASRModelOrder {
                if Task.isCancelled { break }
                guard let index = models.firstIndex(where: { $0.id == modelID }) else { continue }
                if isRunnableModel(models[index]) { continue }
                selectedModelID = modelID
                await prepareModelAtIndex(index)
            }
            currentModelPreparationTask = nil
        }
    }

    private func prepareModelAtIndex(_ initialIndex: Int) async {
        guard models.indices.contains(initialIndex) else { return }
        let model = models[initialIndex]
        let modelID = model.id
        let shouldRetryIncompleteDownload = model.localPath != nil && model.validationSummary?.contains("不完整") == true

        if !shouldRetryIncompleteDownload, let found = existingModelAsset(for: model), model.runtime != .externalCLI {
            applyReadyModel(at: found, to: initialIndex)
            activeTaskTitle = "\(models[initialIndex].name) 已下载"
            activeTaskProgress = 1
            currentStage = "本地模型已识别"
            lastError = nil
            return
        }

        guard model.status != .planned || model.downloadURL != nil || model.runtimeModelName != nil else {
            activeTaskTitle = "\(model.name) 暂未接入下载"
            lastError = "\(model.name) 已列入模型库，但下载地址、文件清单或本机运行路线还没有确认，先不自动下载。"
            return
        }

        guard model.downloadURL != nil || model.runtime == .externalCLI else {
            activeTaskTitle = "\(model.name) 暂不可下载"
            lastError = "\(model.name) 还没有接入可验证的下载和推理流程，先不放进可用模型。"
            return
        }

        models[initialIndex].status = .downloading
        models[initialIndex].progress = 0.01
        models[initialIndex].downloadMetrics = DownloadMetrics()
        modelPreparationFailures[modelID] = nil
        activeTaskTitle = "正在下载 \(model.name)"
        activeTaskProgress = 0.01
        currentStage = "准备下载"
        elapsedTimeLabel = "--"
        remainingTimeLabel = "--"
        lastError = nil
        let downloadStartedAt = Date()

        do {
            let localURL: URL
            if let downloadURL = model.downloadURL {
                let downloader = ArchiveModelDownloader { [weak self] metrics in
                    Task { @MainActor in
                        guard let self, let currentIndex = self.models.firstIndex(where: { $0.id == modelID }) else { return }
                        let fraction = self.downloadFraction(for: metrics)
                        self.models[currentIndex].progress = min(fraction, 0.96)
                        self.models[currentIndex].downloadMetrics = metrics
                        self.activeTaskProgress = min(fraction, 0.96)
                        self.activeTaskTitle = self.downloadTitle(for: self.models[currentIndex])
                    }
                }
                localURL = try await downloader.downloadAndExtract(
                    from: downloadURL,
                    into: modelStorage.assetDirectory(for: model),
                    archiveDirectory: modelStorage.downloadsRoot
                )
            } else if model.runtime == .externalCLI {
                localURL = try await prepareExternalModel(model) { [weak self] metrics, title in
                    Task { @MainActor in
                        guard let self, let currentIndex = self.models.firstIndex(where: { $0.id == modelID }) else { return }
                        let metrics = Self.sanitizedDownloadMetrics(metrics)
                        let fraction = self.downloadFraction(for: metrics)
                        self.models[currentIndex].progress = fraction
                        self.models[currentIndex].downloadMetrics = metrics
                        self.activeTaskProgress = fraction
                        self.activeTaskTitle = title
                        self.currentStage = title
                        self.elapsedTimeLabel = Self.formatDuration(Date().timeIntervalSince(downloadStartedAt))
                        self.remainingTimeLabel = metrics.estimatedRemainingSeconds.map(Self.formatDuration) ?? "--"
                    }
                }
            } else {
                throw ASREngineError.unsupportedRuntime(model.runtime.rawValue)
            }

            if let currentIndex = models.firstIndex(where: { $0.id == modelID }) {
                guard isCompleteModel(models[currentIndex], at: localURL) else {
                    throw ASREngineError.adapterNotImplemented(validationSummary(for: models[currentIndex], at: localURL))
                }
                try? writeManifest(for: models[currentIndex], localURL: localURL)
                models[currentIndex].status = .ready
                models[currentIndex].progress = 1
                models[currentIndex].downloadMetrics.estimatedRemainingSeconds = 0
                models[currentIndex].localPath = localURL.path
                models[currentIndex].sourceDescription = modelSourceDescription(for: models[currentIndex])
                models[currentIndex].validationSummary = validationSummary(for: models[currentIndex], at: localURL)
                activeTaskProgress = 1
                activeTaskTitle = "\(models[currentIndex].name) 已下载"
            }
        } catch {
            if let currentIndex = models.firstIndex(where: { $0.id == modelID }) {
                models[currentIndex].status = .failed
                models[currentIndex].progress = 0
                let failure = recordModelPreparationFailure(error, for: models[currentIndex])
                models[currentIndex].validationSummary = failure.summary
                lastError = failure.summary
            } else {
                lastError = userReadablePreparationFailure(from: error, modelName: model.name).summary
            }
            activeTaskTitle = "下载失败"
        }
    }

    private func prepareExternalModel(
        _ model: ASRModelSpec,
        progress: @escaping @Sendable (DownloadMetrics, String) -> Void
    ) async throws -> URL {
        if let found = existingModelAsset(for: model) {
            let expectedBytes = Self.expectedDownloadBytes(for: model)
            progress(
                DownloadMetrics(
                    downloadedBytes: Self.directorySize(at: found.path),
                    totalBytes: expectedBytes,
                    speedBytesPerSecond: 0,
                    estimatedRemainingSeconds: nil
                ),
                "正在准备 \(model.name) 推理环境"
            )
            try await installExternalRuntimeIfNeeded(for: model, progress: progress)
            return found
        }

        return try await installAndPrefetchExternalModel(model, progress: progress)
    }

    func runComparison() {
        currentComparisonTask?.cancel()
        var selected = models.filter {
            selectedModelIDs.contains($0.id) && isRunnableModel($0)
        }
        if selected.isEmpty {
            selectedModelIDs = Self.defaultSelectedASRModelIDs
            selectedModelID = Self.primaryDefaultASRModelID
            selected = models.filter { selectedModelIDs.contains($0.id) && isRunnableModel($0) }
            if selected.isEmpty {
                activeTaskTitle = "没有可用模型"
                lastError = "当前默认 ASR 模型不可运行，请先到模型库检查 Qwen3-ASR、GLM-ASR 和 MiMo MLX 的本机配置。"
                return
            }
        }
        guard !selectedAudioPath.isEmpty else {
            activeTaskTitle = "请选择测试音频"
            lastError = "需要先选择一段本地音频，才能开始横向对比。"
            return
        }

        runs = selected.flatMap { model -> [ComparisonRun] in
            if model.id == "mimo-v2-5-asr", compareMiMoAccelerators {
                return ["mps", "cpu"].map { device in
                    ComparisonRun(
                        modelID: model.id,
                        modelName: "\(model.name) · \(device.uppercased())",
                        runtime: model.runtime.rawValue,
                        terminologyPostProcessingEnabled: useTerminologyPostProcessing,
                        requestedAcceleratorDevice: device,
                        requestedChunkSeconds: longAudioChunkSeconds,
                        longAudioCacheEnabled: false,
                        status: "等待运行",
                        transcriptPreview: ""
                    )
                }
            }
            if compareTerminologyPostProcessing, model.runtime == .externalCLI {
                return [
                    ComparisonRun(
                        modelID: model.id,
                        modelName: "\(model.name) · 原始",
                        runtime: model.runtime.rawValue,
                        terminologyPostProcessingEnabled: false,
                        requestedChunkSeconds: longAudioChunkSeconds,
                        longAudioCacheEnabled: longAudioCacheEnabled,
                        status: "等待运行",
                        transcriptPreview: ""
                    ),
                    ComparisonRun(
                        modelID: model.id,
                        modelName: "\(model.name) · 术语",
                        runtime: model.runtime.rawValue,
                        terminologyPostProcessingEnabled: true,
                        requestedChunkSeconds: longAudioChunkSeconds,
                        longAudioCacheEnabled: longAudioCacheEnabled,
                        status: "等待运行",
                        transcriptPreview: ""
                    )
                ]
            }
            return [
                ComparisonRun(
                    modelID: model.id,
                    modelName: model.name,
                    runtime: model.runtime.rawValue,
                    terminologyPostProcessingEnabled: useTerminologyPostProcessing,
                    requestedChunkSeconds: longAudioChunkSeconds,
                    longAudioCacheEnabled: longAudioCacheEnabled,
                    status: "等待运行",
                    transcriptPreview: ""
                )
            ]
        }

        activeTaskTitle = "正在准备 \(selected.count) 个模型的对比任务"
        activeTaskProgress = 0.08
        lastError = nil
        selectedHistoryID = nil
        liveTranscript = ""
        currentStage = "准备中"
        elapsedTimeLabel = "--"
        remainingTimeLabel = "--"
        isRunning = true
        selectedSection = .lab
        saveCurrentRunToHistory()

        currentComparisonTask = Task { @MainActor in
            defer {
                isRunning = false
                currentComparisonTask = nil
            }

            for index in runs.indices {
                if Task.isCancelled {
                    markPendingRunsAsCancelled()
                    updateSelectedHistoryFromCurrentRuns()
                    return
                }
                guard let model = models.first(where: { $0.id == runs[index].modelID }) else { continue }

                runs[index].status = "转写中"
                activeTaskTitle = "正在运行 \(runs[index].modelName)"
                activeTaskProgress = Double(index) / Double(max(runs.count, 1))
                updateSelectedHistoryFromCurrentRuns()

                do {
                    let result = try await transcribe(
                        model: model,
                        terminologyPostProcessing: runs[index].terminologyPostProcessingEnabled,
                        acceleratorDevice: runs[index].requestedAcceleratorDevice,
                        longAudioCacheEnabled: runs[index].longAudioCacheEnabled,
                        longAudioChunkSeconds: runs[index].requestedChunkSeconds,
                        progress: { [weak self] update in
                            Task { @MainActor in
                                guard let self else { return }
                                self.currentStage = update.stage
                                self.activeTaskProgress = update.fraction
                                self.elapsedTimeLabel = Self.formatDuration(update.elapsed)
                                self.remainingTimeLabel = update.estimatedRemaining.map(Self.formatDuration) ?? "--"
                                if let segmentCount = update.segmentCount {
                                    self.runs[index].segmentCount = segmentCount
                                    self.runs[index].cachedSegmentCount = update.cachedSegmentCount
                                }
                                if Self.isTranscriptProgressText(update) {
                                    self.liveTranscript = update.partialText
                                    self.runs[index].transcriptPreview = update.partialText
                                }
                                self.updateSelectedHistoryFromCurrentRuns()
                            }
                        }
                    )
                    if Task.isCancelled {
                        runs[index].status = "已停止"
                        runs[index].errorMessage = "用户停止了当前转写任务。"
                        updateSelectedHistoryFromCurrentRuns()
                        return
                    }
                    runs[index].status = result.text.isEmpty ? "无文本" : "完成"
                    runs[index].duration = result.metrics.duration
                    runs[index].transcribeTime = result.metrics.transcribeTime
                    runs[index].rtf = result.metrics.rtf
                    runs[index].speed = result.metrics.speed
                    runs[index].acceleratorDevice = result.metrics.acceleratorDevice
                    runs[index].acceleratorFallbackReason = result.metrics.acceleratorFallbackReason
                    runs[index].characterErrorRate = nil
                    runs[index].transcriptPreview = result.text
                    if result.text.isEmpty {
                        runs[index].reviewerVerdict = .missed
                        runs[index].errorMessage = "模型完成了推理，但没有输出可显示文本。请换一段更清晰的音频，或关闭热词/VAD 后重试。"
                    } else if let warning = runs[index].automaticQualityWarning {
                        runs[index].reviewerVerdict = .missed
                        runs[index].errorMessage = warning
                    }
                    recomputeEquivalenceGroups()

                    if let currentIndex = models.firstIndex(where: { $0.id == model.id }), models[currentIndex].localPath == nil {
                        models[currentIndex].status = .ready
                        models[currentIndex].progress = 1
                    }
                    updateSelectedHistoryFromCurrentRuns()
                    if shouldAutoGenerateMeetingAnalysis(for: runs[index]) {
                        generateMeetingAnalysis(for: runs[index].id, cancelInFlight: false)
                    }
                } catch {
                    runs[index].status = "失败"
                    runs[index].reviewerVerdict = .missed
                    runs[index].errorMessage = error.localizedDescription
                    lastError = error.localizedDescription
                    recomputeEquivalenceGroups()
                    updateSelectedHistoryFromCurrentRuns()
                }
            }
            activeTaskProgress = 1.0
            remainingTimeLabel = "0s"
            activeTaskTitle = "对比完成"
            updateSelectedHistoryFromCurrentRuns()
        }
    }

    func rerunRun(_ runID: UUID) {
        rerunRuns(
            named: "重跑当前项",
            ids: [runID]
        )
    }

    func rerunAutomaticQualityFailures() {
        let ids = runs
            .filter {
                $0.automaticQualityWarning != nil ||
                $0.reviewerVerdict == .missed ||
                $0.status == "无文本" ||
                $0.status == "失败"
            }
            .map(\.id)
        rerunRuns(named: "重跑异常项", ids: ids)
    }

    private func rerunRuns(named taskName: String, ids: [UUID]) {
        currentComparisonTask?.cancel()
        guard !ids.isEmpty else {
            activeTaskTitle = "没有需要重跑的结果"
            lastError = "当前结果里没有自动质检异常、失败或无文本项。"
            return
        }
        guard !selectedAudioPath.isEmpty, FileManager.default.fileExists(atPath: selectedAudioPath) else {
            activeTaskTitle = "无法重跑"
            lastError = "找不到这次结果对应的音频文件。请先从历史记录载入该次结果，或重新选择原始音频。"
            return
        }

        let timestamp = Self.rerunDateFormatter.string(from: Date())
        var rerunIDs: [UUID] = []
        for sourceID in ids {
            guard let sourceIndex = runs.firstIndex(where: { $0.id == sourceID }) else { continue }
            let source = runs[sourceIndex]
            let rerun = ComparisonRun(
                modelID: source.modelID,
                modelName: "\(source.modelName) · 原参数重跑 \(timestamp)",
                runtime: source.runtime,
                terminologyPostProcessingEnabled: source.terminologyPostProcessingEnabled,
                requestedAcceleratorDevice: source.requestedAcceleratorDevice,
                requestedChunkSeconds: source.requestedChunkSeconds,
                longAudioCacheEnabled: false,
                status: "等待重跑",
                reviewerNote: "从“\(source.modelName)”按原模型、原切片、原参数绕过缓存重跑生成。",
                segmentCount: source.segmentCount,
                transcriptPreview: ""
            )
            runs.insert(rerun, at: min(sourceIndex + 1, runs.count))
            rerunIDs.append(rerun.id)
        }

        guard !rerunIDs.isEmpty else {
            activeTaskTitle = "没有可重跑的结果"
            lastError = "没有找到对应的结果行。"
            return
        }

        activeTaskTitle = "正在准备\(taskName)"
        activeTaskProgress = 0.03
        lastError = nil
        liveTranscript = ""
        currentStage = "已在原结果下方新增重跑行"
        elapsedTimeLabel = "--"
        remainingTimeLabel = "--"
        isRunning = true
        selectedSection = .lab
        updateSelectedHistoryFromCurrentRuns()

        currentComparisonTask = Task { @MainActor in
            defer {
                isRunning = false
                currentComparisonTask = nil
            }

            for (offset, runID) in rerunIDs.enumerated() {
                if Task.isCancelled {
                    markPendingRunsAsCancelled()
                    updateSelectedHistoryFromCurrentRuns()
                    return
                }
                guard let index = runs.firstIndex(where: { $0.id == runID }),
                      let model = models.first(where: { $0.id == runs[index].modelID }) else {
                    continue
                }

                runs[index].status = "重跑中"
                runs[index].errorMessage = nil
                runs[index].reviewerVerdict = .unrated
                activeTaskTitle = "\(taskName) \(offset + 1)/\(rerunIDs.count)：\(runs[index].modelName)"
                activeTaskProgress = Double(offset) / Double(max(rerunIDs.count, 1))
                currentStage = "绕过缓存重新推理"
                updateSelectedHistoryFromCurrentRuns()

                do {
                    let result = try await transcribe(
                        model: model,
                        terminologyPostProcessing: runs[index].terminologyPostProcessingEnabled,
                        acceleratorDevice: runs[index].requestedAcceleratorDevice,
                        longAudioCacheEnabled: false,
                        longAudioChunkSeconds: runs[index].requestedChunkSeconds,
                        progress: { [weak self] update in
                            Task { @MainActor in
                                guard let self,
                                      let currentIndex = self.runs.firstIndex(where: { $0.id == runID }) else { return }
                                self.currentStage = update.stage
                                self.activeTaskProgress = update.fraction
                                self.elapsedTimeLabel = Self.formatDuration(update.elapsed)
                                self.remainingTimeLabel = update.estimatedRemaining.map(Self.formatDuration) ?? "--"
                                if let segmentCount = update.segmentCount {
                                    self.runs[currentIndex].segmentCount = segmentCount
                                    self.runs[currentIndex].cachedSegmentCount = update.cachedSegmentCount
                                }
                                if Self.isTranscriptProgressText(update) {
                                    self.liveTranscript = update.partialText
                                    self.runs[currentIndex].transcriptPreview = update.partialText
                                }
                                self.updateSelectedHistoryFromCurrentRuns()
                            }
                        }
                    )
                    guard let currentIndex = runs.firstIndex(where: { $0.id == runID }) else { continue }
                    applyTranscriptionResult(result, to: currentIndex)
                    recomputeEquivalenceGroups()
                    updateSelectedHistoryFromCurrentRuns()
                    if shouldAutoGenerateMeetingAnalysis(for: runs[currentIndex]) {
                        generateMeetingAnalysis(for: runs[currentIndex].id, cancelInFlight: false)
                    }
                } catch {
                    guard let currentIndex = runs.firstIndex(where: { $0.id == runID }) else { continue }
                    runs[currentIndex].status = "失败"
                    runs[currentIndex].reviewerVerdict = .missed
                    runs[currentIndex].errorMessage = error.localizedDescription
                    lastError = error.localizedDescription
                    recomputeEquivalenceGroups()
                    updateSelectedHistoryFromCurrentRuns()
                }
            }

            activeTaskProgress = 1
            remainingTimeLabel = "0s"
            activeTaskTitle = "\(taskName)完成"
            currentStage = "已绕过缓存重跑所选结果"
            updateSelectedHistoryFromCurrentRuns()
        }
    }

    func cancelCurrentTask() {
        guard isRunning else { return }
        currentComparisonTask?.cancel()
        terminateExternalASRProcesses()
        isRunning = false
        activeTaskTitle = "已停止当前任务"
        currentStage = "用户停止"
        remainingTimeLabel = "--"
        markPendingRunsAsCancelled()
        updateSelectedHistoryFromCurrentRuns()
    }

    func generateMeetingAnalysis(for runID: UUID, refinementInstructions: String = "", cancelInFlight: Bool = true) {
        if cancelInFlight {
            currentMeetingAnalysisTask?.cancel()
        } else if currentMeetingAnalysisTask != nil {
            return
        }
        guard let index = runs.firstIndex(where: { $0.id == runID }) else { return }
        let transcript = runs[index].cleanTranscriptPreview
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lastError = "没有可整理的转写文本。"
            return
        }

        isGeneratingMeetingAnalysis = true
        meetingAnalysisStatus = "正在整理会议结构"
        lastError = nil

        let settings = meetingAISettings
        currentMeetingAnalysisTask = Task { @MainActor in
            defer {
                isGeneratingMeetingAnalysis = false
                currentMeetingAnalysisTask = nil
            }
            do {
                let analysis = try await meetingAIService.analyze(
                    transcript: transcript,
                    materials: [],
                    settings: settings,
                    refinementInstructions: refinementInstructions
                )
                guard !Task.isCancelled else { return }
                if let currentIndex = runs.firstIndex(where: { $0.id == runID }) {
                    runs[currentIndex].meetingAnalysis = analysis
                    runs[currentIndex].meetingAnalysisHistory.insert(analysis, at: 0)
                    meetingAnalysisStatus = "会议整理已生成"
                    updateSelectedHistoryFromCurrentRuns()
                }
            } catch {
                guard !Task.isCancelled else { return }
                meetingAnalysisStatus = "会议整理生成失败"
                lastError = error.localizedDescription
            }
        }
    }

    func validateMeetingAISettings() {
        guard !meetingAISettings.isMissingRequiredAPIKey else {
            var updated = meetingAISettings
            updated.validationPassed = false
            updated.validationSummary = "远程端点通常需要 API Key；本机 localhost 端点可以留空。"
            updated.lastValidatedAt = nil
            meetingAISettings = updated
            activeTaskTitle = "会议 AI 等待填写 API Key"
            lastError = nil
            return
        }
        isValidatingMeetingAI = true
        var settings = meetingAISettings
        settings.validationSummary = settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "正在校验本机 AI 地址和模型名称..."
            : "正在校验 AI 地址、API Key 和模型名称..."
        settings.validationPassed = false
        settings.lastValidatedAt = nil
        meetingAISettings = settings
        lastError = nil

        Task { @MainActor in
            defer { isValidatingMeetingAI = false }
            do {
                let result = try await meetingAIService.validate(settings: meetingAISettings)
                var updated = meetingAISettings
                updated.validationPassed = result.passed
                updated.validationSummary = result.summary
                updated.lastValidatedAt = Date()
                meetingAISettings = updated
                activeTaskTitle = "会议 AI 校验通过"
            } catch {
                var updated = meetingAISettings
                updated.validationPassed = false
                updated.validationSummary = "校验失败：\(error.localizedDescription)"
                updated.lastValidatedAt = Date()
                meetingAISettings = updated
                activeTaskTitle = "会议 AI 校验失败"
                lastError = updated.validationSummary
            }
        }
    }

    private func shouldAutoGenerateMeetingAnalysis(for run: ComparisonRun) -> Bool {
        meetingAISettings.autoGenerateAfterTranscription &&
        meetingAISettings.hasUsableAPIKey &&
        run.meetingAnalysis == nil &&
        !run.cleanTranscriptPreview.isEmpty &&
        run.passesAutomaticQualityCheck &&
        (run.reviewerVerdict == .best || run.id == primaryTranscriptRun?.id)
    }

    private func applyTranscriptionResult(_ result: ASRTranscriptionResult, to index: Int) {
        runs[index].status = result.text.isEmpty ? "无文本" : "完成"
        runs[index].duration = result.metrics.duration
        runs[index].transcribeTime = result.metrics.transcribeTime
        runs[index].rtf = result.metrics.rtf
        runs[index].speed = result.metrics.speed
        runs[index].acceleratorDevice = result.metrics.acceleratorDevice
        runs[index].acceleratorFallbackReason = result.metrics.acceleratorFallbackReason
        runs[index].characterErrorRate = nil
        runs[index].cachedSegmentCount = nil
        runs[index].transcriptPreview = result.text
        runs[index].meetingAnalysis = nil
        runs[index].meetingAnalysisHistory = []

        if result.text.isEmpty {
            runs[index].reviewerVerdict = .missed
            runs[index].errorMessage = "模型完成了推理，但没有输出可显示文本。请换一段更清晰的音频，或关闭热词/VAD 后重试。"
        } else if let warning = runs[index].automaticQualityWarning {
            runs[index].reviewerVerdict = .missed
            runs[index].errorMessage = warning
        } else {
            runs[index].reviewerVerdict = .unrated
            runs[index].errorMessage = nil
        }
    }

    private func markPendingRunsAsCancelled() {
        for index in runs.indices where runs[index].status == "等待运行" || runs[index].status == "转写中" || runs[index].status == "重跑中" {
            runs[index].status = "已停止"
            runs[index].errorMessage = "用户停止了当前转写任务。"
        }
    }

    private nonisolated func terminateExternalASRProcesses() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        process.arguments = [
            "-f",
            "Scripts/asr/(hf_asr_transcribe|mimo_mlx_transcribe)\\.py"
        ]
        try? process.run()
        process.waitUntilExit()
    }

    func addHotwordSet() {
        hotwordSets.append(
            HotwordSet(id: UUID(), name: "新热词组", words: ["请输入热词"], weight: 1.0, isEnabled: true)
        )
    }

    func updateHotwords(for setID: UUID, text: String) {
        guard let index = hotwordSets.firstIndex(where: { $0.id == setID }) else { return }
        hotwordSets[index].words = text
            .split(whereSeparator: { $0 == "\n" || $0 == "," || $0 == "，" || $0 == "、" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    func updateReview(for runID: UUID, verdict: TranscriptVerdict) {
        guard let index = runs.firstIndex(where: { $0.id == runID }) else { return }
        runs[index].reviewerVerdict = verdict
        if verdict == .best {
            runs[index].reviewerScore = runs[index].reviewerScore ?? 5
        } else if verdict == .sameGood {
            runs[index].reviewerScore = runs[index].reviewerScore ?? 4
        } else if verdict == .missed {
            runs[index].reviewerScore = 0
        }
        updateSelectedHistoryFromCurrentRuns()
    }

    func updateScore(for runID: UUID, score: Int?) {
        guard let index = runs.firstIndex(where: { $0.id == runID }) else { return }
        runs[index].reviewerScore = score.map { min(max($0, 0), 5) }
        updateSelectedHistoryFromCurrentRuns()
    }

    func updateNote(for runID: UUID, note: String) {
        guard let index = runs.firstIndex(where: { $0.id == runID }) else { return }
        runs[index].reviewerNote = note
        updateSelectedHistoryFromCurrentRuns()
    }

    func applyMeetingAIPreset(_ preset: MeetingAIPreset) {
        meetingAISettings.baseURL = preset.baseURL
        meetingAISettings.apiKey = preset.apiKey
        meetingAISettings.model = preset.model
        meetingAISettings.tokenPlan = preset.tokenPlan
        if let customMaxTokens = preset.customMaxTokens {
            meetingAISettings.customMaxTokens = customMaxTokens
        }
        if let customInputCharacterLimit = preset.customInputCharacterLimit {
            meetingAISettings.customInputCharacterLimit = customInputCharacterLimit
        }
        meetingAISettings.validationPassed = false
        meetingAISettings.validationSummary = "已切换到 \(preset.title)，建议重新测试连接。"
        meetingAISettings.lastValidatedAt = nil
    }

    func markEquivalentGroupAsSameGood(for group: String?) {
        guard let group else { return }
        for index in runs.indices where runs[index].equivalenceGroup == group {
            runs[index].reviewerVerdict = .sameGood
            runs[index].reviewerScore = runs[index].reviewerScore ?? 4
        }
        updateSelectedHistoryFromCurrentRuns()
    }

    func selectHistory(_ entry: RunHistoryEntry) {
        guard !isRunning else {
            lastError = "当前正在转写，先保持正在运行的任务不被历史记录覆盖。任务完成后再打开历史记录。"
            return
        }
        currentHistoryLoadTask?.cancel()
        selectedHistoryID = entry.id
        selectedAudioPath = entry.audioPath
        activeTaskTitle = "正在载入历史记录"
        activeTaskProgress = 0.05
        currentStage = Self.historyDateFormatter.string(from: entry.createdAt)
        elapsedTimeLabel = "--"
        remainingTimeLabel = "--"
        liveTranscript = ""
        isLoadingHistory = true

        let targetID = entry.id
        let targetAudioPath = entry.audioPath
        let targetRuns = normalizedRuns(entry.runs)
        let targetStage = Self.historyDateFormatter.string(from: entry.createdAt)
        currentHistoryLoadTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled, selectedHistoryID == targetID else { return }
            selectedAudioPath = targetAudioPath
            runs = targetRuns
            activeTaskTitle = "已载入历史记录"
            activeTaskProgress = 1
            currentStage = targetStage
            isLoadingHistory = false
            currentHistoryLoadTask = nil
        }
    }

    private func transcribe(
        audioPath: String? = nil,
        model: ASRModelSpec,
        terminologyPostProcessing: Bool,
        acceleratorDevice: String?,
        longAudioCacheEnabled: Bool,
        longAudioChunkSeconds requestedChunkSeconds: Int? = nil,
        progress: @escaping @Sendable (ASRProgressUpdate) -> Void
    ) async throws -> ASRTranscriptionResult {
        guard isRunnableModel(model) else {
            throw ASREngineError.adapterNotImplemented(unavailableRuntimeMessage(for: model))
        }
        let resolvedAudioPath = audioPath ?? selectedAudioPath
        let resolvedChunkSeconds = requestedChunkSeconds ?? longAudioChunkSeconds

        switch model.runtime {
        case .sherpaONNX:
            throw ASREngineError.adapterNotImplemented(Self.cleanUnsupportedRuntimeMessage)
        case .externalCLI:
            let engine = hfEngine
            let cacheDirectory = modelStorage.systemRoot
            let hotwords = enabledHotwords
            let useVAD = useVAD
            let preferAccuracy = preferAccuracy
            return try await Task.detached(priority: .userInitiated) {
                try await engine.transcribe(
                    audioPath: resolvedAudioPath,
                    model: model,
                    cacheDirectory: cacheDirectory,
                    hotwords: hotwords,
                    useVAD: useVAD,
                    preferAccuracy: preferAccuracy,
                    terminologyPostProcessing: terminologyPostProcessing,
                    longAudioCacheEnabled: longAudioCacheEnabled,
                    longAudioChunkSeconds: resolvedChunkSeconds,
                    acceleratorDevice: acceleratorDevice,
                    progress: progress
                )
            }.value
        default:
            throw ASREngineError.unsupportedRuntime(model.runtime.rawValue)
        }
    }

    private func recomputeEquivalenceGroups() {
        for index in runs.indices {
            runs[index].equivalenceGroup = nil
        }

        var groupIndex = 1
        var assigned = Set<UUID>()
        let completed = runs.indices.filter {
            !runs[$0].cleanTranscriptPreview.isEmpty
        }

        for sourceIndex in completed {
            let sourceID = runs[sourceIndex].id
            guard !assigned.contains(sourceID) else { continue }

            let matchingIndices = completed.filter { candidateIndex in
                sourceIndex == candidateIndex || areTranscriptsEffectivelyEqual(
                    runs[sourceIndex].cleanTranscriptPreview,
                    runs[candidateIndex].cleanTranscriptPreview
                )
            }

            guard matchingIndices.count > 1 else { continue }

            let group = "相同组 \(groupIndex)"
            groupIndex += 1
            for index in matchingIndices {
                runs[index].equivalenceGroup = group
                assigned.insert(runs[index].id)
            }
        }
    }

    private var historyDirectoryURL: URL {
        resolvedModelCacheURL
            .deletingLastPathComponent()
            .appending(path: "History", directoryHint: .isDirectory)
    }

    private var appSupportDirectoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: MeetingTruthConfig.supportDirectoryName, directoryHint: .isDirectory)
    }

    private var appSettingsURL: URL {
        appSupportDirectoryURL.appending(path: "app-settings.json")
    }

    private var meetingTruthDirectoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: MeetingTruthConfig.supportDirectoryName, directoryHint: .isDirectory)
            .appending(path: "MeetingTruth", directoryHint: .isDirectory)
    }

    private var meetingTruthProjectsFileURL: URL {
        meetingTruthDirectoryURL.appending(path: "projects.json")
    }

    private var historyFileURL: URL {
        historyDirectoryURL.appending(path: "runs.json")
    }

    private func loadRunHistory() {
        guard let data = try? Data(contentsOf: historyFileURL),
              let decoded = try? JSONDecoder.localASR.decode([RunHistoryEntry].self, from: data) else {
            runHistory = []
            return
        }
        runHistory = decoded.filter { !$0.containsLegacyASRBaseline }
            .map(normalizedHistoryEntry)
            .filter { !$0.runs.isEmpty }
            .sorted { $0.createdAt > $1.createdAt }
        saveRunHistory()
    }

    private func saveRunHistory() {
        do {
            try FileManager.default.createDirectory(at: historyDirectoryURL, withIntermediateDirectories: true)
            let data = try JSONEncoder.localASR.encode(runHistory)
            try data.write(to: historyFileURL, options: .atomic)
        } catch {
            lastError = "历史记录保存失败：\(error.localizedDescription)"
        }
    }

    private func loadMeetingTruthProjects() {
        guard let data = try? Data(contentsOf: meetingTruthProjectsFileURL),
              let decoded = try? JSONDecoder.localASR.decode(MeetingTruthProjectsStore.self, from: data),
              let projectID = decoded.lastOpenedProjectID,
              let project = decoded.projects.first(where: { $0.id == projectID }) ?? decoded.projects.first else {
            return
        }
        meetingTruthHistory = decoded.history
        applyMeetingTruthProject(project)
    }

    private func saveMeetingTruthProjects() {
        let project = currentMeetingTruthProject()
        archiveMeetingTruthHistorySnapshot(for: project)
        let payload = MeetingTruthProjectsStore(
            lastOpenedProjectID: project.id,
            projects: [project],
            history: meetingTruthHistory
        )
        do {
            try FileManager.default.createDirectory(at: meetingTruthDirectoryURL, withIntermediateDirectories: true)
            let data = try JSONEncoder.localASR.encode(payload)
            try data.write(to: meetingTruthProjectsFileURL, options: .atomic)
        } catch {
            lastError = "MeetingTruth 项目保存失败：\(error.localizedDescription)"
        }
    }

    private func saveCurrentRunToHistory() {
        guard !runs.isEmpty else { return }
        let entry = normalizedHistoryEntry(RunHistoryEntry(audioPath: selectedAudioPath, runs: runs))
        runHistory.insert(entry, at: 0)
        selectedHistoryID = entry.id
        saveRunHistory()
    }

    private func updateSelectedHistoryFromCurrentRuns() {
        guard let selectedHistoryID,
              let index = runHistory.firstIndex(where: { $0.id == selectedHistoryID }) else {
            return
        }
        runHistory[index].runs = normalizedRuns(runs)
        runHistory[index].audioPath = selectedAudioPath
        saveRunHistory()
    }

    private func normalizedHistoryEntry(_ entry: RunHistoryEntry) -> RunHistoryEntry {
        var normalized = entry
        normalized.runs = normalizedRuns(entry.runs)
        return normalized
    }

    private func normalizedRuns(_ runs: [ComparisonRun]) -> [ComparisonRun] {
        runs
            .map { run in
            var normalized = run
            if normalized.meetingAnalysisHistory.isEmpty, let analysis = normalized.meetingAnalysis {
                normalized.meetingAnalysisHistory = [analysis]
            }
            if normalized.meetingAnalysis == nil, let latest = normalized.meetingAnalysisHistory.first {
                normalized.meetingAnalysis = latest
            }
            return normalized
        }
    }

    private var externalModelConfigurationsURL: URL {
        appSupportDirectoryURL.appending(path: "external-model-configurations.json")
    }

    private func loadExternalModelConfigurations() {
        let legacyURL = historyDirectoryURL.appending(path: "external-model-configurations.json")
        let candidates = [externalModelConfigurationsURL, legacyURL]
        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let decoded = try? JSONDecoder.localASR.decode([String: ExternalModelConfiguration].self, from: data) else {
                continue
            }
            externalModelConfigurations = decoded
            if url != externalModelConfigurationsURL {
                saveExternalModelConfigurations()
            }
            return
        }
        externalModelConfigurations = [:]
    }

    private func saveExternalModelConfigurations() {
        do {
            try FileManager.default.createDirectory(at: appSupportDirectoryURL, withIntermediateDirectories: true)
            let data = try JSONEncoder.localASR.encode(externalModelConfigurations)
            try data.write(to: externalModelConfigurationsURL, options: .atomic)
        } catch {
            lastError = "外部模型配置保存失败：\(error.localizedDescription)"
        }
    }

    private func applyExternalModelConfigurations() {
        for index in models.indices where models[index].runtime == .externalCLI {
            guard let configuration = externalModelConfigurations[models[index].id] else { continue }
            let runtimeModelName = configuration.runtimeModelName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !runtimeModelName.isEmpty {
                models[index].runtimeModelName = runtimeModelName
            }

            let configuredPath = configuration.localPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if !configuredPath.isEmpty {
                let expandedPath = NSString(string: configuredPath).expandingTildeInPath
                models[index].localPath = expandedPath
                let localURL = URL(fileURLWithPath: expandedPath)
                let exists = FileManager.default.fileExists(atPath: expandedPath)
                let complete = exists && isCompleteModel(models[index], at: localURL)
                models[index].status = complete ? .ready : .failed
                models[index].progress = models[index].status == .ready ? 1 : 0
                models[index].sourceDescription = modelSourceDescription(for: models[index])
                models[index].validationSummary = complete
                    ? configuration.validationSummary
                    : validationSummary(for: models[index], at: localURL)
            } else if !configuration.validationSummary.isEmpty, configuration.validationSummary != "尚未校验" {
                models[index].validationSummary = configuration.validationSummary
            }
        }
    }

    private var meetingAISettingsURL: URL {
        appSupportDirectoryURL.appending(path: "meeting-ai-settings.json")
    }

    private func loadAppSettings() {
        guard let data = try? Data(contentsOf: appSettingsURL),
              let decoded = try? JSONDecoder.localASR.decode(AppSettings.self, from: data) else {
            return
        }
        let decodedPath = decoded.modelCachePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !decodedPath.isEmpty {
            modelCachePath = decodedPath
        }
    }

    private func saveAppSettings() {
        do {
            try FileManager.default.createDirectory(at: appSupportDirectoryURL, withIntermediateDirectories: true)
            let data = try JSONEncoder.localASR.encode(AppSettings(modelCachePath: modelCachePath))
            try data.write(to: appSettingsURL, options: .atomic)
        } catch {
            lastError = "应用设置保存失败：\(error.localizedDescription)"
        }
    }

    private func loadMeetingAISettings() {
        let legacyURL = historyDirectoryURL.appending(path: "meeting-ai-settings.json")
        let candidates = [meetingAISettingsURL, legacyURL]
        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let decoded = try? JSONDecoder.localASR.decode(MeetingAISettings.self, from: data) else {
                continue
            }
            meetingAISettings = decoded
            if url != meetingAISettingsURL {
                saveMeetingAISettings()
            }
            return
        }
    }

    private func saveMeetingAISettings() {
        do {
            try FileManager.default.createDirectory(at: appSupportDirectoryURL, withIntermediateDirectories: true)
            let data = try JSONEncoder.localASR.encode(meetingAISettings)
            try data.write(to: meetingAISettingsURL, options: .atomic)
        } catch {
            lastError = "AI 设置保存失败：\(error.localizedDescription)"
        }
    }

    private func areTranscriptsEffectivelyEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Self.normalizedTranscript(lhs)
        let right = Self.normalizedTranscript(rhs)
        guard !left.isEmpty, !right.isEmpty else { return false }
        if left == right { return true }
        let minLength = min(left.count, right.count)
        let maxLength = max(left.count, right.count)
        guard minLength >= 12 else { return false }
        guard Double(minLength) / Double(maxLength) >= 0.92 else { return false }

        let leftSample = Self.comparisonSample(left)
        let rightSample = Self.comparisonSample(right)
        if leftSample == rightSample { return true }
        return Self.similarity(leftSample, rightSample) >= 0.96
    }

    nonisolated private static func normalizedTranscript(_ text: String) -> String {
        text
            .folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive], locale: .current)
            .filter { character in
                character.isLetter || character.isNumber
            }
    }

    nonisolated private static func similarity(_ lhs: String, _ rhs: String) -> Double {
        let left = Array(lhs)
        let right = Array(rhs)
        guard !left.isEmpty || !right.isEmpty else { return 1 }
        guard !left.isEmpty, !right.isEmpty else { return 0 }

        var previous = Array(0...right.count)
        var current = Array(repeating: 0, count: right.count + 1)

        for leftIndex in 1...left.count {
            current[0] = leftIndex
            for rightIndex in 1...right.count {
                let substitution = previous[rightIndex - 1] + (left[leftIndex - 1] == right[rightIndex - 1] ? 0 : 1)
                current[rightIndex] = min(
                    previous[rightIndex] + 1,
                    current[rightIndex - 1] + 1,
                    substitution
                )
            }
            swap(&previous, &current)
        }

        let distance = previous[right.count]
        let maxLength = max(left.count, right.count)
        return 1 - (Double(distance) / Double(maxLength))
    }

    nonisolated private static func comparisonSample(_ text: String) -> String {
        let limit = 1800
        guard text.count > limit else { return text }
        let headCount = 900
        let tailCount = 900
        return String(text.prefix(headCount)) + String(text.suffix(tailCount))
    }

    private func runnableModel(id: String) -> ASRModelSpec? {
        models.first { $0.id == id && isRunnableModel($0) }
    }

    private func isRunnableModel(_ model: ASRModelSpec) -> Bool {
        if isUnsupportedCleanRuntime(model) {
            return false
        }
        if model.runtime == .sherpaONNX {
            return model.localPath != nil && model.status == .ready
        }
        if model.runtime == .externalCLI {
            guard model.localPath != nil && model.status == .ready else { return false }
            return hasImplementedExternalAdapter(for: model) && externalRuntimeIsReady(for: model)
        }
        return false
    }

    func canSelectForExperiment(_ model: ASRModelSpec) -> Bool {
        isRunnableModel(model)
    }

    func experimentAvailabilityTitle(for model: ASRModelSpec) -> String {
        if isRunnableModel(model) {
            return "可测试"
        }
        if model.status == .downloading {
            return "下载中"
        }
        if model.localPath == nil {
            return "未下载"
        }
        if model.validationSummary?.contains("不完整") == true {
            return "文件不完整"
        }
        return "推理未接入"
    }

    func experimentAvailabilityReason(for model: ASRModelSpec) -> String {
        if isRunnableModel(model) {
            return modelSubtitle(for: model)
        }
        if model.status == .downloading {
            return "模型还在下载，完成后再勾选测试。"
        }
        if model.localPath == nil {
            return "模型库里可以下载，下载完成后才可能进入实验。"
        }
        if let validation = model.validationSummary, validation.contains("不完整") {
            return validation
        }
        return unavailableRuntimeMessage(for: model)
    }

    private func modelSubtitle(for model: ASRModelSpec) -> String {
        switch model.runtime {
        case .sherpaONNX:
            return "\(model.family)：本地 ONNX 模型已就绪"
        case .externalCLI:
            return "\(model.family)：外部 CLI adapter 可测试"
        case .mlxSwift:
            return "\(model.family)：MLX adapter 可测试"
        }
    }

    private func unavailableRuntimeMessage(for model: ASRModelSpec) -> String {
        if isUnsupportedCleanRuntime(model) {
            return Self.cleanUnsupportedRuntimeMessage
        }
        if model.runtime == .externalCLI,
           !hasImplementedExternalAdapter(for: model) {
            return "\(model.name) 权重可下载，但当前还没有接入可用的本机推理 adapter，先不加入主流程。"
        }
        if model.runtime == .externalCLI,
           !externalRuntimeIsReady(for: model) {
            if let setupScript = externalSetupScript(for: model) {
                return "\(model.name) 模型文件已准备，但推理依赖还没安装完成。请在模型库点击准备，或运行：./\(setupScript.pathComponents.suffix(2).joined(separator: "/"))"
            }
            return "\(model.name) 模型文件已准备，但缺少推理依赖安装脚本。"
        }
        if model.id == "mimo-v2-5-asr" {
            return "MiMo-V2.5-ASR 官方权重已下载；本机实验 adapter 可用，但推荐优先试 GGUF Q4_K / Metal 路线。"
        }
        if model.id == "canary-qwen-2-5b" {
            return "Canary-Qwen 权重已下载，但当前 Mac CPU 本机链路对中文音频会输出重复英文，不加入批量转写。"
        }
        if model.id.contains("mimo-v2-5-asr-gguf") {
            return "MiMo GGUF 已下载；还需要安装 CrispASR，或设置 LOCAL_ASR_CRISPASR_BIN 指向 crispasr 可执行文件。"
        }
        if model.id.contains("qwen3-asr") && (model.runtimeModelName ?? "").lowercased().contains("gguf") {
            return "Qwen3-ASR GGUF 已下载；还需要安装 CrispASR，或设置 LOCAL_ASR_CRISPASR_BIN 指向 crispasr 可执行文件。"
        }
        return "\(model.name) 已下载，但当前 runtime 还没有可用的本机推理 adapter。"
    }

    private func isUnsupportedCleanRuntime(_ model: ASRModelSpec) -> Bool {
        model.runtime == .sherpaONNX
            || model.id.contains("funasr")
            || model.id == "dolphin"
            || model.id == "omnilingual-asr"
            || model.id.hasPrefix("vibevoice-asr")
            || model.id == "canary-qwen-2-5b"
            || model.id == "mimo-v2-5-asr"
            || model.id.contains("mimo-v2-5-asr-gguf")
            || model.id.contains("qwen3-asr-mlx")
            || (model.id.contains("qwen3-asr") && (model.runtimeModelName ?? "").lowercased().contains("gguf"))
    }

    private func hasImplementedExternalAdapter(for model: ASRModelSpec) -> Bool {
        if isUnsupportedCleanRuntime(model) { return false }
        if model.id.contains("qwen3-asr") { return true }
        if model.id.contains("glm") { return true }
        if model.id.hasPrefix("mimo-v2-5-asr-mlx") { return true }
        return false
    }

    private func expectedFolderName(for model: ASRModelSpec) -> String? {
        switch model.id {
        case "sensevoice-small":
            return "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17"
        case "paraformer-zh":
            return "sherpa-onnx-paraformer-zh-small-2024-03-09"
        case "firered-asr2":
            return "sherpa-onnx-fire-red-asr2-ctc-zh_en-int8-2026-02-25"
        default:
            return nil
        }
    }

    private func existingModelAsset(for model: ASRModelSpec) -> URL? {
        let newDirectory = modelStorage.assetDirectory(for: model)
        if isCompleteModel(model, at: newDirectory) {
            return manifestLocalPath(in: newDirectory) ?? newDirectory
        }

        if let folderName = expectedFolderName(for: model) {
            let legacy = modelStorage.legacySherpaDirectory(folderName: folderName)
            if isCompleteModel(model, at: legacy) {
                return legacy
            }
            if let found = findDirectory(named: folderName, under: resolvedModelCacheURL),
               isCompleteModel(model, at: found) {
                return found
            }
        }

        if model.runtime == .externalCLI,
           let found = existingExternalCache(for: model) {
            return found
        }

        return nil
    }

    private func applyReadyModel(at localURL: URL, to index: Int) {
        models[index].localPath = localURL.path
        models[index].progress = 1
        models[index].status = .ready
        models[index].sourceDescription = modelSourceDescription(for: models[index])
        models[index].validationSummary = validationSummary(for: models[index], at: localURL)
    }

    private func manifestLocalPath(in directory: URL) -> URL? {
        if let manifest = modelStorage.readManifest(at: directory), !manifest.localPath.isEmpty {
            return URL(fileURLWithPath: manifest.localPath)
        }
        if let markerText = try? String(contentsOf: directory.appending(path: ".local-asr-ready"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !markerText.isEmpty {
            return URL(fileURLWithPath: markerText)
        }
        return nil
    }

    private func installAndPrefetchExternalModel(
        _ model: ASRModelSpec,
        progress: @escaping @Sendable (DownloadMetrics, String) -> Void
    ) async throws -> URL {
        guard let modelID = model.runtimeModelName else {
            throw ASREngineError.missingRuntimeModelName(model.name)
        }

        let runtime = externalRuntimeName(for: model)
        guard let prefetchScript = RuntimePaths.projectFile("Scripts/asr/prefetch_model.py") else {
            throw ASREngineError.adapterNotImplemented("找不到 prefetch_model.py 下载脚本。")
        }
        guard let preflightScript = RuntimePaths.projectFile("Scripts/asr/preflight_model_env.py") else {
            throw ASREngineError.adapterNotImplemented("找不到 preflight_model_env.py 环境预检脚本。")
        }

        let targetURL = modelStorage.assetDirectory(for: model)
        try FileManager.default.createDirectory(at: targetURL, withIntermediateDirectories: true, attributes: nil)

        let expectedBytes = Self.expectedDownloadBytes(for: model)
        let runtimeDir = RuntimePaths.workspaceRoot
            .appending(path: ".runtime", directoryHint: .isDirectory)
            .appending(path: runtime, directoryHint: .isDirectory)
        progress(
            DownloadMetrics(downloadedBytes: Self.directorySize(at: targetURL.path), totalBytes: expectedBytes, speedBytesPerSecond: 0, estimatedRemainingSeconds: nil),
            "正在预检 \(model.name) 本机环境"
        )
        _ = try await runProcessWithStructuredProgress(
            executable: RuntimePaths.pythonExecutable(preferredRuntime: runtime),
            arguments: [
                preflightScript.path,
                "--model-id", modelID,
                "--target", targetURL.path,
                "--runtime-dir", runtimeDir.path,
                "--expected-bytes", "\(expectedBytes)",
                "--min-python", "3.10",
                "--max-python", "3.12"
            ],
            environment: externalDownloadEnvironment(for: model)
        ) { metrics, stage in
            progress(metrics, stage ?? "正在预检 \(model.name) 本机环境")
        }

        progress(
            DownloadMetrics(downloadedBytes: Self.directorySize(at: targetURL.path), totalBytes: expectedBytes, speedBytesPerSecond: 0, estimatedRemainingSeconds: nil),
            "正在下载 \(model.name)"
        )
        let output = try await runProcessWithDiskProgress(
            executable: RuntimePaths.pythonExecutable(preferredRuntime: runtime),
            arguments: [
                prefetchScript.path,
                "--model-kind", externalModelKind(for: model),
                "--model-id", modelID,
                "--target", targetURL.path,
                "--shared-target", sharedModelCacheURL.path,
                "--app-model-id", model.id,
                "--app-model-name", model.name,
                "--runtime", model.runtime.rawValue
            ],
            environment: externalDownloadEnvironment(for: model)
        ) { metrics, stage in
            let title = stage ?? Self.downloadTitle(modelName: model.name, metrics: metrics)
            progress(metrics, title)
        }

        progress(
            DownloadMetrics(downloadedBytes: expectedBytes, totalBytes: expectedBytes, speedBytesPerSecond: 0, estimatedRemainingSeconds: 0),
            "正在验证 \(model.name) 本地缓存"
        )
        if let data = output.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(PrefetchOutput.self, from: data),
           !decoded.localPath.isEmpty {
            let localURL = URL(fileURLWithPath: decoded.localPath)
            if model.id.contains("mimo-v2-5-asr-gguf") {
                try validateMiMoGGUFInstall(at: localURL)
            }
            if model.id.hasPrefix("mimo-v2-5-asr-mlx") {
                try validateMiMoMLXInstall(at: localURL, modelID: model.id)
            }
            if model.id == "glm-asr-nano-2512" {
                try validateGLMASRInstall(at: localURL)
            }
            if model.id == "qwen3-asr-timestamps" || model.id == "qwen3-asr-1.7b-timestamps" {
                try validateQwenTimestampInstall(at: localURL, modelID: model.id)
            }
            if model.id.contains("qwen3-asr") && (model.runtimeModelName ?? "").lowercased().contains("gguf") {
                try validateQwen3GGUFInstall(at: localURL)
            }
            try await installExternalRuntimeIfNeeded(for: model, progress: progress)
            return localURL
        }

        try await installExternalRuntimeIfNeeded(for: model, progress: progress)
        return targetURL
    }

    private func installExternalRuntimeIfNeeded(
        for model: ASRModelSpec,
        progress: @escaping @Sendable (DownloadMetrics, String) -> Void
    ) async throws {
        guard let setupScript = externalSetupScript(for: model) else { return }
        progress(
            DownloadMetrics(downloadedBytes: 0, totalBytes: Self.expectedDownloadBytes(for: model), speedBytesPerSecond: 0, estimatedRemainingSeconds: nil),
            "正在配置 \(model.name) 推理依赖"
        )
        _ = try await runProcessWithStructuredProgress(
            executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: [setupScript.path],
            environment: nil
        ) { metrics, stage in
            progress(metrics, stage ?? "正在配置 \(model.name) 推理依赖")
        }
        guard externalRuntimeIsReady(for: model) else {
            throw ASREngineError.adapterNotImplemented("\(model.name) 推理依赖安装脚本已结束，但 runtime-ready 标记缺失。请重试准备模型。")
        }
    }

    private func externalRuntimeIsReady(for model: ASRModelSpec) -> Bool {
        let marker = RuntimePaths.workspaceRoot
            .appending(path: ".runtime", directoryHint: .isDirectory)
            .appending(path: externalRuntimeName(for: model), directoryHint: .isDirectory)
            .appending(path: ".local-asr-runtime-ready")
        return FileManager.default.fileExists(atPath: marker.path)
    }

    private func recordModelPreparationFailure(_ error: Error, for model: ASRModelSpec) -> ModelPreparationFailure {
        var failure = userReadablePreparationFailure(from: error, modelName: model.name)
        failure.modelID = model.id
        modelPreparationFailures[model.id] = failure
        return failure
    }

    private func userReadablePreparationFailure(from error: Error, modelName: String) -> ModelPreparationFailure {
        let details = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = details.lowercased()
        let summary: String
        var suggestions: [String]

        if normalized.contains("unsupported operand type") && normalized.contains("|") ||
            normalized.contains("低于要求") ||
            normalized.contains("高于已验证范围") ||
            normalized.contains("python 3.9") ||
            normalized.contains("python 3.8") ||
            normalized.contains("python 3.7") ||
            normalized.contains("python 3.13") ||
            normalized.contains("python 3.14") {
            summary = "模型准备失败：当前 Python 版本不在已验证范围。请安装 Python 3.10-3.12，推荐 Python 3.11。"
            suggestions = [
                "安装 Python 3.11 后重新检测环境。",
                "如果已安装多个 Python，请设置 LOCAL_ASR_PYTHON311 指向可执行文件。",
                "重新点击这个模型的重试按钮。"
            ]
        } else if normalized.contains("network") ||
                    normalized.contains("网络不可达") ||
                    normalized.contains("timed out") ||
                    normalized.contains("timeout") ||
                    normalized.contains("could not resolve") ||
                    normalized.contains("connection") ||
                    normalized.contains("所有 hugging face 下载源都失败") {
            summary = "模型准备失败：下载源暂时不可达。请检查网络，或配置 HF_ENDPOINT / LOCAL_ASR_HF_ENDPOINTS 镜像后重试。"
            suggestions = [
                "确认浏览器能访问 Hugging Face 或配置可用镜像。",
                "在启动 App 前设置 HF_ENDPOINT=https://hf-mirror.com，或设置 LOCAL_ASR_HF_ENDPOINTS 为多个源。",
                "稍后重试，下载器会复用已完成文件并继续 .part 断点。"
            ]
        } else if normalized.contains("磁盘空间不足") ||
                    normalized.contains("no space left") ||
                    normalized.contains("disk") {
            summary = "模型准备失败：磁盘空间不足。请清理空间或把模型缓存目录改到更大的磁盘。"
            suggestions = [
                "至少预留模型标称大小 1.15 倍的可用空间。",
                "在设置里调整模型缓存目录。",
                "清理损坏缓存后重试。"
            ]
        } else if normalized.contains("permission") ||
                    normalized.contains("权限") ||
                    normalized.contains("operation not permitted") ||
                    normalized.contains("无法写入") {
            summary = "模型准备失败：无法写入模型缓存目录。请检查目录权限或更换缓存路径。"
            suggestions = [
                "确认当前用户能写入模型缓存目录。",
                "在设置里更换模型缓存目录。",
                "避免把缓存目录放在只读磁盘或需要额外授权的位置。"
            ]
        } else if normalized.contains("pip") ||
                    normalized.contains("ensurepip") ||
                    normalized.contains("venv") ||
                    normalized.contains("no module named") ||
                    normalized.contains("依赖") ||
                    normalized.contains("package") {
            summary = "模型准备失败：Python 依赖安装或校验失败。请检查 pip 网络和 Python 版本后重试。"
            suggestions = [
                "推荐使用 Python 3.11，并让 App 重新创建独立 .runtime 虚拟环境。",
                "确认 pip 源可访问；如需镜像，设置 LOCAL_ASR_PIP_INDEX_URLS。",
                "删除对应 .runtime 子目录后重试可触发干净安装。"
            ]
        } else if normalized.contains(".part") ||
                    normalized.contains("大小不匹配") ||
                    normalized.contains("不完整") ||
                    normalized.contains("损坏") {
            summary = "模型准备失败：本地模型缓存不完整或损坏。可以继续重试，若反复失败请清理该模型缓存后重新下载。"
            suggestions = [
                "直接点击重试，下载器会优先尝试断点续传。",
                "如果仍失败，删除该模型目录中的 .part 文件或整个模型目录。",
                "确认磁盘和网络稳定后再重试。"
            ]
        } else {
            summary = "模型准备失败：\(modelName) 没有完成下载、依赖安装或校验。请按建议重试，开发者详情中保留了完整日志。"
            suggestions = [
                "重新检测环境。",
                "重新安装依赖或删除对应 .runtime 子目录后重试。",
                "检查网络、HF 镜像和模型缓存目录权限。"
            ]
        }

        return ModelPreparationFailure(
            modelID: "",
            summary: summary,
            recoverySuggestions: suggestions,
            developerDetails: details.isEmpty ? String(describing: error) : details
        )
    }

    private func externalSetupScript(for model: ASRModelSpec) -> URL? {
        if isUnsupportedCleanRuntime(model) { return nil }
        if model.id.contains("qwen3-asr"),
           !(model.runtimeModelName ?? "").lowercased().contains("gguf") {
            return RuntimePaths.projectFile("script/setup_qwen_asr_runtime.sh")
        }
        if model.id.hasPrefix("mimo-v2-5-asr-mlx") {
            return RuntimePaths.projectFile("script/setup_mimo_mlx_runtime.sh")
        }
        return RuntimePaths.projectFile("script/setup_hf_asr_runtime.sh")
    }

    private func externalRuntimeName(for model: ASRModelSpec) -> String {
        if isUnsupportedCleanRuntime(model) { return "unsupported-clean-asr" }
        if model.id.hasPrefix("mimo-v2-5-asr-mlx") { return "mimo-mlx" }
        if model.id.contains("qwen3-asr") { return "qwen-asr" }
        return "hf-asr"
    }

    private func externalModelKind(for model: ASRModelSpec) -> String {
        if isUnsupportedCleanRuntime(model) { return "unsupported" }
        if model.id.hasPrefix("mimo-v2-5-asr-mlx") { return "mimo-mlx" }
        if model.id.contains("qwen3-asr") { return "qwen" }
        if model.id.contains("glm") { return "glm" }
        return "auto"
    }

    private func downloadFraction(for metrics: DownloadMetrics) -> Double {
        guard metrics.totalBytes > 0 else {
            return 0.05
        }
        return min(max(Double(metrics.downloadedBytes) / Double(metrics.totalBytes), 0.01), 0.99)
    }

    nonisolated private static func sanitizedDownloadMetrics(_ metrics: DownloadMetrics) -> DownloadMetrics {
        guard metrics.totalBytes > 0 else { return metrics }
        let remainingBytes = max(metrics.totalBytes - metrics.downloadedBytes, 0)
        let maxReasonableSpeed = Double(metrics.totalBytes) / 5
        let speed = metrics.speedBytesPerSecond > 0
            ? min(metrics.speedBytesPerSecond, maxReasonableSpeed)
            : 0
        let remaining = speed > 0 ? Double(remainingBytes) / speed : metrics.estimatedRemainingSeconds
        return DownloadMetrics(
            downloadedBytes: metrics.downloadedBytes,
            totalBytes: metrics.totalBytes,
            speedBytesPerSecond: speed,
            estimatedRemainingSeconds: remaining
        )
    }

    nonisolated private static func isTranscriptProgressText(_ update: ASRProgressUpdate) -> Bool {
        let text = update.partialText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }

        let preparationText = text.localizedCaseInsensitiveContains("forced aligner")
            || text.contains("时间戳对齐器")
            || text.contains("首次使用需要准备")
        let preparationStage = update.stage.contains("下载")
            || update.stage.contains("准备")
            || update.stage.contains("加载 Qwen 时间戳对齐器")
        return !(preparationText && preparationStage)
    }

    private func downloadTitle(for model: ASRModelSpec) -> String {
        Self.downloadTitle(modelName: model.name, metrics: model.downloadMetrics)
    }

    nonisolated private static func downloadTitle(modelName: String, metrics: DownloadMetrics) -> String {
        "正在下载 \(modelName) · \(formatBytes(metrics.downloadedBytes)) / \(formatBytes(metrics.totalBytes))"
    }

    nonisolated private static func expectedDownloadBytes(for model: ASRModelSpec) -> Int64 {
        switch model.id {
        case "glm-asr-nano-2512":
            return Int64(4.52 * 1_000_000_000)
        case "mimo-v2-5-asr-gguf-q4":
            return Int64(5.5 * 1_000_000_000)
        case "mimo-v2-5-asr-gguf-f16":
            return Int64(15.5 * 1_000_000_000)
        case "mimo-v2-5-asr-mlx":
            return Int64(5.0 * 1_000_000_000)
        case "mimo-v2-5-asr-mlx-bf16":
            return Int64(18.0 * 1_000_000_000)
        case "mimo-v2-5-asr":
            return 35_997_910_525
        case "funasr-sensevoice":
            return Int64(1.5 * 1_000_000_000)
        case "funasr-nano-2512":
            return Int64(2.1 * 1_000_000_000)
        case "vibevoice-asr", "vibevoice-asr-bf16":
            return Int64(18.0 * 1_073_741_824)
        case "vibevoice-asr-4bit":
            return Int64(6.0 * 1_000_000_000)
        case "canary-qwen-2-5b":
            return Int64(6.0 * 1_000_000_000)
        case "omnilingual-asr":
            return Int64(12.0 * 1_073_741_824)
        case "dolphin":
            return Int64(1.0 * 1_073_741_824)
        case "qwen3-asr":
            return Int64(2.0 * 1_000_000_000)
        case "qwen3-asr-timestamps":
            return Int64(3.9 * 1_000_000_000)
        case "qwen3-asr-mlx-0-6b-8bit":
            return Int64(1.2 * 1_000_000_000)
        case "qwen3-asr-mlx-0-6b-bf16":
            return Int64(1.7 * 1_000_000_000)
        case "qwen3-asr-1.7b":
            return Int64(4.6 * 1_000_000_000)
        case "qwen3-asr-1.7b-timestamps":
            return Int64(6.5 * 1_000_000_000)
        case "qwen3-asr-mlx-1-7b-8bit":
            return Int64(2.8 * 1_000_000_000)
        case "qwen3-asr-mlx-1-7b-bf16":
            return Int64(4.0 * 1_000_000_000)
        case "qwen3-asr-gguf-q4":
            return Int64(600 * 1_000_000)
        case "qwen3-asr-1-7b-gguf-q4":
            return Int64(1.8 * 1_000_000_000)
        default:
            return Int64(5.0 * 1_000_000_000)
        }
    }

    private func existingExternalCache(for model: ASRModelSpec) -> URL? {
        var candidates = modelStorage.legacyExternalDirectories(
            for: model,
            runtimes: externalCacheRuntimeNames(for: model)
        )
        if let alias = primaryAssetAlias(for: model) {
            candidates.append(contentsOf: modelStorage.legacyExternalDirectories(
                for: alias,
                runtimes: externalCacheRuntimeNames(for: model)
            ))
        }

        for candidate in candidates {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                continue
            }

            let localURL = manifestLocalPath(in: candidate) ?? candidate
            if isCompleteModel(model, at: localURL) {
                return localURL
            }
        }
        return nil
    }

    private func primaryAssetAlias(for model: ASRModelSpec) -> ASRModelSpec? {
        let primaryID: String
        switch model.id {
        case "qwen3-asr-timestamps":
            primaryID = "qwen3-asr"
        case "qwen3-asr-1.7b-timestamps":
            primaryID = "qwen3-asr-1.7b"
        default:
            return nil
        }
        return models.first { $0.id == primaryID } ?? ModelRegistry.initialModels.first { $0.id == primaryID }
    }

    private func isCompleteModel(_ model: ASRModelSpec, at localURL: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: localURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }

        switch model.runtime {
        case .sherpaONNX:
            return findFiles(under: localURL, suffix: ".onnx", nameContains: "").isEmpty == false
                && findFiles(under: localURL, suffix: "tokens.txt", nameContains: "").isEmpty == false
        case .externalCLI:
            guard !hasPartialDownloadFiles(at: localURL) else {
                return false
            }
            if model.id.contains("mimo-v2-5-asr-gguf") {
                return hasMiMoGGUFAssets(at: localURL)
            }
            if model.id.contains("qwen3-asr"),
               (model.runtimeModelName ?? "").lowercased().contains("gguf") {
                return hasQwen3GGUFAssets(at: localURL)
            }
            if model.id == "mimo-v2-5-asr" {
                return FileManager.default.fileExists(atPath: localURL.appending(path: "MiMo-V2.5-ASR/model.safetensors.index.json").path)
                    || FileManager.default.fileExists(atPath: localURL.appending(path: "model.safetensors.index.json").path)
            }
            if model.id.hasPrefix("mimo-v2-5-asr-mlx") {
                return hasMiMoMLXAssets(at: localURL, modelID: model.id)
            }
            if model.id == "vibevoice-asr-bf16" {
                return hasLargeHFSnapshotAssets(at: localURL, minimumBytes: Int64(12.0 * 1_000_000_000))
            }
            if model.id == "vibevoice-asr-4bit" {
                return hasLargeHFSnapshotAssets(at: localURL, minimumBytes: Int64(4.0 * 1_000_000_000))
            }
            if model.id == "funasr-sensevoice" {
                return isNonEmptyDirectory(localURL)
            }
            if model.id == "funasr-nano-2512" {
                return hasFunASRNanoAssets(at: localURL)
            }
            if model.id == "qwen3-asr-timestamps" || model.id == "qwen3-asr-1.7b-timestamps" {
                return hasQwenTimestampAssets(at: localURL, modelID: model.id)
            }
            if model.id == "glm-asr-nano-2512" {
                return isValidGLMASRInstall(at: localURL)
            }
            if model.id == "dolphin" {
                return findFiles(under: localURL, suffix: ".pt", nameContains: "base").isEmpty == false
                    && findFiles(under: localURL, suffix: "bpe.model", nameContains: "").isEmpty == false
                    && findFiles(under: localURL, suffix: "config.yaml", nameContains: "").isEmpty == false
            }
            if model.id == "omnilingual-asr" {
                return findFiles(under: localURL, suffix: ".pt", nameContains: "omniasr").isEmpty == false
                    && FileManager.default.fileExists(atPath: localURL.appending(path: "omniASR_tokenizer.model").path)
            }
            return FileManager.default.fileExists(atPath: localURL.appending(path: "config.json").path)
                || findFiles(under: localURL, suffix: ".safetensors", nameContains: "").isEmpty == false
                || findFiles(under: localURL, suffix: ".bin", nameContains: "").isEmpty == false
                || findFiles(under: localURL, suffix: ".pt", nameContains: "").isEmpty == false
                || findFiles(under: localURL, suffix: ".pth", nameContains: "").isEmpty == false
        case .mlxSwift:
            return false
        }
    }

    private func validateMiMoGGUFInstall(at localURL: URL) throws {
        let fileManager = FileManager.default
        guard let asrFile = findFiles(under: localURL, suffix: ".gguf", nameContains: "mimo-asr").first else {
            throw ASREngineError.adapterNotImplemented("MiMo GGUF 下载不完整：找不到 mimo-asr GGUF 文件。")
        }
        guard fileSize(at: asrFile) > Int64(1_000_000_000) else {
            throw ASREngineError.adapterNotImplemented("MiMo GGUF 下载不完整：\(asrFile.lastPathComponent) 体积异常，可能还没下载完。")
        }

        let tokenizerFiles = findFiles(under: localURL, suffix: ".gguf", nameContains: "tokenizer")
        guard let tokenizerFile = tokenizerFiles.first else {
            throw ASREngineError.adapterNotImplemented("MiMo GGUF 下载不完整：找不到 MiMo tokenizer GGUF 文件。")
        }
        guard fileManager.fileExists(atPath: tokenizerFile.path) else {
            throw ASREngineError.adapterNotImplemented("MiMo tokenizer 链接不可用：\(tokenizerFile.path)")
        }

        guard let crispasrBin = RuntimePaths.projectFile(".runtime/crispasr/build-ninja-compile/bin/crispasr"),
              fileManager.isExecutableFile(atPath: crispasrBin.path) else {
            throw ASREngineError.adapterNotImplemented("CrispASR/Metal runtime 未就绪：请重新点击 MiMo GGUF 下载，下载流程会自动编译 runtime。")
        }

        let process = Process()
        process.executableURL = crispasrBin
        process.arguments = ["--list-backends"]
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        let stdout = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0, stdout.contains("mimo-asr") else {
            throw ASREngineError.adapterNotImplemented("CrispASR 可执行文件缺少 mimo-asr backend：\(stderr.isEmpty ? stdout : stderr)")
        }
    }

    private func isValidMiMoGGUFInstall(at localURL: URL) -> Bool {
        do {
            try validateMiMoGGUFInstall(at: localURL)
            return true
        } catch {
            return false
        }
    }

    private func hasMiMoGGUFAssets(at localURL: URL) -> Bool {
        guard let asrFile = findFiles(under: localURL, suffix: ".gguf", nameContains: "mimo-asr").first,
              fileSize(at: asrFile) > Int64(1_000_000_000),
              let tokenizerFile = findFiles(under: localURL, suffix: ".gguf", nameContains: "tokenizer").first else {
            return false
        }
        return FileManager.default.fileExists(atPath: tokenizerFile.path)
    }

    private func validateMiMoMLXInstall(at localURL: URL, modelID: String) throws {
        guard !hasPartialDownloadFiles(at: localURL) else {
            throw ASREngineError.adapterNotImplemented("MiMo MLX 下载不完整：仍存在 .part 断点文件。请重试下载或清理该模型缓存。")
        }
        guard FileManager.default.fileExists(atPath: localURL.appending(path: "mlx_manifest.json").path)
            || FileManager.default.fileExists(atPath: localURL.appending(path: "config.json").path) else {
            throw ASREngineError.adapterNotImplemented("MiMo MLX 下载不完整：缺少 mlx_manifest.json 或 config.json。")
        }
        let weights = findFiles(under: localURL, suffix: ".safetensors", nameContains: "")
            .filter { !$0.path.contains("/MiMo-Audio-Tokenizer/") }
        let minimumWeightCount = modelID.contains("bf16") ? 6 : 1
        let minimumTotalBytes = modelID.contains("bf16") ? Int64(12.0 * 1_000_000_000) : Int64(3.5 * 1_000_000_000)
        let weightBytes = weights.reduce(Int64(0)) { $0 + fileSize(at: $1) }
        guard weights.count >= minimumWeightCount, weightBytes >= minimumTotalBytes else {
            throw ASREngineError.adapterNotImplemented("MiMo MLX 下载不完整：权重体积异常，文件数 \(weights.count)/\(minimumWeightCount)，体积 \(Self.formatBytes(weightBytes))/\(Self.formatBytes(minimumTotalBytes))。")
        }
        let tokenizerConfig = localURL.appending(path: "MiMo-Audio-Tokenizer/config.json")
        guard FileManager.default.fileExists(atPath: tokenizerConfig.path) else {
            throw ASREngineError.adapterNotImplemented("MiMo MLX 下载不完整：缺少 MiMo-Audio-Tokenizer/config.json。")
        }
        let tokenizerBytes = findFiles(under: localURL.appending(path: "MiMo-Audio-Tokenizer"), suffix: ".safetensors", nameContains: "")
            .reduce(Int64(0)) { $0 + fileSize(at: $1) }
        guard tokenizerBytes >= Int64(500 * 1_000_000) else {
            throw ASREngineError.adapterNotImplemented("MiMo MLX 下载不完整：音频 tokenizer 权重体积异常。")
        }
    }

    private func hasMiMoMLXAssets(at localURL: URL, modelID: String) -> Bool {
        guard !hasPartialDownloadFiles(at: localURL) else {
            return false
        }
        let hasManifest = FileManager.default.fileExists(atPath: localURL.appending(path: "mlx_manifest.json").path)
            || FileManager.default.fileExists(atPath: localURL.appending(path: "config.json").path)
        let weights = findFiles(under: localURL, suffix: ".safetensors", nameContains: "")
        let minimumWeightCount = modelID.contains("bf16") ? 6 : 1
        let minimumTotalBytes = modelID.contains("bf16") ? Int64(12.0 * 1_000_000_000) : Int64(4.0 * 1_000_000_000)
        let hasWeights = weights.count >= minimumWeightCount && directorySize(at: localURL) >= minimumTotalBytes
        let hasTokenizer = modelID.contains("mimo-v2-5-asr-mlx")
            ? FileManager.default.fileExists(atPath: localURL.appending(path: "MiMo-Audio-Tokenizer/config.json").path)
                || FileManager.default.fileExists(atPath: localURL.appending(path: "audio_tokenizer/config.json").path)
            : true
        return hasManifest && hasWeights && hasTokenizer
    }

    private func hasLargeHFSnapshotAssets(at localURL: URL, minimumBytes: Int64) -> Bool {
        guard !hasPartialDownloadFiles(at: localURL),
              FileManager.default.fileExists(atPath: localURL.appending(path: "config.json").path) else {
            return false
        }
        let weights = findFiles(under: localURL, suffix: ".safetensors", nameContains: "")
        return weights.count >= 2 && directorySize(at: localURL) >= minimumBytes
    }

    private func validateGLMASRInstall(at localURL: URL) throws {
        guard !hasPartialDownloadFiles(at: localURL) else {
            throw ASREngineError.adapterNotImplemented("GLM-ASR 下载不完整：仍存在 .part 断点文件。请重试下载或清理该模型缓存。")
        }
        let configURL = localURL.appending(path: "config.json")
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            throw ASREngineError.adapterNotImplemented("GLM-ASR 下载不完整：缺少 config.json。")
        }
        let configData = try Data(contentsOf: configURL)
        let config = (try JSONSerialization.jsonObject(with: configData) as? [String: Any]) ?? [:]
        guard config["model_type"] as? String == "glmasr" else {
            throw ASREngineError.adapterNotImplemented("GLM-ASR 下载不完整：config.model_type 异常。")
        }
        let architectures = config["architectures"] as? [String] ?? []
        guard architectures.contains("GlmAsrForConditionalGeneration") else {
            throw ASREngineError.adapterNotImplemented("GLM-ASR 下载不完整：config.architectures 异常。")
        }
        guard FileManager.default.fileExists(atPath: localURL.appending(path: "processor_config.json").path) else {
            throw ASREngineError.adapterNotImplemented("GLM-ASR 下载不完整：缺少 processor_config.json。")
        }
        guard FileManager.default.fileExists(atPath: localURL.appending(path: "tokenizer_config.json").path)
                || FileManager.default.fileExists(atPath: localURL.appending(path: "tokenizer.json").path) else {
            throw ASREngineError.adapterNotImplemented("GLM-ASR 下载不完整：缺少 tokenizer 配置。")
        }
        let weightBytes = findFiles(under: localURL, suffix: ".safetensors", nameContains: "")
            .reduce(Int64(0)) { $0 + fileSize(at: $1) }
        guard weightBytes >= Int64(3.5 * 1_000_000_000) else {
            throw ASREngineError.adapterNotImplemented("GLM-ASR 下载不完整：权重体积异常，当前 \(Self.formatBytes(weightBytes))。")
        }
    }

    private func isValidGLMASRInstall(at localURL: URL) -> Bool {
        do {
            try validateGLMASRInstall(at: localURL)
            return true
        } catch {
            return false
        }
    }

    private func hasFunASRNanoAssets(at localURL: URL) -> Bool {
        guard !hasPartialDownloadFiles(at: localURL) else {
            return false
        }
        let requiredFiles = [
            "config.yaml",
            "configuration.json",
            "model.pt",
            "multilingual.tiktoken"
        ]
        return requiredFiles.allSatisfy { fileName in
            FileManager.default.fileExists(atPath: localURL.appending(path: fileName).path)
        }
    }

    private func hasQwenTimestampAssets(at localURL: URL, modelID: String) -> Bool {
        do {
            try validateQwenTimestampInstall(at: localURL, modelID: modelID)
            return true
        } catch {
            return false
        }
    }

    private func validateQwenTimestampInstall(at localURL: URL, modelID: String) throws {
        guard !hasPartialDownloadFiles(at: localURL) else {
            throw ASREngineError.adapterNotImplemented("Qwen3-ASR 下载不完整：仍存在 .part 断点文件。请重试下载或清理该模型缓存。")
        }
        let configURL = localURL.appending(path: "config.json")
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            throw ASREngineError.adapterNotImplemented("Qwen3-ASR 下载不完整：缺少 config.json。")
        }
        let configData = try Data(contentsOf: configURL)
        let config = (try JSONSerialization.jsonObject(with: configData) as? [String: Any]) ?? [:]
        guard config["model_type"] as? String == "qwen3_asr" else {
            throw ASREngineError.adapterNotImplemented("Qwen3-ASR 下载不完整：config.model_type 异常。")
        }
        guard FileManager.default.fileExists(atPath: localURL.appending(path: "tokenizer_config.json").path)
                || FileManager.default.fileExists(atPath: localURL.appending(path: "preprocessor_config.json").path) else {
            throw ASREngineError.adapterNotImplemented("Qwen3-ASR 下载不完整：缺少 tokenizer/preprocessor 配置。")
        }
        let modelWeights = findFiles(under: localURL, suffix: ".safetensors", nameContains: "")
            .filter { !$0.path.contains("Qwen3-ForcedAligner-0.6B") }
        let modelBytes = modelWeights.reduce(Int64(0)) { $0 + fileSize(at: $1) }
        let minimumModelBytes = modelID.contains("1.7b") ? Int64(3.8 * 1_000_000_000) : Int64(700 * 1_000_000)
        guard modelBytes >= minimumModelBytes else {
            throw ASREngineError.adapterNotImplemented("Qwen3-ASR 下载不完整：主模型权重体积异常，当前 \(Self.formatBytes(modelBytes))。")
        }
        let alignerURL = localURL.appending(path: "Qwen3-ForcedAligner-0.6B", directoryHint: .isDirectory)
        let alignerConfigURL = alignerURL.appending(path: "config.json")
        guard FileManager.default.fileExists(atPath: alignerConfigURL.path) else {
            throw ASREngineError.adapterNotImplemented("Qwen3-ASR 时间戳对齐器下载不完整：缺少 config.json。")
        }
        let alignerConfigData = try Data(contentsOf: alignerConfigURL)
        let alignerConfig = (try JSONSerialization.jsonObject(with: alignerConfigData) as? [String: Any]) ?? [:]
        guard alignerConfig["model_type"] as? String == "qwen3_asr" else {
            throw ASREngineError.adapterNotImplemented("Qwen3-ASR 时间戳对齐器下载不完整：config.model_type 异常。")
        }
        let alignerBytes = findFiles(under: alignerURL, suffix: ".safetensors", nameContains: "")
            .reduce(Int64(0)) { $0 + fileSize(at: $1) }
        guard alignerBytes >= Int64(1.0 * 1_000_000_000) else {
            throw ASREngineError.adapterNotImplemented("Qwen3-ASR 时间戳对齐器下载不完整：权重体积异常，当前 \(Self.formatBytes(alignerBytes))。")
        }
    }

    private func hasPartialDownloadFiles(at localURL: URL) -> Bool {
        findFiles(under: localURL, suffix: ".part", nameContains: "").isEmpty == false
    }

    private func validateQwen3GGUFInstall(at localURL: URL) throws {
        let fileManager = FileManager.default
        let asrFiles = findFiles(under: localURL, suffix: ".gguf", nameContains: "qwen3-asr")
        guard let asrFile = asrFiles.first else {
            throw ASREngineError.adapterNotImplemented("Qwen3-ASR GGUF 下载不完整：找不到 qwen3-asr GGUF 文件。")
        }
        guard fileSize(at: asrFile) > Int64(500_000_000) else {
            throw ASREngineError.adapterNotImplemented("Qwen3-ASR GGUF 下载不完整：\(asrFile.lastPathComponent) 体积异常，可能还没下载完。")
        }

        guard let crispasrBin = RuntimePaths.projectFile(".runtime/crispasr/build-ninja-compile/bin/crispasr"),
              fileManager.isExecutableFile(atPath: crispasrBin.path) else {
            throw ASREngineError.adapterNotImplemented("CrispASR runtime 未就绪：请重新点击 Qwen3-ASR GGUF 下载，下载流程会自动编译 runtime。")
        }

        let process = Process()
        process.executableURL = crispasrBin
        process.arguments = ["--list-backends"]
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        let stdout = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0, stdout.contains("qwen3") else {
            throw ASREngineError.adapterNotImplemented("CrispASR 可执行文件缺少 qwen3 backend：\(stderr.isEmpty ? stdout : stderr)")
        }
    }

    private func isValidQwen3GGUFInstall(at localURL: URL) -> Bool {
        do {
            try validateQwen3GGUFInstall(at: localURL)
            return true
        } catch {
            return false
        }
    }

    private func hasQwen3GGUFAssets(at localURL: URL) -> Bool {
        guard let asrFile = findFiles(under: localURL, suffix: ".gguf", nameContains: "qwen3-asr").first else {
            return false
        }
        return fileSize(at: asrFile) > Int64(500_000_000)
    }

    private func findFiles(under root: URL, suffix: String, nameContains: String) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return enumerator.compactMap { item in
            guard let url = item as? URL else { return nil }
            let name = url.lastPathComponent.lowercased()
            let normalizedSuffix = suffix.lowercased()
            let normalizedNeedle = nameContains.lowercased()
            guard name.hasSuffix(normalizedSuffix),
                  normalizedNeedle.isEmpty || name.contains(normalizedNeedle) else {
                return nil
            }
            return url
        }
    }

    private func isNonEmptyDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let children = try? FileManager.default.contentsOfDirectory(atPath: url.path) else {
            return false
        }
        return children.contains { !$0.hasPrefix(".") }
    }

    private func writeManifest(for model: ASRModelSpec, localURL: URL) throws {
        let manifest = ModelAssetManifest(
            modelID: model.id,
            modelName: model.name,
            runtime: model.runtime.rawValue,
            sourceType: modelStorage.sourceKey(for: model),
            source: modelSourceDescription(for: model),
            downloadedAt: Date(),
            localPath: localURL.path,
            requiredFiles: requiredFileSummary(for: model),
            expectedSize: Self.expectedDownloadBytes(for: model),
            checksum: nil,
            downloadSource: modelSourceDescription(for: model),
            preparedAt: Date(),
            validationStatus: validationSummary(for: model, at: localURL),
            errorMessage: nil,
            notes: "模型资产目录只保存模型权重、tokenizer/config 和最小来源信息；runtime、下载临时文件、运行缓存放在 System 目录。"
        )
        try modelStorage.writeManifest(manifest, for: model)
    }

    private func modelSourceDescription(for model: ASRModelSpec) -> String {
        if let downloadURL = model.downloadURL {
            return downloadURL.absoluteString
        }
        if let runtimeModelName = model.runtimeModelName {
            return runtimeModelName
        }
        return model.family
    }

    private func requiredFileSummary(for model: ASRModelSpec) -> [String] {
        switch model.runtime {
        case .sherpaONNX:
            return ["tokens.txt", "*.onnx"]
        case .externalCLI:
            if model.id.contains("gguf") {
                return ["*.gguf", "tokenizer/config files when required"]
            }
            if model.id == "dolphin" {
                return ["base.pt", "bpe.model", "config.yaml"]
            }
            if model.id == "mimo-v2-5-asr" {
                return ["MiMo-V2.5-ASR/model.safetensors.index.json", "MiMo-Audio-Tokenizer/config.json"]
            }
            if model.id.contains("qwen3-asr-mlx") {
                return ["config.json", "*.safetensors", "tokenizer/config files"]
            }
            if model.id.hasPrefix("mimo-v2-5-asr-mlx") {
                return ["mlx_manifest.json/config.json", "*.safetensors", "MiMo-Audio-Tokenizer/config.json"]
            }
            if model.id == "omnilingual-asr" {
                return ["omniASR-CTC-3B.pt", "omniASR_tokenizer.model"]
            }
            if model.id == "funasr-nano-2512" {
                return ["config.yaml", "configuration.json", "model.pt", "multilingual.tiktoken"]
            }
            if model.id == "qwen3-asr-timestamps" || model.id == "qwen3-asr-1.7b-timestamps" {
                return ["config.json", "model weights", "Qwen3-ForcedAligner-0.6B/config.json", "Qwen3-ForcedAligner-0.6B/model weights"]
            }
            return ["config.json", "model weights"]
        case .mlxSwift:
            return []
        }
    }

    private func validationSummary(for model: ASRModelSpec, at localURL: URL) -> String {
        if isCompleteModel(model, at: localURL) {
            if model.runtime == .externalCLI {
                return externalRuntimeIsReady(for: model)
                    ? "模型文件和推理依赖完整：\(requiredFileSummary(for: model).joined(separator: "、"))"
                    : "模型文件完整，但推理依赖未完成：\(requiredFileSummary(for: model).joined(separator: "、"))"
            }
            return "模型文件完整：\(requiredFileSummary(for: model).joined(separator: "、"))"
        }
        return "模型文件不完整或路径不可用：\(localURL.path)"
    }

    private func fileSize(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    private func directorySize(at url: URL) -> Int64 {
        Self.directorySize(at: url.path)
    }

    private func externalCacheRuntimeNames(for model: ASRModelSpec) -> [String] {
        let runtime = externalRuntimeName(for: model)
        if model.id == "mimo-v2-5-asr" {
            return [runtime, "hf-asr"]
        }
        if model.id.hasPrefix("mimo-v2-5-asr-mlx") {
            return [runtime]
        }
        if model.id.contains("qwen3-asr-mlx") {
            return [runtime]
        }
        if model.id.contains("qwen3-asr"),
           !(model.runtimeModelName ?? "").lowercased().contains("gguf") {
            return [runtime, "hf-asr"]
        }
        if model.id.contains("mimo-v2-5-asr-gguf") || (model.id.contains("qwen3-asr") && (model.runtimeModelName ?? "").lowercased().contains("gguf")) {
            return [runtime]
        }
        return [runtime]
    }

    private func externalDownloadEnvironment(for model: ASRModelSpec) -> [String: String] {
        externalRuntimeEnvironment(runtime: externalRuntimeName(for: model))
    }

    private func externalRuntimeEnvironment(runtime: String) -> [String: String] {
        let cache = modelStorage.hfHome(for: runtime).path
        var environment = ProcessInfo.processInfo.environment
        environment["HF_HOME"] = cache
        environment["HF_HUB_ENABLE_HF_TRANSFER"] = "0"
        environment["HF_HUB_DISABLE_XET"] = "1"
        environment["HF_HUB_DOWNLOAD_TIMEOUT"] = "30"
        return environment
    }

    private func runProcess(
        executable: URL,
        arguments: [String],
        environment: [String: String]?
    ) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            if let environment {
                process.environment = environment
            }

            let output = Pipe()
            let error = Pipe()
            process.standardOutput = output
            process.standardError = error

            try process.run()
            process.waitUntilExit()

            let stdout = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let stderr = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            guard process.terminationStatus == 0 else {
                throw ASREngineError.adapterNotImplemented(stderr.isEmpty ? stdout : stderr)
            }
            return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
    }

    private func runProcessWithStructuredProgress(
        executable: URL,
        arguments: [String],
        environment: [String: String]?,
        progress: @escaping @Sendable (DownloadMetrics, String?) -> Void
    ) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            if let environment {
                process.environment = environment
            }

            let output = Pipe()
            let error = Pipe()
            process.standardOutput = output
            process.standardError = error

            let stderrCollector = DownloadPipeCollector(progress: progress)
            error.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                stderrCollector.append(data)
            }

            try process.run()
            process.waitUntilExit()
            error.fileHandleForReading.readabilityHandler = nil
            stderrCollector.finish()

            let stdout = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let stderr = stderrCollector.text + (String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
            guard process.terminationStatus == 0 else {
                throw ASREngineError.adapterNotImplemented(stderr.isEmpty ? stdout : stderr)
            }
            return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
    }

    private func runProcessWithDiskProgress(
        executable: URL,
        arguments: [String],
        environment: [String: String]?,
        progress: @escaping @Sendable (DownloadMetrics, String?) -> Void
    ) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            if let environment {
                process.environment = environment
            }

            let output = Pipe()
            let error = Pipe()
            process.standardOutput = output
            process.standardError = error

            let stderrCollector = DownloadPipeCollector(progress: progress)
            error.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                stderrCollector.append(data)
            }

            try process.run()

            let targetPath = Self.argumentValue(after: "--target", in: arguments) ?? arguments.last ?? ""
            let appModelID = Self.argumentValue(after: "--app-model-id", in: arguments)
            let expectedBytes = Self.expectedDownloadBytes(forAppModelID: appModelID, targetPath: targetPath)
            var lastBytes = Self.directorySize(at: targetPath)
            var lastDate = Date()
            var sawStructuredProgress = false
            while process.isRunning {
                let currentBytes = Self.directorySize(at: targetPath)
                let now = Date()
                let elapsed = now.timeIntervalSince(lastDate)
                let speed = elapsed > 0 ? Double(max(currentBytes - lastBytes, 0)) / elapsed : 0
                let remaining = speed > 0 ? Double(max(expectedBytes - currentBytes, 0)) / speed : nil
                sawStructuredProgress = stderrCollector.hasStructuredProgress
                if !sawStructuredProgress {
                    progress(
                        DownloadMetrics(
                            downloadedBytes: currentBytes,
                            totalBytes: expectedBytes,
                            speedBytesPerSecond: speed,
                            estimatedRemainingSeconds: remaining
                        ),
                        nil
                    )
                }
                lastBytes = currentBytes
                lastDate = now
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            process.waitUntilExit()
            error.fileHandleForReading.readabilityHandler = nil
            stderrCollector.finish()

            let finalBytes = Self.directorySize(at: targetPath)
            progress(
                DownloadMetrics(
                    downloadedBytes: finalBytes,
                    totalBytes: expectedBytes,
                    speedBytesPerSecond: 0,
                    estimatedRemainingSeconds: 0
                ),
                nil
            )

            let stdout = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let stderr = stderrCollector.text + (String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
            guard process.terminationStatus == 0 else {
                throw ASREngineError.adapterNotImplemented(stderr.isEmpty ? stdout : stderr)
            }
            return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
    }

    nonisolated private static func argumentValue(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }

    nonisolated private static func directorySize(at path: String) -> Int64 {
        guard !path.isEmpty,
              let enumerator = FileManager.default.enumerator(
                at: URL(fileURLWithPath: path),
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
              ) else {
            return 0
        }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else {
                continue
            }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    nonisolated private static func expectedDownloadBytes(forTargetPath path: String) -> Int64 {
        if path.contains("glm-asr-nano-2512") {
            return Int64(4.52 * 1_000_000_000)
        }
        if path.contains("mimo-v2-5-asr-gguf-q4") {
            return Int64(5.5 * 1_000_000_000)
        }
        if path.contains("mimo-v2-5-asr-gguf-f16") {
            return Int64(15.5 * 1_000_000_000)
        }
        if path.contains("mimo-v2-5-asr-mlx-bf16") {
            return Int64(18.0 * 1_000_000_000)
        }
        if path.contains("mimo-v2-5-asr-mlx") {
            return Int64(5.0 * 1_000_000_000)
        }
        if path.contains("mimo-v2-5-asr") {
            return 35_997_910_525
        }
        if path.contains("funasr-sensevoice") {
            return Int64(1.5 * 1_000_000_000)
        }
        if path.contains("funasr-nano-2512") {
            return Int64(2.1 * 1_000_000_000)
        }
        if path.contains("vibevoice-asr") {
            if path.contains("4bit") {
                return Int64(6.0 * 1_000_000_000)
            }
            return Int64(18.0 * 1_073_741_824)
        }
        if path.contains("canary-qwen-2-5b") {
            return Int64(6.0 * 1_000_000_000)
        }
        if path.contains("omnilingual-asr") {
            return Int64(12.0 * 1_073_741_824)
        }
        if path.contains("dolphin") {
            return Int64(1.0 * 1_073_741_824)
        }
        if path.contains("qwen3-asr") {
            if path.contains("gguf") {
                if path.contains("1-7b") {
                    return Int64(1.8 * 1_000_000_000)
                }
                return Int64(600 * 1_000_000)
            }
            if path.contains("mlx-0-6b-8bit") {
                return Int64(1.2 * 1_000_000_000)
            }
            if path.contains("mlx-0-6b-bf16") {
                return Int64(1.7 * 1_000_000_000)
            }
            if path.contains("mlx-1-7b-8bit") {
                return Int64(2.8 * 1_000_000_000)
            }
            if path.contains("mlx-1-7b-bf16") {
                return Int64(4.0 * 1_000_000_000)
            }
            if path.contains("timestamps") {
                if path.contains("1.7b") || path.contains("1-7b") {
                    return Int64(6.5 * 1_000_000_000)
                }
                return Int64(3.9 * 1_000_000_000)
            }
            if path.contains("1.7b") {
                return Int64(4.6 * 1_000_000_000)
            }
            return Int64(800 * 1_000_000)
        }
        return Int64(5.0 * 1_000_000_000)
    }

    nonisolated private static func expectedDownloadBytes(forAppModelID id: String?, targetPath path: String) -> Int64 {
        switch id {
        case "glm-asr-nano-2512":
            return Int64(4.52 * 1_000_000_000)
        case "mimo-v2-5-asr-mlx":
            return Int64(5.0 * 1_000_000_000)
        case "qwen3-asr-1.7b-timestamps":
            return Int64(6.5 * 1_000_000_000)
        case "qwen3-asr-timestamps":
            return Int64(3.9 * 1_000_000_000)
        default:
            return expectedDownloadBytes(forTargetPath: path)
        }
    }

    private func findDirectory(named folderName: String, under root: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        for case let url as URL in enumerator where url.lastPathComponent == folderName {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return url
            }
        }

        return nil
    }

    private func findDirectory(containing nameFragment: String, under root: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        for case let url as URL in enumerator where url.lastPathComponent.contains(nameFragment) {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return url
            }
        }

        return nil
    }

    private static func formatDuration(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "--" }
        let value = max(Int(seconds.rounded()), 0)
        if value < 60 {
            return "\(value)s"
        }
        let minutes = value / 60
        let rest = value % 60
        if minutes < 60 {
            return "\(minutes)m \(rest)s"
        }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    nonisolated static let historyDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    nonisolated private static let rerunDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    nonisolated private static func formatBytes(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(max(bytes, 0))
        var unitIndex = 0
        while value >= 1000, unitIndex < units.count - 1 {
            value /= 1000
            unitIndex += 1
        }

        if unitIndex == 0 {
            return "\(Int(value)) \(units[unitIndex])"
        }
        return String(format: "%.1f %@", value, units[unitIndex])
    }
}

private struct PrefetchOutput: Decodable {
    let localPath: String
}

private struct DownloadProgressEvent: Decodable {
    let stage: String
    let downloadedBytes: Int64
    let totalBytes: Int64
    let speedBytesPerSecond: Double
    let estimatedRemainingSeconds: Double?

    static func decode(_ payload: String) -> DownloadProgressEvent? {
        guard let data = payload.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(DownloadProgressEvent.self, from: data)
    }
}

private extension JSONEncoder {
    static var localASR: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var localASR: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private final class DownloadPipeCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var storage = ""
    private var didSeeStructuredProgress = false
    private let progress: @Sendable (DownloadMetrics, String?) -> Void
    private let prefix = "LOCAL_ASR_DOWNLOAD_PROGRESS "

    init(progress: @escaping @Sendable (DownloadMetrics, String?) -> Void) {
        self.progress = progress
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var hasStructuredProgress: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didSeeStructuredProgress
    }

    func append(_ data: Data) {
        lock.lock()
        buffer.append(data)
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: 10) {
            let lineData = buffer.prefix(upTo: newline)
            buffer.removeSubrange(...newline)
            let line = String(data: lineData, encoding: .utf8) ?? ""
            storage += line + "\n"
            lines.append(line)
        }
        lock.unlock()

        handle(lines)
    }

    func finish() {
        lock.lock()
        let line = String(data: buffer, encoding: .utf8) ?? ""
        buffer.removeAll()
        if !line.isEmpty {
            storage += line
        }
        lock.unlock()

        if !line.isEmpty {
            handle([line])
        }
    }

    private func handle(_ lines: [String]) {
        for line in lines where line.hasPrefix(prefix) {
            let payload = String(line.dropFirst(prefix.count))
            guard let event = DownloadProgressEvent.decode(payload) else { continue }
            lock.lock()
            didSeeStructuredProgress = true
            lock.unlock()
            progress(
                DownloadMetrics(
                    downloadedBytes: event.downloadedBytes,
                    totalBytes: event.totalBytes,
                    speedBytesPerSecond: event.speedBytesPerSecond,
                    estimatedRemainingSeconds: event.estimatedRemainingSeconds
                ),
                event.stage
            )
        }
    }
}

private extension Character {
    var isASCIIWord: Bool {
        unicodeScalars.allSatisfy { scalar in
            (65...90).contains(Int(scalar.value)) ||
            (97...122).contains(Int(scalar.value)) ||
            (48...57).contains(Int(scalar.value)) ||
            scalar.value == 95
        }
    }
}
