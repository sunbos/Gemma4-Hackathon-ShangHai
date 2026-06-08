import Foundation

enum MeetingTruthConfig {
    static let bundleIdentifier = "local.meetingtruth.clean"
    static let supportDirectoryName = "MeetingTruthClean"

    static let defaultModelCachePath = "~/Library/Application Support/MeetingTruthClean/Models"
}

enum LabSection: String, CaseIterable, Identifiable {
    case meetingTruth
    case meetingTruthWorkflowCompare
    case meetingTruthToolAB
    case meetingTruthProcessingTrace
    case meetingTruthDetail
    case lab
    case models
    case hotwords
    case results
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .meetingTruth: "会议整理"
        case .meetingTruthWorkflowCompare: "效果对比"
        case .meetingTruthToolAB: "函数调用 AB"
        case .meetingTruthProcessingTrace: "处理链路追踪"
        case .meetingTruthDetail: "处理详情"
        case .lab: "实验台"
        case .models: "模型库"
        case .hotwords: "热词库"
        case .results: "结果对比"
        case .settings: "设置"
        }
    }

    var systemImage: String {
        switch self {
        case .meetingTruth: "doc.text.magnifyingglass"
        case .meetingTruthWorkflowCompare: "rectangle.split.3x1"
        case .meetingTruthToolAB: "function"
        case .meetingTruthProcessingTrace: "point.3.connected.trianglepath.dotted"
        case .meetingTruthDetail: "list.bullet.clipboard"
        case .lab: "waveform.badge.magnifyingglass"
        case .models: "square.stack.3d.up"
        case .hotwords: "text.badge.checkmark"
        case .results: "chart.bar.xaxis"
        case .settings: "slider.horizontal.3"
        }
    }
}

enum MeetingTruthConfidence: String, Hashable, Codable {
    case high
    case medium
    case low

    var title: String {
        switch self {
        case .high: "高置信"
        case .medium: "中置信"
        case .low: "需确认"
        }
    }
}

enum MeetingTruthConflictKind: String, Hashable, Codable {
    case terminology
    case amount
    case person
    case date
    case project
    case system
    case actionItem
    case decision
    case ordinaryExpression

    var title: String {
        switch self {
        case .terminology: "专业词"
        case .amount: "金额 / 数字"
        case .person: "人名"
        case .date: "日期"
        case .project: "项目名"
        case .system: "系统名"
        case .actionItem: "行动项"
        case .decision: "决策"
        case .ordinaryExpression: "普通表达"
        }
    }
}

enum MeetingTruthASRSourceRole: String, Hashable, Codable {
    case primaryDraft
    case timelineAnchor
    case auxiliaryReference
    case other

    var title: String {
        switch self {
        case .primaryDraft: "主要内容底稿"
        case .timelineAnchor: "时间轴锚点"
        case .auxiliaryReference: "辅助参考"
        case .other: "其他候选"
        }
    }

    var shortLabel: String {
        switch self {
        case .primaryDraft: "主底稿"
        case .timelineAnchor: "定位"
        case .auxiliaryReference: "参考"
        case .other: "候选"
        }
    }
}

struct MeetingTruthCandidate: Identifiable, Hashable, Codable {
    var id: UUID = UUID()
    var source: String
    var text: String
    var sourceRole: MeetingTruthASRSourceRole? = nil
}

enum MeetingTruthConflictReviewStatus: String, Hashable, Codable {
    case suggestedApplied
    case needsHumanReview
    case evidenceConflicted
    case replacementValidationFailed
    case deferredForCentralReview
    case ignoredLowRisk
    case markedIrrelevant
    case pending

    var title: String {
        switch self {
        case .suggestedApplied: "建议已应用"
        case .needsHumanReview: "需要你确认"
        case .evidenceConflicted: "证据冲突"
        case .replacementValidationFailed: "自动修正未应用"
        case .deferredForCentralReview: "后续复核"
        case .ignoredLowRisk: "低风险，不打扰"
        case .markedIrrelevant: "已标记无关"
        case .pending: "待处理"
        }
    }
}

enum MeetingTruthConflictUserAction: String, Hashable, Codable {
    case adoptSuggestion
    case manualRewrite
    case ignoreLowRisk
    case deferForReview
    case markIrrelevant
    case clearSelection

    var title: String {
        switch self {
        case .adoptSuggestion: "采用建议"
        case .manualRewrite: "修改写法"
        case .ignoreLowRisk: "忽略低风险"
        case .deferForReview: "暂不处理 / 后续复核"
        case .markIrrelevant: "标记无关"
        case .clearSelection: "撤销应用"
        }
    }
}

struct MeetingTruthReplacementSpan: Identifiable, Hashable, Codable {
    var id: UUID = UUID()
    var windowID: String
    var spanID: String
    var originalText: String
    var replacementText: String
    var rangeStart: Int
    var rangeEnd: Int
    var preContext: String
    var postContext: String
}

struct MeetingTruthReplacementValidationResult: Hashable, Codable {
    var isValid: Bool
    var reason: String
    var appliedSpanCount: Int
    var pollutionChecks: [String]

    static var notRun: MeetingTruthReplacementValidationResult {
        MeetingTruthReplacementValidationResult(
            isValid: false,
            reason: "尚未执行替换校验。",
            appliedSpanCount: 0,
            pollutionChecks: []
        )
    }
}

struct MeetingTruthConflict: Identifiable, Hashable, Codable {
    var id: UUID = UUID()
    var timestamp: String
    var kind: MeetingTruthConflictKind
    var context: String
    var candidates: [MeetingTruthCandidate]
    var recommendation: String
    var confidence: MeetingTruthConfidence
    var evidence: String
    var selectedText: String?
    var reviewStatus: MeetingTruthConflictReviewStatus? = nil
    var lastUserAction: MeetingTruthConflictUserAction? = nil
    var evidenceChain: [MeetingTruthEvidenceSupport]? = nil
    var candidateScores: [MeetingTruthCandidateScore]? = nil
    var replacementSpans: [MeetingTruthReplacementSpan]? = nil
    var replacementValidationResult: MeetingTruthReplacementValidationResult? = nil
    var oneLineBasis: String? = nil
    var affectedOutputs: [MeetingTruthFactAffectsOutput]? = nil
    var developerTrace: [MeetingTruthToolCallRecord]? = nil

    var isResolved: Bool {
        selectedText != nil ||
        reviewStatus == .ignoredLowRisk ||
        reviewStatus == .markedIrrelevant ||
        reviewStatus == .deferredForCentralReview
    }

    var requiresHumanReview: Bool {
        if reviewStatus == .needsHumanReview ||
            reviewStatus == .evidenceConflicted ||
            reviewStatus == .replacementValidationFailed {
            return true
        }
        return confidence == .low
    }
}

struct MeetingTruthMaterial: Identifiable, Hashable, Codable {
    var id: UUID = UUID()
    var name: String
    var kind: String
    var detail: String
    var localPath: String? = nil
    var extractedText: String = ""
}

enum MeetingTruthMultimodalMode: String, CaseIterable, Hashable, Codable {
    case textOnly
    case visionSeparate
    case audioTextSeparate
    case fusedMultimodal

    var title: String {
        switch self {
        case .textOnly: "不用多模态"
        case .visionSeparate: "图像分开用"
        case .audioTextSeparate: "音频/文本分开"
        case .fusedMultimodal: "多模态同时融合"
        }
    }

    var shortDescription: String {
        switch self {
        case .textOnly:
            "只用 ASR 转写文本，不发送图片。"
        case .visionSeparate:
            "Gemma 4 先单独读取图片，形成图片证据摘要。"
        case .audioTextSeparate:
            "音频先经 ASR 成为文字，Gemma 4 处理转写文本。"
        case .fusedMultimodal:
            "Gemma 4 同时接收转写、图片证据摘要、原图和文本材料。"
        }
    }
}

struct MeetingTruthVisualEvidence: Identifiable, Hashable, Codable {
    var id: UUID = UUID()
    var materialID: UUID
    var materialName: String
    var summary: String
    var extractedNumbers: [String]
    var keywords: [String]
    var actionHints: [String]
    var participants: [MeetingTruthParticipantEvidence] = []
    var layoutCues: [String] = []
    var visualMarks: [String] = []
    var ocrContrast: String = ""
    var confidence: MeetingTruthConfidence
    var useForASRIteration: Bool = false
    var asrCandidateTerms: [String] = []
    var generatedAt: Date = Date()
    var model: String

    enum CodingKeys: String, CodingKey {
        case id
        case materialID
        case materialName
        case summary
        case extractedNumbers
        case keywords
        case actionHints
        case participants
        case layoutCues
        case visualMarks
        case ocrContrast
        case confidence
        case useForASRIteration
        case asrCandidateTerms
        case generatedAt
        case model
    }

    init(
        id: UUID = UUID(),
        materialID: UUID,
        materialName: String,
        summary: String,
        extractedNumbers: [String],
        keywords: [String],
        actionHints: [String],
        participants: [MeetingTruthParticipantEvidence] = [],
        layoutCues: [String] = [],
        visualMarks: [String] = [],
        ocrContrast: String = "",
        confidence: MeetingTruthConfidence,
        useForASRIteration: Bool = false,
        asrCandidateTerms: [String] = [],
        generatedAt: Date = Date(),
        model: String
    ) {
        self.id = id
        self.materialID = materialID
        self.materialName = materialName
        self.summary = summary
        self.extractedNumbers = extractedNumbers
        self.keywords = keywords
        self.actionHints = actionHints
        self.participants = participants
        self.layoutCues = layoutCues
        self.visualMarks = visualMarks
        self.ocrContrast = ocrContrast
        self.confidence = confidence
        self.useForASRIteration = useForASRIteration
        self.asrCandidateTerms = asrCandidateTerms
        self.generatedAt = generatedAt
        self.model = model
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        materialID = try container.decode(UUID.self, forKey: .materialID)
        materialName = try container.decode(String.self, forKey: .materialName)
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        extractedNumbers = try container.decodeIfPresent([String].self, forKey: .extractedNumbers) ?? []
        keywords = try container.decodeIfPresent([String].self, forKey: .keywords) ?? []
        actionHints = try container.decodeIfPresent([String].self, forKey: .actionHints) ?? []
        participants = try container.decodeIfPresent([MeetingTruthParticipantEvidence].self, forKey: .participants) ?? []
        layoutCues = try container.decodeIfPresent([String].self, forKey: .layoutCues) ?? []
        visualMarks = try container.decodeIfPresent([String].self, forKey: .visualMarks) ?? []
        ocrContrast = try container.decodeIfPresent(String.self, forKey: .ocrContrast) ?? ""
        confidence = try container.decodeIfPresent(MeetingTruthConfidence.self, forKey: .confidence) ?? .low
        useForASRIteration = try container.decodeIfPresent(Bool.self, forKey: .useForASRIteration) ?? false
        asrCandidateTerms = try container.decodeIfPresent([String].self, forKey: .asrCandidateTerms) ?? []
        generatedAt = try container.decodeIfPresent(Date.self, forKey: .generatedAt) ?? Date()
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? "Gemma 4"
    }

