import Foundation
import UniformTypeIdentifiers

struct MeetingTruthConflictDiscoveryProgress: Sendable {
    enum Stage: Sendable {
        case localFiltering
        case gemmaReview
        case fullContextReview
    }

    let stage: Stage
    let completed: Int
    let total: Int

    var statusText: String {
        switch stage {
        case .localFiltering:
            total == 0
                ? "本地差异筛选完成，没有需要 Gemma 4 判断的关键窗口"
                : "本地差异筛选完成，找到 \(total) 个候选窗口"
        case .gemmaReview:
            completed == total
                ? "Gemma 4 已完成 \(total) 个差异窗口判定"
                : "Gemma 4 正在判定差异窗口 \(completed + 1)/\(total)"
        case .fullContextReview:
            total == 0
                ? "Gemma 4 正在用全文上下文复核冲突"
                : "Gemma 4 正在用全文上下文复核 \(total) 个冲突"
        }
    }
}

struct MeetingAIService {
    func extractVisualEvidence(
        materials: [MeetingTruthMaterial],
        transcriptHints: [MeetingTruthTranscriptSource],
        settings: MeetingAISettings
    ) async throws -> [MeetingTruthVisualEvidence] {
        let imageMaterials = materials.filter(isImageMaterial)
        guard !imageMaterials.isEmpty else { return [] }
        guard settings.hasUsableAPIKey else {
            throw MeetingAIError.missingAPIKey
        }
        guard let url = URL(string: settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw MeetingAIError.invalidBaseURL
        }

        let completion = try await requestCompletion(
            url: url,
            settings: settings,
            systemContent: visualEvidenceSystemPrompt,
            userMessage: visualEvidenceUserMessage(
                materials: imageMaterials,
                transcriptHints: transcriptHints
            ),
            maxTokens: min(max(settings.resolvedMaxTokens, 1_200), 4_000)
        )
        guard completion.choices.first?.finishReason != "length" else {
            throw MeetingAIError.responseTruncated
        }
        guard let content = assistantResponseText(from: completion), !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MeetingAIError.emptyResponse
        }
        return try decodeVisualEvidence(
            from: content,
            materials: imageMaterials,
            model: settings.model
        )
    }

    @MainActor
    func reviewMeetingTruthCentrally(
        transcriptSources: [MeetingTruthTranscriptSource],
        materials: [MeetingTruthMaterial],
        visualEvidence: [MeetingTruthVisualEvidence],
        conflicts: [MeetingTruthConflict],
        factDecisions: [MeetingTruthFactDecision],
        manualConfirmations: [MeetingTruthManualConfirmation],
        currentLedger: MeetingTruthCentralReviewLedger?,
        analysis: MeetingAnalysis?,
        settings: MeetingAISettings,
        useToolCalling: Bool = true
    ) async throws -> MeetingTruthCentralReviewLedger {
        guard !transcriptSources.isEmpty || !materials.isEmpty else {
            throw MeetingAIError.emptyTranscript
        }
        guard settings.hasUsableAPIKey else {
            throw MeetingAIError.missingAPIKey
        }
        guard let url = URL(string: settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw MeetingAIError.invalidBaseURL
        }

        let toolRun = useToolCalling
            ? try? await requestCentralReviewToolCalls(
                url: url,
                transcriptSources: transcriptSources,
                materials: materials,
                visualEvidence: visualEvidence,
                conflicts: conflicts,
                factDecisions: factDecisions,
                manualConfirmations: manualConfirmations,
                currentLedger: currentLedger,
                analysis: analysis,
                settings: settings
            )
            : nil

        let completion = try await requestCompletion(
            url: url,
            settings: settings,
            systemContent: centralReviewSystemPrompt,
            userMessage: try centralReviewUserMessage(
                transcriptSources: transcriptSources,
                materials: materials,
                visualEvidence: visualEvidence,
                conflicts: conflicts,
                factDecisions: factDecisions,
                manualConfirmations: manualConfirmations,
                currentLedger: currentLedger,
                analysis: analysis,
                toolRun: toolRun,
                settings: settings
            ),
            maxTokens: usesLargeGemmaContext(settings.model)
                ? min(max(settings.resolvedMaxTokens, 6_000), 24_000)
                : min(max(settings.resolvedMaxTokens, 2_400), 6_000)
        )
        guard completion.choices.first?.finishReason != "length" else {
            throw MeetingAIError.responseTruncated
        }
        guard let content = assistantResponseText(from: completion),
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MeetingAIError.emptyResponse
        }
        return try decodeCentralReviewLedger(
            from: content,
            model: settings.model,
            fallbackLedger: currentLedger,
            toolRun: toolRun,
            tokenUsage: completion.usage?.meetingTruthUsage
        )
    }

    func validate(settings: MeetingAISettings) async throws -> MeetingAIValidationResult {
        guard settings.hasUsableAPIKey else {
            throw MeetingAIError.missingAPIKey
        }
        guard let url = URL(string: settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw MeetingAIError.invalidBaseURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 30

        let payload = ChatCompletionRequest(
            model: settings.model,
            messages: [
                ChatRequestMessage(role: "system", content: "你是连接测试助手，只能回答 OK。"),
                ChatRequestMessage(role: "user", content: "请回复 OK")
            ],
            temperature: 0,
            maxTokens: 64,
            enableThinking: nil,
            tools: nil,
            toolChoice: nil
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            throw MeetingAIError.requestFailed(httpResponse.statusCode, String(data: data, encoding: .utf8) ?? "")
        }

        let completion = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        let content = (assistantResponseText(from: completion) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            throw MeetingAIError.emptyResponse
        }
        return MeetingAIValidationResult(
            passed: true,
            summary: settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "校验通过：本机端点可访问，模型 \(settings.model) 可完成调用。"
                : "校验通过：Base URL 可访问，API Key 有效，模型 \(settings.model) 可完成调用。",
            model: settings.model
        )
    }

    func analyze(
        transcript: String,
        materials: [MeetingTruthMaterial],
        settings: MeetingAISettings,
        refinementInstructions: String = ""
    ) async throws -> MeetingAnalysis {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MeetingAIError.emptyTranscript
        }
        guard settings.hasUsableAPIKey else {
            throw MeetingAIError.missingAPIKey
        }
        guard let url = URL(string: settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw MeetingAIError.invalidBaseURL
        }

        if shouldUseChunkedAnalysis(for: trimmed, settings: settings) {
            return try await analyzeInChunks(
                transcript: trimmed,
                materials: materials,
                settings: settings,
                refinementInstructions: refinementInstructions,
                url: url
            )
        }

        let attempts: [(inputLimit: Int, compact: Bool)] = [
            (resolvedInputLimit(for: settings, compact: false), false),
            (resolvedInputLimit(for: settings, compact: true), true)
        ]

        var lastError: Error?
        var encounteredTruncation = false
        for attempt in attempts {
            do {
                let preparedTranscript = preparedInput(from: trimmed, limit: attempt.inputLimit)
                let completion = try await requestAnalysisCompletion(
                    url: url,
                    settings: settings,
                    transcript: preparedTranscript,
                    materials: materials,
                    refinementInstructions: refinementInstructions,
                    compact: attempt.compact
                )
                if completion.choices.first?.finishReason == "length" {
                    encounteredTruncation = true
                    lastError = MeetingAIError.responseTruncated
                    continue
                }
                guard let content = assistantResponseText(from: completion), !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw MeetingAIError.emptyResponse
                }
                return try decodeAnalysis(
                    from: content,
                    settings: settings,
                    refinementInstructions: refinementInstructions
                )
            } catch {
                if MeetingAIError.isTruncationRelated(error) {
                    encounteredTruncation = true
                }
                lastError = error
            }
        }

        if encounteredTruncation {
            return try await analyzeInChunks(
                transcript: trimmed,
                materials: materials,
                settings: settings,
                refinementInstructions: refinementInstructions + "\n\n上一轮完整成果包输出被截断。现在改用分段整理与最终合并：每段保留议题、结论、证据和待办，最终合并时去重但不要丢失长会主要议题。",
                url: url
            )
        }
        throw lastError ?? MeetingAIError.emptyResponse
    }

    private enum AnalysisGenerationBounds {
        static let largeContextSinglePassCharacters = 45_000
        static let nonLargeThinkingDisabledSinglePassCharacters = 8_000
        static let nonLargeDefaultSinglePassCharacters = 10_000
        static let largeContextMinimumOutputTokens = 12_000
        static let largeContextCompactMinimumOutputTokens = 8_000
        static let largeContextMergeMinimumOutputTokens = 12_000
        static let nonLargeMinimumOutputTokens = 2_600
        static let nonLargeCompactMinimumOutputTokens = 2_200
        static let nonLargeMergeMinimumOutputTokens = 3_200
        static let nonLargeMaximumOutputTokens = 4_200
        static let nonLargeCompactMaximumOutputTokens = 3_600
        static let nonLargeMergeMaximumOutputTokens = 4_800
        static let absoluteMaximumOutputTokens = 131_072
    }

    private func analysisOutputTokens(for settings: MeetingAISettings, compact: Bool) -> Int {
        let isLargeGemma = usesLargeGemmaContext(settings.model)
        if isLargeGemma {
            let minimum = compact
                ? AnalysisGenerationBounds.largeContextCompactMinimumOutputTokens
                : AnalysisGenerationBounds.largeContextMinimumOutputTokens
            return min(
                max(settings.resolvedMaxTokens, minimum),
                AnalysisGenerationBounds.absoluteMaximumOutputTokens
            )
        }

        let minimum = compact
            ? AnalysisGenerationBounds.nonLargeCompactMinimumOutputTokens
            : AnalysisGenerationBounds.nonLargeMinimumOutputTokens
        let maximum = compact
            ? AnalysisGenerationBounds.nonLargeCompactMaximumOutputTokens
            : AnalysisGenerationBounds.nonLargeMaximumOutputTokens
        return min(max(settings.resolvedMaxTokens, minimum), maximum)
    }

    private func mergeOutputTokens(for settings: MeetingAISettings) -> Int {
        if usesLargeGemmaContext(settings.model) {
            return min(
                max(settings.resolvedMaxTokens, AnalysisGenerationBounds.largeContextMergeMinimumOutputTokens),
                AnalysisGenerationBounds.absoluteMaximumOutputTokens
            )
        }
        return min(
            max(settings.resolvedMaxTokens, AnalysisGenerationBounds.nonLargeMergeMinimumOutputTokens),
            AnalysisGenerationBounds.nonLargeMergeMaximumOutputTokens
        )
    }

    private func singlePassInputLimit(for settings: MeetingAISettings) -> Int {
        if usesLargeGemmaContext(settings.model) {
            return min(
                settings.resolvedInputCharacterLimit,
                AnalysisGenerationBounds.largeContextSinglePassCharacters
            )
        }
        if shouldDisableThinking(for: settings.model) {
            return min(
                settings.resolvedInputCharacterLimit,
                AnalysisGenerationBounds.nonLargeThinkingDisabledSinglePassCharacters
            )
        }
        return min(
            settings.resolvedInputCharacterLimit,
            AnalysisGenerationBounds.nonLargeDefaultSinglePassCharacters
        )
    }

    private func compactInputLimit(for settings: MeetingAISettings) -> Int {
        min(settings.resolvedInputCharacterLimit, chunkInputLimit(for: settings))
    }

    private func settingsBoundarySummary(_ settings: MeetingAISettings) -> String {
        """
        当前模型：\(settings.model)
        单次成果包输入上限：\(singlePassInputLimit(for: settings)) 字符；超过后自动分段。
        分段大小：\(chunkInputLimit(for: settings)) 字符。
        单次输出上限：\(analysisOutputTokens(for: settings, compact: false)) tokens；紧凑/分段输出上限：\(analysisOutputTokens(for: settings, compact: true)) tokens；最终合并输出上限：\(mergeOutputTokens(for: settings)) tokens。
        请求超时：按输出预算动态设置，范围 300-900 秒。
        """
    }

    private func truncationError(for settings: MeetingAISettings) -> MeetingAIError {
        .responseTruncatedAfterRetries(settingsBoundarySummary(settings))
    }

    private func chunkTruncationError(index: Int, total: Int, settings: MeetingAISettings) -> MeetingAIError {
        .chunkResponseTruncated(index, total, settingsBoundarySummary(settings))
    }

    private func mergeTruncationError(settings: MeetingAISettings) -> MeetingAIError {
        .mergeResponseTruncated(settingsBoundarySummary(settings))
    }

    func resolveConflicts(
        conflicts: [MeetingTruthConflict],
        materials: [MeetingTruthMaterial],
        settings: MeetingAISettings
    ) async throws -> [MeetingTruthConflict] {
        guard !conflicts.isEmpty else { return [] }
        guard settings.hasUsableAPIKey else {
            throw MeetingAIError.missingAPIKey
        }
        guard let url = URL(string: settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw MeetingAIError.invalidBaseURL
        }

        let completion = try await requestCompletion(
            url: url,
            settings: settings,
            systemContent: conflictResolverSystemPrompt,
            userMessage: try conflictResolverUserMessage(conflicts: conflicts, materials: materials),
            maxTokens: min(max(settings.resolvedMaxTokens, 1200), 3200)
        )
        guard completion.choices.first?.finishReason != "length" else {
            throw MeetingAIError.responseTruncated
        }
        guard let content = assistantResponseText(from: completion), !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MeetingAIError.emptyResponse
        }
        return try decodeConflictResolutions(from: content, originalConflicts: conflicts)
    }

    func discoverConflicts(
        sources: [MeetingTruthTranscriptSource],
        materials: [MeetingTruthMaterial],
        settings: MeetingAISettings,
        progress: @escaping @Sendable (MeetingTruthConflictDiscoveryProgress) async -> Void = { _ in }
    ) async throws -> [MeetingTruthConflict] {
        guard sources.count >= 2 else {
            throw MeetingAIError.insufficientTranscriptSources
        }
        guard settings.hasUsableAPIKey else {
            throw MeetingAIError.missingAPIKey
        }
        guard let url = URL(string: settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw MeetingAIError.invalidBaseURL
        }

        let windows = localConflictWindows(from: sources)
        await progress(.init(stage: .localFiltering, completed: windows.count, total: windows.count))
        guard !windows.isEmpty else { return [] }

        var conflicts: [MeetingTruthConflict] = []
        let prioritizedWindows = windows.sorted { $0.differenceScore > $1.differenceScore }
        for (index, window) in prioritizedWindows.enumerated() {
            await progress(.init(stage: .gemmaReview, completed: index, total: prioritizedWindows.count))
            let discovered = try await discoverConflicts(
                in: window,
                materials: materials,
                settings: settings,
                url: url,
                segmentOffset: conflicts.count
            )
            conflicts.append(contentsOf: discovered)
            conflicts = deduplicatedConflicts(conflicts)
        }
        await progress(.init(stage: .gemmaReview, completed: prioritizedWindows.count, total: prioritizedWindows.count))
        guard !conflicts.isEmpty else { return [] }
        await progress(.init(stage: .fullContextReview, completed: 0, total: conflicts.count))
        let reviewed = try await reviewConflictsAgainstFullContext(
            conflicts: conflicts,
            sources: sources,
            materials: materials,
            settings: settings,
            url: url
        )
        await progress(.init(stage: .fullContextReview, completed: conflicts.count, total: conflicts.count))
        return reviewed
    }

    private var systemPrompt: String {
        """
        你是专业会议纪要和会议结构图助手。你的第一目标不是压缩文字，而是还原“会议真实讨论结构”。

        工作方法：
        1. 先通读转写，识别会议真正讨论的 3-7 个一级议题。一级议题必须是会议中的业务主题/决策主题，不要用“开场”“讨论”“总结”这类空泛标题。
        2. 每个一级议题下再归纳 2-5 个子议题。子议题要覆盖该议题里的主要观点、分歧、结论、风险、数据或背景。
        3. 对每个子议题，优先写“结论/共识/决策”，再写支撑原因；没有结论时明确写“尚未形成结论”。
        4. 待办事项只能来自转写中明确或高度暗示的行动，不确定负责人和时间留空。
        5. 会议纪要要像正式会议纪要，不要像聊天摘要；删除口头禅、重复、寒暄和识别噪声。
        6. 不要编造没有出现的项目名、负责人、日期、指标或结论。
        7. 先输出 topics，再输出 summary/keyPoints/mindMap/minutes/actionItems。除非内容确实跨主题，否则所有字段必须引用同一批一级议题，不能各自发散。

        事实优先级：
        - 最高优先级：用户人工确认、中枢复核 accepted/corrected、已安全应用到可信转写的修正。
        - 高优先级：会议材料、PPT、会议通知、手写稿、OCR、原图理解支持的事实。
        - 中优先级：多路 ASR 一致内容。
        - 低优先级：单路 ASR、证据不足内容、被标记低风险或忽略的内容。
        - 用户整理偏好只能影响表达结构和组织方式，不能改变事实判断，不能覆盖人工确认、中枢复核、可信转写和证据链结果。
        - 不得把待确认内容写成确定结论；不得重新引入被修正前的错误候选；不得把已忽略或已拒绝内容写入正式成果。
        - 信息不足、证据冲突或结构不支持单独待确认字段时，写“待确认”并放入 evidenceNotes。

        结构图要求：
        - mindMap 的一级节点必须是“大框/主题框”。
        - 每个一级节点的 children 是“小框/子议题框”。
        - 子议题框下面可以再放“结论：...”“依据：...”“待办：...”。
        - 如果转写本身混乱，也要按语义重新归类，而不是照时间顺序堆文本。

        一致性要求：
        - topics 是唯一事实主干。summary 中提到“几点/几方面/几个问题”时，数量和名称必须对应 topics 的一级议题。
        - keyPoints 必须按 topics 顺序组织，每条前缀使用“【一级议题】”。
        - minutes 必须按 topics 顺序组织，每条前缀使用“【一级议题】”。
        - actionItems 如能归属议题，task 前缀使用“【一级议题】”。
        - 不允许把一级议题降到三级，也不允许把细节提升成一级议题。一级议题是“会议在解决的问题”，子议题是“围绕这个问题讨论了什么”。
        - 如果发现摘要和结构图会不一致，优先修改摘要，使它服从 topics。

        请只返回 JSON，不要 Markdown，不要解释。
        JSON schema:
        {
          "topics": [
            {
              "id": "T1",
              "title": "一级议题大框",
              "summary": "本议题的一句话结论或状态",
              "subtopics": [
                {
                  "title": "子议题小框",
                  "conclusion": "结论/共识/未决状态",
                  "evidence": ["支撑依据、讨论原因或转写里的关键信息"],
                  "risks": ["风险、分歧或依赖，没有则空数组"]
                }
              ]
            }
          ],
          "summary": "一段 150-260 字的会议摘要，必须按 topics 的一级议题概括会议目的、核心结论、未决问题和下一步",
          "keyPoints": ["【一级议题】关键结论或主要观点"],
          "mindMap": [{"title": "一级议题大框", "children": [{"title": "子议题小框", "children": [{"title": "结论/依据/风险/待办", "children": []}]}]}],
          "minutes": ["【一级议题】正式会议纪要条目，包含讨论背景、结论、决策或未决事项"],
          "actionItems": [{"task": "待办事项", "owner": "负责人，没有则为空字符串", "due": "截止时间，没有则为空字符串"}],
          "evidenceNotes": ["【来源】说明该结论来自转写、图片证据、文本材料，或多模态融合判断"]
        }
        """
    }

    private var compactSystemPrompt: String {
        """
        你是会议成果包助手。请返回结构化 JSON，但不要把成果包简化成摘要。
        逐字稿由系统单独保留，你只负责纪要、结构图、要点、待办和证据说明。
        事实优先级必须固定：用户人工确认、中枢复核 accepted/corrected、已安全应用到可信转写的修正最高；会议材料/PPT/通知/手写稿/OCR/原图理解支持的事实次之；多路 ASR 一致内容再次；单路 ASR、证据不足、低风险或忽略内容最低。
        用户整理偏好只能影响表达结构，不能覆盖人工确认、中枢复核、可信转写和证据链结果。
        不得编造会议中未出现的信息，不得把待确认内容写成确定结论，不得重新引入被修正前的错误候选，不得把已忽略或已拒绝内容写入正式成果。信息不足时写“待确认”并放入 evidenceNotes。
        保留 4-8 个一级议题；每个一级议题保留 2-4 个关键子议题。
        每个子议题保留结论、关键依据和风险；可以压缩措辞，但不能省略重要议题。
        summary 控制在 150-260 字。
        keyPoints 建议 6-10 条；minutes 必须覆盖所有一级议题，建议 8-14 条；actionItems 保留所有明确行动。
        mindMap 必须返回，结构要与 topics 一致。
        只返回 JSON，不要 Markdown，不要解释。
        JSON schema:
        {
          "topics": [{"id":"T1","title":"一级议题","summary":"一句话","subtopics":[{"title":"子议题","conclusion":"结论","evidence":["依据1","依据2"],"risks":["风险"]}]}],
          "summary":"摘要",
          "keyPoints":["【一级议题】要点"],
          "mindMap":[{"title":"一级议题大框","children":[{"title":"子议题小框","children":[{"title":"结论/依据/风险/待办","children":[]}]}]}],
          "minutes":["【一级议题】纪要"],
          "actionItems":[{"task":"待办","owner":"","due":""}],
          "evidenceNotes":["【来源】一句话说明"]
        }
        """
    }

    private var visualEvidenceSystemPrompt: String {
        """
        你是 MeetingTruth 的 Gemma 4 视觉证据提取器。你只能使用输入图片和少量转写提示，不允许编造图片中看不到的信息。
        对每张图片分别提取：摘要、参会人员/姓名/角色、数字/百分比/编号、术语关键词、疑似行动项、版式结构、圈注/箭头/提示框等视觉标记，并给出 high/medium/low 置信度。
        这不是 OCR 任务。你必须优先描述只有看原图才能知道的事实：位置关系、层级、框选、圈注、箭头指向、表格结构、手写强调、截图界面状态、谁和谁被放在同一区域。
        手写内容看不清时要明确写“不确定”或降低置信度。只有非常清楚的数字、专名、术语才能给 high；模糊手写、可能误读、依赖上下文猜测的内容必须给 medium 或 low。
        participants 必须只放图片中明确可见的参会者、姓名、昵称、组织或角色；看不清不要猜。人名证据会用于 ASR 错名校验。
        numbers、keywords 和 participants.name 将被用户确认后用于 ASR 热词迭代，因此不要放入长句、解释或不确定猜测。
        layout_cues 写图片里能影响理解的结构，例如标题/分栏/流程/表格/层级/靠近关系。
        visual_marks 写圈注、箭头、框选、下划线、颜色强调、便签、提示框等视觉标记，以及它们指向什么。
        ocr_contrast 用一句话说明：如果只把图片当 OCR 文本，会丢失哪些版式、圈注、箭头、提示框或空间关系。
        只返回 JSON，不要 Markdown，不要解释。

        JSON schema:
        {
          "evidence": [
            {
              "material_name": "图片文件名",
              "summary": "图片中可见内容摘要",
              "participants": [{"name": "图片中明确可见的人名或参会者", "role": "角色/职位，没有则空字符串", "organization": "组织/部门，没有则空字符串", "evidence": "来自图片哪个区域或文字", "confidence": "high | medium | low"}],
              "numbers": ["数字、百分比、编号"],
              "keywords": ["术语、项目名或关键词；人名单独放 participants"],
              "action_hints": ["疑似待办或决策线索"],
              "layout_cues": ["标题/分栏/层级/表格/流程等版式证据"],
              "visual_marks": ["圈注/箭头/提示框/框选等视觉标记"],
              "ocr_contrast": "仅 OCR 文本分析会丢失什么",
              "confidence": "high | medium | low"
            }
          ]
        }
        """
    }

    private var centralReviewSystemPrompt: String {
        """
        你是 MeetingTruth 的 Gemma 4 多模态中枢复核引擎，不是普通会议摘要助手。

        你的任务是把多路 ASR、OCR 基线、文本/PDF 材料、已提取的图片视觉证据、冲突卡、事实台账、人工确认和已生成成果包放在同一张复核账本里交叉核验。专业 ASR 和 OCR 已经做完底层识别；你要使用 Gemma 4 的多模态能力做融会贯通的事实判断，尤其要直接阅读 image_url 原图中的版式、手写、箭头、圈注、表格行列、截图状态和空间关系。

        human_confirmations 是最高优先级证据。用户已经确认过的事实、原文变体、候选词或中枢裁决，不得在后续轮次重新标记为 needsHumanReview、conflicted 或 missing；应作为 human 证据进入支持证据和 final_verdict。

        必须按固定轮次执行：
        1. raw_image_understanding：逐张看原图，提取 OCR 看不到或容易误解的视觉事实。
        2. ocr_vs_raw_correction：把 OCR 基线和原图理解对比，指出 OCR 可能误读、漏掉或无法表达的内容。
        3. candidate_validity_review：先判断事实台账里的每个候选是否真的是可写入成果包的事实。语气词、连词、句子碎片、泛泛表达、口头填充、仅因正则误切得到的“人名/负责人”必须标记 rejected，不得继续进入支持证据裁决。
        4. support_review：为每个有效关键事实找支持证据，区分 ASR、OCR、原图、文本材料、冲突卡和人工确认。ASR 多路重复只证明“说过这段话”，不能单独证明它是人名、负责人或正式事实。
        5. challenge_review：主动寻找反证、冲突、缺少来源和高风险事实。
        6. final_verdict：只给可追溯结论；证据不足时标记 needsHumanReview / conflicted / missing；无效候选标记 rejected；不允许猜。

        高风险事实包括人名、角色、项目名、金额/数字、日期、负责人、截止时间、正式决策、待办和风险。高风险事实必须有跨来源证据、原图明确证据、文本材料证据或人工确认，否则必须 requires_human_review。人名/负责人必须由材料名单、原图参会人、明确“姓名+动作/职务”的上下文或人工确认支持；语气词、连词、介词、口头填充、修饰短语、半截句和正则误切片段必须 rejected。

        图片 OCR 只能作为 imageOCR 基线，不是 rawVision。只有直接依赖 image_url 原图视觉事实的证据，channel 才能写 rawVision。

        只返回 JSON，不要 Markdown，不要解释。
        JSON schema:
        {
          "input_summary": ["本次复核输入概览"],
          "visual_observations": [
            {
              "material_name": "图片名",
              "material_role": "白板/手写纪要/群聊截图/会议材料/未知",
              "summary": "原图理解摘要",
              "layout_cues": ["版式/层级/表格/空间关系"],
              "visual_marks": ["箭头/圈注/框选/手写/颜色强调"],
              "action_hints": ["原图中暗示的待办或决策"],
              "ocr_baseline": "OCR 基线文字摘要，没有则空",
              "ocr_contrast": "OCR 与原图理解的差异",
              "confidence": "high | medium | low"
            }
          ],
          "claims": [
            {
              "kind": "person | amount | date | owner | project | decision | actionItem | risk | term",
              "claim": "待复核事实",
              "proposed_canonical_text": "建议写入可信逐字稿/成果包的标准说法；不确定则写当前说法",
              "source_span": "可信逐字稿或 ASR 中可被替换的原始片段；没有则空",
              "status": "accepted | corrected | conflicted | missing | needsHumanReview | rejected",
              "confidence": 0.0,
              "importance": "low | medium | high",
              "risk_level": "low | medium | high",
              "supporting_evidence": [{"channel":"asr | imageOCR | rawVision | material | conflict | human | generatedPackage","source_name":"来源","text":"证据文本","visual_cue":"视觉依据，没有则空","confidence":0.0}],
              "contradicting_evidence": [{"channel":"asr | imageOCR | rawVision | material | conflict | human | generatedPackage","source_name":"来源","text":"反证文本","visual_cue":"视觉依据，没有则空","confidence":0.0}],
              "missing_evidence": ["缺什么证据"],
              "human_question": "需要问人的具体问题；不需要则空",
              "decision_reason": "裁决理由"
            }
          ],
          "gaps": [{"kind":"missingOwner | missingDueDate | unsupportedHighRiskFact | ocrRawVisionMismatch | packageTraceability | noRawVision | noCrossModalEvidence","title":"缺口标题","detail":"缺口说明","requires_human_review":true}],
          "package_audit_notes": ["如果已有成果包，检查每条输出是否可追溯；没有成果包则说明生成前门禁状态"],
          "completion_standard": ["本轮复核完成标准"]
        }
        """
    }

    private var conflictResolverSystemPrompt: String {
        """
        你是 MeetingTruth 的 Gemma 4 语义校验器。你的任务不是总结会议，而是在生成纪要之前校验多源 ASR 冲突。

        规则：
        1. 对每个冲突逐条判断，必须保留输入 conflict_id。
        2. 优先使用会议材料、术语表和上下文作为证据，不允许编造证据。
        3. 金额、日期、人名和关键项目名只要证据不足，就将 confidence 设为 low，need_human_review 设为 true。
        4. 即使多个 ASR 一致，如果证据不足，也不能假装确定。
        5. recommendation 必须是适合直接写入清洁逐字稿的短文本。
        6. 只返回 JSON，不要 Markdown，不要解释。

        JSON schema:
        {
          "resolutions": [
            {
              "conflict_id": "输入 id",
              "recommendation": "建议文本",
              "confidence": "high | medium | low",
              "need_human_review": true,
              "evidence": "判断依据或需要人工确认的原因"
            }
          ]
        }
        """
    }

    private var fullContextConflictReviewSystemPrompt: String {
        """
        你是 MeetingTruth 的全文复核器。前一步只在局部差异窗口里发现了 ASR 冲突；你的任务是带着这些冲突回看会议全文和材料，判断后文、前文或重复追问中是否已经给出答案。

        规则：
        1. 必须保留输入 conflict_id，不要新增冲突。
        2. 重点查找：同一个问题在不同位置反复询问、后面补充回答、主持人确认、材料中给出标准写法、前文定义过简称。
        3. 如果全文里已经能稳定回答，recommendation 写可直接进入清洁逐字稿的短文本，confidence 可设为 high 或 medium，并在 evidence 说明“来自全文复核”及关键依据。
        4. 如果全文仍然不能确定，保持或降低为 low，need_human_review=true，并说明缺哪类证据。
        5. 金额、日期、人名、项目名不能靠猜；必须有全文、图片参会人员名单、OCR 或材料证据才可提高置信度。图片中明确可见的参会人员优先作为人名标准写法。
        6. 只返回 JSON，不要 Markdown，不要解释。

        JSON schema:
        {
          "resolutions": [
            {
              "conflict_id": "输入 id",
              "recommendation": "建议文本",
              "confidence": "high | medium | low",
              "need_human_review": true,
              "evidence": "全文复核依据或仍需人工确认的原因"
            }
          ]
        }
        """
    }

    private var conflictDiscoverySystemPrompt: String {
        """
        你是 MeetingTruth 的 ASR 差异裁判。输入已经由本地程序筛选为同一位置的小窗口，不要重新总结全文。
        只输出会影响纪要准确性的专业词、金额/数字、人名、日期、项目名差异。最多输出 4 个最重要冲突。
        证据不足的金额、日期、人名和项目名必须 confidence=low。若图片/材料里有参会人员名单或标准写法，必须用它和 ASR 候选逐项交叉核对。没有关键冲突时返回 {"conflicts":[]}。
        timestamp 只能沿用输入中的明确时间戳；没有时间戳就写“片段”。context、recommendation、evidence 每项只写一句短句。
        只返回 JSON，不要 Markdown，不要解释。

        JSON schema:
        {"conflicts":[{"timestamp":"片段","kind":"terminology | amount | person | date | project","context":"短上下文","candidates":[{"source":"来源","text":"候选"}],"recommendation":"建议文本","confidence":"high | medium | low","evidence":"短依据"}]}
        """
    }

    private func conflictResolverUserMessage(
        conflicts: [MeetingTruthConflict],
        materials: [MeetingTruthMaterial]
    ) throws -> ChatRequestMessage {
        let input = MeetingTruthConflictRequestPayload(
            materials: materials.map {
                .init(name: $0.name, kind: $0.kind, detail: $0.detail, extractedText: $0.extractedText)
            },
            conflicts: conflicts.map {
                .init(
                    conflictID: $0.id.uuidString,
                    timestamp: $0.timestamp,
                    kind: $0.kind.rawValue,
                    context: $0.context,
                    candidates: $0.candidates.map {
                        .init(source: $0.source, text: $0.text)
                    }
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(input)
        guard let json = String(data: data, encoding: .utf8) else {
            throw MeetingAIError.invalidJSON
        }
        return multimodalUserMessage(
            text: "请校验以下会议冲突：\n\(json)",
            materials: materials,
            imageInstruction: "以下图片是会议材料原图，请直接使用 Gemma 的视觉能力理解图片内容，并结合冲突进行判断。"
        )
    }

    private func fullContextConflictReviewUserMessage(
        conflicts: [MeetingTruthConflict],
        sources: [MeetingTruthTranscriptSource],
        materials: [MeetingTruthMaterial],
        settings: MeetingAISettings
    ) throws -> ChatRequestMessage {
        let sourceLimit = fullContextSourceLimit(settings: settings, sourceCount: sources.count)
        let materialLimit = usesLargeGemmaContext(settings.model) ? 4_000 : 1_800
        let input = MeetingTruthFullContextConflictReviewPayload(
            materials: materials.map {
                .init(
                    name: $0.name,
                    kind: $0.kind,
                    detail: $0.detail,
                    extractedText: String($0.extractedText.prefix(materialLimit))
                )
            },
            sources: sources.map {
                .init(name: $0.name, text: String($0.text.prefix(sourceLimit)))
            },
            conflicts: conflicts.map {
                .init(
                    conflictID: $0.id.uuidString,
                    timestamp: $0.timestamp,
                    kind: $0.kind.rawValue,
                    context: $0.context,
                    candidates: $0.candidates.map {
                        .init(source: $0.source, text: $0.text)
                    },
                    currentRecommendation: $0.recommendation,
                    currentConfidence: $0.confidence.rawValue,
                    currentEvidence: $0.evidence
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(input)
        guard let json = String(data: data, encoding: .utf8) else {
            throw MeetingAIError.invalidJSON
        }
        return multimodalUserMessage(
            text: "请带着这些冲突回看会议全文，寻找前后文、重复追问和后续确认中能解决冲突的证据：\n\(json)",
            materials: materials,
            imageInstruction: "以下图片是会议材料原图。若文本材料不足，请直接读图，并把图片证据作为全文复核的一部分。"
        )
    }

    private func conflictDiscoveryUserMessage(
        sources: [MeetingTruthTranscriptSource],
        materials: [MeetingTruthMaterial],
        sourceCharacterLimit: Int,
        materialCharacterLimit: Int
    ) throws -> ChatRequestMessage {
        let input = MeetingTruthConflictDiscoveryRequestPayload(
            materials: materials.map {
                .init(
                    name: $0.name,
                    kind: $0.kind,
                    detail: $0.detail,
                    extractedText: String($0.extractedText.prefix(materialCharacterLimit))
                )
            },
            sources: sources.map {
                .init(name: $0.name, text: String($0.text.prefix(sourceCharacterLimit)))
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(input)
        guard let json = String(data: data, encoding: .utf8) else {
            throw MeetingAIError.invalidJSON
        }
        return multimodalUserMessage(
            text: "请发现以下多源转写中的关键冲突：\n\(json)",
            materials: materials,
            imageInstruction: "以下图片是会议现场截图、白板、群聊截图或材料原图，请直接使用 Gemma 的视觉能力识别关键信息，并与多份转写交叉核对。"
        )
    }

    private func decodeConflictResolutions(
        from content: String,
        originalConflicts: [MeetingTruthConflict]
    ) throws -> [MeetingTruthConflict] {
        let jsonText = extractJSONObject(from: content)
        guard let data = jsonText.data(using: .utf8) else {
            throw MeetingAIError.invalidJSON
        }
        let payload = try JSONDecoder().decode(MeetingTruthConflictResponsePayload.self, from: data)
        let resolutions = Dictionary(uniqueKeysWithValues: payload.resolutions.map { ($0.conflictID, $0) })

        return originalConflicts.map { conflict in
            guard let resolution = resolutions[conflict.id.uuidString] else { return conflict }
            var updated = conflict
            updated.recommendation = resolution.recommendation
            updated.confidence = MeetingTruthConfidence(rawValue: resolution.confidence) ?? .low
            if resolution.needHumanReview {
                updated.confidence = .low
            }
            updated.evidence = resolution.evidence
            updated.selectedText = nil
            return updated
        }
    }

    private func decodeDiscoveredConflicts(
        from content: String,
        forceSegmentLocations: Bool,
        segmentOffset: Int = 0
    ) throws -> [MeetingTruthConflict] {
        let jsonText = extractJSONObject(from: content)
        guard let data = jsonText.data(using: .utf8) else {
            throw MeetingAIError.invalidJSON
        }
        let payload = try JSONDecoder().decode(MeetingTruthConflictDiscoveryResponsePayload.self, from: data)
        return payload.conflicts.enumerated().map { index, conflict in
            MeetingTruthConflict(
                timestamp: forceSegmentLocations ? "片段 \(segmentOffset + index + 1)" : conflict.timestamp,
                kind: MeetingTruthConflictKind(rawValue: conflict.kind) ?? .terminology,
                context: conflict.context,
                candidates: conflict.candidates.map {
                    MeetingTruthCandidate(source: $0.source, text: $0.text)
                },
                recommendation: conflict.recommendation,
                confidence: MeetingTruthConfidence(rawValue: conflict.confidence) ?? .low,
                evidence: conflict.evidence
            )
        }
    }

    private var mergeSystemPrompt: String {
        """
        你是会议纪要汇总助手。你会收到多个“分段会议整理 JSON”，每个 JSON 只覆盖原会议的一部分。
        你的任务是把它们合并成一个完整的会议纪要 JSON。

        合并要求：
        1. 合并同名或高度相近的一级议题，不要重复列出。
        2. 保留所有阶段的重要议题，不能因为前半段信息更丰富就忽略后半段。
        3. summary 必须覆盖整场会议，而不是只总结前几个议题。
        4. keyPoints、minutes、actionItems 必须覆盖从头到尾的重要内容；不要只保留 5-6 条概括。
        5. topics 保持 4-10 个一级议题，每个一级议题最多 4 个子议题。
        6. minutes 必须按 topics 顺序覆盖所有一级议题，建议 8-16 条。
        7. mindMap 必须返回，并与 topics 使用同一批一级议题。
        8. 合并时继续遵守事实优先级：人工确认、中枢复核 accepted/corrected 和已应用到可信转写的修正最高；材料/OCR/原图事实高于多路 ASR；多路 ASR 高于单路 ASR；证据不足、低风险、忽略或已拒绝内容不得写成正式结论。
        9. 用户整理偏好只能影响表达结构，不能改变事实判断。不得编造未出现信息，不得覆盖人工确认或中枢复核，不得重新引入被修正前的错误候选；信息不足写“待确认”并放入 evidenceNotes。
        10. 只返回 JSON，不要 Markdown，不要解释。

        JSON schema:
        {
          "topics": [{"id":"T1","title":"一级议题","summary":"一句话","subtopics":[{"title":"子议题","conclusion":"结论","evidence":["依据1","依据2"],"risks":["风险"]}]}],
          "summary":"摘要",
          "keyPoints":["【一级议题】要点"],
          "mindMap": [{"title":"一级议题大框","children":[{"title":"子议题小框","children":[{"title":"结论/依据/风险/待办","children":[]}]}]}],
          "minutes":["【一级议题】纪要"],
          "actionItems":[{"task":"待办","owner":"","due":""}],
          "evidenceNotes":["【来源】一句话说明"]
        }
        """
    }

    private func analysisUserPrompt(transcript: String, settings: MeetingAISettings, refinementInstructions: String) -> String {
        let defaults = settings.defaultOrganizationInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        let refinement = refinementInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        默认整理偏好：
        \(defaults.isEmpty ? "无" : defaults)

        整理偏好边界：
        上述偏好只用于控制纪要、摘要、要点、待办和思维导图的表达结构。它不能覆盖可信转写、人工确认、中枢复核 accepted/corrected、已安全应用的修正、会议材料/OCR/原图证据和证据备注。若偏好与事实核验结果冲突，必须服从事实核验结果；证据不足或冲突时写“待确认”或放入 evidenceNotes。

        本次补充背景/纠偏要求：
        \(refinement.isEmpty ? "无" : refinement)

        会议转写全文：
        \(transcript)
        """
    }

    private func visualEvidenceUserMessage(
        materials: [MeetingTruthMaterial],
        transcriptHints: [MeetingTruthTranscriptSource]
    ) -> ChatRequestMessage {
        let transcriptHint = transcriptHints
            .prefix(2)
            .map { "【\($0.name)】\n\(String($0.text.prefix(800)))" }
            .joined(separator: "\n\n")
        let text = """
        请读取以下图片材料。少量转写提示只用于理解会议背景，不能替代图片内容。

        转写提示：
        \(transcriptHint.isEmpty ? "无" : transcriptHint)
        """
        return multimodalUserMessage(
            text: text,
            materials: materials,
            imageInstruction: "以下图片是参赛多模态输入。请直接读原图，不要只做 OCR；必须关注手写内容、版式层级、圈注、箭头、框选、提示框和空间关系如何影响会议结论。"
        )
    }

    @MainActor
    private func requestCentralReviewToolCalls(
        url: URL,
        transcriptSources: [MeetingTruthTranscriptSource],
        materials: [MeetingTruthMaterial],
        visualEvidence: [MeetingTruthVisualEvidence],
        conflicts: [MeetingTruthConflict],
        factDecisions: [MeetingTruthFactDecision],
        manualConfirmations: [MeetingTruthManualConfirmation],
        currentLedger: MeetingTruthCentralReviewLedger?,
        analysis: MeetingAnalysis?,
        settings: MeetingAISettings
    ) async throws -> MeetingTruthToolCallingRun {
        var messages = [
            ChatRequestMessage(role: "system", content: centralReviewToolCallingSystemPrompt),
            centralReviewToolCallingUserMessage(
                transcriptSources: transcriptSources,
                materials: materials,
                visualEvidence: visualEvidence,
                conflicts: conflicts,
                factDecisions: factDecisions,
                manualConfirmations: manualConfirmations,
                currentLedger: currentLedger,
                analysis: analysis
            )
        ]
        var finalRecords: [MeetingTruthToolCallRecord] = []
        var tokenUsage: MeetingTruthTokenUsage?
        var fallbackContent = ""

        for _ in 0..<8 {
            let completion = try await requestCompletion(
                url: url,
                settings: settings,
                messages: messages,
                maxTokens: min(max(settings.resolvedMaxTokens, 900), 2_400),
                tools: centralReviewToolDefinitions,
                toolChoice: "auto"
            )
            tokenUsage = tokenUsage?.merged(with: completion.usage?.meetingTruthUsage) ?? completion.usage?.meetingTruthUsage
            guard let message = completion.choices.first?.message else { break }
            fallbackContent = message.content

            if !message.toolCalls.isEmpty {
                messages.append(.assistantToolCalls(message.toolCalls))
                let nativeCalls = message.toolCalls.map {
                    MeetingTruthRequestedToolCall(
                        id: $0.id,
                        name: $0.function.name,
                        arguments: $0.function.arguments,
                        invocationSource: .nativeToolCall
                    )
                }
                let nativeRecords = executeCentralReviewToolCalls(
                    nativeCalls,
                    transcriptSources: transcriptSources,
                    materials: materials,
                    visualEvidence: visualEvidence,
                    conflicts: conflicts,
                    factDecisions: factDecisions,
                    manualConfirmations: manualConfirmations
                )
                finalRecords.append(contentsOf: nativeRecords)
                for (call, record) in zip(nativeCalls, nativeRecords) {
                    messages.append(.toolResult(
                        toolCallID: call.id ?? call.name,
                        name: call.name,
                        content: toolResultContent(for: record)
                    ))
                }
                continue
            }

            let textCalls = parseStructuredToolCalls(from: message.content)
            if !textCalls.isEmpty && finalRecords.isEmpty {
                let fallbackCalls = evidenceToolChainCalls(textCalls).enumerated().map { index, call in
                    MeetingTruthRequestedToolCall(
                        id: "json-fallback-\(index + 1)",
                        name: call.name,
                        arguments: call.arguments,
                        invocationSource: call.invocationSource
                    )
                }
                messages.append(.assistantToolCalls(fallbackCalls.map {
                    ChatToolCall(
                        id: $0.id,
                        type: "function",
                        function: .init(name: $0.name, arguments: $0.arguments)
                    )
                }))
                let fallbackRecords = executeCentralReviewToolCalls(
                    fallbackCalls,
                    transcriptSources: transcriptSources,
                    materials: materials,
                    visualEvidence: visualEvidence,
                    conflicts: conflicts,
                    factDecisions: factDecisions,
                    manualConfirmations: manualConfirmations
                )
                finalRecords.append(contentsOf: fallbackRecords)
                for (call, record) in zip(fallbackCalls, fallbackRecords) {
                    messages.append(.toolResult(
                        toolCallID: call.id ?? call.name,
                        name: call.name,
                        content: toolResultContent(for: record)
                    ))
                }
                continue
            }
            break
        }

        if finalRecords.isEmpty {
            let textCalls = parseStructuredToolCalls(from: fallbackContent)
            finalRecords = executeCentralReviewToolCalls(
                evidenceToolChainCalls(textCalls),
                transcriptSources: transcriptSources,
                materials: materials,
                visualEvidence: visualEvidence,
                conflicts: conflicts,
                factDecisions: factDecisions,
                manualConfirmations: manualConfirmations
            )
        } else {
            let executedNames = Set(finalRecords.map(\.functionName))
            let missingCalls = evidenceToolChainCalls([])
                .filter { !executedNames.contains($0.name) }
            let supplementalRecords = executeCentralReviewToolCalls(
                missingCalls,
                transcriptSources: transcriptSources,
                materials: materials,
                visualEvidence: visualEvidence,
                conflicts: conflicts,
                factDecisions: factDecisions,
                manualConfirmations: manualConfirmations
            )
            finalRecords.append(contentsOf: supplementalRecords)
        }
        return MeetingTruthToolCallingRun(
            records: finalRecords,
            comparison: toolCallingComparison(
                records: finalRecords,
                currentLedger: currentLedger,
                transcriptSources: transcriptSources,
                materials: materials,
                visualEvidence: visualEvidence,
                factDecisions: factDecisions
            ),
            tokenUsage: tokenUsage
        )
    }

    private var centralReviewToolCallingSystemPrompt: String {
        """
        You are Gemma 4 running MeetingTruth native function calling as an evidence-driven meeting fact adjudicator. Do not produce the final review ledger in this turn.
        Use tools to reduce context and force evidence-backed decisions. Do not ask tools to perform shallow claim contains lookup.
        Prefer this chain: extract_meeting_fact_candidates -> filter_reviewable_facts -> detect_asr_conflicts -> retrieve_supporting_evidence -> score_fact_candidates -> make_fact_decision -> create_human_review_task only when the decision is conflicted or needsHumanReview.
        Use the first two tools as the semantic risk-admission gate. Do not allow generic process phrases, oral fillers, tool evaluations, or ordinary verb phrases to become human confirmation tasks.
        Use the remaining tools for high-risk ASR disagreement, image/material/glossary grounding, candidate scoring, final fact decisions, and human confirmation tasks.
        Use native tool calls. The request already includes a tools array, so do not write a JSON object named tool_calls in message content.
        Return normal content only after tool results have been provided by the system. Do not include Markdown or explanations.
        """
    }

    private var centralReviewToolDefinitions: [ChatToolDefinition] {
        [
            toolDefinition(
                name: "extract_meeting_fact_candidates",
                description: "Semantically extract only meeting facts that may affect final outputs. Reject oral fillers, connectors, generic process phrases, tool evaluations, ordinary verb phrases, and snippets without a clear subject.",
                properties: [
                    "window_hint": "Optional topic, time, or phrase hint for compressed meeting windows.",
                    "output_focus": "minutes, action_items, participants, project_names, risk_list, evidence_note, or none."
                ],
                required: []
            ),
            toolDefinition(
                name: "filter_reviewable_facts",
                description: "Admission gate for fact candidates. Only keep explicit person/owner, date/time, amount/number, project/system name, decision, action item, risk/issue, ASR high-risk conflict, or material/image-vs-ASR conflict.",
                properties: [
                    "candidate_hint": "Optional candidate text or id to filter.",
                    "rejection_policy": "Low-value rules to apply before evidence adjudication."
                ],
                required: []
            ),
            toolDefinition(
                name: "detect_asr_conflicts",
                description: "Find important differences from aligned ASR windows. Output candidates, conflict type, risk, and whether the difference affects meeting minutes. Do not use claim contains.",
                properties: [
                    "window_hint": "Optional time, topic, or phrase hint for the ASR window to inspect."
                ],
                required: []
            ),
            toolDefinition(
                name: "retrieve_supporting_evidence",
                description: "Retrieve evidence for conflict candidates from meeting notice, handwritten notes, PPT/materials, glossary, image OCR, Gemma raw image understanding, ASR, and human confirmation. Return support_type values: supports, contradicts, partial_support, contextual_hint, absence_not_evidence, not_applicable, unknown.",
                properties: [
                    "conflict_id": "Conflict id returned by detect_asr_conflicts. Empty means use the highest-risk conflict.",
                    "candidates": "Optional comma-separated candidates to ground."
                ],
                required: []
            ),
            toolDefinition(
                name: "score_fact_candidates",
                description: "Score candidate facts with fact-type-aware evidence weights. MiMo is the primary content draft, Qwen3 is the timeline anchor, GLM is auxiliary reference. Do not majority-vote ASR and do not auto-apply high-risk facts without an evidence_chain.",
                properties: [
                    "conflict_id": "Conflict id returned by detect_asr_conflicts. Empty means score the highest-risk conflict."
                ],
                required: []
            ),
            toolDefinition(
                name: "make_fact_decision",
                description: "Make a standard fact decision from candidate scores and risk rules. Status must be accepted, corrected, conflicted, needsHumanReview, or rejected. Return final_text, confidence, enter_minutes, evidence_chain, explanation.",
                properties: [
                    "conflict_id": "Conflict id returned by detect_asr_conflicts. Empty means decide the highest-scoring conflict."
                ],
                required: []
            ),
            toolDefinition(
                name: "create_human_review_task",
                description: "Create a user-facing confirmation task only when make_fact_decision outputs conflicted or needsHumanReview.",
                properties: [
                    "conflict_id": "Conflict id returned by detect_asr_conflicts. Empty means use the highest-risk unresolved conflict.",
                    "reason": "Why human confirmation is required."
                ],
                required: []
            )
        ]
    }

    private func toolDefinition(
        name: String,
        description: String,
        properties: [String: String],
        required: [String]
    ) -> ChatToolDefinition {
        ChatToolDefinition(
            function: .init(
                name: name,
                description: description,
                parameters: .init(
                    properties: properties.mapValues { .init(type: "string", description: $0) },
                    required: required
                )
            )
        )
    }

    private func centralReviewToolCallingUserMessage(
        transcriptSources: [MeetingTruthTranscriptSource],
        materials: [MeetingTruthMaterial],
        visualEvidence: [MeetingTruthVisualEvidence],
        conflicts: [MeetingTruthConflict],
        factDecisions: [MeetingTruthFactDecision],
        manualConfirmations: [MeetingTruthManualConfirmation],
        currentLedger: MeetingTruthCentralReviewLedger?,
        analysis: MeetingAnalysis?
    ) -> ChatRequestMessage {
        let highRiskClaims = factDecisions
            .filter { $0.riskLevel == .high || $0.requiresUserInput }
            .prefix(10)
            .map { "\($0.kind.title)：\($0.chosenText)；状态：\($0.status.title)；缺口：\($0.missingEvidence.joined(separator: "；"))" }
            .joined(separator: "\n")
        let conflictSummary = conflicts.prefix(8).map {
            "\($0.kind.title)：\($0.context)；建议：\($0.recommendation)；置信度：\($0.confidence.title)"
        }.joined(separator: "\n")
        let roleSummary = transcriptSources.prefix(6).map {
            "\(Self.factSafeSourceLabel($0.name))：\(Self.asrRole(for: $0).title)，\($0.hasTimestamp ? "可作时间窗口定位" : "无可靠时间戳")"
        }.joined(separator: "\n")
        let imageSummary = materials.filter(isImageMaterial).prefix(6).map { material in
            let hasVision = visualEvidence.contains { $0.materialID == material.id || $0.materialName == material.name }
            let hasOCR = !material.extractedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return "\(material.name)：OCR=\(hasOCR ? "yes" : "no") rawVision=\(hasVision ? "yes" : "no")"
        }.joined(separator: "\n")
        let text = """
        Decide which MeetingTruth evidence adjudication tools to call before final central review.

        Inputs:
        - ASR candidates: \(transcriptSources.count)
        - materials: \(materials.count), images: \(materials.filter(isImageMaterial).count)
        - visual evidence records: \(visualEvidence.count)
        - conflicts: \(conflicts.count)
        - fact decisions: \(factDecisions.count)
        - human confirmations: \(manualConfirmations.count)
        - existing ledger blockers: \(currentLedger?.blockingItems.count ?? 0)
        - generated package exists: \(analysis == nil ? "no" : "yes")

        ASR source roles:
        \(roleSummary.isEmpty ? "none" : roleSummary)

        High-risk or pending claims:
        \(highRiskClaims.isEmpty ? "none" : highRiskClaims)

        Conflicts:
        \(conflictSummary.isEmpty ? "none" : conflictSummary)

        Image coverage:
        \(imageSummary.isEmpty ? "none" : imageSummary)

        Call the smallest useful chain. Stage 2 is named 检查转写冲突. Use Qwen3 only as timeline anchor, MiMo as the primary trusted transcript draft, and GLM as auxiliary reference. Continue with detect_asr_conflicts when ASR candidates disagree. Then retrieve evidence, score candidates, make a fact decision, and create human review only if required. Always prefer tool results over guessing.
        """
        return multimodalUserMessage(
            text: text,
            materials: materials,
            imageInstruction: "Original images are attached. Use retrieve_supporting_evidence to connect image/OCR/rawVision evidence to ASR candidates instead of only checking whether an image was processed."
        )
    }

    private func parseStructuredToolCalls(from content: String) -> [MeetingTruthRequestedToolCall] {
        let jsonText = extractJSONObject(from: content)
        guard let data = jsonText.data(using: .utf8),
              let payload = try? JSONDecoder().decode(MeetingTruthStructuredToolCallPayload.self, from: data) else {
            return []
        }
        return payload.toolCalls.map {
            MeetingTruthRequestedToolCall(
                id: nil,
                name: $0.name,
                arguments: (try? String(data: JSONEncoder().encode($0.arguments), encoding: .utf8)) ?? "{}",
                invocationSource: .jsonFallback
            )
        }
    }

    private func evidenceToolChainCalls(_ calls: [MeetingTruthRequestedToolCall]) -> [MeetingTruthRequestedToolCall] {
        let orderedNames = [
            "extract_meeting_fact_candidates",
            "filter_reviewable_facts",
            "detect_asr_conflicts",
            "retrieve_supporting_evidence",
            "score_fact_candidates",
            "make_fact_decision",
            "create_human_review_task"
        ]
        let valid = calls.filter { orderedNames.contains($0.name) }
        var byName: [String: MeetingTruthRequestedToolCall] = [:]
        for call in valid {
            byName[call.name] = call
        }
        return orderedNames.map { name in
            byName[name] ?? MeetingTruthRequestedToolCall(name: name, arguments: "{}", invocationSource: .autoPipeline)
        }
    }

    private func toolResultContent(for record: MeetingTruthToolCallRecord) -> String {
        let payload = MeetingTruthToolResultPayload(
            functionName: record.functionName,
            argumentsSummary: record.argumentsSummary,
            resultSummary: record.resultSummary,
            impactSummary: record.impactSummary,
            status: record.status.rawValue,
            asrConflicts: record.asrConflicts ?? [],
            evidenceChain: record.evidenceChain ?? [],
            candidateScores: record.candidateScores ?? [],
            factDecision: record.factDecision,
            humanReviewTask: record.humanReviewTask,
            affectedMinutesText: record.affectedMinutesText ?? ""
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload),
              let content = String(data: data, encoding: .utf8) else {
            return """
            {"function_name":"\(record.functionName)","status":"\(record.status.rawValue)","result_summary":"\(record.resultSummary)"}
            """
        }
        return content
    }

    private func executeCentralReviewToolCalls(
        _ calls: [MeetingTruthRequestedToolCall],
        transcriptSources: [MeetingTruthTranscriptSource],
        materials: [MeetingTruthMaterial],
        visualEvidence: [MeetingTruthVisualEvidence],
        conflicts: [MeetingTruthConflict],
        factDecisions: [MeetingTruthFactDecision],
        manualConfirmations: [MeetingTruthManualConfirmation]
    ) -> [MeetingTruthToolCallRecord] {
        calls.prefix(8).enumerated().map { index, call in
            let args = parseToolArguments(call.arguments)
            var record: MeetingTruthToolCallRecord
            switch call.name {
            case "extract_meeting_fact_candidates":
                record = extractMeetingFactCandidatesRecord(index: index + 1, args: args, transcriptSources: transcriptSources, materials: materials, visualEvidence: visualEvidence)
            case "filter_reviewable_facts":
                record = filterReviewableFactsRecord(index: index + 1, args: args, transcriptSources: transcriptSources, materials: materials, visualEvidence: visualEvidence, conflicts: conflicts)
            case "detect_asr_conflicts":
                record = detectASRConflictsRecord(index: index + 1, args: args, transcriptSources: transcriptSources, conflicts: conflicts)
            case "retrieve_supporting_evidence":
                record = retrieveSupportingEvidenceRecord(index: index + 1, args: args, transcriptSources: transcriptSources, materials: materials, visualEvidence: visualEvidence, conflicts: conflicts)
            case "score_fact_candidates":
                record = scoreFactCandidatesRecord(index: index + 1, args: args, transcriptSources: transcriptSources, materials: materials, visualEvidence: visualEvidence, conflicts: conflicts, manualConfirmations: manualConfirmations)
            case "make_fact_decision":
                record = makeFactDecisionRecord(index: index + 1, args: args, transcriptSources: transcriptSources, materials: materials, visualEvidence: visualEvidence, conflicts: conflicts, manualConfirmations: manualConfirmations)
            case "create_human_review_task":
                record = createHumanReviewTaskRecord(index: index + 1, args: args, transcriptSources: transcriptSources, materials: materials, visualEvidence: visualEvidence, conflicts: conflicts, manualConfirmations: manualConfirmations)
            default:
                record = MeetingTruthToolCallRecord(
                    callIndex: index + 1,
                    functionName: call.name,
                    argumentsSummary: compactArgumentsSummary(args),
                    resultSummary: "未知工具，未执行。",
                    impactSummary: "该调用不会影响中枢账本。",
                    status: .skipped
                )
            }
            record.invocationSource = call.invocationSource
            return record
        }
    }

    private func parseToolArguments(_ arguments: String) -> [String: String] {
        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object.reduce(into: [String: String]()) { result, pair in
            if let value = pair.value as? String {
                result[pair.key] = value
            } else {
                result[pair.key] = String(describing: pair.value)
            }
        }
    }

    private func extractMeetingFactCandidatesRecord(
        index: Int,
        args: [String: String],
        transcriptSources: [MeetingTruthTranscriptSource],
        materials: [MeetingTruthMaterial],
        visualEvidence: [MeetingTruthVisualEvidence]
    ) -> MeetingTruthToolCallRecord {
        let windows = compressedFactAdmissionWindows(
            transcriptSources: transcriptSources,
            materials: materials,
            visualEvidence: visualEvidence,
            hint: args["window_hint"]
        )
        return MeetingTruthToolCallRecord(
            callIndex: index,
            functionName: "extract_meeting_fact_candidates",
            argumentsSummary: args["window_hint"].map { "压缩会议窗口提示：\($0)" } ?? "从压缩会议窗口中做成果包风险候选发现",
            resultSummary: windows.isEmpty
                ? "未找到需要进入事实候选的会议窗口。"
                : "抽取 \(windows.count) 个候选窗口；只保留可能影响纪要、待办、参会人、项目名、风险清单或证据备注的事实。",
            impactSummary: "入口工具负责语义准入，口语词、连接词、工具评价和泛泛流程短语不会直接变成人工确认卡。",
            status: windows.isEmpty ? .skipped : .executed,
            alignmentWindows: asrAlignmentWindows(transcriptSources: transcriptSources),
            evidenceProfiles: evidenceProfiles(materials: materials, visualEvidence: visualEvidence, transcriptSources: transcriptSources)
        )
    }

    private func filterReviewableFactsRecord(
        index: Int,
        args: [String: String],
        transcriptSources: [MeetingTruthTranscriptSource],
        materials: [MeetingTruthMaterial],
        visualEvidence: [MeetingTruthVisualEvidence],
        conflicts: [MeetingTruthConflict]
    ) -> MeetingTruthToolCallRecord {
        let windows = compressedFactAdmissionWindows(
            transcriptSources: transcriptSources,
            materials: materials,
            visualEvidence: visualEvidence,
            hint: args["candidate_hint"]
        )
        let conflicts = evidenceToolConflicts(transcriptSources: transcriptSources, conflicts: conflicts)
        let admitted = windows.filter { Self.factAdmissionWindowLooksReviewable($0) }
        let rejected = max(0, windows.count - admitted.count)
        let conflictCount = conflicts.filter(\.impactsMinutes).count
        return MeetingTruthToolCallRecord(
            callIndex: index,
            functionName: "filter_reviewable_facts",
            argumentsSummary: "按成果包影响、高风险类型和低价值规则过滤候选事实",
            resultSummary: "准入 \(admitted.count) 个候选窗口；低价值拒绝 \(rejected) 个；保留 \(conflictCount) 个多路 ASR 高风险冲突进入后续裁决。",
            impactSummary: "只有准入后的候选会继续走 retrieve_supporting_evidence / score_fact_candidates / make_fact_decision；确认卡仍只能由 create_human_review_task 产生。",
            status: admitted.isEmpty && conflictCount == 0 ? .skipped : .executed,
            alignmentWindows: asrAlignmentWindows(transcriptSources: transcriptSources),
            evidenceProfiles: evidenceProfiles(materials: materials, visualEvidence: visualEvidence, transcriptSources: transcriptSources)
        )
    }

    private func evidenceProfiles(
        materials: [MeetingTruthMaterial],
        visualEvidence: [MeetingTruthVisualEvidence],
        transcriptSources: [MeetingTruthTranscriptSource]
    ) -> [MeetingTruthEvidenceProfile] {
        let materialProfiles = materials.map { material in
            let visual = visualEvidence.first { $0.materialID == material.id || $0.materialName == material.name }
            let sourceType = Self.evidenceSourceType(for: material)
            let text = material.extractedText.isEmpty ? "\(material.name) \(material.detail)" : material.extractedText
            return MeetingTruthEvidenceProfile(
                sourceID: material.id.uuidString,
                sourceType: sourceType,
                sourceTypeConfidence: sourceType == .unknown ? 0.35 : 0.78,
                title: material.name,
                extractedTextFromOCR: material.extractedText,
                visualSummaryFromGemma: visual?.summary ?? "",
                layoutCues: visual?.layoutCues ?? [],
                arrowsOrHighlights: visual?.visualMarks ?? [],
                keyEntities: Self.highRiskTokens(in: text + " " + (visual?.keywords.joined(separator: " ") ?? "")),
                participantCandidates: visual?.participants.map(\.displayText) ?? Self.personLikeTokens(in: text),
                projectOrSystemNames: Self.projectLikeTokens(in: text + " " + (visual?.keywords.joined(separator: " ") ?? "")),
                dateTimeMentions: Self.dateTimeMentions(in: text),
                amountMentions: Self.amountMentions(in: text),
                actionItemHints: visual?.actionHints ?? Self.actionHints(in: text),
                coverageScope: Self.coverageScope(for: sourceType),
                reliabilityByFactType: Self.reliabilityByFactType(for: sourceType)
            )
        }
        let transcriptProfiles = transcriptSources.map { source in
            MeetingTruthEvidenceProfile(
                sourceID: source.id.uuidString,
                sourceType: .transcript,
                sourceTypeConfidence: source.hasTimestamp ? 0.72 : 0.62,
                title: Self.factSafeSourceLabel(source.name),
                extractedTextFromOCR: "",
                visualSummaryFromGemma: "",
                layoutCues: [],
                arrowsOrHighlights: [],
                keyEntities: Self.highRiskTokens(in: source.text),
                participantCandidates: Self.personLikeTokens(in: source.text),
                projectOrSystemNames: Self.projectLikeTokens(in: source.text),
                dateTimeMentions: Self.dateTimeMentions(in: source.text),
                amountMentions: Self.amountMentions(in: source.text),
                actionItemHints: Self.actionHints(in: source.text),
                coverageScope: "\(Self.asrRole(for: source).title)：ASR 证明现场语音候选，但人名、缩写、金额和项目名需外部证据。",
                reliabilityByFactType: ["ordinary": 0.62, "term": 0.42, "person": 0.36, "amount": 0.38, "time": 0.46]
            )
        }
        return Array((materialProfiles + transcriptProfiles).prefix(16))
    }

    private static func evidenceSourceType(for material: MeetingTruthMaterial) -> MeetingTruthEvidenceSourceType {
        let text = "\(material.name) \(material.kind) \(material.detail) \(material.extractedText)".lowercased()
        if text.contains("通知") || text.contains("agenda") || text.contains("参会") { return .meetingNotice }
        if text.contains("手写") || text.contains("纪要") || text.contains("要点") || text.contains("笔记") { return .handwrittenNote }
        if text.contains("ppt") || text.contains("slide") || text.contains("汇报") || text.contains("方案") || text.contains("材料") { return .slideOrPPT }
        if text.contains("白板") || text.contains("板书") { return .whiteboard }
        if text.contains("截图") || text.contains("screenshot") { return .screenshot }
        if text.contains("术语") || text.contains("glossary") { return .glossary }
        if isImageMaterialKind(material.kind) { return .screenshot }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .unknown }
        return .otherMaterial
    }

    private static func coverageScope(for sourceType: MeetingTruthEvidenceSourceType) -> String {
        switch sourceType {
        case .meetingNotice: "适合证明会议名称、时间、地点、参会人、议题、主持人和正式名称；缺失不反驳现场实际发言。"
        case .handwrittenNote: "适合证明重点事项、待办、决策、关键术语、人名简称和时间节点；缺失不反驳 ASR。"
        case .slideOrPPT: "适合证明项目名、系统名、术语、指标、金额、政策表述和正式名称；不证明现场逐字说过。"
        case .whiteboard: "适合证明现场重点、箭头关系、圈注、手写结构和行动项线索。"
        case .screenshot: "适合证明系统界面文字和状态；截图外的会议事实只作背景。"
        case .glossary: "适合证明术语、系统名、项目名和缩写规范。"
        case .transcript: "适合证明现场语音候选；专名、缩写、金额和项目名需交叉核验。"
        case .otherMaterial: "作为背景材料使用，需结合内容类型判断适用范围。"
        case .unknown: "资料类型不明，只能作为弱背景线索。"
        }
    }

    private static func reliabilityByFactType(for sourceType: MeetingTruthEvidenceSourceType) -> [String: Double] {
        switch sourceType {
        case .meetingNotice:
            ["person": 0.88, "time": 0.86, "project": 0.76, "term": 0.70, "amount": 0.42, "ordinary": 0.20]
        case .handwrittenNote:
            ["action": 0.78, "decision": 0.78, "term": 0.70, "person": 0.68, "time": 0.64, "amount": 0.54, "ordinary": 0.24]
        case .slideOrPPT:
            ["project": 0.88, "system": 0.88, "term": 0.86, "amount": 0.78, "time": 0.56, "person": 0.42, "ordinary": 0.24]
        case .whiteboard:
            ["action": 0.72, "decision": 0.66, "term": 0.64, "project": 0.58, "person": 0.46, "amount": 0.52]
        case .screenshot:
            ["system": 0.74, "term": 0.68, "project": 0.62, "amount": 0.54, "ordinary": 0.30]
        case .glossary:
            ["term": 0.96, "system": 0.94, "project": 0.92, "person": 0.22, "ordinary": 0.12]
        case .transcript:
            ["ordinary": 0.62, "action": 0.54, "decision": 0.50, "term": 0.42, "person": 0.36, "amount": 0.38, "time": 0.46]
        case .otherMaterial:
            ["project": 0.58, "term": 0.54, "ordinary": 0.28]
        case .unknown:
            ["ordinary": 0.18]
        }
    }

    private func asrAlignmentWindows(transcriptSources: [MeetingTruthTranscriptSource]) -> [MeetingTruthASRAlignmentWindow] {
        let qwen = transcriptSources.first { Self.asrRole(for: $0) == .timelineAnchor } ?? transcriptSources.first(where: \.hasTimestamp)
        let mimo = transcriptSources.first { Self.asrRole(for: $0) == .primaryDraft }
        let glm = transcriptSources.first { Self.asrRole(for: $0) == .auxiliaryReference }
        let anchorSegments = Self.timestampSegments(in: qwen?.text ?? "")
        let segments = anchorSegments.isEmpty
            ? Self.slidingTextSegments(in: qwen?.text ?? transcriptSources.first?.text ?? "")
            : anchorSegments
        return segments.prefix(24).enumerated().map { index, segment in
            let mimoText = Self.bestAlignedSnippet(for: segment.text, in: mimo?.text ?? "")
            let glmText = Self.bestAlignedSnippet(for: segment.text, in: glm?.text ?? "")
            let score = max(Self.tokenOverlap(segment.text, mimoText), Self.tokenOverlap(segment.text, glmText))
            var warnings: [String] = []
            if qwen == nil { warnings.append("没有 Qwen3 时间轴，使用滑动文本窗口。") }
            if mimo == nil { warnings.append("缺少 MiMo 主底稿，只能用可用转写近似对齐。") }
            if score < 0.18 { warnings.append("MiMo/GLM 与该窗口关键词重叠较低。") }
            return MeetingTruthASRAlignmentWindow(
                windowID: "window-\(index + 1)",
                startTime: segment.start,
                endTime: segment.end,
                qwenText: segment.text,
                mimoText: mimoText,
                glmText: glmText,
                alignmentScore: score,
                alignmentWarnings: warnings
            )
        }
    }

    private func compressedFactAdmissionWindows(
        transcriptSources: [MeetingTruthTranscriptSource],
        materials: [MeetingTruthMaterial],
        visualEvidence: [MeetingTruthVisualEvidence],
        hint: String?
    ) -> [String] {
        let hintText = hint?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sourceText = transcriptSources
            .sorted { $0.text.count > $1.text.count }
            .prefix(3)
            .flatMap { source in
                source.text
                    .split(whereSeparator: { "\n。！？!?；;".contains($0) })
                    .map(String.init)
                    .filter { hintText.isEmpty || $0.localizedCaseInsensitiveContains(hintText) }
                    .prefix(12)
            }
        let materialText = materials.prefix(4).map { material in
            [material.name, material.detail, material.extractedText].joined(separator: " ")
        }
        let visualText = visualEvidence.prefix(4).map { evidence in
            ([evidence.summary] + evidence.keywords + evidence.extractedNumbers + evidence.actionHints).joined(separator: " ")
        }
        return Array((sourceText + materialText + visualText)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(40))
    }

    private static func factAdmissionWindowLooksReviewable(_ text: String) -> Bool {
        let highRiskSignals = [
            "负责人", "负责", "提交", "截止", "预算", "金额", "项目名", "系统名", "项目", "系统",
            "风险", "阻塞", "决定", "结论", "通过", "采用", "上线", "验收", "OpenClaw", "OpenCloud", "OpenCL"
        ]
        let lowValueSignals = ["才能", "要挂模型", "混乱流程", "要完善多元的校验流程"]
        let normalized = normalizedEvidenceToken(text)
        if lowValueSignals.contains(where: { normalized.contains(normalizedEvidenceToken($0)) }) {
            return false
        }
        return highRiskSignals.contains { text.localizedCaseInsensitiveContains($0) } ||
            text.range(of: #"\d+(?:\.\d+)?\s*(?:万|万元|%|％|人|项|天|周|月)"#, options: .regularExpression) != nil
    }

    private func detectASRConflictsRecord(
        index: Int,
        args: [String: String],
        transcriptSources: [MeetingTruthTranscriptSource],
        conflicts: [MeetingTruthConflict]
    ) -> MeetingTruthToolCallRecord {
        let findings = evidenceToolConflicts(transcriptSources: transcriptSources, conflicts: conflicts)
        let highRisk = findings.filter(\.impactsMinutes)
        let summary = highRisk.prefix(4).map { finding in
            "\(finding.conflictType)：\(finding.candidates.joined(separator: " / "))"
        }.joined(separator: "；")
        return MeetingTruthToolCallRecord(
            callIndex: index,
            functionName: "detect_asr_conflicts",
            argumentsSummary: args["window_hint"].map { "窗口提示：\($0)" } ?? "Qwen3 建时间轴，MiMo 做主文本，GLM 做辅助参考；扫描已对齐的多路 ASR 高风险转写冲突窗口",
            resultSummary: findings.isEmpty ? "未发现影响纪要的 ASR 候选差异。" : "发现 \(findings.count) 个候选差异；高风险 \(highRisk.count) 个；\(summary)",
            impactSummary: findings.isEmpty ? "后续证据检索不会创建修正项。" : "不是三路多数投票；把 ASR 分歧压缩成候选事实组，后续只围绕这些候选查证和裁决。",
            status: findings.isEmpty ? .skipped : .executed,
            asrConflicts: findings,
            alignmentWindows: asrAlignmentWindows(transcriptSources: transcriptSources)
        )
    }

    private func retrieveSupportingEvidenceRecord(
        index: Int,
        args: [String: String],
        transcriptSources: [MeetingTruthTranscriptSource],
        materials: [MeetingTruthMaterial],
        visualEvidence: [MeetingTruthVisualEvidence],
        conflicts: [MeetingTruthConflict]
    ) -> MeetingTruthToolCallRecord {
        let findings = selectedEvidenceConflicts(args: args, transcriptSources: transcriptSources, conflicts: conflicts)
        let evidence = evidenceSupports(for: findings, transcriptSources: transcriptSources, materials: materials, visualEvidence: visualEvidence, manualConfirmations: [])
        let supported = evidence.filter(\.supportsCandidate)
        let sources = supported.prefix(5).map { "\($0.sourceType.rawValue): \($0.matchedText)" }.joined(separator: "；")
        return MeetingTruthToolCallRecord(
            callIndex: index,
            functionName: "retrieve_supporting_evidence",
            argumentsSummary: "围绕 \(findings.first?.candidates.joined(separator: " / ") ?? "最高风险候选") 检索 ASR、图片、材料、术语表和上下文证据",
            resultSummary: evidence.isEmpty ? "没有找到候选事实的支持或反驳证据。" : "找到 \(evidence.count) 条证据，其中支持 \(supported.count) 条；\(sources)",
            impactSummary: supported.isEmpty ? "证据不足，候选不能自动写入纪要。" : "证据链会进入候选评分，会议通知/手写稿/PPT/术语表/OCR/原图理解按适用边界计算。",
            status: evidence.isEmpty ? .failed : .executed,
            asrConflicts: findings,
            evidenceChain: evidence,
            evidenceProfiles: evidenceProfiles(materials: materials, visualEvidence: visualEvidence, transcriptSources: transcriptSources)
        )
    }

    private func scoreFactCandidatesRecord(
        index: Int,
        args: [String: String],
        transcriptSources: [MeetingTruthTranscriptSource],
        materials: [MeetingTruthMaterial],
        visualEvidence: [MeetingTruthVisualEvidence],
        conflicts: [MeetingTruthConflict],
        manualConfirmations: [MeetingTruthManualConfirmation]
    ) -> MeetingTruthToolCallRecord {
        let findings = selectedEvidenceConflicts(args: args, transcriptSources: transcriptSources, conflicts: conflicts)
        let evidence = evidenceSupports(for: findings, transcriptSources: transcriptSources, materials: materials, visualEvidence: visualEvidence, manualConfirmations: manualConfirmations)
        let scores = candidateScores(for: findings, evidence: evidence)
        let best = scores.max { $0.score < $1.score }
        return MeetingTruthToolCallRecord(
            callIndex: index,
            functionName: "score_fact_candidates",
            argumentsSummary: "基于 ASR 角色、多源证据权重和事实类型重新评分候选写法",
            resultSummary: scores.isEmpty ? "没有可评分候选。" : "最高候选：\(best?.candidate ?? "无")，分数 \(Int(((best?.score ?? 0) * 100).rounded()))；候选数 \(scores.count)。",
            impactSummary: best.map { "推荐值 \($0.recommendedValue)，推荐裁决 \($0.recommendedDecision.title)：\($0.reason)" } ?? "没有候选进入最终裁决。",
            status: scores.isEmpty ? .failed : .executed,
            asrConflicts: findings,
            evidenceChain: evidence,
            candidateScores: scores,
            evidenceProfiles: evidenceProfiles(materials: materials, visualEvidence: visualEvidence, transcriptSources: transcriptSources)
        )
    }

    private func makeFactDecisionRecord(
        index: Int,
        args: [String: String],
        transcriptSources: [MeetingTruthTranscriptSource],
        materials: [MeetingTruthMaterial],
        visualEvidence: [MeetingTruthVisualEvidence],
        conflicts: [MeetingTruthConflict],
        manualConfirmations: [MeetingTruthManualConfirmation]
    ) -> MeetingTruthToolCallRecord {
        let findings = selectedEvidenceConflicts(args: args, transcriptSources: transcriptSources, conflicts: conflicts)
        let evidence = evidenceSupports(for: findings, transcriptSources: transcriptSources, materials: materials, visualEvidence: visualEvidence, manualConfirmations: manualConfirmations)
        let scores = candidateScores(for: findings, evidence: evidence)
        let decision = factDecisionTrace(for: findings, scores: scores, evidence: evidence)
        let corrected = decision?.correctedFrom.joined(separator: " / ") ?? ""
        return MeetingTruthToolCallRecord(
            callIndex: index,
            functionName: "make_fact_decision",
            argumentsSummary: "按候选评分和风险规则输出 accepted/corrected/conflicted/needsHumanReview/rejected 裁决",
            resultSummary: decision.map { "\($0.status.title)：final_text=\($0.finalText)，confidence=\(Int(($0.confidence * 100).rounded()))%，enter_minutes=\($0.enterMinutes ? "yes" : "no")" } ?? "没有足够候选做事实裁决。",
            impactSummary: decision.map {
                $0.status == .corrected
                    ? "最终纪要应写 \($0.finalText)，并将 \(corrected) 修正为 \($0.finalText)。"
                    : $0.explanation
            } ?? "最终纪要不应自动写入该事实。",
            status: decision == nil ? .failed : .executed,
            asrConflicts: findings,
            evidenceChain: evidence,
            candidateScores: scores,
            factDecision: decision,
            affectedMinutesText: decision?.enterMinutes == true ? "我们下阶段要接入 \(decision?.finalText ?? "")，并用 Gemma 4 做交叉校验。" : nil,
            evidenceProfiles: evidenceProfiles(materials: materials, visualEvidence: visualEvidence, transcriptSources: transcriptSources)
        )
    }

    private func createHumanReviewTaskRecord(
        index: Int,
        args: [String: String],
        transcriptSources: [MeetingTruthTranscriptSource],
        materials: [MeetingTruthMaterial],
        visualEvidence: [MeetingTruthVisualEvidence],
        conflicts: [MeetingTruthConflict],
        manualConfirmations: [MeetingTruthManualConfirmation]
    ) -> MeetingTruthToolCallRecord {
        let findings = selectedEvidenceConflicts(args: args, transcriptSources: transcriptSources, conflicts: conflicts)
        let evidence = evidenceSupports(for: findings, transcriptSources: transcriptSources, materials: materials, visualEvidence: visualEvidence, manualConfirmations: manualConfirmations)
        let scores = candidateScores(for: findings, evidence: evidence)
        let decision = factDecisionTrace(for: findings, scores: scores, evidence: evidence)
        let needsReview = decision?.status == .conflicted || decision?.status == .needsHumanReview
        let task = needsReview ? humanReviewTask(for: findings, decision: decision, reason: args["reason"]) : nil
        return MeetingTruthToolCallRecord(
            callIndex: index,
            functionName: "create_human_review_task",
            argumentsSummary: "仅当裁决为 conflicted 或 needsHumanReview 时生成用户确认任务",
            resultSummary: task.map { "问题：\($0.question)；选项：\($0.options.joined(separator: " / "))" } ?? "当前候选已有足够证据自动裁决，无需人工确认。",
            impactSummary: task.map { "人工确认会影响：\($0.impact)" } ?? "不会增加人工确认队列。",
            status: task == nil ? .skipped : .executed,
            asrConflicts: findings,
            evidenceChain: evidence,
            candidateScores: scores,
            factDecision: decision,
            humanReviewTask: task
        )
    }

    private func selectedEvidenceConflicts(
        args: [String: String],
        transcriptSources: [MeetingTruthTranscriptSource],
        conflicts: [MeetingTruthConflict]
    ) -> [MeetingTruthASRConflictFinding] {
        let findings = evidenceToolConflicts(transcriptSources: transcriptSources, conflicts: conflicts)
        let requestedID = args["conflict_id"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !requestedID.isEmpty, let found = findings.first(where: { $0.conflictID == requestedID }) {
            return [found]
        }
        return Array(findings.prefix(1))
    }

    private func evidenceToolConflicts(
        transcriptSources: [MeetingTruthTranscriptSource],
        conflicts: [MeetingTruthConflict]
    ) -> [MeetingTruthASRConflictFinding] {
        var findings: [MeetingTruthASRConflictFinding] = []
        let sourceTokens = transcriptSources.map { source in
            (source: source, tokens: Self.highRiskTokens(in: source.text))
        }
        var groups: [[String]] = []
        for item in sourceTokens {
            for token in item.tokens {
                guard !Self.isLowValueASRToken(token) else { continue }
                if let index = groups.firstIndex(where: { group in group.contains { Self.areLikelyASRVariants($0, token) } }) {
                    if !groups[index].contains(where: { Self.normalizedEvidenceToken($0) == Self.normalizedEvidenceToken(token) }) {
                        groups[index].append(token)
                    }
                } else {
                    groups.append([token])
                }
            }
        }

        for group in groups where Set(group.map(Self.normalizedEvidenceToken)).count >= 2 {
            let candidates = Self.rankCandidateStrings(group)
            let sourceTexts = transcriptSources.compactMap { source -> String? in
                guard let token = sourceTokens.first(where: { $0.source.id == source.id })?.tokens.first(where: { token in
                    candidates.contains { Self.areLikelyASRVariants($0, token) }
                }) else { return nil }
                return "\(Self.factSafeSourceLabel(source.name))：\(Self.windowAround(token, in: source.text))"
            }
            let type = Self.conflictType(for: candidates)
            let riskKeywords = ["系统名", "技术术语", "人名", "时间", "金额", "责任人", "截止日期"]
            let risk: MeetingTruthASRConflictFinding.RiskLevel = riskKeywords.contains { type.contains($0) } ? .high : .medium
            findings.append(
                MeetingTruthASRConflictFinding(
                    conflictID: "asr-\(findings.count + 1)",
                    conflictType: type,
                    candidates: candidates,
                    sourceTexts: sourceTexts,
                    riskLevel: risk,
                    impactsMinutes: risk != .low,
                    reason: "多路 ASR 在同一语义位置出现 \(candidates.joined(separator: " / ")) 变体，属于会影响纪要事实的高风险候选。",
                    relatedWindow: sourceTexts.joined(separator: "\n")
                )
            )
        }

        if findings.isEmpty {
            findings.append(contentsOf: conflicts.prefix(3).map { conflict in
                MeetingTruthASRConflictFinding(
                    conflictID: conflict.id.uuidString,
                    conflictType: conflict.kind.title,
                    candidates: Self.rankCandidateStrings(conflict.candidates.map(\.text) + [conflict.recommendation]),
                    sourceTexts: conflict.candidates.map { "\($0.source)：\($0.text)" },
                    riskLevel: conflict.confidence == .low ? .high : .medium,
                    impactsMinutes: true,
                    reason: conflict.evidence.isEmpty ? "来自现有冲突卡，仍需证据链复核。" : conflict.evidence,
                    relatedWindow: conflict.context
                )
            })
        }
        return findings.sorted { lhs, rhs in
            if lhs.riskLevel != rhs.riskLevel {
                return lhs.riskLevel == .high
            }
            return lhs.candidates.count > rhs.candidates.count
        }
    }

    private func evidenceSupports(
        for findings: [MeetingTruthASRConflictFinding],
        transcriptSources: [MeetingTruthTranscriptSource],
        materials: [MeetingTruthMaterial],
        visualEvidence: [MeetingTruthVisualEvidence],
        manualConfirmations: [MeetingTruthManualConfirmation]
    ) -> [MeetingTruthEvidenceSupport] {
        var supports: [MeetingTruthEvidenceSupport] = []
        let candidates = findings.flatMap(\.candidates)
        guard !candidates.isEmpty else { return [] }

        for source in transcriptSources {
            for candidate in candidates where Self.exactEvidenceContains(source.text, candidate) {
                let role = Self.asrRole(for: source)
                supports.append(.init(
                    sourceType: .asr,
                    sourceID: source.id.uuidString,
                    matchedText: "\(Self.factSafeSourceLabel(source.name))（\(role.shortLabel)）：\(Self.windowAround(candidate, in: source.text))",
                    candidate: candidate,
                    supportsCandidate: true,
                    supportType: .partialSupport,
                    confidence: Self.asrEvidenceConfidence(for: role)
                ))
            }
        }

        for material in materials {
            let profileType = Self.evidenceSourceType(for: material)
            let sourceType = Self.evidenceSupportSourceType(for: profileType, material: material)
            for candidate in candidates {
                let materialText = material.extractedText.isEmpty ? "\(material.name) \(material.detail)" : material.extractedText
                let match = Self.evidenceTokenMatch(in: "\(materialText) \(material.name) \(material.detail)", candidate: candidate)
                if match.exact != nil {
                    supports.append(.init(
                        sourceType: sourceType,
                        sourceID: material.id.uuidString,
                        matchedText: "\(Self.factSafeSourceLabel(material.name))：\(Self.windowAround(candidate, in: materialText))",
                        candidate: candidate,
                        supportsCandidate: true,
                        supportType: .supports,
                        confidence: Self.supportConfidence(for: profileType, sourceType: sourceType)
                    ))
                } else if let variant = match.variant {
                    let supportType = Self.variantSupportType(for: profileType)
                    supports.append(.init(
                        sourceType: sourceType,
                        sourceID: material.id.uuidString,
                        matchedText: "\(Self.factSafeSourceLabel(material.name))：出现近似写法 \(variant)，不是 \(candidate)。\(Self.windowAround(variant, in: materialText))",
                        candidate: candidate,
                        supportsCandidate: supportType != .contradicts ? true : false,
                        supportType: supportType,
                        confidence: Self.contradictionConfidence(for: profileType, sourceType: sourceType)
                    ))
                } else if Self.shouldRecordAbsenceNotEvidence(for: profileType) {
                    supports.append(.init(
                        sourceType: sourceType,
                        sourceID: material.id.uuidString,
                        matchedText: "\(Self.factSafeSourceLabel(material.name)) 未出现“\(candidate)”，但该资料不完整或不覆盖现场实际发言，不能作为反驳。",
                        candidate: candidate,
                        supportsCandidate: false,
                        supportType: .absenceNotEvidence,
                        confidence: 0.18
                    ))
                } else if profileType == .screenshot || profileType == .unknown {
                    supports.append(.init(
                        sourceType: sourceType,
                        sourceID: material.id.uuidString,
                        matchedText: "\(Self.factSafeSourceLabel(material.name)) 不适合判断“\(candidate)”这一事实。",
                        candidate: candidate,
                        supportsCandidate: false,
                        supportType: .notApplicable,
                        confidence: 0.12
                    ))
                }
            }
        }

        for evidence in visualEvidence {
            var visualParts: [String] = [evidence.summary]
            visualParts.append(contentsOf: evidence.keywords)
            visualParts.append(contentsOf: evidence.extractedNumbers)
            visualParts.append(contentsOf: evidence.actionHints)
            visualParts.append(contentsOf: evidence.layoutCues)
            visualParts.append(contentsOf: evidence.visualMarks)
            visualParts.append(contentsOf: evidence.participants.map(\.name))
            let visualText = visualParts.joined(separator: " ")
            for candidate in candidates {
                let match = Self.evidenceTokenMatch(in: visualText, candidate: candidate)
                if match.exact != nil {
                    supports.append(.init(
                        sourceType: .rawVision,
                        sourceID: evidence.id.uuidString,
                        matchedText: "\(Self.factSafeSourceLabel(evidence.materialName)) 原图理解：\(Self.windowAround(candidate, in: visualText))",
                        candidate: candidate,
                        supportsCandidate: true,
                        supportType: .supports,
                        confidence: 0.9
                    ))
                } else if let variant = match.variant {
                    supports.append(.init(
                        sourceType: .rawVision,
                        sourceID: evidence.id.uuidString,
                        matchedText: "\(Self.factSafeSourceLabel(evidence.materialName)) 原图理解出现近似写法 \(variant)，不是 \(candidate)。\(Self.windowAround(variant, in: visualText))",
                        candidate: candidate,
                        supportsCandidate: false,
                        supportType: .contradicts,
                        confidence: 0.76
                    ))
                } else if !visualText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    supports.append(.init(
                        sourceType: .rawVision,
                        sourceID: evidence.id.uuidString,
                        matchedText: "\(Self.factSafeSourceLabel(evidence.materialName)) 原图理解没有覆盖“\(candidate)”，仅作为上下文提示。",
                        candidate: candidate,
                        supportsCandidate: false,
                        supportType: .contextualHint,
                        confidence: 0.16
                    ))
                }
            }
        }

        for confirmation in manualConfirmations {
            guard let selected = confirmation.selectedText, !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            for candidate in candidates {
                let match = Self.evidenceTokenMatch(in: selected, candidate: candidate)
                if match.exact != nil {
                    supports.append(.init(
                        sourceType: .human,
                        sourceID: confirmation.id.uuidString,
                        matchedText: "人工确认：\(selected)",
                        candidate: candidate,
                        supportsCandidate: true,
                        supportType: .supports,
                        confidence: 0.98
                    ))
                } else if let variant = match.variant {
                    supports.append(.init(
                        sourceType: .human,
                        sourceID: confirmation.id.uuidString,
                        matchedText: "人工确认选择 \(variant)，不是 \(candidate)。",
                        candidate: candidate,
                        supportsCandidate: false,
                        supportType: .contradicts,
                        confidence: 0.94
                    ))
                }
            }
        }

        return Self.uniqueEvidenceSupports(supports)
    }

    private func candidateScores(
        for findings: [MeetingTruthASRConflictFinding],
        evidence: [MeetingTruthEvidenceSupport]
    ) -> [MeetingTruthCandidateScore] {
        let candidates = findings.flatMap(\.candidates)
        return candidates.map { candidate in
            let supporting = Self.uniqueEvidenceSupports(evidence.filter { $0.candidate == candidate && $0.supportsCandidate })
            let conflicting = Self.uniqueEvidenceSupports(evidence.filter { $0.candidate == candidate && !$0.supportsCandidate })
            let conflictPenalty = conflicting.reduce(0.0) { $0 + Self.evidenceConflictPenalty($1) }
            let score = min(1.0, max(0.0, 0.08 + supporting.reduce(0.0) { $0 + Self.evidenceWeight($1) } - conflictPenalty))
            let decision: MeetingTruthCandidateScore.RecommendedDecision
            if score >= 0.72 {
                decision = .corrected
            } else if score >= 0.55 {
                decision = .accepted
            } else if score >= 0.38 {
                decision = .needsHumanReview
            } else {
                decision = .rejected
            }
            let reason = Self.candidateScoreReason(supporting: supporting, conflicting: conflicting)
            return MeetingTruthCandidateScore(
                candidate: candidate,
                score: score,
                supportingSources: supporting.map { "\($0.sourceType.rawValue):\($0.sourceID)" },
                conflictingSources: conflicting.map { "\($0.sourceType.rawValue):\($0.sourceID)" },
                reason: reason,
                recommendedValue: candidate,
                recommendedDecision: decision
            )
        }.sorted { $0.score > $1.score }
    }

    private func factDecisionTrace(
        for findings: [MeetingTruthASRConflictFinding],
        scores: [MeetingTruthCandidateScore],
        evidence: [MeetingTruthEvidenceSupport]
    ) -> MeetingTruthFactDecisionTrace? {
        guard let best = scores.first else { return nil }
        let second = scores.dropFirst().first
        let highRisk = findings.contains { $0.riskLevel == .high && $0.impactsMinutes }
        let delta = best.score - (second?.score ?? 0)
        let status: MeetingTruthCandidateScore.RecommendedDecision
        if best.score >= 0.72, delta >= 0.18 {
            status = (scores.count > 1 && scores.contains { $0.candidate != best.candidate }) ? .corrected : .accepted
        } else if highRisk {
            status = .needsHumanReview
        } else if delta < 0.12 {
            status = .conflicted
        } else {
            status = .accepted
        }
        let enterMinutes = status == .accepted || status == .corrected
        let correctedFrom = scores.filter { $0.candidate != best.candidate && $0.score < best.score }.map(\.candidate)
        let chain = evidence
            .filter { $0.candidate == best.candidate && $0.supportsCandidate }
            .sorted { $0.confidence > $1.confidence }
            .prefix(5)
            .map { "\($0.sourceType.rawValue)：\($0.matchedText)（\($0.supportType.title)，\(Int(($0.confidence * 100).rounded()))%）" }
        return MeetingTruthFactDecisionTrace(
            finalText: best.candidate,
            status: status,
            confidence: best.score,
            enterMinutes: enterMinutes,
            evidenceChain: chain,
            explanation: status == .corrected
                ? "多路 ASR 存在 \(scores.map(\.candidate).joined(separator: " / ")) 分歧；材料/图片证据更支持 \(best.candidate)，因此自动修正。"
                : "候选 \(best.candidate) 的证据分数最高：\(best.reason)",
            correctedFrom: correctedFrom
        )
    }

    private func humanReviewTask(
        for findings: [MeetingTruthASRConflictFinding],
        decision: MeetingTruthFactDecisionTrace?,
        reason: String?
    ) -> MeetingTruthHumanReviewTask? {
        guard let finding = findings.first else { return nil }
        return MeetingTruthHumanReviewTask(
            question: "这里应写哪一个事实：\(finding.candidates.joined(separator: " / "))？",
            options: finding.candidates + ["都不对，手动填写"],
            whyNeeded: reason?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? reason! : (decision?.explanation ?? "证据不足以自动裁决。"),
            impact: "确认后会影响最终纪要中的事实写法和可信逐字稿修正。",
            relatedWindow: finding.relatedWindow
        )
    }

    private static func evidenceSupportSourceType(
        for profileType: MeetingTruthEvidenceSourceType,
        material: MeetingTruthMaterial
    ) -> MeetingTruthEvidenceSupport.SourceType {
        switch profileType {
        case .meetingNotice: .meetingNotice
        case .handwrittenNote: .handwrittenNote
        case .slideOrPPT: .slideOrPPT
        case .whiteboard: .whiteboard
        case .screenshot: .screenshot
        case .glossary: .glossary
        case .transcript: .asr
        case .otherMaterial, .unknown:
            isImageMaterialKind(material.kind) ? .imageOCR : .material
        }
    }

    private static func asrEvidenceConfidence(for role: MeetingTruthASRSourceRole) -> Double {
        switch role {
        case .primaryDraft: 0.58
        case .timelineAnchor: 0.46
        case .auxiliaryReference: 0.40
        case .other: 0.34
        }
    }

    private static func asrRoleWeight(from matchedText: String) -> Double {
        if matchedText.contains("主底稿") { return 0.18 }
        if matchedText.contains("定位") { return 0.10 }
        if matchedText.contains("参考") { return 0.08 }
        return 0.06
    }

    private static func supportConfidence(
        for profileType: MeetingTruthEvidenceSourceType,
        sourceType: MeetingTruthEvidenceSupport.SourceType
    ) -> Double {
        switch profileType {
        case .glossary: 0.94
        case .slideOrPPT: 0.86
        case .meetingNotice: 0.84
        case .handwrittenNote: 0.78
        case .whiteboard: 0.72
        case .screenshot: 0.68
        case .transcript: 0.48
        case .otherMaterial: sourceType == .imageOCR ? 0.68 : 0.62
        case .unknown: 0.34
        }
    }

    private static func contradictionConfidence(
        for profileType: MeetingTruthEvidenceSourceType,
        sourceType: MeetingTruthEvidenceSupport.SourceType
    ) -> Double {
        switch profileType {
        case .glossary: 0.86
        case .slideOrPPT: 0.76
        case .meetingNotice: 0.34
        case .handwrittenNote: 0.28
        case .whiteboard: 0.44
        case .screenshot: 0.36
        case .transcript: 0.16
        case .otherMaterial: sourceType == .imageOCR ? 0.46 : 0.42
        case .unknown: 0.12
        }
    }

    private static func variantSupportType(for profileType: MeetingTruthEvidenceSourceType) -> MeetingTruthEvidenceSupport.SupportType {
        switch profileType {
        case .meetingNotice:
            .contextualHint
        case .handwrittenNote:
            .partialSupport
        case .unknown:
            .unknown
        case .screenshot:
            .contextualHint
        case .transcript:
            .partialSupport
        case .slideOrPPT, .whiteboard, .glossary, .otherMaterial:
            .contradicts
        }
    }

    private static func shouldRecordAbsenceNotEvidence(for profileType: MeetingTruthEvidenceSourceType) -> Bool {
        switch profileType {
        case .meetingNotice, .handwrittenNote, .slideOrPPT, .whiteboard:
            true
        case .screenshot, .glossary, .transcript, .otherMaterial, .unknown:
            false
        }
    }

    private static func evidenceWeight(_ evidence: MeetingTruthEvidenceSupport) -> Double {
        switch evidence.supportType {
        case .supports:
            break
        case .partialSupport:
            return evidence.sourceType == .asr ? asrRoleWeight(from: evidence.matchedText) : 0.18
        case .contextualHint:
            return 0.04
        case .absenceNotEvidence, .notApplicable, .unknown, .contradicts:
            return 0
        }
        switch evidence.sourceType {
        case .human: return 0.62
        case .glossary: return 0.58
        case .slideOrPPT: return 0.50
        case .meetingNotice: return 0.46
        case .handwrittenNote: return 0.44
        case .rawVision: return 0.38
        case .material: return 0.38
        case .imageOCR: return 0.34
        case .whiteboard: return 0.34
        case .screenshot: return 0.28
        case .asr: return asrRoleWeight(from: evidence.matchedText)
        case .context: return evidence.supportsCandidate ? 0.04 : 0
        }
    }

    private static func evidenceConflictPenalty(_ evidence: MeetingTruthEvidenceSupport) -> Double {
        switch evidence.supportType {
        case .contradicts:
            break
        case .partialSupport, .contextualHint, .absenceNotEvidence, .notApplicable, .unknown, .supports:
            return 0
        }
        switch evidence.sourceType {
        case .human: return 0.58
        case .glossary: return 0.48
        case .slideOrPPT: return 0.42
        case .rawVision: return 0.36
        case .material: return 0.34
        case .meetingNotice: return 0.18
        case .handwrittenNote: return 0.14
        case .imageOCR: return 0.30
        case .whiteboard: return 0.24
        case .screenshot: return 0.18
        case .asr: return 0.04
        case .context: return 0.02
        }
    }

    private static func uniqueEvidenceSupports(_ evidence: [MeetingTruthEvidenceSupport]) -> [MeetingTruthEvidenceSupport] {
        var bestByKey: [String: MeetingTruthEvidenceSupport] = [:]
        for item in evidence {
            let textKey = normalizedEvidenceToken(item.matchedText)
            let key = [
                item.candidate,
                item.sourceType.rawValue,
                item.sourceID,
                item.supportType.rawValue,
                item.supportsCandidate ? "supports" : "contradicts",
                textKey
            ].joined(separator: "::")
            if let existing = bestByKey[key], existing.confidence >= item.confidence {
                continue
            }
            bestByKey[key] = item
        }
        return Array(bestByKey.values).sorted { lhs, rhs in
            if lhs.confidence != rhs.confidence {
                return lhs.confidence > rhs.confidence
            }
            return lhs.sourceType.rawValue < rhs.sourceType.rawValue
        }
    }

    private static func candidateScoreReason(
        supporting: [MeetingTruthEvidenceSupport],
        conflicting: [MeetingTruthEvidenceSupport]
    ) -> String {
        let strongSupport = supporting.filter { $0.sourceType != .asr && $0.sourceType != .context }
        let supportText = (strongSupport.isEmpty ? supporting : strongSupport)
            .prefix(3)
            .map { "\($0.sourceType.rawValue)=\($0.matchedText)" }
            .joined(separator: "；")
        let conflictText = conflicting
            .filter { $0.sourceType != .context }
            .prefix(2)
            .map { "\($0.sourceType.rawValue)=\($0.matchedText)" }
            .joined(separator: "；")
        if supportText.isEmpty {
            return "没有材料、图片或人工确认支持；不能自动采用。"
        }
        if conflictText.isEmpty {
            return "强支持证据：\(supportText)"
        }
        return "强支持证据：\(supportText)。反驳证据：\(conflictText)"
    }

    private func compactArgumentsSummary(_ args: [String: String]) -> String {
        args.isEmpty
            ? "无参数"
            : args.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "；")
    }

    private func toolCallingComparison(
        records: [MeetingTruthToolCallRecord],
        currentLedger: MeetingTruthCentralReviewLedger?,
        transcriptSources: [MeetingTruthTranscriptSource],
        materials: [MeetingTruthMaterial],
        visualEvidence: [MeetingTruthVisualEvidence],
        factDecisions: [MeetingTruthFactDecision]
    ) -> MeetingTruthToolCallingComparison {
        let executed = records.filter { $0.status == .executed }
        let toolNames = Set(executed.map(\.functionName))
        var improvements: [String] = []
        if toolNames.contains("detect_asr_conflicts") {
            improvements.append("多路 ASR 先被压缩成影响纪要的候选差异，不再让模型从全文里硬找所有问题。")
        }
        if toolNames.contains("retrieve_supporting_evidence") {
            improvements.append("候选事实会连接到材料、图片 OCR、原图视觉理解、上下文和人工确认等具体证据。")
        }
        if toolNames.contains("score_fact_candidates") {
            improvements.append("候选事实按 ASR 一致性、图片证据、材料证据和人工确认重新评分，不再查询旧 factDecision 冒充评分。")
        }
        if toolNames.contains("make_fact_decision") {
            improvements.append("工具链会输出 accepted/corrected/conflicted/needsHumanReview/rejected 裁决，并明确最终纪要是否写入。")
        }
        if toolNames.contains("create_human_review_task") {
            improvements.append("证据不足时会生成用户能看懂的确认问题、选项和影响说明。")
        }
        let skipped = records.filter { $0.status != .executed }
        let limitations = skipped.isEmpty ? [] : ["有 \(skipped.count) 个工具调用未执行或不可解析；这些项仍按保守中枢门禁处理。"]
        return MeetingTruthToolCallingComparison(
            baselineModeTitle: "不调用函数工具",
            toolCallingModeTitle: "Gemma 4 函数调用",
            baselineSummary: "纯 JSON prompt 模式依赖模型一次性阅读 \(transcriptSources.count) 路 ASR、\(materials.count) 份材料和 \(factDecisions.count) 个事实裁决；工程侧只能事后解析 JSON。",
            toolCallingSummary: "函数调用模式让模型调度 \(records.count) 个证据裁决工具，由 Swift 做 ASR 差异压缩、证据检索、候选评分、事实裁决和人工确认任务，再把真实结果回填给中枢复核。",
            improvements: improvements,
            limitations: limitations,
            invokedToolCount: executed.count,
            impactedClaimCount: max(records.compactMap(\.factDecision).count, min(executed.count, max(factDecisions.count, 1)))
        )
    }

    private static func textContains(_ text: String, _ needle: String) -> Bool {
        let normalizedText = text.replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression).lowercased()
        let normalizedNeedle = needle.replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression).lowercased()
        guard !normalizedText.isEmpty, !normalizedNeedle.isEmpty else { return false }
        return normalizedText.contains(normalizedNeedle) || normalizedNeedle.contains(normalizedText)
    }

    private static func asrRole(for source: MeetingTruthTranscriptSource) -> MeetingTruthASRSourceRole {
        let name = source.name.lowercased()
        if name.contains("qwen") || name.contains("qwen3") {
            return .timelineAnchor
        }
        if name.contains("mimo") || name.contains("mi mo") {
            return .primaryDraft
        }
        if name.contains("glm") {
            return .auxiliaryReference
        }
        if source.hasTimestamp {
            return .timelineAnchor
        }
        return .other
    }

    private static func isImageMaterialKind(_ kind: String) -> Bool {
        let normalized = kind.lowercased()
        return normalized.contains("图片") ||
            normalized.contains("image") ||
            normalized.contains("png") ||
            normalized.contains("jpg") ||
            normalized.contains("jpeg") ||
            normalized.contains("heic")
    }

    private static func timestampSegments(in text: String) -> [(start: String, end: String, text: String)] {
        let pattern = #"(?:\[|\()?(\d{1,2}:\d{2}(?::\d{2})?)(?:\s*[-–~>]\s*(\d{1,2}:\d{2}(?::\d{2})?))?(?:\]|\))?\s*([^\n]{8,260})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        return matches.compactMap { match in
            guard match.numberOfRanges > 3 else { return nil }
            let start = nsText.substring(with: match.range(at: 1))
            let end = match.range(at: 2).location == NSNotFound ? start : nsText.substring(with: match.range(at: 2))
            let body = nsText.substring(with: match.range(at: 3)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return nil }
            return (start, end, body)
        }
    }

    private static func slidingTextSegments(in text: String) -> [(start: String, end: String, text: String)] {
        let sentences = text
            .split(whereSeparator: { "\n。！？!?；;".contains($0) })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !sentences.isEmpty else { return [] }
        var result: [(start: String, end: String, text: String)] = []
        var index = 0
        while index < sentences.count {
            let window = sentences[index..<min(index + 4, sentences.count)].joined(separator: "。")
            result.append(("文本窗口 \(index + 1)", "文本窗口 \(min(index + 4, sentences.count))", window))
            index += 3
        }
        return result
    }

    private static func bestAlignedSnippet(for anchor: String, in text: String) -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        let segments = slidingTextSegments(in: text).map(\.text)
        return segments.max { tokenOverlap(anchor, $0) < tokenOverlap(anchor, $1) } ?? String(text.prefix(220))
    }

    private static func tokenOverlap(_ lhs: String, _ rhs: String) -> Double {
        let left = Set(highRiskTokens(in: lhs).map(normalizedEvidenceToken))
        let right = Set(highRiskTokens(in: rhs).map(normalizedEvidenceToken))
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        let intersection = left.intersection(right).count
        return Double(intersection) / Double(max(left.count, right.count))
    }

    private static func personLikeTokens(in text: String) -> [String] {
        let nsText = text as NSString
        let pattern = #"[一-龥]{1,3}(?:总|经理|主任|书记|老师|博士)|[一-龥]{2,3}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
            .map { nsText.substring(with: $0.range) }
            .filter { !$0.contains("会议") && !$0.contains("项目") && !$0.contains("系统") }
        return Array(matches.prefix(12))
    }

    private static func projectLikeTokens(in text: String) -> [String] {
        rankCandidateStrings(highRiskTokens(in: text).filter { token in
            token.range(of: #"[A-Za-z]"#, options: .regularExpression) != nil ||
            token.contains("项目") ||
            token.contains("系统") ||
            token.contains("平台") ||
            token.contains("方案")
        })
    }

    private static func dateTimeMentions(in text: String) -> [String] {
        regexMatches(in: text, pattern: #"\d{4}年\d{1,2}月\d{1,2}日|\d{1,2}月\d{1,2}日|周[一二三四五六日天]|\d{1,2}:\d{2}"#)
    }

    private static func amountMentions(in text: String) -> [String] {
        regexMatches(in: text, pattern: #"\d+(?:\.\d+)?\s*(?:万|万元|亿|%|％)"#)
    }

    private static func actionHints(in text: String) -> [String] {
        text
            .split(whereSeparator: { "\n。！？!?；;".contains($0) })
            .map(String.init)
            .filter { sentence in
                ["负责", "提交", "截止", "推进", "完成", "跟进", "上线", "验收"].contains { sentence.contains($0) }
            }
            .prefix(8)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private static func regexMatches(in text: String, pattern: String) -> [String] {
        let nsText = text as NSString
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
            .map { nsText.substring(with: $0.range) }
    }

    private static func highRiskTokens(in text: String) -> [String] {
        let nsText = text as NSString
        let patterns = [
            #"[A-Za-z][A-Za-z0-9+#.\-]{2,}"#,
            #"\d+(?:\.\d+)?\s*(?:万|万元|亿|%|点|时|:|：)"#,
            #"[一-龥]{2,8}(?:系统|平台|项目|方案|指标|样本包|流程|模型|校验|纪要)"#
        ]
        var tokens: [String] = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
            for match in matches {
                let token = nsText.substring(with: match.range).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !token.isEmpty, !isLowValueASRToken(token) else { continue }
                tokens.append(token)
            }
        }
        return rankCandidateStrings(tokens)
    }

    private static func isLowValueASRToken(_ token: String) -> Bool {
        let normalized = normalizedEvidenceToken(token)
        let stop = Set(["asr", "json", "api", "sdk", "token", "gemma", "chatgpt"])
        if stop.contains(normalized) { return false }
        if normalized.count < 4 { return true }
        let filler = ["这个", "那个", "然后", "就是", "可以", "我们", "你们", "他们", "会议", "讨论", "总结"]
        return filler.contains { normalized.contains($0) }
    }

    private static func normalizedEvidenceToken(_ token: String) -> String {
        token
            .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[^A-Za-z0-9+#.\-\u{4e00}-\u{9fff}]"#, with: "", options: .regularExpression)
            .lowercased()
    }

    private static func areLikelyASRVariants(_ lhs: String, _ rhs: String) -> Bool {
        let a = normalizedEvidenceToken(lhs)
        let b = normalizedEvidenceToken(rhs)
        guard a != b, a.count >= 4, b.count >= 4 else { return false }
        let protectedGenericTerms = Set(["open", "openai", "token", "gemma", "chatgpt", "api", "sdk", "json"])
        if protectedGenericTerms.contains(a) || protectedGenericTerms.contains(b) {
            return false
        }
        if a.hasPrefix(String(b.prefix(min(5, b.count)))) || b.hasPrefix(String(a.prefix(min(5, a.count)))) {
            return true
        }
        let distance = levenshteinDistance(a, b)
        let threshold = max(2, min(4, max(a.count, b.count) / 3))
        return distance <= threshold
    }

    private static func approximateContains(_ haystack: String, _ needle: String) -> Bool {
        let normalizedHaystack = normalizedEvidenceToken(haystack)
        let normalizedNeedle = normalizedEvidenceToken(needle)
        guard !normalizedHaystack.isEmpty, !normalizedNeedle.isEmpty else { return false }
        if normalizedHaystack.contains(normalizedNeedle) { return true }
        let tokens = highRiskTokens(in: haystack)
        return tokens.contains { token in
            normalizedEvidenceToken(token) == normalizedNeedle || areLikelyASRVariants(token, needle)
        }
    }

    private static func exactEvidenceContains(_ haystack: String, _ needle: String) -> Bool {
        let normalizedNeedle = normalizedEvidenceToken(needle)
        guard !normalizedNeedle.isEmpty else { return false }
        return highRiskTokens(in: haystack).contains { normalizedEvidenceToken($0) == normalizedNeedle }
    }

    private static func evidenceTokenMatch(in haystack: String, candidate: String) -> (exact: String?, variant: String?) {
        let normalizedCandidate = normalizedEvidenceToken(candidate)
        guard !normalizedCandidate.isEmpty else { return (nil, nil) }
        let tokens = highRiskTokens(in: haystack)
        if let exact = tokens.first(where: { normalizedEvidenceToken($0) == normalizedCandidate }) {
            return (exact, nil)
        }
        let variant = tokens.first { token in
            let normalizedToken = normalizedEvidenceToken(token)
            return normalizedToken != normalizedCandidate && areLikelyASRVariants(token, candidate)
        }
        return (nil, variant)
    }

    private static func rankCandidateStrings(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = normalizedEvidenceToken(trimmed)
            guard !trimmed.isEmpty, !key.isEmpty, seen.insert(key).inserted else { continue }
            result.append(trimmed)
        }
        return result.sorted { lhs, rhs in
            let lhsScore = candidateSurfaceScore(lhs)
            let rhsScore = candidateSurfaceScore(rhs)
            if lhsScore != rhsScore { return lhsScore > rhsScore }
            return lhs.count < rhs.count
        }
    }

    private static func candidateSurfaceScore(_ value: String) -> Int {
        var score = 0
        if value.range(of: #"[A-Z]"#, options: .regularExpression) != nil { score += 3 }
        if value.range(of: #"[a-z]"#, options: .regularExpression) != nil { score += 2 }
        if value.contains("+") || value.contains("#") { score += 1 }
        if value.count <= 16 { score += 1 }
        return score
    }

    private static func conflictType(for candidates: [String]) -> String {
        let joined = candidates.joined(separator: " ")
        if joined.range(of: #"\d"#, options: .regularExpression) != nil { return "时间/数字" }
        if joined.range(of: #"[A-Za-z]"#, options: .regularExpression) != nil { return "系统名/技术术语" }
        if joined.contains("项目") || joined.contains("方案") { return "项目名" }
        if joined.contains("负责") || joined.contains("责任") { return "责任人" }
        return "事实候选"
    }

    private static func windowAround(_ needle: String, in text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return needle }
        let normalizedNeedle = normalizedEvidenceToken(needle)
        if let range = trimmed.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) {
            let lower = trimmed.index(range.lowerBound, offsetBy: -min(28, trimmed.distance(from: trimmed.startIndex, to: range.lowerBound)), limitedBy: trimmed.startIndex) ?? trimmed.startIndex
            let upper = trimmed.index(range.upperBound, offsetBy: min(42, trimmed.distance(from: range.upperBound, to: trimmed.endIndex)), limitedBy: trimmed.endIndex) ?? trimmed.endIndex
            return String(trimmed[lower..<upper])
        }
        if let token = highRiskTokens(in: trimmed).first(where: { normalizedEvidenceToken($0) == normalizedNeedle || areLikelyASRVariants($0, needle) }),
           let range = trimmed.range(of: token, options: [.caseInsensitive, .diacriticInsensitive]) {
            let lower = trimmed.index(range.lowerBound, offsetBy: -min(28, trimmed.distance(from: trimmed.startIndex, to: range.lowerBound)), limitedBy: trimmed.startIndex) ?? trimmed.startIndex
            let upper = trimmed.index(range.upperBound, offsetBy: min(42, trimmed.distance(from: range.upperBound, to: trimmed.endIndex)), limitedBy: trimmed.endIndex) ?? trimmed.endIndex
            return String(trimmed[lower..<upper])
        }
        return trimmed.count > 90 ? "\(trimmed.prefix(90))..." : trimmed
    }

    private static func levenshteinDistance(_ lhs: String, _ rhs: String) -> Int {
        let a = Array(lhs)
        let b = Array(rhs)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = Array(repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + cost
                )
            }
            previous = current
        }
        return previous[b.count]
    }

    private func centralReviewUserMessage(
        transcriptSources: [MeetingTruthTranscriptSource],
        materials: [MeetingTruthMaterial],
        visualEvidence: [MeetingTruthVisualEvidence],
        conflicts: [MeetingTruthConflict],
        factDecisions: [MeetingTruthFactDecision],
        manualConfirmations: [MeetingTruthManualConfirmation],
        currentLedger: MeetingTruthCentralReviewLedger?,
        analysis: MeetingAnalysis?,
        toolRun: MeetingTruthToolCallingRun?,
        settings: MeetingAISettings
    ) throws -> ChatRequestMessage {
        let sourceLimit = usesLargeGemmaContext(settings.model) ? 6_000 : 2_400
        let materialLimit = usesLargeGemmaContext(settings.model) ? 3_000 : 1_200
        let input = CentralReviewRequestPayload(
            workflowInstruction: """
            请按 raw_image_understanding -> ocr_vs_raw_correction -> candidate_validity_review -> support_review -> challenge_review -> final_verdict 固定轮次输出中枢复核账本。先拒绝无效候选，再裁决证据。
            证据域必须和系统元数据域隔离：ASR 来源名、模型名、历史导入时间、处理时间、文件名时间戳、截图保存时间、缓存批次和运行标签都不是会议事实，不得用来推断会议日期、会议时间、负责人、决策或 packageTraceability 冲突。会议事实只能来自 transcript text、材料正文/OCR、原图视觉事实、冲突卡文本、事实台账或人工确认。
            """,
            transcripts: transcriptSources.prefix(4).map {
                .init(
                    name: Self.factSafeSourceLabel($0.name),
                    originalLabelRole: "display_only_metadata_not_fact",
                    hasTimestamp: $0.hasTimestamp,
                    text: String($0.text.prefix(sourceLimit))
                )
            },
            materials: materials.prefix(8).map {
                .init(
                    name: Self.factSafeSourceLabel($0.name),
                    originalLabelRole: "display_only_metadata_not_fact",
                    kind: $0.kind,
                    detail: Self.factSafeSourceLabel($0.detail),
                    ocrOrExtractedText: String($0.extractedText.prefix(materialLimit))
                )
            },
            visualEvidence: visualEvidence.map {
                .init(
                    materialName: Self.factSafeSourceLabel($0.materialName),
                    summary: $0.summary,
                    participants: $0.participants.map(\.displayText),
                    numbers: $0.extractedNumbers,
                    keywords: $0.keywords,
                    actionHints: $0.actionHints,
                    layoutCues: $0.layoutCues,
                    visualMarks: $0.visualMarks,
                    ocrContrast: $0.ocrContrast,
                    confidence: $0.confidence.rawValue
                )
            },
            conflicts: conflicts.map {
                .init(
                    conflictID: $0.id.uuidString,
                    kind: $0.kind.rawValue,
                    context: $0.context,
                    candidates: $0.candidates.map { "\(Self.factSafeSourceLabel($0.source))：\($0.text)" },
                    recommendation: $0.recommendation,
                    confidence: $0.confidence.rawValue,
                    selectedText: $0.selectedText ?? "",
                    evidence: $0.evidence
                )
            },
            factDecisions: factDecisions.map {
                .init(
                    factID: $0.factID.uuidString,
                    kind: $0.kind.rawValue,
                    claim: $0.claim,
                    chosenText: $0.chosenText,
                    status: $0.status.rawValue,
                    confidence: $0.confidence,
                    missingEvidence: $0.missingEvidence,
                    requiresUserInput: $0.requiresUserInput,
                    importance: $0.importance.rawValue,
                    riskLevel: $0.riskLevel.rawValue,
                    reason: $0.reason
                )
            },
            humanConfirmations: centralReviewHumanConfirmations(
                confirmations: manualConfirmations,
                conflicts: conflicts,
                factDecisions: factDecisions,
                currentLedger: currentLedger
            ),
            currentCentralLedger: currentLedger.map {
                .init(
                    blockingItems: $0.blockingItems.filter { !Self.looksLikeMetadataOnlyConflict($0) },
                    advisoryItems: $0.advisoryItems,
                    claims: $0.claims.map { claim in
                        .init(
                            kind: claim.kind.rawValue,
                            claim: claim.claim,
                            proposedCanonicalText: claim.proposedCanonicalText,
                            status: claim.status.rawValue,
                            confidence: claim.confidence,
                            missingEvidence: claim.missingEvidence,
                            decisionReason: claim.decisionReason
                        )
                    }
                )
            },
            generatedPackage: analysis.map {
                .init(
                    summary: $0.summary,
                    keyPoints: $0.keyPoints,
                    minutes: $0.minutes,
                    actionItems: $0.actionItems.map { "\($0.task) · \($0.owner ?? "待确认") · \($0.due ?? "待确认")" },
                    evidenceNotes: $0.evidenceNotes
                )
            },
            toolCallingAudit: toolRun.map {
                .init(
                    records: $0.records.map {
                        .init(
                            functionName: $0.functionName,
                            argumentsSummary: $0.argumentsSummary,
                            resultSummary: $0.resultSummary,
                            impactSummary: $0.impactSummary,
                            status: $0.status.rawValue
                        )
                    },
                    comparison: .init(
                        baselineSummary: $0.comparison.baselineSummary,
                        toolCallingSummary: $0.comparison.toolCallingSummary,
                        improvements: $0.comparison.improvements,
                        limitations: $0.comparison.limitations,
                        invokedToolCount: $0.comparison.invokedToolCount,
                        impactedClaimCount: $0.comparison.impactedClaimCount
                    )
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(input)
        guard let json = String(data: data, encoding: .utf8) else {
            throw MeetingAIError.invalidJSON
        }
        let toolInstruction = toolRun == nil
            ? "本轮没有可用的函数调用执行结果；请按普通多模态复核输出，并在缺口中保守标注证据不足。"
            : "本轮已经完成 Gemma 4 函数调用工具执行。tool_calling_audit 是真实工具返回结果，不是 prompt 描述；最终 claims/gaps 必须优先引用这些工具结果。"
        return multimodalUserMessage(
            text: "请执行 MeetingTruth 多模态中枢复核，不要总结会议。human_confirmations 是用户已经明确确认过的最高优先级事实，不得再次对同一事实、同一原文变体或同一含义输出 needsHumanReview/conflicted/missing。\n\(toolInstruction)\n输入如下：\n\(json)",
            materials: materials,
            imageInstruction: """
            以下图片必须作为 image_url 原图进入 raw_image_understanding 轮次。
            OCR 基线已经放在 JSON 中，只能用于 ocr_vs_raw_correction；不能把 OCR 文字当作 rawVision。
            如果原图中的箭头、圈注、手写、表格行列、空间靠近关系能改变事实判断，必须写入 rawVision 证据。
            """
        )
    }

    private static func factSafeSourceLabel(_ label: String) -> String {
        var text = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let patterns = [
            #"·\s*\d{4}年\d{1,2}月\d{1,2}日\s+\d{1,2}:\d{2}"#,
            #"\d{4}[-_/年]\d{1,2}[-_/月]\d{1,2}日?[_\s-]*\d{1,2}[:：]\d{2}(:\d{2})?"#,
            #"ScreenShot[_ -]?\d{4}[-_]\d{2}[-_]\d{2}[_ -]\d{6}[_ -]?\d*"#,
            #"剪贴板图片-\d+"#,
            #"·\s*\d{1,2}:\d{2}(:\d{2})?"#
        ]
        for pattern in patterns {
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: " ·-_"))
        return text.isEmpty ? "来源标签已隐藏" : text
    }

    private static func looksLikeMetadataOnlyConflict(_ text: String) -> Bool {
        let normalized = text.replacingOccurrences(of: " ", with: "")
        let hasProcessingTime = normalized.range(of: #"\d{4}年\d{1,2}月\d{1,2}日\d{1,2}:\d{2}"#, options: .regularExpression) != nil
            || normalized.range(of: #"\d{4}[-_/]\d{1,2}[-_/]\d{1,2}[_-]?\d{1,2}[:：]\d{2}"#, options: .regularExpression) != nil
        let mentionsMetadata = normalized.contains("处理") ||
            normalized.contains("导入") ||
            normalized.contains("历史") ||
            normalized.contains("ASR") ||
            normalized.contains("转写") ||
            normalized.contains("来源名") ||
            normalized.contains("文件名") ||
            normalized.contains("截图")
        return hasProcessingTime && mentionsMetadata
    }

    private func centralReviewHumanConfirmations(
        confirmations: [MeetingTruthManualConfirmation],
        conflicts: [MeetingTruthConflict],
        factDecisions: [MeetingTruthFactDecision],
        currentLedger: MeetingTruthCentralReviewLedger?
    ) -> [CentralReviewRequestPayload.HumanConfirmation] {
        confirmations.compactMap { confirmation -> CentralReviewRequestPayload.HumanConfirmation? in
            guard let selected = confirmation.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !selected.isEmpty else {
                return nil
            }
            if let conflict = conflicts.first(where: { $0.id == confirmation.conflictID }) {
                return .init(
                    confirmationID: confirmation.conflictID.uuidString,
                    source: "conflict",
                    kind: conflict.kind.rawValue,
                    confirmedText: selected,
                    originalTexts: conflict.candidates.map(\.text),
                    relatedClaim: conflict.context,
                    instruction: "用户已确认该冲突的最终写入文本。后续中枢复核不得因这些原始候选或同义问题再次要求人工确认。"
                )
            }
            if let decision = factDecisions.first(where: { $0.factID == confirmation.conflictID }) {
                return .init(
                    confirmationID: confirmation.conflictID.uuidString,
                    source: "fact",
                    kind: decision.kind.rawValue,
                    confirmedText: selected,
                    originalTexts: [decision.claim, decision.chosenText],
                    relatedClaim: decision.claim,
                    instruction: "用户已确认该事实的最终说法。该事实应作为已确认事实进入 final_verdict。"
                )
            }
            if let claim = currentLedger?.claims.first(where: { $0.id == confirmation.conflictID }) {
                return .init(
                    confirmationID: confirmation.conflictID.uuidString,
                    source: "centralClaim",
                    kind: claim.kind.rawValue,
                    confirmedText: selected,
                    originalTexts: [claim.claim, claim.proposedCanonicalText, claim.sourceSpan],
                    relatedClaim: claim.claim,
                    instruction: "用户已确认该中枢裁决。下一轮复核必须继承该人工确认，不得重新生成同义阻塞项。"
                )
            }
            return .init(
                confirmationID: confirmation.conflictID.uuidString,
                source: "manual",
                kind: "term",
                confirmedText: selected,
                originalTexts: [],
                relatedClaim: "",
                instruction: "用户已明确确认该文本；如后续复核遇到同义或包含该文本的问题，应视为人工确认。"
            )
        }
    }

    private func requestAnalysisCompletion(
        url: URL,
        settings: MeetingAISettings,
        transcript: String,
        materials: [MeetingTruthMaterial],
        refinementInstructions: String,
        compact: Bool
    ) async throws -> ChatCompletionResponse {
        try await requestCompletion(
            url: url,
            settings: settings,
            systemContent: compact ? compactSystemPrompt : systemPrompt,
            userMessage: analysisUserMessage(
                transcript: transcript,
                materials: materials,
                settings: settings,
                refinementInstructions: refinementInstructions
            ),
            maxTokens: adjustedMaxTokens(for: settings, compact: compact)
        )
    }

    private func requestCompletion(
        url: URL,
        settings: MeetingAISettings,
        systemContent: String,
        userMessage: ChatRequestMessage,
        maxTokens: Int,
        tools: [ChatToolDefinition]? = nil,
        toolChoice: String? = nil
    ) async throws -> ChatCompletionResponse {
        try await requestCompletion(
            url: url,
            settings: settings,
            messages: [
                ChatRequestMessage(role: "system", content: systemContent),
                userMessage
            ],
            maxTokens: maxTokens,
            tools: tools,
            toolChoice: toolChoice
        )
    }

    private func requestCompletion(
        url: URL,
        settings: MeetingAISettings,
        messages: [ChatRequestMessage],
        maxTokens: Int,
        tools: [ChatToolDefinition]? = nil,
        toolChoice: String? = nil
    ) async throws -> ChatCompletionResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = requestTimeoutSeconds(maxTokens: maxTokens)

        let payload = ChatCompletionRequest(
            model: settings.model,
            messages: messages,
            temperature: min(settings.resolvedTemperature, 0.2),
            maxTokens: maxTokens,
            enableThinking: nil,
            tools: tools,
            toolChoice: toolChoice
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            throw MeetingAIError.requestFailed(httpResponse.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
    }

    private func analyzeInChunks(
        transcript: String,
        materials: [MeetingTruthMaterial],
        settings: MeetingAISettings,
        refinementInstructions: String,
        url: URL
    ) async throws -> MeetingAnalysis {
        let chunks = transcriptChunks(from: transcript, preferredChunkSize: chunkInputLimit(for: settings))
        var chunkOutputs: [String] = []
        chunkOutputs.reserveCapacity(chunks.count)

        for (index, chunk) in chunks.enumerated() {
            let completion = try await requestAnalysisCompletion(
                url: url,
                settings: settings,
                transcript: chunk,
                materials: materials,
                refinementInstructions: refinementInstructions + "\n\n当前仅整理第 \(index + 1)/\(chunks.count) 段，请忠实覆盖这段内容，不要假设后续内容不存在。",
                compact: true
            )
            guard completion.choices.first?.finishReason != "length" else {
                throw chunkTruncationError(index: index + 1, total: chunks.count, settings: settings)
            }
            guard let content = assistantResponseText(from: completion), !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MeetingAIError.emptyResponse
            }
            chunkOutputs.append(content)
        }

        let mergeUserContent = mergeUserPrompt(
            chunkOutputs: chunkOutputs,
            settings: settings,
            refinementInstructions: refinementInstructions
        )
        let mergedCompletion = try await requestCompletion(
            url: url,
            settings: settings,
            systemContent: mergeSystemPrompt,
            userMessage: ChatRequestMessage(role: "user", content: mergeUserContent),
            maxTokens: mergeOutputTokens(for: settings)
        )
        guard mergedCompletion.choices.first?.finishReason != "length" else {
            throw mergeTruncationError(settings: settings)
        }
        guard let content = assistantResponseText(from: mergedCompletion), !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MeetingAIError.emptyResponse
        }
        return try decodeAnalysis(
            from: content,
            settings: settings,
            refinementInstructions: refinementInstructions
        )
    }

    private func requestTimeoutSeconds(maxTokens: Int) -> TimeInterval {
        min(max(300, Double(maxTokens) / 20.0 + 120), 900)
    }

    private func decodeAnalysis(
        from content: String,
        settings: MeetingAISettings,
        refinementInstructions: String
    ) throws -> MeetingAnalysis {
        let jsonText = extractJSONObject(from: content)
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = jsonText.data(using: .utf8) else {
            throw MeetingAIError.invalidJSON
        }
        let decoded: MeetingAnalysisPayload
        do {
            decoded = try JSONDecoder().decode(MeetingAnalysisPayload.self, from: data)
        } catch let error as DecodingError {
            throw MeetingAIError.invalidAnalysisPayload(decodingIssueDescription(for: error))
        } catch {
            throw MeetingAIError.invalidAnalysisPayload(error.localizedDescription)
        }
        let topicMindMap = mindMap(from: decoded.topics)
        let mindMap = topicMindMap.isEmpty ? decoded.mindMap : topicMindMap
        let keyPoints = normalizedKeyPoints(decoded.keyPoints, topics: decoded.topics)
        let minutes = normalizedMinutes(decoded.minutes, topics: decoded.topics)
        let summary = normalizedSummary(decoded.summary, topics: decoded.topics, keyPoints: keyPoints, minutes: minutes)
        let actionItems = decoded.actionItems
            .filter { !$0.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map {
                MeetingActionItem(
                    task: $0.task,
                    owner: normalizedOptional($0.owner),
                    due: normalizedOptional($0.due)
                )
            }
        let evidenceNotes = decoded.evidenceNotes
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !summary.isEmpty || !keyPoints.isEmpty || !mindMap.isEmpty || !minutes.isEmpty || !actionItems.isEmpty else {
            throw MeetingAIError.invalidAnalysisPayload("模型返回了 JSON，但缺少可用的 summary、topics、minutes 或 actionItems 内容。")
        }
        return MeetingAnalysis(
            generatedAt: Date(),
            model: settings.model,
            tokenPlan: settings.tokenPlan,
            refinementInstructions: refinementInstructions,
            summary: summary,
            keyPoints: keyPoints,
            mindMap: mindMap,
            minutes: minutes,
            actionItems: actionItems,
            evidenceNotes: evidenceNotes
        )
    }

    private func decodeVisualEvidence(
        from content: String,
        materials: [MeetingTruthMaterial],
        model: String
    ) throws -> [MeetingTruthVisualEvidence] {
        let jsonText = extractJSONObject(from: content)
        guard let data = jsonText.data(using: .utf8) else {
            throw MeetingAIError.invalidJSON
        }
        let payload = try JSONDecoder().decode(VisualEvidenceResponsePayload.self, from: data)
        return payload.evidence.compactMap { item in
            let name = item.materialName.trimmingCharacters(in: .whitespacesAndNewlines)
            let material = materials.first { $0.name == name } ?? materials.first
            guard let material else { return nil }
            let confidence = MeetingTruthConfidence(rawValue: item.confidence) ?? .low
            let participants = item.participants.compactMap { participant -> MeetingTruthParticipantEvidence? in
                let participantName = participant.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !participantName.isEmpty else { return nil }
                return MeetingTruthParticipantEvidence(
                    name: participantName,
                    role: participant.role.trimmingCharacters(in: .whitespacesAndNewlines),
                    organization: participant.organization.trimmingCharacters(in: .whitespacesAndNewlines),
                    evidence: participant.evidence.trimmingCharacters(in: .whitespacesAndNewlines),
                    confidence: MeetingTruthConfidence(rawValue: participant.confidence) ?? .low
                )
            }
            let candidateTerms = (item.numbers + item.keywords + participants.map(\.name))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0.count <= 32 }
            return MeetingTruthVisualEvidence(
                materialID: material.id,
                materialName: material.name,
                summary: item.summary.trimmingCharacters(in: .whitespacesAndNewlines),
                extractedNumbers: item.numbers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
                keywords: item.keywords.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
                actionHints: item.actionHints.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
                participants: participants,
                layoutCues: item.layoutCues.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
                visualMarks: item.visualMarks.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
                ocrContrast: item.ocrContrast.trimmingCharacters(in: .whitespacesAndNewlines),
                confidence: confidence,
                useForASRIteration: confidence == .high,
                asrCandidateTerms: Array(Set(candidateTerms)).sorted(),
                model: model
            )
        }
        .filter(\.hasContent)
    }

    private func decodeCentralReviewLedger(
        from content: String,
        model: String,
        fallbackLedger: MeetingTruthCentralReviewLedger?,
        toolRun: MeetingTruthToolCallingRun?,
        tokenUsage: MeetingTruthTokenUsage?
    ) throws -> MeetingTruthCentralReviewLedger {
        let jsonText = extractJSONObject(from: content)
        guard let data = jsonText.data(using: .utf8) else {
            throw MeetingAIError.invalidJSON
        }
        let payload = try JSONDecoder().decode(CentralReviewResponsePayload.self, from: data)
        let fallbackObservations = fallbackLedger?.visualObservations ?? []
        let observations = payload.visualObservations.map { item in
            let fallback = fallbackObservations.first { $0.materialName == item.materialName }
            return MeetingTruthVisualObservation(
                materialID: fallback?.materialID,
                materialName: normalizedText(item.materialName, fallback: fallback?.materialName ?? "图片材料"),
                materialRole: normalizedText(item.materialRole, fallback: fallback?.materialRole ?? "待判断"),
                summary: normalizedText(item.summary, fallback: fallback?.summary ?? "Gemma 4 已完成原图理解。"),
                layoutCues: normalizedStrings(item.layoutCues),
                visualMarks: normalizedStrings(item.visualMarks),
                participantEvidence: fallback?.participantEvidence ?? [],
                actionHints: normalizedStrings(item.actionHints),
                ocrBaseline: item.ocrBaseline.trimmingCharacters(in: .whitespacesAndNewlines),
                ocrContrast: item.ocrContrast.trimmingCharacters(in: .whitespacesAndNewlines),
                confidence: MeetingTruthConfidence(rawValue: item.confidence) ?? .low
            )
        }
        let claims = payload.claims.compactMap { item -> MeetingTruthCentralClaim? in
            let claim = item.claim.trimmingCharacters(in: .whitespacesAndNewlines)
            let proposed = item.proposedCanonicalText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !claim.isEmpty || !proposed.isEmpty else { return nil }
            let status = MeetingTruthCentralVerdictStatus(rawValue: item.status) ?? .needsHumanReview
            let riskLevel = MeetingTruthFactRiskLevel(rawValue: item.riskLevel) ?? .high
            let confidence = clampedConfidence(item.confidence)
            let humanQuestion = item.humanQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
            let missingEvidence = normalizedStrings(item.missingEvidence)
            let requiresHumanReview = status == .needsHumanReview || status == .conflicted || status == .missing || (riskLevel == .high && confidence < 0.78)
            return MeetingTruthCentralClaim(
                factID: nil,
                kind: MeetingTruthFactKind(rawValue: item.kind) ?? .term,
                claim: claim.isEmpty ? proposed : claim,
                proposedCanonicalText: proposed.isEmpty ? claim : proposed,
                sourceSpan: item.sourceSpan.trimmingCharacters(in: .whitespacesAndNewlines),
                status: requiresHumanReview && status == .accepted ? .needsHumanReview : status,
                confidence: confidence,
                importance: MeetingTruthFactImportance(rawValue: item.importance) ?? .medium,
                riskLevel: riskLevel,
                supportingEvidence: item.supportingEvidence.map { centralEvidence(from: $0, supportsClaim: true) },
                contradictingEvidence: item.contradictingEvidence.map { centralEvidence(from: $0, supportsClaim: false) },
                missingEvidence: missingEvidence,
                humanQuestion: humanQuestion.isEmpty && requiresHumanReview ? defaultCentralQuestion(for: claim, proposed: proposed, missingEvidence: missingEvidence) : (humanQuestion.isEmpty ? nil : humanQuestion),
                decisionReason: normalizedText(item.decisionReason, fallback: requiresHumanReview ? "证据不足，需要人工确认。" : "Gemma 4 多模态中枢复核已通过。")
            )
        }
        let gaps = payload.gaps.compactMap { item -> MeetingTruthReviewGap? in
            let detail = item.detail.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !detail.isEmpty else { return nil }
            return MeetingTruthReviewGap(
                kind: MeetingTruthReviewGap.Kind(rawValue: item.kind) ?? .noCrossModalEvidence,
                title: normalizedText(item.title, fallback: "复核缺口"),
                detail: detail,
                relatedClaimID: nil,
                requiresHumanReview: item.requiresHumanReview
            )
        }
        let completionStandard = normalizedStrings(payload.completionStandard)
        return MeetingTruthCentralReviewLedger(
            model: model,
            inputSummary: normalizedStrings(payload.inputSummary).isEmpty ? fallbackLedger?.inputSummary ?? [] : normalizedStrings(payload.inputSummary),
            visualObservations: observations.isEmpty ? fallbackObservations : observations,
            claims: claims.isEmpty ? fallbackLedger?.claims ?? [] : claims,
            gaps: gaps.isEmpty ? fallbackLedger?.gaps ?? [] : gaps,
            packageAuditNotes: normalizedStrings(payload.packageAuditNotes).isEmpty ? fallbackLedger?.packageAuditNotes ?? [] : normalizedStrings(payload.packageAuditNotes),
            completionStandard: completionStandard.isEmpty ? fallbackLedger?.completionStandard ?? [] : completionStandard,
            toolCallRecords: toolRun?.records ?? fallbackLedger?.toolCallRecords ?? [],
            toolCallingComparison: toolRun?.comparison ?? fallbackLedger?.toolCallingComparison,
            tokenUsage: toolRun?.tokenUsage?.merged(with: tokenUsage) ?? tokenUsage ?? fallbackLedger?.tokenUsage
        )
    }

    private func centralEvidence(from payload: CentralReviewResponsePayload.Evidence, supportsClaim: Bool) -> MeetingTruthCentralEvidence {
        MeetingTruthCentralEvidence(
            channel: MeetingTruthCentralEvidenceChannel(rawValue: payload.channel) ?? .material,
            sourceName: normalizedText(payload.sourceName, fallback: "Gemma 4 复核"),
            text: payload.text.trimmingCharacters(in: .whitespacesAndNewlines),
            visualCue: payload.visualCue.trimmingCharacters(in: .whitespacesAndNewlines),
            supportsClaim: supportsClaim,
            confidence: clampedConfidence(payload.confidence),
            priority: centralEvidencePriority(for: payload.channel)
        )
    }

    private func centralEvidencePriority(for channel: String) -> Int {
        switch MeetingTruthCentralEvidenceChannel(rawValue: channel) {
        case .human: 100
        case .material: 82
        case .rawVision: 78
        case .imageOCR: 50
        case .asr: 46
        case .conflict: 42
        case .generatedPackage: 30
        case .none: 20
        }
    }

    private func normalizedText(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private func normalizedStrings(_ values: [String]) -> [String] {
        values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private func clampedConfidence(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    private func defaultCentralQuestion(for claim: String, proposed: String, missingEvidence: [String]) -> String {
        let target = proposed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? claim : proposed
        let missing = missingEvidence.isEmpty ? "缺少跨模态证据或原图证据" : missingEvidence.joined(separator: "；")
        return "请确认「\(target)」是否为最终应写入的真实信息。原因：\(missing)"
    }

    private func mindMap(from topics: [MeetingTopicPayload]) -> [MindMapNode] {
        topics.map { topic in
            MindMapNode(
                title: topic.title,
                children: topic.subtopics.map { subtopic in
                    var children: [MindMapNode] = []
                    if !subtopic.conclusion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        children.append(MindMapNode(title: "结论：\(subtopic.conclusion)"))
                    }
                    children += subtopic.evidence.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                        .map { MindMapNode(title: "依据：\($0)") }
                    children += subtopic.risks.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                        .map { MindMapNode(title: "风险：\($0)") }
                    return MindMapNode(title: subtopic.title, children: children)
                }
            )
        }
    }

    private func normalizedKeyPoints(_ keyPoints: [String], topics: [MeetingTopicPayload]) -> [String] {
        guard !topics.isEmpty else { return keyPoints }
        if keyPoints.isEmpty {
            return topics.map { "【\($0.title)】\($0.summary)" }
        }
        return keyPoints
    }

    private func normalizedMinutes(_ minutes: [String], topics: [MeetingTopicPayload]) -> [String] {
        guard !topics.isEmpty else { return minutes }
        if minutes.isEmpty {
            return topics.flatMap { topic in
                topic.subtopics.map { subtopic in
                    "【\(topic.title)】\(subtopic.title)：\(subtopic.conclusion)"
                }
            }
        }
        return minutes
    }

    private func normalizedSummary(
        _ summary: String,
        topics: [MeetingTopicPayload],
        keyPoints: [String],
        minutes: [String]
    ) -> String {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        if !topics.isEmpty {
            return topics.prefix(3).map {
                let topicSummary = $0.summary.trimmingCharacters(in: .whitespacesAndNewlines)
                return topicSummary.isEmpty ? $0.title : "\($0.title)：\(topicSummary)"
            }
            .joined(separator: "；")
        }
        if !keyPoints.isEmpty {
            return keyPoints.prefix(3).joined(separator: "；")
        }
        if !minutes.isEmpty {
            return minutes.prefix(2).joined(separator: "；")
        }
        return ""
    }

    private func normalizedOptional(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private func preparedInput(from transcript: String, limit: Int) -> String {
        guard transcript.count > limit else { return transcript }
        let headCount = max(Int(Double(limit) * 0.45), 1)
        let middleCount = max(Int(Double(limit) * 0.20), 1)
        let tailCount = max(limit - headCount - middleCount, 1)
        let middleStart = transcript.index(transcript.startIndex, offsetBy: max((transcript.count - middleCount) / 2, 0))
        let middleEnd = transcript.index(middleStart, offsetBy: middleCount, limitedBy: transcript.endIndex) ?? transcript.endIndex
        let tailStart = transcript.index(transcript.endIndex, offsetBy: -min(tailCount, transcript.count))
        return [
            String(transcript.prefix(headCount)),
            "\n\n[中间内容节选]\n\n",
            String(transcript[middleStart..<middleEnd]),
            "\n\n[末尾内容节选]\n\n",
            String(transcript[tailStart...])
        ].joined()
    }

    private func transcriptChunks(from transcript: String, preferredChunkSize: Int) -> [String] {
        guard transcript.count > preferredChunkSize else { return [transcript] }
        let separators = CharacterSet(charactersIn: "。！？\n")
        let characters = Array(transcript)
        var chunks: [String] = []
        var start = 0

        while start < characters.count {
            let targetEnd = min(start + preferredChunkSize, characters.count)
            var end = targetEnd
            if end < characters.count {
                var cursor = end
                let lowerBound = max(start + Int(Double(preferredChunkSize) * 0.65), start + 1)
                while cursor > lowerBound {
                    if String(characters[cursor - 1]).rangeOfCharacter(from: separators) != nil {
                        end = cursor
                        break
                    }
                    cursor -= 1
                }
            }
            chunks.append(String(characters[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines))
            start = end
        }

        return chunks.filter { !$0.isEmpty }
    }

    private func mergeUserPrompt(
        chunkOutputs: [String],
        settings: MeetingAISettings,
        refinementInstructions: String
    ) -> String {
        let defaults = settings.defaultOrganizationInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        let refinement = refinementInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        let joined = chunkOutputs.enumerated().map { index, output in
            "分段 \(index + 1)：\n\(output)"
        }.joined(separator: "\n\n")
        return """
        默认整理偏好：
        \(defaults.isEmpty ? "无" : defaults)

        整理偏好边界：
        上述偏好只影响合并后的表达结构，不能覆盖人工确认、中枢复核 accepted/corrected、已应用到可信转写的修正或证据链结果。证据不足、已拒绝、已忽略或互相冲突的内容不得写成正式结论，只能标为“待确认”或放入 evidenceNotes。

        本次补充背景/纠偏要求：
        \(refinement.isEmpty ? "无" : refinement)

        以下是同一场会议的分段整理结果，请合并为完整会议纪要：
        \(joined)
        """
    }

    private func extractJSONObject(from content: String) -> String {
        let stripped = content
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = stripped.firstIndex(of: "{") else {
            return stripped
        }
        var depth = 0
        var inString = false
        var isEscaped = false
        var index = start

        while index < stripped.endIndex {
            let character = stripped[index]
            if inString {
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else if character == "\"" {
                inString = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    return String(stripped[start...index])
                }
            }
            index = stripped.index(after: index)
        }

        return String(stripped[start...])
    }

    private func shouldDisableThinking(for model: String) -> Bool {
        let normalized = model.lowercased()
        return normalized.contains("gemma-4") || normalized.contains("qwen3.5") || normalized.contains("qwen-plus")
    }

    private func discoverConflicts(
        in window: LocalConflictWindow,
        materials: [MeetingTruthMaterial],
        settings: MeetingAISettings,
        url: URL,
        segmentOffset: Int
    ) async throws -> [MeetingTruthConflict] {
        let attempts = [
            (sourceLimit: 1_200, materialLimit: 1_400, maxTokens: 4_200),
            (sourceLimit: 700, materialLimit: 800, maxTokens: 3_200)
        ]
        var lastError: Error?

        for attempt in attempts {
            do {
                let completion = try await requestCompletion(
                    url: url,
                    settings: settings,
                    systemContent: conflictDiscoverySystemPrompt,
                    userMessage: try conflictDiscoveryUserMessage(
                        sources: window.sources,
                        materials: materials,
                        sourceCharacterLimit: attempt.sourceLimit,
                        materialCharacterLimit: attempt.materialLimit
                    ),
                    maxTokens: attempt.maxTokens
                )
                guard completion.choices.first?.finishReason != "length" else {
                    throw MeetingAIError.responseTruncated
                }
                guard let content = assistantResponseText(from: completion), !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw MeetingAIError.emptyResponse
                }
        return try decodeDiscoveredConflicts(
            from: content,
            forceSegmentLocations: window.sources.allSatisfy { !$0.hasTimestamp },
            segmentOffset: segmentOffset
        )
            } catch {
                lastError = error
            }
        }
        throw lastError ?? MeetingAIError.emptyResponse
    }

    private func reviewConflictsAgainstFullContext(
        conflicts: [MeetingTruthConflict],
        sources: [MeetingTruthTranscriptSource],
        materials: [MeetingTruthMaterial],
        settings: MeetingAISettings,
        url: URL
    ) async throws -> [MeetingTruthConflict] {
        let batches = stride(from: 0, to: conflicts.count, by: 8).map {
            Array(conflicts[$0..<min($0 + 8, conflicts.count)])
        }
        var reviewed: [MeetingTruthConflict] = []
        reviewed.reserveCapacity(conflicts.count)
        var lastError: Error?

        for batch in batches {
            do {
                let completion = try await requestCompletion(
                    url: url,
                    settings: settings,
                    systemContent: fullContextConflictReviewSystemPrompt,
                    userMessage: try fullContextConflictReviewUserMessage(
                        conflicts: batch,
                        sources: sources,
                        materials: materials,
                        settings: settings
                    ),
                    maxTokens: usesLargeGemmaContext(settings.model)
                        ? min(max(settings.resolvedMaxTokens, 4_000), 16_000)
                        : min(max(settings.resolvedMaxTokens, 1_600), 3_200)
                )
                guard completion.choices.first?.finishReason != "length" else {
                    throw MeetingAIError.responseTruncated
                }
                guard let content = assistantResponseText(from: completion), !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw MeetingAIError.emptyResponse
                }
                reviewed.append(contentsOf: try decodeConflictResolutions(from: content, originalConflicts: batch))
            } catch {
                lastError = error
                reviewed.append(contentsOf: batch)
            }
        }

        if reviewed.isEmpty, let lastError {
            throw lastError
        }
        return deduplicatedConflicts(reviewed)
    }

    private func localConflictWindows(from sources: [MeetingTruthTranscriptSource]) -> [LocalConflictWindow] {
        let chunkedSources = sources.map { source in
            transcriptConflictWindows(from: source.text)
        }
        let windowCount = chunkedSources.map(\.count).max() ?? 0
        var windows: [LocalConflictWindow] = []

        for index in 0..<windowCount {
            let windowSources = sources.enumerated().compactMap { sourceIndex, source -> MeetingTruthTranscriptSource? in
                guard chunkedSources[sourceIndex].indices.contains(index) else { return nil }
                return MeetingTruthTranscriptSource(
                    name: source.name,
                    text: chunkedSources[sourceIndex][index]
                )
            }
            guard windowSources.count >= 2 else {
                continue
            }
            let differenceScore = localDifferenceScore(in: windowSources)
            guard differenceScore > 0.035 else { continue }
            windows.append(LocalConflictWindow(sources: windowSources, differenceScore: differenceScore))
        }
        return windows
    }

    private func localDifferenceScore(in sources: [MeetingTruthTranscriptSource]) -> Double {
        guard let baseline = sources.first else { return 0 }
        return sources.dropFirst().map {
            pairwiseDifferenceScore(baseline.text, $0.text)
        }.max() ?? 0
    }

    private func pairwiseDifferenceScore(_ lhs: String, _ rhs: String) -> Double {
        let characterDifference = 1 - characterBigramSimilarity(lhs, rhs)
        let salientDifference = jaccardDifference(
            salientTerms(in: lhs),
            salientTerms(in: rhs)
        )
        let numericDifference = jaccardDifference(
            numericTerms(in: lhs),
            numericTerms(in: rhs)
        )

        var score = max(characterDifference, salientDifference * 0.9)
        if numericDifference > 0 {
            score = max(score, 0.18 + numericDifference * 0.72)
        }
        if salientDifference > 0.12 {
            score += 0.05
        }
        return min(score, 1)
    }

    private func characterBigramSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let left = characterBigrams(in: lhs)
        let right = characterBigrams(in: rhs)
        guard !left.isEmpty || !right.isEmpty else { return 1 }
        let union = left.union(right)
        guard !union.isEmpty else { return 1 }
        return Double(left.intersection(right).count) / Double(union.count)
    }

    private func characterBigrams(in text: String) -> Set<String> {
        let characters = Array(
            text.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
        )
        guard characters.count >= 2 else { return Set(characters.map(String.init)) }
        return Set((0..<(characters.count - 1)).map {
            String(characters[$0...($0 + 1)])
        })
    }

    private func transcriptConflictWindows(from transcript: String) -> [String] {
        let preferredChunkSize = 420
        let minimumOverlap = 140
        guard transcript.count > preferredChunkSize else { return [transcript] }

        let separators = CharacterSet(charactersIn: "。！？；\n")
        let characters = Array(transcript)
        let step = max(preferredChunkSize - minimumOverlap, 1)
        var start = 0
        var chunks: [String] = []

        while start < characters.count {
            let targetEnd = min(start + preferredChunkSize, characters.count)
            var end = targetEnd
            if end < characters.count {
                var cursor = end
                let lowerBound = max(start + Int(Double(preferredChunkSize) * 0.6), start + 1)
                while cursor > lowerBound {
                    if String(characters[cursor - 1]).rangeOfCharacter(from: separators) != nil {
                        end = cursor
                        break
                    }
                    cursor -= 1
                }
            }

            let chunk = String(characters[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !chunk.isEmpty, chunks.last != chunk {
                chunks.append(chunk)
            }
            if end >= characters.count {
                break
            }
            start = min(start + step, end)
        }

        return chunks
    }

    private func salientTerms(in text: String) -> Set<String> {
        regexMatches(
            pattern: #"[A-Za-z][A-Za-z0-9._/-]{1,}|[\p{Han}]{2,}"#,
            in: text
        ).reduce(into: Set<String>()) { result, token in
            let normalized = token.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalized.count >= 2 else { return }
            result.insert(normalized)
        }
    }

    private func numericTerms(in text: String) -> Set<String> {
        Set(
            regexMatches(
                pattern: #"\d+(?:\.\d+)?(?:万|亿|%|岁|月|日|号|点|年|w|k)?|[一二三四五六七八九十百千万亿两]+(?:月|日|号|点|年|万|亿)?"#,
                in: text
            )
        )
    }

    private func jaccardDifference(_ lhs: Set<String>, _ rhs: Set<String>) -> Double {
        guard !lhs.isEmpty || !rhs.isEmpty else { return 0 }
        let union = lhs.union(rhs)
        guard !union.isEmpty else { return 0 }
        return 1 - (Double(lhs.intersection(rhs).count) / Double(union.count))
    }

    private func regexMatches(pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: range).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            return String(text[range])
        }
    }

    private func decodingIssueDescription(for error: DecodingError) -> String {
        switch error {
        case let .keyNotFound(key, context):
            return "模型返回的 JSON 缺少字段“\(key.stringValue)”。路径：\(codingPathDescription(context.codingPath))。"
        case let .valueNotFound(type, context):
            return "模型返回的 JSON 缺少 \(type) 类型内容。路径：\(codingPathDescription(context.codingPath))。"
        case let .typeMismatch(type, context):
            return "模型返回的 JSON 字段类型不匹配，预期 \(type)。路径：\(codingPathDescription(context.codingPath))。"
        case let .dataCorrupted(context):
            return "模型返回的 JSON 内容损坏：\(context.debugDescription)"
        @unknown default:
            return error.localizedDescription
        }
    }

    private func codingPathDescription(_ path: [CodingKey]) -> String {
        let parts = path.map(\.stringValue).filter { !$0.isEmpty }
        return parts.isEmpty ? "根节点" : parts.joined(separator: ".")
    }

    private func deduplicatedConflicts(_ conflicts: [MeetingTruthConflict]) -> [MeetingTruthConflict] {
        var seen: Set<String> = []
        return conflicts.filter {
            let key = "\($0.kind.rawValue)|\($0.recommendation.lowercased())|\($0.context.lowercased())"
            return seen.insert(key).inserted
        }
    }

    private func shouldUseChunkedAnalysis(for transcript: String, settings: MeetingAISettings) -> Bool {
        transcript.count > chunkInputLimit(for: settings)
    }

    private func adjustedMaxTokens(for settings: MeetingAISettings, compact: Bool) -> Int {
        analysisOutputTokens(for: settings, compact: compact)
    }

    private func resolvedInputLimit(for settings: MeetingAISettings, compact: Bool) -> Int {
        compact ? compactInputLimit(for: settings) : singlePassInputLimit(for: settings)
    }

    private func chunkInputLimit(for settings: MeetingAISettings) -> Int {
        if usesLargeGemmaContext(settings.model) {
            return min(settings.resolvedInputCharacterLimit, AnalysisGenerationBounds.largeContextSinglePassCharacters)
        }
        if shouldDisableThinking(for: settings.model) {
            return 6_000
        }
        return 9_000
    }

    private func fullContextSourceLimit(settings: MeetingAISettings, sourceCount: Int) -> Int {
        let count = max(sourceCount, 1)
        if usesLargeGemmaContext(settings.model) {
            let perSourceBudget = max(settings.resolvedInputCharacterLimit / count, 16_000)
            return min(perSourceBudget, 60_000)
        }
        return min(max(settings.resolvedInputCharacterLimit / max(count + 1, 1), 4_000), 8_000)
    }

    private func usesLargeGemmaContext(_ model: String) -> Bool {
        let normalized = model.lowercased()
        return normalized.contains("gemma-4-e4b")
            || normalized.contains("gemma-4-12b")
            || normalized.contains("gemma-4-26b")
    }

    private func assistantResponseText(from completion: ChatCompletionResponse) -> String? {
        guard let message = completion.choices.first?.message else { return nil }
        let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if !content.isEmpty {
            return content
        }
        return nil
    }

    private func analysisUserMessage(
        transcript: String,
        materials: [MeetingTruthMaterial],
        settings: MeetingAISettings,
        refinementInstructions: String
    ) -> ChatRequestMessage {
        multimodalUserMessage(
            text: analysisUserPrompt(
                transcript: transcript,
                settings: settings,
                refinementInstructions: refinementInstructions + materialReferenceInstructions(for: materials)
            ),
            materials: materials,
            imageInstruction: """
            以下图片是会议相关原始材料，必须作为原图 image_url 输入理解，而不是先转成文字再处理。
            请优先利用只有原图能提供的视觉事实：版式层级、表格结构、圈注/箭头/框选、手写位置、截图界面状态、空间靠近关系、视觉强调。
            如果某个结论只来自图片 OCR 文本，不得标成“原图证据”；只有结论依赖上述视觉事实时，才可写为“图片原图/多模态融合”。
            """
        )
    }

    private func multimodalUserMessage(
        text: String,
        materials: [MeetingTruthMaterial],
        imageInstruction: String
    ) -> ChatRequestMessage {
        let imageParts = imageContentParts(from: materials)
        guard !imageParts.isEmpty else {
            return ChatRequestMessage(role: "user", content: text)
        }

        var parts: [ChatMessageContentPart] = [.text(text)]
        parts.append(.text("\n\n\(imageInstruction)"))
        parts.append(contentsOf: imageParts)
        return ChatRequestMessage(role: "user", parts: parts)
    }

    private func materialReferenceInstructions(for materials: [MeetingTruthMaterial]) -> String {
        let textualEvidence = materials
            .filter {
                !isImageMaterial($0) &&
                !$0.extractedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            .prefix(3)
            .map {
                let excerpt = String($0.extractedText.prefix(1_200))
                let suffix = $0.extractedText.count > excerpt.count ? "\n[材料节选已截断]" : ""
                return "【\($0.name)】\n\(excerpt)\(suffix)"
            }
            .joined(separator: "\n\n")

        let imageOCRBaseline = materials
            .filter {
                isImageMaterial($0) &&
                !$0.extractedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            .prefix(2)
            .map {
                let excerpt = String($0.extractedText.prefix(500))
                return "【\($0.name) OCR 基线】\n\(excerpt)"
            }
            .joined(separator: "\n\n")

        let imageNames = materials
            .filter { isImageMaterial($0) }
            .prefix(3)
            .map(\.name)

        var sections: [String] = []
        if !textualEvidence.isEmpty {
            sections.append("以下是可直接引用的会议材料文本证据：\n\(textualEvidence)")
        }
        if !imageOCRBaseline.isEmpty {
            sections.append("以下图片 OCR 只作为基线对照，不可替代原图多模态判断，也不可单独作为“图片原图证据”：\n\(imageOCRBaseline)")
        }
        if !imageNames.isEmpty {
            sections.append("另外还附带了 \(imageNames.count) 张图片材料原图：\(imageNames.joined(separator: "、"))。必须直接阅读 image_url 原图，利用版式、空间关系、圈注、箭头、框选、手写位置和截图状态；不能把图片 OCR 当作多模态结果。")
        }
        guard !sections.isEmpty else { return "" }
        return "\n\n补充会议材料：\n" + sections.joined(separator: "\n\n")
    }

    private func imageContentParts(from materials: [MeetingTruthMaterial]) -> [ChatMessageContentPart] {
        Array(materials.filter(isImageMaterial).prefix(3)).reduce(into: [ChatMessageContentPart]()) { result, material in
            guard let dataURL = dataURLForImageMaterial(material) else { return }
            result.append(.text("图片材料：\(material.name)\n类型：\(material.kind)\n说明：\(material.detail)"))
            result.append(.imageURL(dataURL))
        }
    }

    private func isImageMaterial(_ material: MeetingTruthMaterial) -> Bool {
        material.kind == "图片" && material.localPath != nil
    }

    private func dataURLForImageMaterial(_ material: MeetingTruthMaterial) -> String? {
        guard let localPath = material.localPath else { return nil }
        let url = URL(fileURLWithPath: localPath)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "image/png"
        return "data:\(mimeType);base64,\(data.base64EncodedString())"
    }
}

enum MeetingAIError: LocalizedError {
    case emptyTranscript
    case insufficientTranscriptSources
    case missingAPIKey
    case invalidBaseURL
    case requestFailed(Int, String)
    case emptyResponse
    case invalidJSON
    case invalidAnalysisPayload(String)
    case responseTruncated
    case responseTruncatedAfterRetries(String)
    case chunkResponseTruncated(Int, Int, String)
    case mergeResponseTruncated(String)

    static func isTruncationRelated(_ error: Error) -> Bool {
        guard let error = error as? MeetingAIError else { return false }
        switch error {
        case .responseTruncated, .responseTruncatedAfterRetries, .chunkResponseTruncated, .mergeResponseTruncated:
            return true
        default:
            return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .emptyTranscript: "没有可整理的转写文本。"
        case .insufficientTranscriptSources: "至少需要两份候选转写，才能发现多源冲突。"
        case .missingAPIKey: "请先在设置里填写 AI API Key。"
        case .invalidBaseURL: "AI Base URL 不是有效地址。"
        case let .requestFailed(status, body): "AI 请求失败（HTTP \(status)）：\(body)"
        case .emptyResponse: "AI 没有返回可解析内容。"
        case .invalidJSON: "AI 返回内容不是有效 JSON，请换用更强模型或提高 token plan。"
        case let .invalidAnalysisPayload(message): "会议成果包生成失败：\(message)"
        case .responseTruncated: "AI 返回被截断了，系统正在尝试用更紧凑的方式重试。"
        case let .responseTruncatedAfterRetries(boundaries):
            "会议成果包生成失败：AI 返回内容在自动分段和重试后仍然被截断。\n\(boundaries)"
        case let .chunkResponseTruncated(index, total, boundaries):
            "会议成果包生成失败：第 \(index)/\(total) 段整理结果被截断，当前模型的单段返回长度不足。\n\(boundaries)"
        case let .mergeResponseTruncated(boundaries):
            "会议成果包生成失败：分段整理已完成，但最终合并结果被截断。\n\(boundaries)"
        }
    }
}

private struct MeetingTruthToolCallingRun {
    var records: [MeetingTruthToolCallRecord]
    var comparison: MeetingTruthToolCallingComparison
    var tokenUsage: MeetingTruthTokenUsage?
}

private struct MeetingTruthRequestedToolCall {
    var id: String? = nil
    var name: String
    var arguments: String
    var invocationSource: MeetingTruthToolInvocationSource
}

private struct MeetingTruthToolResultPayload: Encodable {
    var functionName: String
    var argumentsSummary: String
    var resultSummary: String
    var impactSummary: String
    var status: String
    var asrConflicts: [MeetingTruthASRConflictFinding]
    var evidenceChain: [MeetingTruthEvidenceSupport]
    var candidateScores: [MeetingTruthCandidateScore]
    var factDecision: MeetingTruthFactDecisionTrace?
    var humanReviewTask: MeetingTruthHumanReviewTask?
    var affectedMinutesText: String

    enum CodingKeys: String, CodingKey {
        case functionName = "function_name"
        case argumentsSummary = "arguments_summary"
        case resultSummary = "result_summary"
        case impactSummary = "impact_summary"
        case status
        case asrConflicts = "asr_conflicts"
        case evidenceChain = "evidence_chain"
        case candidateScores = "candidate_scores"
        case factDecision = "fact_decision"
        case humanReviewTask = "human_review_task"
        case affectedMinutesText = "affected_minutes_text"
    }
}

private struct MeetingTruthStructuredToolCallPayload: Decodable {
    var toolCalls: [ToolCall]

    enum CodingKeys: String, CodingKey {
        case toolCalls = "tool_calls"
    }

    struct ToolCall: Decodable {
        var name: String
        var arguments: [String: String]
    }
}

private struct ChatCompletionRequest: Encodable {
    let model: String
    let messages: [ChatRequestMessage]
    let temperature: Double
    let maxTokens: Int
    let enableThinking: Bool?
    let tools: [ChatToolDefinition]?
    let toolChoice: String?

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case temperature
        case maxTokens = "max_tokens"
        case enableThinking = "enable_thinking"
        case tools
        case toolChoice = "tool_choice"
    }
}

private struct ChatToolDefinition: Encodable {
    var type = "function"
    var function: Function

    struct Function: Encodable {
        var name: String
        var description: String
        var parameters: Parameters
    }

    struct Parameters: Encodable {
        var type = "object"
        var properties: [String: Property]
        var required: [String]
    }

    struct Property: Encodable {
        var type: String
        var description: String
    }
}

private struct ChatRequestMessage: Encodable {
    let role: String
    let content: ChatRequestContent
    let reasoningContent: String?
    let toolCalls: [ChatToolCall]?
    let toolCallID: String?
    let name: String?

    init(role: String, content: String, reasoningContent: String? = nil) {
        self.role = role
        self.content = .text(content)
        self.reasoningContent = reasoningContent
        self.toolCalls = nil
        self.toolCallID = nil
        self.name = nil
    }

    init(role: String, parts: [ChatMessageContentPart], reasoningContent: String? = nil) {
        self.role = role
        self.content = .parts(parts)
        self.reasoningContent = reasoningContent
        self.toolCalls = nil
        self.toolCallID = nil
        self.name = nil
    }

    static func assistantToolCalls(_ toolCalls: [ChatToolCall]) -> ChatRequestMessage {
        ChatRequestMessage(
            role: "assistant",
            content: .text(""),
            reasoningContent: nil,
            toolCalls: toolCalls,
            toolCallID: nil,
            name: nil
        )
    }

    static func toolResult(toolCallID: String, name: String, content: String) -> ChatRequestMessage {
        ChatRequestMessage(
            role: "tool",
            content: .text(content),
            reasoningContent: nil,
            toolCalls: nil,
            toolCallID: toolCallID,
            name: name
        )
    }

    private init(
        role: String,
        content: ChatRequestContent,
        reasoningContent: String?,
        toolCalls: [ChatToolCall]?,
        toolCallID: String?,
        name: String?
    ) {
        self.role = role
        self.content = content
        self.reasoningContent = reasoningContent
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.name = name
    }

    enum CodingKeys: String, CodingKey {
        case role
        case content
        case reasoningContent = "reasoning_content"
        case toolCalls = "tool_calls"
        case toolCallID = "tool_call_id"
        case name
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        try container.encode(content, forKey: .content)
        try container.encodeIfPresent(reasoningContent, forKey: .reasoningContent)
        try container.encodeIfPresent(toolCalls, forKey: .toolCalls)
        try container.encodeIfPresent(toolCallID, forKey: .toolCallID)
        try container.encodeIfPresent(name, forKey: .name)
    }
}

private enum ChatRequestContent: Encodable {
    case text(String)
    case parts([ChatMessageContentPart])

    func encode(to encoder: Encoder) throws {
        var singleValueContainer = encoder.singleValueContainer()
        switch self {
        case let .text(content):
            try singleValueContainer.encode(content)
        case let .parts(parts):
            try singleValueContainer.encode(parts)
        }
    }
}

private enum ChatMessageContentPart: Encodable {
    case text(String)
    case imageURL(String)

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .text(text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case let .imageURL(url):
            try container.encode("image_url", forKey: .type)
            try container.encode(ImageURL(url: url), forKey: .imageURL)
        }
    }

    private struct ImageURL: Encodable {
        let url: String
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case imageURL = "image_url"
    }
}

private struct LocalConflictWindow {
    let sources: [MeetingTruthTranscriptSource]
    let differenceScore: Double
}

private struct ChatCompletionResponse: Decodable {
    let choices: [Choice]
    let usage: ChatUsage?

    struct Choice: Decodable {
        let message: ChatResponseMessage
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case message
            case finishReason = "finish_reason"
        }
    }
}

private struct ChatUsage: Decodable {
    let promptTokens: Int?
    let completionTokens: Int?
    let totalTokens: Int?

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
    }

    var meetingTruthUsage: MeetingTruthTokenUsage {
        MeetingTruthTokenUsage(
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            totalTokens: totalTokens
        )
    }
}

private struct ChatResponseMessage: Decodable {
    let role: String
    let content: String
    let reasoningContent: String?
    let toolCalls: [ChatToolCall]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decode(String.self, forKey: .role)
        reasoningContent = try container.decodeIfPresent(String.self, forKey: .reasoningContent)
        if let text = try? container.decode(String.self, forKey: .content) {
            content = text
        } else {
            let parts = try container.decodeIfPresent([ChatResponseContentPart].self, forKey: .content) ?? []
            content = parts.compactMap(\.text).joined(separator: "\n")
        }
        toolCalls = try container.decodeIfPresent([ChatToolCall].self, forKey: .toolCalls) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case role
        case content
        case reasoningContent = "reasoning_content"
        case toolCalls = "tool_calls"
    }
}

private struct ChatToolCall: Codable {
    let id: String?
    let type: String?
    let function: Function

    struct Function: Codable {
        let name: String
        let arguments: String
    }
}

private struct ChatResponseContentPart: Decodable {
    let text: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decodeIfPresent(String.self, forKey: .text)
    }

    private enum CodingKeys: String, CodingKey {
        case text
    }
}

private struct MeetingAnalysisPayload: Decodable {
    var topics: [MeetingTopicPayload] = []
    var summary: String
    var keyPoints: [String]
    var mindMap: [MindMapNode]
    var minutes: [String]
    var actionItems: [ActionPayload]
    var evidenceNotes: [String]

    enum CodingKeys: String, CodingKey {
        case topics
        case summary
        case keyPoints
        case mindMap
        case minutes
        case actionItems
        case evidenceNotes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        topics = try container.decodeIfPresent([MeetingTopicPayload].self, forKey: .topics) ?? []
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        keyPoints = try container.decodeIfPresent([String].self, forKey: .keyPoints) ?? []
        mindMap = try container.decodeIfPresent([MindMapNode].self, forKey: .mindMap) ?? []
        minutes = try container.decodeIfPresent([String].self, forKey: .minutes) ?? []
        actionItems = try container.decodeIfPresent([ActionPayload].self, forKey: .actionItems) ?? []
        evidenceNotes = try container.decodeIfPresent([String].self, forKey: .evidenceNotes) ?? []
    }

    struct ActionPayload: Decodable {
        var task: String
        var owner: String?
        var due: String?

        enum CodingKeys: String, CodingKey {
            case task
            case owner
            case due
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            task = try container.decodeIfPresent(String.self, forKey: .task) ?? ""
            owner = try container.decodeIfPresent(String.self, forKey: .owner)
            due = try container.decodeIfPresent(String.self, forKey: .due)
        }
    }
}

private struct VisualEvidenceResponsePayload: Decodable {
    var evidence: [Evidence]

    struct Evidence: Decodable {
        struct Participant: Decodable {
            var name: String
            var role: String
            var organization: String
            var evidence: String
            var confidence: String

            enum CodingKeys: String, CodingKey {
                case name
                case role
                case organization
                case evidence
                case confidence
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
                role = try container.decodeIfPresent(String.self, forKey: .role) ?? ""
                organization = try container.decodeIfPresent(String.self, forKey: .organization) ?? ""
                evidence = try container.decodeIfPresent(String.self, forKey: .evidence) ?? ""
                confidence = try container.decodeIfPresent(String.self, forKey: .confidence) ?? "low"
            }
        }

        var materialName: String
        var summary: String
        var participants: [Participant]
        var numbers: [String]
        var keywords: [String]
        var actionHints: [String]
        var layoutCues: [String]
        var visualMarks: [String]
        var ocrContrast: String
        var confidence: String

        enum CodingKeys: String, CodingKey {
            case materialName = "material_name"
            case summary
            case participants
            case numbers
            case keywords
            case actionHints = "action_hints"
            case layoutCues = "layout_cues"
            case visualMarks = "visual_marks"
            case ocrContrast = "ocr_contrast"
            case confidence
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            materialName = try container.decodeIfPresent(String.self, forKey: .materialName) ?? ""
            summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
            participants = try container.decodeIfPresent([Participant].self, forKey: .participants) ?? []
            numbers = try container.decodeIfPresent([String].self, forKey: .numbers) ?? []
            keywords = try container.decodeIfPresent([String].self, forKey: .keywords) ?? []
            actionHints = try container.decodeIfPresent([String].self, forKey: .actionHints) ?? []
            layoutCues = try container.decodeIfPresent([String].self, forKey: .layoutCues) ?? []
            visualMarks = try container.decodeIfPresent([String].self, forKey: .visualMarks) ?? []
            ocrContrast = try container.decodeIfPresent(String.self, forKey: .ocrContrast) ?? ""
            confidence = try container.decodeIfPresent(String.self, forKey: .confidence) ?? "low"
        }
    }
}

private struct CentralReviewRequestPayload: Encodable {
    var workflowInstruction: String
    var transcripts: [Transcript]
    var materials: [Material]
    var visualEvidence: [VisualEvidence]
    var conflicts: [Conflict]
    var factDecisions: [FactDecision]
    var humanConfirmations: [HumanConfirmation]
    var currentCentralLedger: CurrentLedger?
    var generatedPackage: GeneratedPackage?
    var toolCallingAudit: ToolCallingAudit?

    struct Transcript: Encodable {
        var name: String
        var originalLabelRole: String
        var hasTimestamp: Bool
        var text: String
    }

    struct Material: Encodable {
        var name: String
        var originalLabelRole: String
        var kind: String
        var detail: String
        var ocrOrExtractedText: String
    }

    struct VisualEvidence: Encodable {
        var materialName: String
        var summary: String
        var participants: [String]
        var numbers: [String]
        var keywords: [String]
        var actionHints: [String]
        var layoutCues: [String]
        var visualMarks: [String]
        var ocrContrast: String
        var confidence: String
    }

    struct Conflict: Encodable {
        var conflictID: String
        var kind: String
        var context: String
        var candidates: [String]
        var recommendation: String
        var confidence: String
        var selectedText: String
        var evidence: String
    }

    struct FactDecision: Encodable {
        var factID: String
        var kind: String
        var claim: String
        var chosenText: String
        var status: String
        var confidence: Double
        var missingEvidence: [String]
        var requiresUserInput: Bool
        var importance: String
        var riskLevel: String
        var reason: String
    }

    struct HumanConfirmation: Encodable {
        var confirmationID: String
        var source: String
        var kind: String
        var confirmedText: String
        var originalTexts: [String]
        var relatedClaim: String
        var instruction: String

        enum CodingKeys: String, CodingKey {
            case confirmationID = "confirmation_id"
            case source
            case kind
            case confirmedText = "confirmed_text"
            case originalTexts = "original_texts"
            case relatedClaim = "related_claim"
            case instruction
        }
    }

    struct CurrentLedger: Encodable {
        var blockingItems: [String]
        var advisoryItems: [String]
        var claims: [Claim]

        struct Claim: Encodable {
            var kind: String
            var claim: String
            var proposedCanonicalText: String
            var status: String
            var confidence: Double
            var missingEvidence: [String]
            var decisionReason: String
        }
    }

    struct GeneratedPackage: Encodable {
        var summary: String
        var keyPoints: [String]
        var minutes: [String]
        var actionItems: [String]
        var evidenceNotes: [String]
    }

    struct ToolCallingAudit: Encodable {
        var records: [Record]
        var comparison: Comparison

        struct Record: Encodable {
            var functionName: String
            var argumentsSummary: String
            var resultSummary: String
            var impactSummary: String
            var status: String
        }

        struct Comparison: Encodable {
            var baselineSummary: String
            var toolCallingSummary: String
            var improvements: [String]
            var limitations: [String]
            var invokedToolCount: Int
            var impactedClaimCount: Int
        }
    }
}

private struct CentralReviewResponsePayload: Decodable {
    var inputSummary: [String]
    var visualObservations: [VisualObservation]
    var claims: [Claim]
    var gaps: [Gap]
    var packageAuditNotes: [String]
    var completionStandard: [String]

    enum CodingKeys: String, CodingKey {
        case inputSummary = "input_summary"
        case visualObservations = "visual_observations"
        case claims
        case gaps
        case packageAuditNotes = "package_audit_notes"
        case completionStandard = "completion_standard"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        inputSummary = try container.decodeIfPresent([String].self, forKey: .inputSummary) ?? []
        visualObservations = try container.decodeIfPresent([VisualObservation].self, forKey: .visualObservations) ?? []
        claims = try container.decodeIfPresent([Claim].self, forKey: .claims) ?? []
        gaps = try container.decodeIfPresent([Gap].self, forKey: .gaps) ?? []
        packageAuditNotes = try container.decodeIfPresent([String].self, forKey: .packageAuditNotes) ?? []
        completionStandard = try container.decodeIfPresent([String].self, forKey: .completionStandard) ?? []
    }

    struct VisualObservation: Decodable {
        var materialName: String
        var materialRole: String
        var summary: String
        var layoutCues: [String]
        var visualMarks: [String]
        var actionHints: [String]
        var ocrBaseline: String
        var ocrContrast: String
        var confidence: String

        enum CodingKeys: String, CodingKey {
            case materialName = "material_name"
            case materialRole = "material_role"
            case summary
            case layoutCues = "layout_cues"
            case visualMarks = "visual_marks"
            case actionHints = "action_hints"
            case ocrBaseline = "ocr_baseline"
            case ocrContrast = "ocr_contrast"
            case confidence
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            materialName = try container.decodeIfPresent(String.self, forKey: .materialName) ?? ""
            materialRole = try container.decodeIfPresent(String.self, forKey: .materialRole) ?? ""
            summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
            layoutCues = try container.decodeIfPresent([String].self, forKey: .layoutCues) ?? []
            visualMarks = try container.decodeIfPresent([String].self, forKey: .visualMarks) ?? []
            actionHints = try container.decodeIfPresent([String].self, forKey: .actionHints) ?? []
            ocrBaseline = try container.decodeIfPresent(String.self, forKey: .ocrBaseline) ?? ""
            ocrContrast = try container.decodeIfPresent(String.self, forKey: .ocrContrast) ?? ""
            confidence = try container.decodeIfPresent(String.self, forKey: .confidence) ?? "low"
        }
    }

    struct Claim: Decodable {
        var kind: String
        var claim: String
        var proposedCanonicalText: String
        var sourceSpan: String
        var status: String
        var confidence: Double
        var importance: String
        var riskLevel: String
        var supportingEvidence: [Evidence]
        var contradictingEvidence: [Evidence]
        var missingEvidence: [String]
        var humanQuestion: String
        var decisionReason: String

        enum CodingKeys: String, CodingKey {
            case kind
            case claim
            case proposedCanonicalText = "proposed_canonical_text"
            case sourceSpan = "source_span"
            case status
            case confidence
            case importance
            case riskLevel = "risk_level"
            case supportingEvidence = "supporting_evidence"
            case contradictingEvidence = "contradicting_evidence"
            case missingEvidence = "missing_evidence"
            case humanQuestion = "human_question"
            case decisionReason = "decision_reason"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? "term"
            claim = try container.decodeIfPresent(String.self, forKey: .claim) ?? ""
            proposedCanonicalText = try container.decodeIfPresent(String.self, forKey: .proposedCanonicalText) ?? ""
            sourceSpan = try container.decodeIfPresent(String.self, forKey: .sourceSpan) ?? ""
            status = try container.decodeIfPresent(String.self, forKey: .status) ?? "needsHumanReview"
            confidence = try container.decodeIfPresent(Double.self, forKey: .confidence) ?? 0
            importance = try container.decodeIfPresent(String.self, forKey: .importance) ?? "medium"
            riskLevel = try container.decodeIfPresent(String.self, forKey: .riskLevel) ?? "high"
            supportingEvidence = try container.decodeIfPresent([Evidence].self, forKey: .supportingEvidence) ?? []
            contradictingEvidence = try container.decodeIfPresent([Evidence].self, forKey: .contradictingEvidence) ?? []
            missingEvidence = try container.decodeIfPresent([String].self, forKey: .missingEvidence) ?? []
            humanQuestion = try container.decodeIfPresent(String.self, forKey: .humanQuestion) ?? ""
            decisionReason = try container.decodeIfPresent(String.self, forKey: .decisionReason) ?? ""
        }
    }

    struct Evidence: Decodable {
        var channel: String
        var sourceName: String
        var text: String
        var visualCue: String
        var confidence: Double

        enum CodingKeys: String, CodingKey {
            case channel
            case sourceName = "source_name"
            case text
            case visualCue = "visual_cue"
            case confidence
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            channel = try container.decodeIfPresent(String.self, forKey: .channel) ?? "material"
            sourceName = try container.decodeIfPresent(String.self, forKey: .sourceName) ?? ""
            text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
            visualCue = try container.decodeIfPresent(String.self, forKey: .visualCue) ?? ""
            confidence = try container.decodeIfPresent(Double.self, forKey: .confidence) ?? 0
        }
    }

    struct Gap: Decodable {
        var kind: String
        var title: String
        var detail: String
        var requiresHumanReview: Bool

        enum CodingKeys: String, CodingKey {
            case kind
            case title
            case detail
            case requiresHumanReview = "requires_human_review"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? "noCrossModalEvidence"
            title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
            detail = try container.decodeIfPresent(String.self, forKey: .detail) ?? ""
            requiresHumanReview = try container.decodeIfPresent(Bool.self, forKey: .requiresHumanReview) ?? true
        }
    }
}

private struct MeetingTopicPayload: Decodable {
    var id: String
    var title: String
    var summary: String
    var subtopics: [Subtopic]

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case summary
        case subtopics
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        subtopics = try container.decodeIfPresent([Subtopic].self, forKey: .subtopics) ?? []
    }

    struct Subtopic: Decodable {
        var title: String
        var conclusion: String
        var evidence: [String]
        var risks: [String]

        enum CodingKeys: String, CodingKey {
            case title
            case conclusion
            case evidence
            case risks
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
            conclusion = try container.decodeIfPresent(String.self, forKey: .conclusion) ?? ""
            evidence = try container.decodeIfPresent([String].self, forKey: .evidence) ?? []
            risks = try container.decodeIfPresent([String].self, forKey: .risks) ?? []
        }
    }
}

private struct MeetingTruthConflictRequestPayload: Encodable {
    var materials: [Material]
    var conflicts: [Conflict]

    struct Material: Encodable {
        var name: String
        var kind: String
        var detail: String
        var extractedText: String

        enum CodingKeys: String, CodingKey {
            case name
            case kind
            case detail
            case extractedText = "extracted_text"
        }
    }

    struct Conflict: Encodable {
        var conflictID: String
        var timestamp: String
        var kind: String
        var context: String
        var candidates: [Candidate]

        enum CodingKeys: String, CodingKey {
            case conflictID = "conflict_id"
            case timestamp
            case kind
            case context
            case candidates
        }
    }

    struct Candidate: Encodable {
        var source: String
        var text: String
    }
}

private struct MeetingTruthConflictDiscoveryRequestPayload: Encodable {
    var materials: [MeetingTruthConflictRequestPayload.Material]
    var sources: [Source]

    struct Source: Encodable {
        var name: String
        var text: String
    }
}

private struct MeetingTruthFullContextConflictReviewPayload: Encodable {
    var materials: [MeetingTruthConflictRequestPayload.Material]
    var sources: [Source]
    var conflicts: [Conflict]

    struct Source: Encodable {
        var name: String
        var text: String
    }

    struct Conflict: Encodable {
        var conflictID: String
        var timestamp: String
        var kind: String
        var context: String
        var candidates: [MeetingTruthConflictRequestPayload.Candidate]
        var currentRecommendation: String
        var currentConfidence: String
        var currentEvidence: String

        enum CodingKeys: String, CodingKey {
            case conflictID = "conflict_id"
            case timestamp
            case kind
            case context
            case candidates
            case currentRecommendation = "current_recommendation"
            case currentConfidence = "current_confidence"
            case currentEvidence = "current_evidence"
        }
    }
}

private struct MeetingTruthConflictResponsePayload: Decodable {
    var resolutions: [Resolution]

    struct Resolution: Decodable {
        var conflictID: String
        var recommendation: String
        var confidence: String
        var needHumanReview: Bool
        var evidence: String

        enum CodingKeys: String, CodingKey {
            case conflictID = "conflict_id"
            case recommendation
            case confidence
            case needHumanReview = "need_human_review"
            case evidence
        }
    }
}

private struct MeetingTruthConflictDiscoveryResponsePayload: Decodable {
    var conflicts: [Conflict]

    struct Conflict: Decodable {
        var timestamp: String
        var kind: String
        var context: String
        var candidates: [Candidate]
        var recommendation: String
        var confidence: String
        var evidence: String
    }

    struct Candidate: Decodable {
        var source: String
        var text: String
    }
}