    var hasContent: Bool {
        !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !extractedNumbers.isEmpty ||
        !keywords.isEmpty ||
        !actionHints.isEmpty ||
        !participants.isEmpty ||
        !layoutCues.isEmpty ||
        !visualMarks.isEmpty ||
        !ocrContrast.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var iterationTerms: [String] {
        let explicitTerms = asrCandidateTerms.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !explicitTerms.isEmpty {
            return explicitTerms
        }
        return (extractedNumbers + keywords + participants.map(\.name))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

enum MeetingTruthEvidenceSourceType: String, Hashable, Codable {
    case meetingNotice = "meeting_notice"
    case handwrittenNote = "handwritten_note"
    case slideOrPPT = "slide_or_ppt"
    case whiteboard
    case screenshot
    case glossary
    case transcript
    case otherMaterial = "other_material"
    case unknown

    var title: String {
        switch self {
        case .meetingNotice: "会议通知"
        case .handwrittenNote: "手写纪要"
        case .slideOrPPT: "PPT / 汇报材料"
        case .whiteboard: "白板 / 板书"
        case .screenshot: "系统截图"
        case .glossary: "术语表"
        case .transcript: "转写文本"
        case .otherMaterial: "其他材料"
        case .unknown: "无法判断"
        }
    }
}

struct MeetingTruthEvidenceProfile: Identifiable, Hashable, Codable {
    var id: String { sourceID }
    var sourceID: String
    var sourceType: MeetingTruthEvidenceSourceType
    var sourceTypeConfidence: Double
    var title: String
    var extractedTextFromOCR: String
    var visualSummaryFromGemma: String
    var layoutCues: [String]
    var arrowsOrHighlights: [String]
    var keyEntities: [String]
    var participantCandidates: [String]
    var projectOrSystemNames: [String]
    var dateTimeMentions: [String]
    var amountMentions: [String]
    var actionItemHints: [String]
    var coverageScope: String
    var reliabilityByFactType: [String: Double]
}

struct MeetingTruthASRAlignmentWindow: Identifiable, Hashable, Codable {
    var id: String { windowID }
    var windowID: String
    var startTime: String
    var endTime: String
    var qwenText: String
    var mimoText: String
    var glmText: String
    var alignmentScore: Double
    var alignmentWarnings: [String]
}

struct MeetingTruthParticipantEvidence: Identifiable, Hashable, Codable {
    var id: UUID = UUID()
    var name: String
    var role: String = ""
    var organization: String = ""
    var evidence: String = ""
    var confidence: MeetingTruthConfidence = .low

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case role
        case organization
        case evidence
        case confidence
    }

    init(
        id: UUID = UUID(),
        name: String,
        role: String = "",
        organization: String = "",
        evidence: String = "",
        confidence: MeetingTruthConfidence = .low
    ) {
        self.id = id
        self.name = name
        self.role = role
        self.organization = organization
        self.evidence = evidence
        self.confidence = confidence
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        role = try container.decodeIfPresent(String.self, forKey: .role) ?? ""
        organization = try container.decodeIfPresent(String.self, forKey: .organization) ?? ""
        evidence = try container.decodeIfPresent(String.self, forKey: .evidence) ?? ""
        confidence = try container.decodeIfPresent(MeetingTruthConfidence.self, forKey: .confidence) ?? .low
    }

    var displayText: String {
        let details = [role, organization]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return details.isEmpty ? name : "\(name)（\(details.joined(separator: " · "))）"
    }
}

struct MeetingTruthMultimodalCallStatus: Hashable {
    var title: String
    var isMultimodalCallProven: Bool
    var rawImageInput: String
    var ocrTextInput: String
    var asrInput: String
    var fusionInput: String
    var model: String
}

struct MeetingTruthEvidenceChannelStatus: Identifiable, Hashable {
    var id: String { title }
    var title: String
    var value: String
    var detail: String
    var isActive: Bool
}

struct MeetingTruthInputRoute: Identifiable, Hashable {
    var id: String { channel }
    var channel: String
    var input: String
    var route: String
    var role: String
    var isMultimodal: Bool
    var isActive: Bool
}

struct MeetingTruthMultimodalProof: Hashable {
    var isProven: Bool
    var title: String
    var model: String
    var latestCallAt: Date?
    var rawImageInputs: [String]
    var inputSummary: [String]
    var outputSummary: [String]
    var derivedJudgementSummary: [String]
    var missingRequirements: [String]
}

struct MeetingTruthDecisionOverview: Hashable {
    struct Metric: Identifiable, Hashable {
        var id: String { title }
        var title: String
        var value: String
        var detail: String
        var isReady: Bool
    }

    var title: String
    var subtitle: String
    var metrics: [Metric]
    var nextAction: String
}

struct MeetingTruthMultimodalComparison: Identifiable, Hashable, Codable {
    var id: UUID = UUID()
    var mode: MeetingTruthMultimodalMode
    var isAvailable: Bool
    var result: String
    var evidenceSources: [String]
}

struct MeetingTruthMultimodalImpactRow: Identifiable, Hashable {
    var id: MeetingTruthMultimodalMode { mode }
    var mode: MeetingTruthMultimodalMode
    var isReady: Bool
    var inputChannels: [String]
    var visibleEffect: String
    var effectItems: [String]
    var limitation: String
}

struct MeetingTruthMultimodalImpactFinding: Identifiable, Hashable {
    enum Kind: String, Hashable {
        case visualTerm
        case conflictCorrection
        case actionHint
        case asrIteration

        var title: String {
            switch self {
            case .visualTerm: "图片补充"
            case .conflictCorrection: "冲突修正"
            case .actionHint: "待办增强"
            case .asrIteration: "ASR 迭代"
            }
        }
    }

    var id: UUID = UUID()
    var kind: Kind
    var title: String
    var withoutMultimodal: String
    var withMultimodal: String
    var evidence: String
    var confidence: MeetingTruthConfidence
}

struct MeetingTruthMultimodalSubjectComparison: Identifiable, Hashable {
    enum Kind: String, Hashable {
        case term
        case conflict
        case action
        case asrIteration

        var title: String {
            switch self {
            case .term: "术语"
            case .conflict: "冲突"
            case .action: "待办"
            case .asrIteration: "ASR 迭代"
            }
        }
    }

    var id: UUID = UUID()
    var kind: Kind
    var subject: String
    var asrOnly: String
    var visionOnly: String
    var separateUse: String
    var fusedUse: String
    var evidence: String
    var confidence: MeetingTruthConfidence
}

struct MeetingTruthOCRValueComparison: Identifiable, Hashable {
    enum Kind: String, Hashable {
        case handwriting
        case layout
        case visualMark
        case action
        case term

        var title: String {
            switch self {
            case .handwriting: "手写"
            case .layout: "版式"
            case .visualMark: "圈注/箭头"
            case .action: "待办"
            case .term: "术语"
            }
        }
    }

    var id: UUID = UUID()
    var kind: Kind
    var subject: String
    var ocrOnly: String
    var gemmaImage: String
    var fusedImpact: String
    var evidence: String
    var confidence: MeetingTruthConfidence
}

struct MeetingTruthCorrectionLedgerRow: Identifiable, Hashable {
    var id: UUID = UUID()
    var subject: String
    var asrRisk: String
    var selectedConclusion: String
    var crossCheck: String
    var visualEvidence: String
    var status: String
    var confidence: MeetingTruthConfidence
}

struct MeetingTruthConclusionEvidence: Identifiable, Hashable {
    enum Kind: String, Hashable {
        case summary
        case keyPoint
        case minute
        case action
        case correction

        var title: String {
            switch self {
            case .summary: "摘要"
            case .keyPoint: "要点"
            case .minute: "纪要"
            case .action: "待办"
            case .correction: "修正"
            }
        }
    }

    var id: UUID = UUID()
    var kind: Kind
    var conclusion: String
    var asrEvidence: String
    var ocrEvidence: String
    var imageEvidence: String
    var fusionReason: String
    var risk: String
    var confidence: MeetingTruthConfidence
}

struct MeetingTruthArbitrationConfig: Hashable, Codable {
    var asrConsensusWeight: Double = 0.34
    var visualEvidenceWeight: Double = 0.30
    var ocrEvidenceWeight: Double = 0.12
    var textMaterialWeight: Double = 0.14
    var humanReviewThreshold: Double = 0.72
    var highRiskPenalty: Double = 0.18
    var allowVisualToPromoteMissingASRTerms: Bool = true
    var strictHighRiskReview: Bool = true
}

struct MeetingTruthArbitrationWorkflowNode: Identifiable, Hashable {
    enum State: String, Hashable {
        case ready
        case waiting
        case warning

        var title: String {
            switch self {
            case .ready: "已就绪"
            case .waiting: "等待输入"
            case .warning: "需确认"
            }
        }
    }

    var id: String { title }
    var title: String
    var subtitle: String
    var result: String
    var state: State
}

struct MeetingTruthEvidenceItem: Identifiable, Hashable {
    enum Channel: String, Hashable {
        case asr
        case ocr
        case visual
        case material
        case human

        var title: String {
            switch self {
            case .asr: "ASR"
            case .ocr: "OCR"
            case .visual: "原图"
            case .material: "材料"
            case .human: "人工"
            }
        }
    }

    var id: UUID = UUID()
    var channel: Channel
    var source: String
    var text: String
    var weight: Double
    var supportsClaim: Bool
}

enum MeetingTruthFactKind: String, CaseIterable, Hashable, Codable {
    case person
    case amount
    case date
    case owner
    case project
    case decision
    case actionItem
    case risk
    case term

    var title: String {
        switch self {
        case .person: "人名"
        case .amount: "金额 / 数字"
        case .date: "日期"
        case .owner: "负责人"
        case .project: "项目名"
        case .decision: "决策"
        case .actionItem: "待办"
        case .risk: "风险"
        case .term: "术语"
        }
    }

    var conflictKind: MeetingTruthConflictKind {
        switch self {
        case .person, .owner: .person
        case .amount: .amount
        case .date: .date
        case .project: .project
        case .decision, .actionItem, .risk, .term: .terminology
        }
    }
}

enum MeetingTruthFactChannel: String, Hashable, Codable {
    case asr
    case imageOCR
    case rawVision
    case material
    case human
    case conflict

    var title: String {
        switch self {
        case .asr: "ASR"
        case .imageOCR: "图片 OCR 基线"
        case .rawVision: "原图视觉"
        case .material: "文本/PDF 材料"
        case .human: "人工确认"
        case .conflict: "冲突卡"
        }
    }

    var evidenceItemChannel: MeetingTruthEvidenceItem.Channel {
        switch self {
        case .asr, .conflict: .asr
        case .imageOCR: .ocr
        case .rawVision: .visual
        case .material: .material
        case .human: .human
        }
    }
}

enum MeetingTruthFactImportance: String, Hashable, Codable {
    case low
    case medium
    case high

    var title: String {
        switch self {
        case .low: "低"
        case .medium: "中"
        case .high: "高"
        }
    }
}

enum MeetingTruthFactRiskLevel: String, Hashable, Codable {
    case low
    case medium
    case high

    var title: String {
        switch self {
        case .low: "低风险"
        case .medium: "中风险"
        case .high: "高风险"
        }
    }
}

enum MeetingTruthFactDecisionStatus: String, Hashable, Codable {
    case accepted
    case confirmed
    case lowConfidence
    case conflicted
    case unsupported
    case needsUserInput

    var title: String {
        switch self {
        case .accepted: "已采信"
        case .confirmed: "人工确认"
        case .lowConfidence: "低置信"
        case .conflicted: "证据冲突"
        case .unsupported: "证据不足"
        case .needsUserInput: "需要确认"
        }
    }
}

enum MeetingTruthFactAffectsOutput: String, CaseIterable, Hashable, Codable {
    case minutes
    case actionItems
    case participants
    case projectNames
    case riskList
    case evidenceNote
    case none

    var title: String {
        switch self {
        case .minutes: "会议纪要"
        case .actionItems: "待办事项"
        case .participants: "参会人"
        case .projectNames: "项目名"
        case .riskList: "风险清单"
        case .evidenceNote: "证据备注"
        case .none: "不影响成果包"
        }
    }
}

enum MeetingTruthFactGateStatus: String, Hashable, Codable {
    case acceptedForAdjudication
    case rejectedAsLowValue

    var title: String {
        switch self {
        case .acceptedForAdjudication: "进入证据裁决"
        case .rejectedAsLowValue: "低价值拒绝"
        }
    }
}

struct MeetingTruthFactCandidate: Identifiable, Hashable, Codable {
    var id: UUID = UUID()
    var kind: MeetingTruthFactKind
    var claim: String
    var sourceSpan: String
    var sourceChannel: MeetingTruthFactChannel
    var importance: MeetingTruthFactImportance
    var riskLevel: MeetingTruthFactRiskLevel
    var confidence: Double
    var needsEvidence: Bool
    var whyItMatters: String? = nil
    var affectsOutputs: [MeetingTruthFactAffectsOutput]? = nil
    var gateStatus: MeetingTruthFactGateStatus? = nil
    var gateReason: String? = nil
    var reviewPriority: Int? = nil
}

struct MeetingTruthEvidenceAtom: Identifiable, Hashable, Codable {
    var id: UUID = UUID()
    var factID: UUID
    var channel: MeetingTruthFactChannel
    var sourceName: String
    var supportsClaim: Bool
    var text: String
    var visualCue: String
    var confidence: Double
    var weight: Double
}

struct MeetingTruthFactDecision: Identifiable, Hashable, Codable {
    var id: UUID { factID }
    var factID: UUID
    var claim: String
    var kind: MeetingTruthFactKind
    var chosenText: String
    var status: MeetingTruthFactDecisionStatus
    var confidence: Double
    var reason: String
    var missingEvidence: [String]
    var requiresUserInput: Bool
    var importance: MeetingTruthFactImportance
    var riskLevel: MeetingTruthFactRiskLevel
    var affectsOutputs: [MeetingTruthFactAffectsOutput]? = nil
    var userVisibleReason: String? = nil
    var noConfirmationConsequence: String? = nil
}

struct MeetingTruthUserQuestion: Identifiable, Hashable, Codable {
    var id: UUID { factID }
    var factID: UUID
    var question: String
    var currentClaim: String
    var knownEvidence: [String]
    var suggestedAnswer: String
    var sourceContext: String?
    var decisionReason: String?
    var missingEvidence: [String]?
    var evidenceDetails: [MeetingTruthQuestionEvidence]?
    var importanceTitle: String?
    var riskTitle: String?
    var affectsOutputs: [MeetingTruthFactAffectsOutput]? = nil
    var userVisibleReason: String? = nil
    var noConfirmationConsequence: String? = nil
}

struct MeetingTruthQuestionEvidence: Identifiable, Hashable, Codable {
    var id: UUID = UUID()
    var channelTitle: String
    var sourceName: String
    var supportsClaim: Bool
    var text: String
    var visualCue: String
    var confidence: Double
}

enum MeetingTruthCentralEvidenceChannel: String, Hashable, Codable {
    case asr
    case imageOCR
    case rawVision
    case material
    case conflict
    case human
    case generatedPackage

    var title: String {
        switch self {
        case .asr: "ASR 候选"
        case .imageOCR: "OCR 基线"
        case .rawVision: "Gemma 原图理解"
        case .material: "文本/PDF 材料"
        case .conflict: "冲突复核"
        case .human: "人工确认"
        case .generatedPackage: "成果包"
        }
    }
}

enum MeetingTruthCentralVerdictStatus: String, Hashable, Codable {
    case accepted
    case corrected
    case conflicted
    case missing
    case needsHumanReview
    case rejected

    var title: String {
        switch self {
        case .accepted: "已采信"
        case .corrected: "建议修正"
        case .conflicted: "证据冲突"
        case .missing: "信息缺失"
        case .needsHumanReview: "需要人工确认"
        case .rejected: "不进入成果包"
        }
    }
}

struct MeetingTruthCentralEvidence: Identifiable, Hashable, Codable {
    var id: UUID = UUID()
    var channel: MeetingTruthCentralEvidenceChannel
    var sourceName: String
    var text: String
    var visualCue: String
    var supportsClaim: Bool
    var confidence: Double
    var priority: Int
}

struct MeetingTruthCentralClaim: Identifiable, Hashable, Codable {
    var id: UUID = UUID()
    var factID: UUID?
    var kind: MeetingTruthFactKind
    var claim: String
    var proposedCanonicalText: String
    var sourceSpan: String
    var status: MeetingTruthCentralVerdictStatus
    var confidence: Double
    var importance: MeetingTruthFactImportance
    var riskLevel: MeetingTruthFactRiskLevel
    var supportingEvidence: [MeetingTruthCentralEvidence]
    var contradictingEvidence: [MeetingTruthCentralEvidence]
    var missingEvidence: [String]
    var humanQuestion: String?
    var decisionReason: String

    var requiresHumanReview: Bool {
        status == .needsHumanReview || status == .conflicted || riskLevel == .high && confidence < 0.78
    }
}

struct MeetingTruthVisualObservation: Identifiable, Hashable, Codable {
    var id: UUID = UUID()
    var materialID: UUID?
    var materialName: String
    var materialRole: String
    var summary: String
    var layoutCues: [String]
    var visualMarks: [String]
    var participantEvidence: [MeetingTruthParticipantEvidence]
    var actionHints: [String]
    var ocrBaseline: String
    var ocrContrast: String
    var confidence: MeetingTruthConfidence

    var hasRawVisionOnlySignal: Bool {
        !layoutCues.isEmpty ||
        !visualMarks.isEmpty ||
        !actionHints.isEmpty ||
        !ocrContrast.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct MeetingTruthReviewGap: Identifiable, Hashable, Codable {
    enum Kind: String, Hashable, Codable {
        case missingOwner
        case missingDueDate
        case unsupportedHighRiskFact
        case ocrRawVisionMismatch
        case packageTraceability
        case noRawVision
        case noCrossModalEvidence

        var title: String {
            switch self {
            case .missingOwner: "缺负责人"
            case .missingDueDate: "缺截止时间"
            case .unsupportedHighRiskFact: "高风险事实缺证据"
            case .ocrRawVisionMismatch: "OCR 与原图理解不一致"
            case .packageTraceability: "成果包缺证据链"
            case .noRawVision: "缺原图理解"
            case .noCrossModalEvidence: "缺跨模态证据"
            }
        }
    }

    var id: UUID = UUID()
    var kind: Kind
    var title: String
    var detail: String
    var relatedClaimID: UUID?
    var requiresHumanReview: Bool

    var blocksPackageGeneration: Bool {
        guard requiresHumanReview else { return false }
        switch kind {
        case .noRawVision, .noCrossModalEvidence:
            return false
        case .missingOwner, .missingDueDate, .unsupportedHighRiskFact, .ocrRawVisionMismatch, .packageTraceability:
            return false
        }
    }

    var advisoryText: String {
        "\(kind.title)：\(detail)"
    }
}

enum MeetingTruthToolInvocationSource: String, Hashable, Codable {
    case nativeToolCall
    case jsonFallback
    case autoPipeline
    case localRule
    case manualConfirmation
    case unknown

    var title: String {
        switch self {
        case .nativeToolCall: "Gemma 主动调用"
        case .jsonFallback: "兼容解析调用"
        case .autoPipeline: "系统自动补全步骤"
        case .localRule: "本地规则校验"
        case .manualConfirmation: "人工确认"
        case .unknown: "来源未知"
        }
    }

    var explanation: String {
        switch self {
        case .nativeToolCall:
            "Gemma 返回了原生工具调用，由系统执行对应工具函数。"
        case .jsonFallback:
            "模型以结构化 JSON 写出了工具调用，系统按兼容模式解析并执行。"
        case .autoPipeline:
            "Gemma 触发进入核验链后，系统按固定流程执行该步骤，保证证据链完整。"
        case .localRule:
            "这一步用于本地安全校验或规则判断，没有单独调用 Gemma 工具函数。"
        case .manualConfirmation:
            "这条结论来自用户人工确认。"
        case .unknown:
            "旧记录或外部记录没有保存来源信息。"
        }
    }

    var shouldShowToolCallLabel: Bool {
        self == .nativeToolCall || self == .jsonFallback
    }
}

struct MeetingTruthToolCallRecord: Identifiable, Hashable, Codable {
    enum Status: String, Hashable, Codable {
        case executed
        case skipped
        case failed

        var title: String {
            switch self {
            case .executed: "已执行"
            case .skipped: "已跳过"
            case .failed: "失败"
            }
        }
    }

    var id: UUID = UUID()
    var callIndex: Int
    var functionName: String
    var argumentsSummary: String
    var resultSummary: String
    var impactSummary: String
    var status: Status
    var invocationSource: MeetingTruthToolInvocationSource? = nil
    var asrConflicts: [MeetingTruthASRConflictFinding]? = nil
    var evidenceChain: [MeetingTruthEvidenceSupport]? = nil
    var candidateScores: [MeetingTruthCandidateScore]? = nil
    var factDecision: MeetingTruthFactDecisionTrace? = nil
    var humanReviewTask: MeetingTruthHumanReviewTask? = nil
    var affectedMinutesText: String? = nil
    var alignmentWindows: [MeetingTruthASRAlignmentWindow]? = nil
    var evidenceProfiles: [MeetingTruthEvidenceProfile]? = nil
    var replacementValidationResult: MeetingTruthReplacementValidationResult? = nil
}

struct MeetingTruthToolAuditSummary: Hashable {
    struct Row: Identifiable, Hashable {
        var id: String { functionName }
        var functionName: String
        var title: String
        var callReason: String
        var count: Int
        var nativeCount: Int
        var fallbackCount: Int
        var autoCount: Int
        var executedCount: Int
        var skippedCount: Int
        var failedCount: Int
        var stateText: String
        var stateKind: StateKind

        enum StateKind: Hashable {
            case called
            case missing
            case conditional
        }
    }

    var rows: [Row]
    var totalCount: Int
    var nativeCount: Int
    var fallbackCount: Int
    var autoCount: Int
    var executedCount: Int
    var lastNativeFunctionName: String?
    var stopTitle: String
    var stopDetail: String
    var missingRequiredTools: [String]

    static let requiredOrder = [
        "extract_meeting_fact_candidates",
        "filter_reviewable_facts",
        "detect_asr_conflicts",
        "retrieve_supporting_evidence",
        "score_fact_candidates",
        "make_fact_decision"
    ]

    static let conditionalOrder = [
        "create_human_review_task"
    ]

    static func make(from records: [MeetingTruthToolCallRecord]) -> MeetingTruthToolAuditSummary {
        let orderedNames = requiredOrder + conditionalOrder
        let rows = orderedNames.map { name in
            let matching = records.filter { $0.functionName == name }
            let native = matching.filter { ($0.invocationSource ?? .unknown) == .nativeToolCall }.count
            let fallback = matching.filter { ($0.invocationSource ?? .unknown) == .jsonFallback }.count
            let auto = matching.filter { ($0.invocationSource ?? .unknown) == .autoPipeline }.count
            let executed = matching.filter { $0.status == .executed }.count
            let skipped = matching.filter { $0.status == .skipped }.count
            let failed = matching.filter { $0.status == .failed }.count
            let isConditional = conditionalOrder.contains(name)
            let stateKind: Row.StateKind = matching.isEmpty ? (isConditional ? .conditional : .missing) : .called
            return Row(
                functionName: name,
                title: toolTitle(name),
                callReason: callReason(name),
                count: matching.count,
                nativeCount: native,
                fallbackCount: fallback,
                autoCount: auto,
                executedCount: executed,
                skippedCount: skipped,
                failedCount: failed,
                stateText: stateText(name: name, records: records, matching: matching, isConditional: isConditional),
                stateKind: stateKind
            )
        }
        let missingRequired = requiredOrder.filter { name in
            records.contains { $0.functionName == name } == false
        }
        let lastNative = records.last { ($0.invocationSource ?? .unknown) == .nativeToolCall }?.functionName
        let stop = stopExplanation(records: records, missingRequired: missingRequired)
        return MeetingTruthToolAuditSummary(
            rows: rows,
            totalCount: records.count,
            nativeCount: records.filter { ($0.invocationSource ?? .unknown) == .nativeToolCall }.count,
            fallbackCount: records.filter { ($0.invocationSource ?? .unknown) == .jsonFallback }.count,
            autoCount: records.filter { ($0.invocationSource ?? .unknown) == .autoPipeline }.count,
            executedCount: records.filter { $0.status == .executed }.count,
            lastNativeFunctionName: lastNative,
            stopTitle: stop.title,
            stopDetail: stop.detail,
            missingRequiredTools: missingRequired
        )
    }

    private static func toolTitle(_ name: String) -> String {
        switch name {
        case "extract_meeting_fact_candidates": "抽取事实候选"
        case "filter_reviewable_facts": "过滤可复核事实"
        case "detect_asr_conflicts": "检查转写冲突"
        case "retrieve_supporting_evidence": "检索支持证据"
        case "score_fact_candidates": "候选事实评分"
        case "make_fact_decision": "标准事实裁决"
        case "create_human_review_task": "生成人工确认"
        default: name
        }
    }

    private static func callReason(_ name: String) -> String {
        switch name {
        case "extract_meeting_fact_candidates":
            "入口步骤。让 Gemma 先判断哪些会议事实可能影响纪要、待办、参会人、项目名、风险清单或证据备注。"
        case "filter_reviewable_facts":
            "准入步骤。过滤口语填充、泛泛流程短语和低价值动词，只保留会影响成果包的事实。"
        case "detect_asr_conflicts":
            "冲突发现。把多路 ASR 中的人名、术语、数字、行动项差异压缩成可裁决候选。"
        case "retrieve_supporting_evidence":
            "证据检索。围绕候选去查 ASR、会议通知、手写纪要、OCR、rawVision、术语表和人工确认。"
        case "score_fact_candidates":
            "评分步骤。按事实类型和证据权重给候选打分，避免简单多数投票。"
        case "make_fact_decision":
            "裁决步骤。把评分结果转成 accepted、corrected、conflicted、needsHumanReview 或 rejected。"
        case "create_human_review_task":
            "条件步骤。只有标准裁决为 conflicted 或 needsHumanReview 时才需要调用。"
        default:
            "工具函数步骤。"
        }
    }

    private static func stateText(
        name: String,
        records: [MeetingTruthToolCallRecord],
        matching: [MeetingTruthToolCallRecord],
        isConditional: Bool
    ) -> String {
        if !matching.isEmpty {
            let native = matching.filter { ($0.invocationSource ?? .unknown) == .nativeToolCall }.count
            let auto = matching.filter { ($0.invocationSource ?? .unknown) == .autoPipeline }.count
            if native > 0 { return "Gemma 原生调用 \(native) 次" }
            if auto > 0 { return "系统自动补全 \(auto) 次" }
            return "已执行 \(matching.count) 次"
        }
        if isConditional {
            let needsReview = records.contains { record in
                record.factDecision?.status == .conflicted || record.factDecision?.status == .needsHumanReview
            }
            return needsReview ? "应生成，等待补全" : "未触发：没有冲突或人工确认需求"
        }
        if name == "make_fact_decision", records.contains(where: { $0.functionName == "score_fact_candidates" }) {
            return "未原生调用：Gemma 在评分后停止"
        }
        return "未执行"
    }

    private static func stopExplanation(
        records: [MeetingTruthToolCallRecord],
        missingRequired: [String]
    ) -> (title: String, detail: String) {
        guard !records.isEmpty else {
            return ("尚未进入工具链", "本轮没有工具流水，可能是未运行证据核验，或 endpoint 没有返回 tool_calls。")
        }
        if missingRequired.isEmpty {
            let decision = records.last { $0.functionName == "make_fact_decision" }?.factDecision
            if decision?.status == .conflicted || decision?.status == .needsHumanReview {
                let hasReviewTask = records.contains { $0.functionName == "create_human_review_task" }
                return hasReviewTask
                    ? ("完整闭环：已生成确认任务", "标准事实裁决需要人工确认，系统已继续生成 create_human_review_task。")
                    : ("等待人工确认任务", "标准事实裁决显示存在冲突或需要人工确认，但尚未看到确认任务步骤。")
            }
            return ("完整闭环：无需人工确认", "工具链已执行到 make_fact_decision，裁决没有触发 conflicted 或 needsHumanReview，因此 create_human_review_task 可以不调用。")
        }
        if records.contains(where: { $0.functionName == "score_fact_candidates" }),
           missingRequired.contains("make_fact_decision") {
            return ("Gemma 在评分后自动停止", "模型看到 score_fact_candidates 的工具返回后认为证据足够，直接返回 stop。它不是接口失败；但若需要标准化审计，应继续补 make_fact_decision。")
        }
        let last = records.last.map { toolTitle($0.functionName) } ?? "未知步骤"
        return ("工具链未到标准终点", "最后执行到 \(last)。缺少必跑步骤：\(missingRequired.map(toolTitle).joined(separator: "、"))。")
    }
}

struct MeetingTruthASRConflictFinding: Identifiable, Hashable, Codable {
    enum RiskLevel: String, Hashable, Codable {
        case high
        case medium
        case low

        var title: String {
            switch self {
            case .high: "高风险"
            case .medium: "中风险"
            case .low: "低风险"
            }
        }
    }

    var id: UUID = UUID()
    var conflictID: String
    var conflictType: String
    var candidates: [String]
    var sourceTexts: [String]
    var riskLevel: RiskLevel
    var impactsMinutes: Bool
    var reason: String
    var relatedWindow: String
    var windowID: String? = nil
    var alignmentScore: Double? = nil
    var alignmentWarnings: [String]? = nil
}

struct MeetingTruthEvidenceSupport: Identifiable, Hashable, Codable {
    enum SourceType: String, Hashable, Codable {
        case asr
        case imageOCR
        case rawVision
        case material
        case glossary
        case context
        case human
        case meetingNotice
        case handwrittenNote
        case slideOrPPT
        case whiteboard
        case screenshot

        var title: String {
            switch self {
            case .asr: "ASR 转写"
            case .imageOCR: "图片文字识别"
            case .rawVision: "Gemma 原图理解"
            case .material: "会议材料"
            case .glossary: "术语表"
            case .context: "上下文"
            case .human: "人工确认"
            case .meetingNotice: "会议通知"
            case .handwrittenNote: "手写纪要"
            case .slideOrPPT: "PPT / 材料"
            case .whiteboard: "白板 / 板书"
            case .screenshot: "系统截图"
            }
        }
    }

    enum SupportType: String, Hashable, Codable {
        case supports
        case contradicts
        case partialSupport = "partial_support"
        case contextualHint = "contextual_hint"
        case absenceNotEvidence = "absence_not_evidence"
        case notApplicable = "not_applicable"
        case unknown

        var title: String {
            switch self {
            case .supports: "支持"
            case .contradicts: "反驳"
            case .partialSupport: "部分支持"
            case .contextualHint: "背景提示"
            case .absenceNotEvidence: "未出现，不作为反驳"
            case .notApplicable: "不适合判断"
            case .unknown: "未知"
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            switch raw {
            case "partial":
                self = .partialSupport
            default:
                self = MeetingTruthEvidenceSupport.SupportType(rawValue: raw) ?? .unknown
            }
        }
    }

    var id: UUID = UUID()
    var sourceType: SourceType
    var sourceID: String
    var matchedText: String
    var candidate: String
    var supportsCandidate: Bool
    var supportType: SupportType
    var confidence: Double
}

struct MeetingTruthCandidateScore: Identifiable, Hashable, Codable {
    enum RecommendedDecision: String, Hashable, Codable {
        case accepted
        case corrected
        case conflicted
        case needsHumanReview
        case rejected

        var title: String {
            switch self {
            case .accepted: "接受"
            case .corrected: "修正"
            case .conflicted: "冲突"
            case .needsHumanReview: "需人工确认"
            case .rejected: "拒绝"
            }
        }
    }

    var id: UUID = UUID()
    var candidate: String
    var score: Double
    var supportingSources: [String]
    var conflictingSources: [String]
    var reason: String
    var recommendedValue: String
    var recommendedDecision: RecommendedDecision
}

struct MeetingTruthFactDecisionTrace: Hashable, Codable {
    var finalText: String
    var status: MeetingTruthCandidateScore.RecommendedDecision
    var confidence: Double
    var enterMinutes: Bool
    var evidenceChain: [String]
    var explanation: String
    var correctedFrom: [String]
}

struct MeetingTruthHumanReviewTask: Identifiable, Hashable, Codable {
    var id: UUID = UUID()
    var question: String
    var options: [String]
    var whyNeeded: String
    var impact: String
    var relatedWindow: String
}

struct MeetingTruthToolCallingComparison: Hashable, Codable {
    var baselineModeTitle: String
    var toolCallingModeTitle: String
    var baselineSummary: String
    var toolCallingSummary: String
    var improvements: [String]
    var limitations: [String]
    var invokedToolCount: Int
    var impactedClaimCount: Int

    var hasContent: Bool {
        invokedToolCount > 0 || !improvements.isEmpty || !limitations.isEmpty
    }
}

struct MeetingTruthTokenUsage: Hashable, Codable {
    var promptTokens: Int?
    var completionTokens: Int?
    var totalTokens: Int?

    init(promptTokens: Int? = nil, completionTokens: Int? = nil, totalTokens: Int? = nil) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
    }

    var hasContent: Bool {
        promptTokens != nil || completionTokens != nil || totalTokens != nil
    }

    func merged(with other: MeetingTruthTokenUsage?) -> MeetingTruthTokenUsage? {
        guard let other else { return hasContent ? self : nil }
        let merged = MeetingTruthTokenUsage(
            promptTokens: Self.sum(promptTokens, other.promptTokens),
            completionTokens: Self.sum(completionTokens, other.completionTokens),
            totalTokens: Self.sum(totalTokens, other.totalTokens)
        )
        return merged.hasContent ? merged : nil
    }

    private static func sum(_ lhs: Int?, _ rhs: Int?) -> Int? {
        switch (lhs, rhs) {
        case let (.some(lhs), .some(rhs)): lhs + rhs
        case let (.some(value), .none), let (.none, .some(value)): value
        case (.none, .none): nil
        }
    }
}

enum MeetingTruthProcessingAnchorKind: String, CaseIterable, Identifiable, Hashable, Codable {
    case importMaterials
    case ocrAndRawVision
    case timelineSegmentation
    case transcriptAlignment
    case conflictDiscovery
    case candidateGrouping
    case evidenceRetrieval
    case candidateScoring
    case conflictAdjudication
    case safeReplacementValidation
    case humanReviewTaskGeneration
    case centralReviewHandoff

    var id: String { rawValue }

    var sequence: Int {
        switch self {
        case .importMaterials: 1
        case .ocrAndRawVision: 2
        case .timelineSegmentation: 3
        case .transcriptAlignment: 4
        case .conflictDiscovery: 5
        case .candidateGrouping: 6
        case .evidenceRetrieval: 7
        case .candidateScoring: 8
        case .conflictAdjudication: 9
        case .safeReplacementValidation: 10
        case .humanReviewTaskGeneration: 11
        case .centralReviewHandoff: 12
        }
    }

    var title: String {
        switch self {
        case .importMaterials: "导入资料"
        case .ocrAndRawVision: "OCR 与原图理解"
        case .timelineSegmentation: "时间轴切分"
        case .transcriptAlignment: "多路转写对齐"
        case .conflictDiscovery: "冲突发现"
        case .candidateGrouping: "候选分组"
        case .evidenceRetrieval: "证据检索"
        case .candidateScoring: "候选评分"
        case .conflictAdjudication: "冲突裁决"
        case .safeReplacementValidation: "安全替换校验"
        case .humanReviewTaskGeneration: "人工确认任务生成"
        case .centralReviewHandoff: "输出给中枢复核"
        }
    }

    var plainExplanation: String {
        switch self {
        case .importMaterials:
            return "系统把用户导入的转写、图片、会议通知、手写稿和材料登记为后续可核验的证据来源。"
        case .ocrAndRawVision:
            return "系统先用 OCR 识别图片文字，再用 Gemma 原图理解判断图片类型、版式、箭头、圈注和重点标记。"
        case .timelineSegmentation:
            return "系统用带时间戳的 Qwen3 ASR 把会议切成片段，方便逐段比较不同 ASR 的结果。"
        case .transcriptAlignment:
            return "系统把 MiMo 和 GLM 的转写内容对齐到同一段会议内容上，方便比较哪里听得不一样。"
        case .conflictDiscovery:
            return "系统比较同一会议片段中不同 ASR 的识别结果，找出可能影响纪要的差异。"
        case .candidateGrouping:
            return "系统把同一类冲突放在一起，避免把无关词混成一组。"
        case .evidenceRetrieval:
            return "系统在会议通知、手写稿、PPT、图片识别、术语表和材料中查找哪个写法更可信。"
        case .candidateScoring:
            return "系统根据证据来源的可靠程度给每个候选写法打分。"
        case .conflictAdjudication:
            return "系统判断是否可以自动采用某个写法，还是需要用户确认。"
        case .safeReplacementValidation:
            return "系统在真正改写可信转写前，会检查替换是否会造成重复、粘连或错误拼写。"
        case .humanReviewTaskGeneration:
            return "系统只把自己拿不准、且会影响纪要的内容交给用户确认。"
        case .centralReviewHandoff:
            return "系统把已修正的可信转写、证据链、人工确认任务和低风险忽略记录交给中枢复核。"
        }
    }
}

enum MeetingTruthProcessingStageStatus: String, Hashable, Codable {
    case notStarted
    case running
    case completed
    case warning
    case failed

    var title: String {
        switch self {
        case .notStarted: "未开始"
        case .running: "运行中"
        case .completed: "完成"
        case .warning: "有警告"
        case .failed: "失败"
        }
    }
}

enum MeetingTruthProcessingTrigger: String, CaseIterable, Hashable, Codable {
    case swiftRules = "Swift 规则"
    case gemmaText = "Gemma 普通调用"
    case gemmaMultimodal = "Gemma 多模态"
    case gemmaFunctionCalling = "Gemma function calling"
    case localToolFunction = "本地工具函数"
    case ocr = "OCR"
    case userConfirmation = "用户确认"
}

enum MeetingTruthProcessingIssueImpact: String, Hashable, Codable {
    case nonBlocking
    case lowersConfidence
    case routesToHumanReview
    case blocksNextStep

    var title: String {
        switch self {
        case .nonBlocking: "不影响继续"
        case .lowersConfidence: "降低置信度"
        case .routesToHumanReview: "转人工确认"
        case .blocksNextStep: "阻塞下一步"
        }
    }
}

struct MeetingTruthProcessingIssue: Identifiable, Hashable, Codable {
    enum Kind: String, Hashable, Codable {
        case warning
        case error

        var title: String {
            switch self {
            case .warning: "警告"
            case .error: "错误"
            }
        }
    }

    var id: UUID = UUID()
    var kind: Kind
    var message: String
    var impact: MeetingTruthProcessingIssueImpact
}

struct MeetingTruthProcessingAnchor: Identifiable, Hashable, Codable {
    var id: MeetingTruthProcessingAnchorKind { kind }
    var kind: MeetingTruthProcessingAnchorKind
    var status: MeetingTruthProcessingStageStatus
    var durationLabel: String
    var inputs: [String]
    var processing: [String]
    var outputs: [String]
    var nextStep: String
    var triggers: [MeetingTruthProcessingTrigger]
    var issues: [MeetingTruthProcessingIssue]
    var technicalDetails: [String]
    var rawDetails: String?

    var warningCount: Int {
        issues.filter { $0.kind == .warning }.count
    }

    var errorCount: Int {
        issues.filter { $0.kind == .error }.count
    }
}

struct MeetingTruthProcessingSummaryMetric: Identifiable, Hashable, Codable {
    var id: String { title }
    var title: String
    var value: String
    var detail: String
}

struct MeetingTruthToolTimelineItem: Identifiable, Hashable, Codable {
    var id: UUID = UUID()
    var stepName: String
    var explanation: String
    var triggers: [MeetingTruthProcessingTrigger]
    var inputSummary: String
    var outputSummary: String
    var status: MeetingTruthProcessingStageStatus
    var durationLabel: String
    var modelUsage: String
    var rawJSON: String?
}

struct MeetingTruthProcessingRun: Identifiable, Hashable, Codable {
    var id: UUID = UUID()
    var runID: String
    var startTime: Date
    var endTime: Date?
    var durationLabel: String
    var inputSummary: [String]
    var outputSummary: [String]
    var currentStage: String
    var stageStatus: MeetingTruthProcessingStageStatus
    var warnings: [MeetingTruthProcessingIssue]
    var errors: [MeetingTruthProcessingIssue]
    var tokenUsage: MeetingTruthTokenUsage?
    var toolUsage: String
    var modelCalls: Int
    var multimodalCalls: Int
    var ocrCalls: Int
    var userActions: Int
    var finalStatus: String
    var summaryMetrics: [MeetingTruthProcessingSummaryMetric]
    var anchors: [MeetingTruthProcessingAnchor]
    var toolTimeline: [MeetingTruthToolTimelineItem]
}

struct MeetingTruthABBranchResult: Hashable, Codable {
    var title: String
    var modeDescription: String
    var durationSeconds: Double
    var startedAt: Date
    var finishedAt: Date
    var ledger: MeetingTruthCentralReviewLedger?
    var errorMessage: String?
    var tokenUsage: MeetingTruthTokenUsage? = nil

    var succeeded: Bool {
        ledger != nil && errorMessage == nil
    }

    var claimCount: Int {
        ledger?.claims.count ?? 0
    }

    var blockingCount: Int {
        ledger?.blockingItems.count ?? 0
    }

    var advisoryCount: Int {
        ledger?.advisoryItems.count ?? 0
    }

    var rawVisionObservationCount: Int {
        ledger?.visualObservations.filter(\.hasRawVisionOnlySignal).count ?? 0
    }

    var toolCallCount: Int {
        ledger?.toolCallRecords.count ?? 0
    }

    var executedToolCallCount: Int {
        ledger?.toolCallRecords.filter { $0.status == .executed }.count ?? 0
    }

    var asrDifferenceCount: Int {
        uniqueASRConflicts.count
    }

    var automaticCorrectionCount: Int {
        factDecisions.filter { $0.status == .corrected }.count
    }

    var confirmationNeededCount: Int {
        humanReviewTaskCount + (ledger?.claims.filter(\.requiresHumanReview).count ?? 0)
    }

    var evidenceChainCount: Int {
        let recordEvidenceCount = toolRecords.reduce(0) { partial, record in
            partial + (record.evidenceChain?.count ?? 0) + (record.factDecision?.evidenceChain.count ?? 0)
        }
        let claimEvidenceCount = (ledger?.claims ?? []).reduce(0) { partial, claim in
            partial + claim.supportingEvidence.count + claim.contradictingEvidence.count
        }
        return recordEvidenceCount + claimEvidenceCount
    }

    var finalMinutesChangeCount: Int {
        Set(toolRecords.compactMap { record in
            let text = record.affectedMinutesText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return text.isEmpty ? nil : text
        }).count
    }

    var toolFunctionStepCount: Int {
        executedToolCallCount
    }

    var multimodalEvidenceCount: Int {
        let recordEvidence = toolRecords.reduce(0) { partial, record in
            partial + (record.evidenceChain ?? []).filter { evidence in
                evidence.sourceType == .imageOCR || evidence.sourceType == .rawVision || evidence.sourceType == .material
            }.count
        }
        let claimEvidence = (ledger?.claims ?? []).reduce(0) { partial, claim in
            partial + (claim.supportingEvidence + claim.contradictingEvidence).filter { evidence in
                evidence.channel == .imageOCR || evidence.channel == .rawVision || evidence.channel == .material
            }.count
        }
        return recordEvidence + claimEvidence
    }

    var unhandledRiskItemCount: Int {
        (ledger?.claims.filter(\.requiresHumanReview).count ?? 0) + blockingCount + advisoryCount
    }

    var verificationAnomalyCount: Int {
        let unresolvedToolDecisions = factDecisions.filter { decision in
            !decision.enterMinutes ||
            decision.status == .conflicted ||
            decision.status == .needsHumanReview ||
            decision.status == .rejected
        }
        let unresolvedLedgerCount = (ledger?.claims.filter(\.requiresHumanReview).count ?? 0) +
            (ledger?.gaps.filter(\.requiresHumanReview).count ?? 0)
        var count = 0
        if (!unresolvedToolDecisions.isEmpty || humanReviewTaskCount > 0), unresolvedLedgerCount == 0 {
            count += 1
        }
        let acceptedTexts = finalCanonicalTextKeys
        for decision in unresolvedToolDecisions {
            let decisionKey = Self.normalizedABText(decision.finalText)
            if !decisionKey.isEmpty, acceptedTexts.contains(decisionKey) {
                count += 1
            }
        }
        let conflictCandidates = Set(toolRecords.flatMap { record in
            (record.asrConflicts ?? []).flatMap(\.candidates).map(Self.normalizedABText)
        }.filter { !$0.isEmpty })
        if !conflictCandidates.isDisjoint(with: acceptedTexts), !unresolvedToolDecisions.isEmpty {
            count += 1
        }
        return count
    }

    var finalCanonicalTexts: [String] {
        let texts = (ledger?.claims ?? [])
            .filter { claim in
                claim.status == .accepted || claim.status == .corrected
            }
            .map(\.proposedCanonicalText)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !texts.isEmpty {
            return Self.uniqueABTexts(texts)
        }
        let fallbackTexts = (ledger?.claims ?? [])
            .map(\.proposedCanonicalText)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return Self.uniqueABTexts(fallbackTexts)
    }

    var finalCanonicalTextKeys: Set<String> {
        Set(finalCanonicalTexts.map(Self.normalizedABText).filter { !$0.isEmpty })
    }

    private var toolRecords: [MeetingTruthToolCallRecord] {
        ledger?.toolCallRecords ?? []
    }

    private var factDecisions: [MeetingTruthFactDecisionTrace] {
        toolRecords.compactMap(\.factDecision)
    }

    private var humanReviewTaskCount: Int {
        toolRecords.compactMap(\.humanReviewTask).count
    }

    private var uniqueASRConflicts: [MeetingTruthASRConflictFinding] {
        var seen = Set<String>()
        var result: [MeetingTruthASRConflictFinding] = []
        for conflict in toolRecords.flatMap({ $0.asrConflicts ?? [] }) {
            let key = conflict.conflictID.isEmpty ? conflict.candidates.joined(separator: "|") : conflict.conflictID
            guard seen.insert(key).inserted else { continue }
            result.append(conflict)
        }
        return result
    }

    private static func normalizedABText(_ text: String) -> String {
        text.lowercased()
            .filter { $0.isLetter || $0.isNumber || $0 == "+" || $0 == "#" || $0 == "." || $0 == "-" }
    }

    private static func uniqueABTexts(_ texts: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for text in texts {
            let key = normalizedABText(text)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            result.append(text)
        }
        return result
    }
}

enum MeetingTruthABOutcomeKind: String, Hashable, Codable {
    case trustGain
    case noVisibleGain
    case verificationAnomaly

    var title: String {
        switch self {
        case .trustGain: "有可信度收益"
        case .noVisibleGain: "本轮无明显收益"
        case .verificationAnomaly: "核验异常"
        }
    }
}

struct MeetingTruthToolCallingABResult: Hashable, Codable {
    var id: UUID = UUID()
    var generatedAt: Date = Date()
    var model: String
    var promptOnly: MeetingTruthABBranchResult
    var toolCalling: MeetingTruthABBranchResult
    var resultDifferences: [String]
    var effectDifferences: [String]
    var timingSummary: String
    var nativeToolCallingObserved: Bool

    var hasContent: Bool {
        promptOnly.ledger != nil || toolCalling.ledger != nil || !resultDifferences.isEmpty || !effectDifferences.isEmpty
    }

    var outcomeKind: MeetingTruthABOutcomeKind {
        if toolCalling.errorMessage != nil || toolCalling.verificationAnomalyCount > 0 {
            return .verificationAnomaly
        }
        let promptTexts = promptOnly.finalCanonicalTextKeys
        let toolTexts = toolCalling.finalCanonicalTextKeys
        let reducedRisk = toolCalling.unhandledRiskItemCount < promptOnly.unhandledRiskItemCount
        let addedCorrection = toolCalling.automaticCorrectionCount > promptOnly.automaticCorrectionCount
        let changedMinutes = toolCalling.finalMinutesChangeCount > promptOnly.finalMinutesChangeCount
        if !toolTexts.isEmpty, promptTexts == toolTexts, !reducedRisk, !addedCorrection, !changedMinutes {
            return .noVisibleGain
        }
        if !nativeToolCallingObserved, !reducedRisk, !addedCorrection, !changedMinutes {
            return .noVisibleGain
        }
        if reducedRisk || addedCorrection || changedMinutes || !promptTexts.isSuperset(of: toolTexts) {
            return .trustGain
        }
        return .noVisibleGain
    }

    var outcomeDetail: String {
        switch outcomeKind {
        case .trustGain:
            return "证据核验带来了可见收益：它减少未处理风险、产生自动修正，或改变了最终纪要中的高风险事实。"
        case .noVisibleGain:
            return "两条路线当前没有形成实质差异；证据核验多花时间和 token，但没有证明最终结果更可信。"
        case .verificationAnomaly:
            return "工具链给出了冲突、拒绝或人工确认信号，但最终 ledger 没有一致地阻塞或解释；本轮不能当作可信度提升。"
        }
    }
}

struct MeetingTruthCentralReviewLedger: Identifiable, Hashable, Codable {
    var id: UUID = UUID()
    var workflowVersion: Int = 1
    var generatedAt: Date = Date()
    var model: String
    var inputSummary: [String]
    var visualObservations: [MeetingTruthVisualObservation]
    var claims: [MeetingTruthCentralClaim]
    var gaps: [MeetingTruthReviewGap]
    var packageAuditNotes: [String]
    var completionStandard: [String]
    var toolCallRecords: [MeetingTruthToolCallRecord] = []
    var toolCallingComparison: MeetingTruthToolCallingComparison?
    var tokenUsage: MeetingTruthTokenUsage?

    enum CodingKeys: String, CodingKey {
        case id
        case workflowVersion
        case generatedAt
        case model
        case inputSummary
        case visualObservations
        case claims
        case gaps
        case packageAuditNotes
        case completionStandard
        case toolCallRecords
        case toolCallingComparison
        case tokenUsage
    }

    init(
        id: UUID = UUID(),
        workflowVersion: Int = 1,
        generatedAt: Date = Date(),
        model: String,
        inputSummary: [String],
        visualObservations: [MeetingTruthVisualObservation],
        claims: [MeetingTruthCentralClaim],
        gaps: [MeetingTruthReviewGap],
        packageAuditNotes: [String],
        completionStandard: [String],
        toolCallRecords: [MeetingTruthToolCallRecord] = [],
        toolCallingComparison: MeetingTruthToolCallingComparison? = nil,
        tokenUsage: MeetingTruthTokenUsage? = nil
    ) {
        self.id = id
        self.workflowVersion = workflowVersion
        self.generatedAt = generatedAt
        self.model = model
        self.inputSummary = inputSummary
        self.visualObservations = visualObservations
        self.claims = claims
        self.gaps = gaps
        self.packageAuditNotes = packageAuditNotes
        self.completionStandard = completionStandard
        self.toolCallRecords = toolCallRecords
        self.toolCallingComparison = toolCallingComparison
        self.tokenUsage = tokenUsage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        workflowVersion = try container.decodeIfPresent(Int.self, forKey: .workflowVersion) ?? 1
        generatedAt = try container.decodeIfPresent(Date.self, forKey: .generatedAt) ?? Date()
        model = try container.decode(String.self, forKey: .model)
        inputSummary = try container.decodeIfPresent([String].self, forKey: .inputSummary) ?? []
        visualObservations = try container.decodeIfPresent([MeetingTruthVisualObservation].self, forKey: .visualObservations) ?? []
        claims = try container.decodeIfPresent([MeetingTruthCentralClaim].self, forKey: .claims) ?? []
        gaps = try container.decodeIfPresent([MeetingTruthReviewGap].self, forKey: .gaps) ?? []
        packageAuditNotes = try container.decodeIfPresent([String].self, forKey: .packageAuditNotes) ?? []
        completionStandard = try container.decodeIfPresent([String].self, forKey: .completionStandard) ?? []
        toolCallRecords = try container.decodeIfPresent([MeetingTruthToolCallRecord].self, forKey: .toolCallRecords) ?? []
        toolCallingComparison = try container.decodeIfPresent(MeetingTruthToolCallingComparison.self, forKey: .toolCallingComparison)
        tokenUsage = try container.decodeIfPresent(MeetingTruthTokenUsage.self, forKey: .tokenUsage)
    }

    var blockingItems: [String] {
        let claimBlocks = claims
            .filter(\.requiresHumanReview)
            .map { "\($0.kind.title)：\($0.proposedCanonicalText)" }
        let gapBlocks = gaps
            .filter(\.blocksPackageGeneration)
            .map(\.advisoryText)
        return claimBlocks + gapBlocks
    }

    var advisoryItems: [String] {
        gaps
            .filter { $0.requiresHumanReview && !$0.blocksPackageGeneration }
            .map(\.advisoryText)
    }

    var isReadyForPackage: Bool {
        blockingItems.isEmpty
    }
}

struct MeetingTruthArbitrationDecision: Identifiable, Hashable {
    enum Decision: String, Hashable {
        case accept
        case review
        case reject

        var title: String {
            switch self {
            case .accept: "自动接受"
            case .review: "人工确认"
            case .reject: "暂不采用"
            }
        }
    }

    var id: UUID
    var claim: String
    var subject: String
    var riskType: MeetingTruthConflictKind
    var decision: Decision
    var score: Double
    var threshold: Double
    var confidence: MeetingTruthConfidence
    var supportingEvidence: [MeetingTruthEvidenceItem]
    var contradictingEvidence: [MeetingTruthEvidenceItem]
    var scoreBreakdown: [String]
    var parameterEffect: String
    var gemmaRole: String
    var needsHumanReview: Bool
}

struct MeetingTruthTranscriptSource: Identifiable, Hashable, Codable {
    var id: UUID = UUID()
    var name: String
    var text: String

    var preview: String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 90 ? "\(trimmed.prefix(90))..." : trimmed
    }

    var hasTimestamp: Bool {
        text.range(
            of: #"\b\d{1,2}:\d{2}(?::\d{2})?\b|"Start"\s*:\s*\d|"start"\s*:\s*\d"#,
            options: .regularExpression
        ) != nil
    }
}

struct MeetingTruthHistoricalASRResult: Identifiable, Hashable {
    var id: String {
        "\(historyID.uuidString)-\(runID.uuidString)"
    }

    var historyID: UUID
    var runID: UUID
    var createdAt: Date
    var audioPath: String
    var modelName: String
    var status: String
    var text: String

    var audioName: String {
        URL(fileURLWithPath: audioPath).lastPathComponent
    }

    var hasTimestamp: Bool {
        text.range(
            of: #"\b\d{1,2}:\d{2}(?::\d{2})?\b|"Start"\s*:\s*\d|"start"\s*:\s*\d"#,
            options: .regularExpression
        ) != nil
    }
}

struct MeetingTruthManualConfirmation: Identifiable, Hashable, Codable {
    enum Decision: String, Codable {
        case acceptedRecommendation
        case selectedCandidate
        case manualEdit
        case ignoredSuggestion
        case clearedSelection
    }

    var id: UUID = UUID()
    var conflictID: UUID
    var decision: Decision
    var selectedText: String?
    var confirmedAt: Date = Date()
}

struct MeetingTruthSuggestionSummary: Hashable, Codable {
    var totalConflicts: Int
    var lowConfidenceCount: Int
    var generatedAt: Date = Date()
}

struct MeetingTruthPackageStatus: Hashable, Codable {
    enum State: String, Codable {
        case idle
        case readyToGenerate
        case generating
        case succeeded
        case failed
    }

    var state: State
    var generatedAt: Date?
    var message: String?
}

struct MeetingTruthFailureRecord: Hashable, Codable {
    enum Stage: String, Codable {
        case importMaterials
        case importTranscripts
        case discoverConflicts
        case resolveConflicts
        case generatePackage
        case restore
    }

    var stage: Stage
    var message: String
    var recordedAt: Date = Date()
    var details: String?
}

struct MeetingTruthActivityRecord: Identifiable, Hashable, Codable {
    enum Stage: String, Codable {
        case importMaterials
    case importTranscripts
    case discoverConflicts
    case resolveConflicts
    case manualConfirmation
    case generatePackage
    case multimodalEvidence
    case restore
}

    var id: UUID = UUID()
    var stage: Stage
    var title: String
    var message: String
    var details: String?
    var recordedAt: Date = Date()
}

struct MeetingTruthReplacementPreview: Hashable {
    var originalText: String
    var resolvedText: String
    var originalContexts: [String]
    var resolvedContexts: [String]

    var originalMatchCount: Int {
        originalContexts.count
    }

    var resolvedMatchCount: Int {
        resolvedContexts.count
    }
}

struct MeetingTruthProject: Identifiable, Hashable, Codable {
    var id: UUID
    var version: Int = 2
    var createdAt: Date
    var updatedAt: Date
    var selectedAudioPath: String?
    var materials: [MeetingTruthMaterial]
    var transcriptSources: [MeetingTruthTranscriptSource]
    var conflicts: [MeetingTruthConflict]
    var hasDiscoveredConflicts: Bool
    var validationStatus: String
    var trustedTranscriptSnapshot: String?
    var suggestionSummary: MeetingTruthSuggestionSummary?
    var manualConfirmations: [MeetingTruthManualConfirmation]
    var analysis: MeetingAnalysis?
    var packageStatus: MeetingTruthPackageStatus
    var currentErrorMessage: String?
    var lastFailure: MeetingTruthFailureRecord?
    var activityLog: [MeetingTruthActivityRecord] = []
    var multimodalMode: MeetingTruthMultimodalMode = .fusedMultimodal
    var visualEvidence: [MeetingTruthVisualEvidence] = []
    var multimodalComparisons: [MeetingTruthMultimodalComparison] = []
    var arbitrationConfig: MeetingTruthArbitrationConfig = MeetingTruthArbitrationConfig()
    var factCandidates: [MeetingTruthFactCandidate] = []
    var evidenceAtoms: [MeetingTruthEvidenceAtom] = []
    var factDecisions: [MeetingTruthFactDecision] = []
    var userQuestions: [MeetingTruthUserQuestion] = []
    var centralReviewLedger: MeetingTruthCentralReviewLedger?
    var toolCallingABResult: MeetingTruthToolCallingABResult?

    enum CodingKeys: String, CodingKey {
        case id
        case version
        case createdAt
        case updatedAt
        case selectedAudioPath
        case materials
        case transcriptSources
        case conflicts
        case hasDiscoveredConflicts
        case validationStatus
        case trustedTranscriptSnapshot
        case suggestionSummary
        case manualConfirmations
        case analysis
        case packageStatus
        case currentErrorMessage
        case lastFailure
        case activityLog
        case multimodalMode
        case visualEvidence
        case multimodalComparisons
        case arbitrationConfig
        case factCandidates
        case evidenceAtoms
        case factDecisions
        case userQuestions
        case centralReviewLedger
        case toolCallingABResult
    }

    init(
        id: UUID,
        version: Int = 2,
        createdAt: Date,
        updatedAt: Date,
        selectedAudioPath: String?,
        materials: [MeetingTruthMaterial],
        transcriptSources: [MeetingTruthTranscriptSource],
        conflicts: [MeetingTruthConflict],
        hasDiscoveredConflicts: Bool,
        validationStatus: String,
        trustedTranscriptSnapshot: String?,
        suggestionSummary: MeetingTruthSuggestionSummary?,
        manualConfirmations: [MeetingTruthManualConfirmation],
        analysis: MeetingAnalysis?,
        packageStatus: MeetingTruthPackageStatus,
        currentErrorMessage: String?,
        lastFailure: MeetingTruthFailureRecord?,
        activityLog: [MeetingTruthActivityRecord] = [],
        multimodalMode: MeetingTruthMultimodalMode = .fusedMultimodal,
        visualEvidence: [MeetingTruthVisualEvidence] = [],
        multimodalComparisons: [MeetingTruthMultimodalComparison] = [],
        arbitrationConfig: MeetingTruthArbitrationConfig = MeetingTruthArbitrationConfig(),
        factCandidates: [MeetingTruthFactCandidate] = [],
        evidenceAtoms: [MeetingTruthEvidenceAtom] = [],
        factDecisions: [MeetingTruthFactDecision] = [],
        userQuestions: [MeetingTruthUserQuestion] = [],
        centralReviewLedger: MeetingTruthCentralReviewLedger? = nil,
        toolCallingABResult: MeetingTruthToolCallingABResult? = nil
    ) {
        self.id = id
        self.version = version
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.selectedAudioPath = selectedAudioPath
        self.materials = materials
        self.transcriptSources = transcriptSources
        self.conflicts = conflicts
        self.hasDiscoveredConflicts = hasDiscoveredConflicts
        self.validationStatus = validationStatus
        self.trustedTranscriptSnapshot = trustedTranscriptSnapshot
        self.suggestionSummary = suggestionSummary
        self.manualConfirmations = manualConfirmations
        self.analysis = analysis
        self.packageStatus = packageStatus
        self.currentErrorMessage = currentErrorMessage
        self.lastFailure = lastFailure
        self.activityLog = activityLog
        self.multimodalMode = multimodalMode
        self.visualEvidence = visualEvidence
        self.multimodalComparisons = multimodalComparisons
        self.arbitrationConfig = arbitrationConfig
        self.factCandidates = factCandidates
        self.evidenceAtoms = evidenceAtoms
        self.factDecisions = factDecisions
        self.userQuestions = userQuestions
        self.centralReviewLedger = centralReviewLedger
        self.toolCallingABResult = toolCallingABResult
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        selectedAudioPath = try container.decodeIfPresent(String.self, forKey: .selectedAudioPath)
        materials = try container.decodeIfPresent([MeetingTruthMaterial].self, forKey: .materials) ?? []
        transcriptSources = try container.decodeIfPresent([MeetingTruthTranscriptSource].self, forKey: .transcriptSources) ?? []
        conflicts = try container.decodeIfPresent([MeetingTruthConflict].self, forKey: .conflicts) ?? []
        hasDiscoveredConflicts = try container.decodeIfPresent(Bool.self, forKey: .hasDiscoveredConflicts) ?? false
        validationStatus = try container.decodeIfPresent(String.self, forKey: .validationStatus) ?? ""
        trustedTranscriptSnapshot = try container.decodeIfPresent(String.self, forKey: .trustedTranscriptSnapshot)
        suggestionSummary = try container.decodeIfPresent(MeetingTruthSuggestionSummary.self, forKey: .suggestionSummary)
        manualConfirmations = try container.decodeIfPresent([MeetingTruthManualConfirmation].self, forKey: .manualConfirmations) ?? []
        analysis = try container.decodeIfPresent(MeetingAnalysis.self, forKey: .analysis)
        packageStatus = try container.decodeIfPresent(MeetingTruthPackageStatus.self, forKey: .packageStatus) ?? MeetingTruthPackageStatus(state: .idle, generatedAt: nil, message: nil)
        currentErrorMessage = try container.decodeIfPresent(String.self, forKey: .currentErrorMessage)
        lastFailure = try container.decodeIfPresent(MeetingTruthFailureRecord.self, forKey: .lastFailure)
        activityLog = try container.decodeIfPresent([MeetingTruthActivityRecord].self, forKey: .activityLog) ?? []
        multimodalMode = try container.decodeIfPresent(MeetingTruthMultimodalMode.self, forKey: .multimodalMode) ?? .fusedMultimodal
        visualEvidence = try container.decodeIfPresent([MeetingTruthVisualEvidence].self, forKey: .visualEvidence) ?? []
        multimodalComparisons = try container.decodeIfPresent([MeetingTruthMultimodalComparison].self, forKey: .multimodalComparisons) ?? []
        arbitrationConfig = try container.decodeIfPresent(MeetingTruthArbitrationConfig.self, forKey: .arbitrationConfig) ?? MeetingTruthArbitrationConfig()
        factCandidates = try container.decodeIfPresent([MeetingTruthFactCandidate].self, forKey: .factCandidates) ?? []
        evidenceAtoms = try container.decodeIfPresent([MeetingTruthEvidenceAtom].self, forKey: .evidenceAtoms) ?? []
        factDecisions = try container.decodeIfPresent([MeetingTruthFactDecision].self, forKey: .factDecisions) ?? []
        userQuestions = try container.decodeIfPresent([MeetingTruthUserQuestion].self, forKey: .userQuestions) ?? []
        centralReviewLedger = try container.decodeIfPresent(MeetingTruthCentralReviewLedger.self, forKey: .centralReviewLedger)
        toolCallingABResult = try container.decodeIfPresent(MeetingTruthToolCallingABResult.self, forKey: .toolCallingABResult)
    }
}

struct MeetingTruthProjectsStore: Hashable, Codable {
    var lastOpenedProjectID: UUID?
    var projects: [MeetingTruthProject]
    var history: [MeetingTruthHistoryEntry] = []

    enum CodingKeys: String, CodingKey {
        case lastOpenedProjectID
        case projects
        case history
    }

    init(lastOpenedProjectID: UUID?, projects: [MeetingTruthProject], history: [MeetingTruthHistoryEntry] = []) {
        self.lastOpenedProjectID = lastOpenedProjectID
        self.projects = projects
        self.history = history
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lastOpenedProjectID = try container.decodeIfPresent(UUID.self, forKey: .lastOpenedProjectID)
        projects = try container.decodeIfPresent([MeetingTruthProject].self, forKey: .projects) ?? []
        history = try container.decodeIfPresent([MeetingTruthHistoryEntry].self, forKey: .history) ?? []
    }
}

struct MeetingTruthHistoryEntry: Identifiable, Hashable, Codable {
    var id: UUID
    var sourceActivityID: UUID?
    var recordedAt: Date
    var title: String
    var message: String
    var details: String?
    var project: MeetingTruthProject
}

enum RuntimeKind: String, Codable, CaseIterable {
    case sherpaONNX = "sherpa-onnx"
    case mlxSwift = "MLX Swift"
    case externalCLI = "外部 CLI"
}

enum ModelStatus: String, Codable {
    case ready
    case downloadable
    case downloading
    case queued
    case planned
    case failed

    var title: String {
        switch self {
        case .ready: "已就绪"
        case .downloadable: "可下载"
        case .downloading: "下载中"
        case .queued: "队列中"
        case .planned: "待接入"
        case .failed: "失败"
        }
    }
}

enum HotwordSupport: String, Codable {
    case native = "原生热词"
    case promptBias = "提示词偏置"
    case planned = "未验证"
    case none = "不支持"
}

enum ModelHotwordCapability: String, Hashable {
    case supported = "支持"
    case promptOnly = "提示词偏置"
    case unsupported = "不支持"
    case unknown = "未知"
}

struct ASRModelSpec: Identifiable, Hashable {
    let id: String
    let name: String
    let family: String
    let runtime: RuntimeKind
    var runtimeModelName: String?
    let downloadURL: URL?
    let sizeLabel: String
    let languageFocus: String
    let hotwordSupport: HotwordSupport
    let defaultForChineseMeetings: Bool
    let notes: String
    var status: ModelStatus
    var progress: Double
    var localPath: String?
    var sourceDescription: String? = nil
    var validationSummary: String? = nil
    var parameterScale: String { ModelCatalogInfo.info(for: id).parameterScale }
    var platformSupport: String { ModelCatalogInfo.info(for: id).platformSupport }
    var optimizationRoute: String { ModelCatalogInfo.info(for: id).optimizationRoute }
    var hotwordCapability: ModelHotwordCapability { ModelCatalogInfo.info(for: id).hotwordCapability }
    var installedSizeLabel: String { ModelCatalogInfo.info(for: id).installedSizeLabel }
    var downloadMetrics = DownloadMetrics()
}

struct ModelPreparationFailure: Hashable, Codable {
    var modelID: String
    var summary: String
    var recoverySuggestions: [String]
    var developerDetails: String
    var occurredAt: Date = Date()
}

struct ExternalModelConfiguration: Hashable, Codable {
    var modelID: String
    var runtimeModelName: String
    var localPath: String
    var preferredAccelerator: String
    var supportsHotwords: Bool
    var supportsTimestamps: Bool
    var supportsDiarization: Bool
    var supportsLongAudio: Bool
    var notes: String
    var lastValidatedAt: Date?
    var validationSummary: String
    var validationPassed: Bool

    init(
        modelID: String,
        runtimeModelName: String = "",
        localPath: String = "",
        preferredAccelerator: String = "",
        supportsHotwords: Bool = false,
        supportsTimestamps: Bool = false,
        supportsDiarization: Bool = false,
        supportsLongAudio: Bool = false,
        notes: String = "",
        lastValidatedAt: Date? = nil,
        validationSummary: String = "尚未校验",
        validationPassed: Bool = false
    ) {
        self.modelID = modelID
        self.runtimeModelName = runtimeModelName
        self.localPath = localPath
        self.preferredAccelerator = preferredAccelerator
        self.supportsHotwords = supportsHotwords
        self.supportsTimestamps = supportsTimestamps
        self.supportsDiarization = supportsDiarization
        self.supportsLongAudio = supportsLongAudio
        self.notes = notes
        self.lastValidatedAt = lastValidatedAt
        self.validationSummary = validationSummary
        self.validationPassed = validationPassed
    }
}

struct ModelCatalogInfo: Hashable {
    let parameterScale: String
    let installedSizeLabel: String
    let platformSupport: String
    let optimizationRoute: String
    let hotwordCapability: ModelHotwordCapability

    static func info(for id: String) -> ModelCatalogInfo {
        known[id] ?? ModelCatalogInfo(
            parameterScale: "未知",
            installedSizeLabel: "未下载",
            platformSupport: "待确认",
            optimizationRoute: "待确认",
            hotwordCapability: .unknown
        )
    }

    private static let known: [String: ModelCatalogInfo] = [
        "qwen3-asr-1.7b-timestamps": ModelCatalogInfo(
            parameterScale: "1.7B + aligner",
            installedSizeLabel: "复用1.7B主模型；另需aligner缓存",
            platformSupport: "Mac: PyTorch/MPS候选；CUDA官方",
            optimizationRoute: "Transformers + Qwen forced aligner",
            hotwordCapability: .unsupported
        ),
        "glm-asr-nano-2512": ModelCatalogInfo(
            parameterScale: "1.5B",
            installedSizeLabel: "4.2 GB",
            platformSupport: "Mac: MPS/CPU实验；CUDA官方",
            optimizationRoute: "Transformers PyTorch",
            hotwordCapability: .unsupported
        ),
        "mimo-v2-5-asr-mlx": ModelCatalogInfo(
            parameterScale: "8B 4-bit",
            installedSizeLabel: "6.6 GB",
            platformSupport: "Mac: Apple Silicon MLX",
            optimizationRoute: "MLX 4-bit / mlx-audio",
            hotwordCapability: .unsupported
        )
    ]
}

struct DownloadMetrics: Hashable, Sendable {
    var downloadedBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var speedBytesPerSecond: Double = 0
    var estimatedRemainingSeconds: Double?

    var pendingBytes: Int64 {
        max(totalBytes - downloadedBytes, 0)
    }

    var hasValues: Bool {
        downloadedBytes > 0 || totalBytes > 0 || speedBytesPerSecond > 0
    }
}

struct HotwordSet: Identifiable, Hashable {
    let id: UUID
    var name: String
    var words: [String]
    var weight: Double
    var isEnabled: Bool

    var preview: String {
        words.prefix(4).joined(separator: "、")
    }
}

struct ComparisonRun: Identifiable, Hashable, Codable {
    let id: UUID
    let modelID: String
    let modelName: String
    let runtime: String
    var terminologyPostProcessingEnabled: Bool = false
    var requestedAcceleratorDevice: String? = nil
    var requestedChunkSeconds: Int? = nil
    var longAudioCacheEnabled: Bool = true
    var status: String
    var rtf: Double?
    var speed: Double?
    var characterErrorRate: Double?
    var duration: Double?
    var transcribeTime: Double?
    var reviewerVerdict: TranscriptVerdict = .unrated
    var reviewerScore: Int?
    var reviewerNote: String = ""
    var equivalenceGroup: String?
    var segmentCount: Int? = nil
    var cachedSegmentCount: Int? = nil
    var acceleratorDevice: String? = nil
    var acceleratorFallbackReason: String? = nil
    var transcriptPreview: String
    var meetingAnalysis: MeetingAnalysis? = nil
    var meetingAnalysisHistory: [MeetingAnalysis] = []
    var errorMessage: String?

    var cleanTranscriptPreview: String {
        let text = transcriptPreview.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !Self.isDependencyPreparationText(text) else { return "" }
        return text
    }

    var automaticQualityWarning: String? {
        Self.qualityWarning(for: cleanTranscriptPreview, duration: duration)
    }

    var passesAutomaticQualityCheck: Bool {
        automaticQualityWarning == nil
    }

    private static func isDependencyPreparationText(_ text: String) -> Bool {
        text.localizedCaseInsensitiveContains("forced aligner")
            || text.contains("首次使用需要准备")
            || text.contains("时间戳对齐器")
    }

    enum CodingKeys: String, CodingKey {
        case id
        case modelID
        case modelName
        case runtime
        case terminologyPostProcessingEnabled
        case requestedAcceleratorDevice
        case requestedChunkSeconds
        case longAudioCacheEnabled
        case status
        case rtf
        case speed
        case characterErrorRate
        case duration
        case transcribeTime
        case reviewerVerdict
        case reviewerScore
        case reviewerNote
        case equivalenceGroup
        case segmentCount
        case cachedSegmentCount
        case acceleratorDevice
        case acceleratorFallbackReason
        case transcriptPreview
        case meetingAnalysis
        case meetingAnalysisHistory
        case errorMessage
    }

    static func qualityWarning(for text: String, duration: Double?) -> String? {
        let compactCharacters = text.filter { !$0.isWhitespace && !$0.isNewline }.map { $0 }
        guard compactCharacters.count >= 2 else {
            if let duration, duration > 120 {
                return "自动质检：长音频只输出了极少文本，疑似没有识别成功。"
            }
            return nil
        }

        if let warning = repeatedPhraseWarning(in: compactCharacters) {
            return warning
        }

        let semanticCount = compactCharacters.filter { $0.isLetter || $0.isNumber }.count
        if let duration, duration > 120 {
            let minimumExpectedCharacters = max(80, Int(duration * 1.2))
            if semanticCount < minimumExpectedCharacters {
                return "自动质检：音频约 \(Int(duration.rounded())) 秒，但有效文本只有 \(semanticCount) 个字，疑似长切片漏识别。"
            }
        }

        return nil
    }

    private static func repeatedPhraseWarning(in characters: [Character]) -> String? {
        guard characters.count >= 40 else { return nil }
        let maxUnitLength = min(12, characters.count / 3)
        guard maxUnitLength >= 1 else { return nil }

        for unitLength in 1...maxUnitLength {
            var index = 0
            while index + unitLength * 3 <= characters.count {
                var repeatCount = 1
                while index + unitLength * (repeatCount + 1) <= characters.count,
                      equalSlice(characters, index, index + unitLength * repeatCount, length: unitLength) {
                    repeatCount += 1
                }

                let repeatedCharacterCount = repeatCount * unitLength
                if repeatCount >= 10, repeatedCharacterCount >= 40 {
                    let unit = Array(characters[index..<index + unitLength])
                    if unit.contains(where: { $0.isLetter || $0.isNumber }) {
                        let preview = String(unit.prefix(12))
                        return "自动质检：检测到“\(preview)”连续重复约 \(repeatCount) 次，疑似模型重复生成，建议标记为没识别出。"
                    }
                }

                index += max(unitLength * max(repeatCount, 1), 1)
            }
        }

        return nil
    }

    private static func equalSlice(_ characters: [Character], _ left: Int, _ right: Int, length: Int) -> Bool {
        guard left + length <= characters.count, right + length <= characters.count else { return false }
        for offset in 0..<length where characters[left + offset] != characters[right + offset] {
            return false
        }
        return true
    }

    init(
        id: UUID = UUID(),
        modelID: String,
        modelName: String,
        runtime: String,
        terminologyPostProcessingEnabled: Bool = false,
        requestedAcceleratorDevice: String? = nil,
        requestedChunkSeconds: Int? = nil,
        longAudioCacheEnabled: Bool = true,
        status: String,
        rtf: Double? = nil,
        speed: Double? = nil,
        characterErrorRate: Double? = nil,
        duration: Double? = nil,
        transcribeTime: Double? = nil,
        reviewerVerdict: TranscriptVerdict = .unrated,
        reviewerScore: Int? = nil,
        reviewerNote: String = "",
        equivalenceGroup: String? = nil,
        segmentCount: Int? = nil,
        cachedSegmentCount: Int? = nil,
        acceleratorDevice: String? = nil,
        acceleratorFallbackReason: String? = nil,
        transcriptPreview: String,
        meetingAnalysis: MeetingAnalysis? = nil,
        meetingAnalysisHistory: [MeetingAnalysis] = [],
        errorMessage: String? = nil
    ) {
        self.id = id
        self.modelID = modelID
        self.modelName = modelName
        self.runtime = runtime
        self.terminologyPostProcessingEnabled = terminologyPostProcessingEnabled
        self.requestedAcceleratorDevice = requestedAcceleratorDevice
        self.requestedChunkSeconds = requestedChunkSeconds
        self.longAudioCacheEnabled = longAudioCacheEnabled
        self.status = status
        self.rtf = rtf
        self.speed = speed
        self.characterErrorRate = characterErrorRate
        self.duration = duration
        self.transcribeTime = transcribeTime
        self.reviewerVerdict = reviewerVerdict
        self.reviewerScore = reviewerScore
        self.reviewerNote = reviewerNote
        self.equivalenceGroup = equivalenceGroup
        self.segmentCount = segmentCount
        self.cachedSegmentCount = cachedSegmentCount
        self.acceleratorDevice = acceleratorDevice
        self.acceleratorFallbackReason = acceleratorFallbackReason
        self.transcriptPreview = transcriptPreview
        self.meetingAnalysis = meetingAnalysis
        self.meetingAnalysisHistory = meetingAnalysisHistory
        self.errorMessage = errorMessage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        modelID = try container.decode(String.self, forKey: .modelID)
        modelName = try container.decode(String.self, forKey: .modelName)
        runtime = try container.decode(String.self, forKey: .runtime)
        terminologyPostProcessingEnabled = try container.decodeIfPresent(Bool.self, forKey: .terminologyPostProcessingEnabled) ?? false
        requestedAcceleratorDevice = try container.decodeIfPresent(String.self, forKey: .requestedAcceleratorDevice)
        requestedChunkSeconds = try container.decodeIfPresent(Int.self, forKey: .requestedChunkSeconds)
        longAudioCacheEnabled = try container.decodeIfPresent(Bool.self, forKey: .longAudioCacheEnabled) ?? true
        status = try container.decode(String.self, forKey: .status)
        rtf = try container.decodeIfPresent(Double.self, forKey: .rtf)
        speed = try container.decodeIfPresent(Double.self, forKey: .speed)
        characterErrorRate = try container.decodeIfPresent(Double.self, forKey: .characterErrorRate)
        duration = try container.decodeIfPresent(Double.self, forKey: .duration)
        transcribeTime = try container.decodeIfPresent(Double.self, forKey: .transcribeTime)
        reviewerVerdict = try container.decodeIfPresent(TranscriptVerdict.self, forKey: .reviewerVerdict) ?? .unrated
        reviewerScore = try container.decodeIfPresent(Int.self, forKey: .reviewerScore)
        reviewerNote = try container.decodeIfPresent(String.self, forKey: .reviewerNote) ?? ""
        equivalenceGroup = try container.decodeIfPresent(String.self, forKey: .equivalenceGroup)
        segmentCount = try container.decodeIfPresent(Int.self, forKey: .segmentCount)
        cachedSegmentCount = try container.decodeIfPresent(Int.self, forKey: .cachedSegmentCount)
        acceleratorDevice = try container.decodeIfPresent(String.self, forKey: .acceleratorDevice)
        acceleratorFallbackReason = try container.decodeIfPresent(String.self, forKey: .acceleratorFallbackReason)
        transcriptPreview = try container.decodeIfPresent(String.self, forKey: .transcriptPreview) ?? ""
        meetingAnalysis = try container.decodeIfPresent(MeetingAnalysis.self, forKey: .meetingAnalysis)
        meetingAnalysisHistory = try container.decodeIfPresent([MeetingAnalysis].self, forKey: .meetingAnalysisHistory) ?? []
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
    }
}

enum MeetingTokenPlan: String, CaseIterable, Hashable, Codable {
    case economy
    case standard
    case deep
    case custom

    var title: String {
        switch self {
        case .economy: "精简"
        case .standard: "标准"
        case .deep: "长会议"
        case .custom: "高保真"
        }
    }

    var userDescription: String {
        switch self {
        case .economy: "生成更短，速度更快，适合快速摘要。"
        case .standard: "适合一般会议，平衡速度和完整度。"
        case .deep: "读取更多转写内容，适合较长会议，速度会更慢。"
        case .custom: "尽量保留更多上下文和证据，适合正式纪要，耗时更长。"
        }
    }

    var maxTokens: Int {
        switch self {
        case .economy: 1200
        case .standard: 2400
        case .deep: 4200
        case .custom: 2400
        }
    }

    var temperature: Double {
        switch self {
        case .economy: 0.2
        case .standard: 0.25
        case .deep: 0.3
        case .custom: 0.25
        }
    }

    var inputCharacterLimit: Int {
        switch self {
        case .economy: 18_000
        case .standard: 45_000
        case .deep: 90_000
        case .custom: 45_000
        }
    }
}

struct AppSettings: Hashable, Codable {
    var modelCachePath: String
}

struct MeetingAIPreset: Identifiable, Hashable {
    let id: String
    let title: String
    let baseURL: String
    let apiKey: String
    let model: String
    let tokenPlan: MeetingTokenPlan
    let customMaxTokens: Int?
    let customInputCharacterLimit: Int?

    static let builtInPresets: [MeetingAIPreset] = [
        MeetingAIPreset(
            id: "local-gemma-4-12b",
            title: "推荐：Gemma 4 12B",
            baseURL: "http://127.0.0.1:1234/v1/chat/completions",
            apiKey: "",
            model: "google/gemma-4-12b",
            tokenPlan: .custom,
            customMaxTokens: 131_072,
            customInputCharacterLimit: 131_072
        ),
        MeetingAIPreset(
            id: "local-gemma-4-e4b",
            title: "备用：Gemma 4 E4B",
            baseURL: "http://127.0.0.1:1234/v1/chat/completions",
            apiKey: "",
            model: "google/gemma-4-e4b",
            tokenPlan: .custom,
            customMaxTokens: 131_072,
            customInputCharacterLimit: 131_072
        ),
        MeetingAIPreset(
            id: "remote-gemma-4-custom",
            title: "远程 Gemma 4 自定义端点",
            baseURL: "https://your-gemma-endpoint.example/v1/chat/completions",
            apiKey: "",
            model: "google/gemma-4-12b",
            tokenPlan: .custom,
            customMaxTokens: 8192,
            customInputCharacterLimit: 90000
        )
    ]
}

struct MeetingAISettings: Hashable, Codable {
    static let legacyProductStyleOrganizationPrefix = "按\("飞书")\("妙记")风格整理"
    static let legacyProductStyleOrganizationInstructions = "\(legacyProductStyleOrganizationPrefix)：先还原会议真实议题大框，每个大框下归纳子议题、关键结论、讨论依据和待办。不要按转写顺序机械分段，不要编造没有出现的信息。"
    static let defaultOrganizationInstructionsText = "按议题归纳整理会议成果：先识别会议中的主要议题，不按转写顺序机械分段。每个议题下整理背景、讨论要点、关键结论、讨论依据和待办事项。待办事项尽量包含负责人、动作和时间；缺失的信息标记为‘待确认’。不得编造会议中没有出现的信息，不得覆盖人工确认结果，不得覆盖中枢复核结论。证据不足或有冲突的内容应标注‘待确认’或放入证据备注。"

    var baseURL: String = "http://127.0.0.1:1234/v1/chat/completions"
    var apiKey: String = ""
    var model: String = "google/gemma-4-12b"
    var tokenPlan: MeetingTokenPlan = .standard
    var autoGenerateAfterTranscription: Bool = false
    var customMaxTokens: Int = 2400
    var customTemperature: Double = 0.25
    var customInputCharacterLimit: Int = 45_000
    var defaultOrganizationInstructions: String = Self.defaultOrganizationInstructionsText
    var lastValidatedAt: Date?
    var validationPassed: Bool = false
    var validationSummary: String = "尚未校验"

    var resolvedMaxTokens: Int {
        tokenPlan == .custom ? min(max(customMaxTokens, 600), 131_072) : tokenPlan.maxTokens
    }

    var resolvedTemperature: Double {
        tokenPlan == .custom ? min(max(customTemperature, 0), 1) : tokenPlan.temperature
    }

    var resolvedInputCharacterLimit: Int {
        tokenPlan == .custom ? min(max(customInputCharacterLimit, 4_000), 131_072) : tokenPlan.inputCharacterLimit
    }

    var hasUsableAPIKey: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || usesLocalEndpoint
    }

    var isMissingRequiredAPIKey: Bool {
        !usesLocalEndpoint && apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var usesLocalEndpoint: Bool {
        guard let host = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased() else {
            return false
        }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    var validationDisplaySummary: String {
        if isMissingRequiredAPIKey {
            return "远程端点通常需要 API Key；本机 localhost 端点可以留空。"
        }
        if validationSummary == "尚未校验", usesLocalEndpoint, apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "本机端点未填写 API Key，这是正常的；需要确认服务已启动时再测试连接。"
        }
        return validationSummary
    }

    var matchingPresetID: String? {
        MeetingAIPreset.builtInPresets.first {
            $0.baseURL == baseURL &&
            $0.apiKey == apiKey &&
            $0.model == model
        }?.id
    }

    enum CodingKeys: String, CodingKey {
        case baseURL
        case apiKey
        case model
        case tokenPlan
        case autoGenerateAfterTranscription
        case customMaxTokens
        case customTemperature
        case customInputCharacterLimit
        case defaultOrganizationInstructions
        case lastValidatedAt
        case validationPassed
        case validationSummary
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = MeetingAISettings()
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? defaults.baseURL
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? defaults.apiKey
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? defaults.model
        tokenPlan = try container.decodeIfPresent(MeetingTokenPlan.self, forKey: .tokenPlan) ?? defaults.tokenPlan
        autoGenerateAfterTranscription = try container.decodeIfPresent(Bool.self, forKey: .autoGenerateAfterTranscription) ?? defaults.autoGenerateAfterTranscription
        customMaxTokens = try container.decodeIfPresent(Int.self, forKey: .customMaxTokens) ?? defaults.customMaxTokens
        customTemperature = try container.decodeIfPresent(Double.self, forKey: .customTemperature) ?? defaults.customTemperature
        customInputCharacterLimit = try container.decodeIfPresent(Int.self, forKey: .customInputCharacterLimit) ?? defaults.customInputCharacterLimit
        let decodedOrganizationInstructions = try container.decodeIfPresent(String.self, forKey: .defaultOrganizationInstructions) ?? defaults.defaultOrganizationInstructions
        defaultOrganizationInstructions = decodedOrganizationInstructions == Self.legacyProductStyleOrganizationInstructions
            ? Self.defaultOrganizationInstructionsText
            : decodedOrganizationInstructions.replacingOccurrences(of: Self.legacyProductStyleOrganizationPrefix, with: "按议题归纳整理会议成果")
        lastValidatedAt = try container.decodeIfPresent(Date.self, forKey: .lastValidatedAt)
        validationPassed = try container.decodeIfPresent(Bool.self, forKey: .validationPassed) ?? defaults.validationPassed
        validationSummary = try container.decodeIfPresent(String.self, forKey: .validationSummary) ?? defaults.validationSummary
    }
}

struct MeetingAIValidationResult: Hashable {
    var passed: Bool
    var summary: String
    var model: String
}

struct MeetingAnalysis: Hashable, Codable {
    var id: UUID = UUID()
    var generatedAt: Date = Date()
    var model: String
    var tokenPlan: MeetingTokenPlan
    var refinementInstructions: String = ""
    var summary: String
    var keyPoints: [String]
    var mindMap: [MindMapNode]
    var minutes: [String]
    var actionItems: [MeetingActionItem]
    var evidenceNotes: [String] = []

    var hasContent: Bool {
        !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !keyPoints.isEmpty ||
        !mindMap.isEmpty ||
        !minutes.isEmpty ||
        !actionItems.isEmpty
    }

    enum CodingKeys: String, CodingKey {
        case id
        case generatedAt
        case model
        case tokenPlan
        case refinementInstructions
        case summary
        case keyPoints
        case mindMap
        case minutes
        case actionItems
        case evidenceNotes
    }

    init(
        id: UUID = UUID(),
        generatedAt: Date = Date(),
        model: String,
        tokenPlan: MeetingTokenPlan,
        refinementInstructions: String = "",
        summary: String,
        keyPoints: [String],
        mindMap: [MindMapNode],
        minutes: [String],
        actionItems: [MeetingActionItem],
        evidenceNotes: [String] = []
    ) {
        self.id = id
        self.generatedAt = generatedAt
        self.model = model
        self.tokenPlan = tokenPlan
        self.refinementInstructions = refinementInstructions
        self.summary = summary
        self.keyPoints = keyPoints
        self.mindMap = mindMap
        self.minutes = minutes
        self.actionItems = actionItems
        self.evidenceNotes = evidenceNotes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        generatedAt = try container.decodeIfPresent(Date.self, forKey: .generatedAt) ?? Date()
        model = try container.decode(String.self, forKey: .model)
        tokenPlan = try container.decode(MeetingTokenPlan.self, forKey: .tokenPlan)
        refinementInstructions = try container.decodeIfPresent(String.self, forKey: .refinementInstructions) ?? ""
        summary = try container.decode(String.self, forKey: .summary)
        keyPoints = try container.decodeIfPresent([String].self, forKey: .keyPoints) ?? []
        mindMap = try container.decodeIfPresent([MindMapNode].self, forKey: .mindMap) ?? []
        minutes = try container.decodeIfPresent([String].self, forKey: .minutes) ?? []
        actionItems = try container.decodeIfPresent([MeetingActionItem].self, forKey: .actionItems) ?? []
        evidenceNotes = try container.decodeIfPresent([String].self, forKey: .evidenceNotes) ?? []
    }
}

struct MindMapNode: Identifiable, Hashable, Codable {
    var id: UUID = UUID()
    var title: String
    var children: [MindMapNode] = []

    enum CodingKeys: String, CodingKey {
        case title
        case children
    }
}

struct MeetingActionItem: Identifiable, Hashable, Codable {
    var id: UUID = UUID()
    var task: String
    var owner: String?
    var due: String?

    enum CodingKeys: String, CodingKey {
        case task
        case owner
        case due
    }
}

enum TranscriptVerdict: String, CaseIterable, Hashable, Codable {
    case unrated
    case best
    case sameGood
    case acceptable
    case flawed
    case missed

    var title: String {
        switch self {
        case .unrated: "未评分"
        case .best: "最好"
        case .sameGood: "一样好"
        case .acceptable: "可用"
        case .flawed: "有明显问题"
        case .missed: "没识别出"
        }
    }

    var systemImage: String {
        switch self {
        case .unrated: "circle"
        case .best: "star.fill"
        case .sameGood: "equal.circle.fill"
        case .acceptable: "checkmark.circle"
        case .flawed: "exclamationmark.triangle"
        case .missed: "xmark.circle"
        }
    }
}

struct RunHistoryEntry: Identifiable, Hashable, Codable {
    let id: UUID
    var createdAt: Date
    var audioPath: String
    var runs: [ComparisonRun]

    init(id: UUID = UUID(), createdAt: Date = Date(), audioPath: String, runs: [ComparisonRun]) {
        self.id = id
        self.createdAt = createdAt
        self.audioPath = audioPath
        self.runs = runs
    }

    var title: String {
        let completed = runs.filter { !$0.cleanTranscriptPreview.isEmpty }.count
        return "\(runs.count) 个模型 · \(completed) 个有文本"
    }

    var containsLegacyASRBaseline: Bool {
        runs.contains { run in
            let haystack = [
                run.modelID,
                run.modelName,
                run.runtime,
                run.cleanTranscriptPreview
            ].joined(separator: "\n").lowercased()
            let legacyFamily = "whis" + "per"
            let legacyRuntime = legacyFamily + "kit"
            return haystack.contains(legacyFamily)
                || haystack.contains(legacyRuntime)
                || haystack.contains("core ml")
        }
    }
}

struct ASRTranscriptionMetrics: Hashable {
    var duration: Double
    var transcribeTime: Double
    var rtf: Double
    var speed: Double
    var acceleratorDevice: String? = nil
    var acceleratorFallbackReason: String? = nil
}

struct ASRTranscriptionResult: Hashable {
    var text: String
    var metrics: ASRTranscriptionMetrics
}

struct ASRProgressUpdate: Hashable, Sendable {
    var stage: String
    var fraction: Double
    var elapsed: Double
    var estimatedRemaining: Double?
    var partialText: String
    var segmentIndex: Int? = nil
    var segmentCount: Int? = nil
    var cachedSegmentCount: Int? = nil
    var segmentStart: Double? = nil
    var segmentEnd: Double? = nil
}
