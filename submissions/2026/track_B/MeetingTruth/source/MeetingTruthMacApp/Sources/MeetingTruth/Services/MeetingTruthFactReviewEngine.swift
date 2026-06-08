import Foundation

struct MeetingTruthFactReviewEngine {
    func extractFacts(
        from trustedTranscript: String,
        sources: [MeetingTruthTranscriptSource]
    ) -> [MeetingTruthFactCandidate] {
        let sentences = Self.sentences(from: trustedTranscript)
        var facts: [MeetingTruthFactCandidate] = []

        for sentence in sentences {
            guard let trimmed = Self.factReviewSentence(from: sentence) else { continue }
            guard trimmed.count >= 3 else { continue }

            facts.append(contentsOf: Self.semanticReviewCandidates(from: trimmed))
        }

        return Self.deduplicated(facts)
            .filter { $0.gateStatus != .rejectedAsLowValue }
            .prefix(80)
            .map { $0 }
    }

    private static func semanticReviewCandidates(from sentence: String) -> [MeetingTruthFactCandidate] {
        var facts: [MeetingTruthFactCandidate] = []

        for value in Self.matches(in: sentence, pattern: Self.amountPattern) {
            facts.append(Self.fact(.amount, claim: value, span: sentence, importance: .high, risk: .high, confidence: 0.54))
        }
        for value in Self.matches(in: sentence, pattern: Self.datePattern) {
            guard Self.isReviewableDate(value, in: sentence) else { continue }
            facts.append(Self.fact(.date, claim: value, span: sentence, importance: .high, risk: .high, confidence: 0.54))
        }
        for value in Self.projectNameClaims(from: sentence) {
            facts.append(Self.fact(.project, claim: value, span: sentence, importance: .high, risk: .high, confidence: 0.52))
        }
        for value in Self.personClaims(from: sentence) {
            facts.append(Self.fact(.person, claim: value, span: sentence, importance: .high, risk: .high, confidence: 0.50))
        }
        if Self.containsAny(sentence, Self.ownerKeywords),
           let owner = Self.personClaims(from: sentence).first,
           Self.isReviewableActionSentence(sentence) {
            facts.append(Self.fact(.owner, claim: owner, span: sentence, importance: .high, risk: .high, confidence: 0.50))
        }
        if Self.isReviewableDecisionSentence(sentence) {
            facts.append(Self.fact(.decision, claim: Self.compactClaim(sentence), span: sentence, importance: .high, risk: .medium, confidence: 0.58))
        }
        if Self.isReviewableActionSentence(sentence) {
            facts.append(Self.fact(.actionItem, claim: Self.compactClaim(sentence), span: sentence, importance: .high, risk: .medium, confidence: 0.58))
        }
        if Self.isReviewableRiskSentence(sentence) {
            facts.append(Self.fact(.risk, claim: Self.compactClaim(sentence), span: sentence, importance: .high, risk: .medium, confidence: 0.56))
        }
        for term in Self.termClaims(from: sentence) where Self.isReviewableTerm(term, in: sentence) {
            facts.append(Self.fact(.term, claim: term, span: sentence, importance: .medium, risk: .medium, confidence: 0.56))
        }

        return facts.filter(Self.acceptedForAdjudication)
    }

    private static func legacyRegexCandidates(from trimmed: String) -> [MeetingTruthFactCandidate] {
        var facts: [MeetingTruthFactCandidate] = []
            for value in Self.matches(in: trimmed, pattern: Self.amountPattern) {
                facts.append(Self.fact(.amount, claim: value, span: trimmed, importance: .high, risk: .high, confidence: 0.52))
            }
            for value in Self.matches(in: trimmed, pattern: Self.datePattern) {
                guard Self.isReviewableDate(value, in: trimmed) else { continue }
                facts.append(Self.fact(.date, claim: value, span: trimmed, importance: .high, risk: .high, confidence: 0.52))
            }
            for value in Self.matches(in: trimmed, pattern: Self.projectPattern) {
                facts.append(Self.fact(.project, claim: value, span: trimmed, importance: .high, risk: .high, confidence: 0.50))
            }
            for value in Self.personClaims(from: trimmed) {
                facts.append(Self.fact(.person, claim: value, span: trimmed, importance: .high, risk: .high, confidence: 0.48))
            }
            if Self.containsAny(trimmed, Self.ownerKeywords),
               let owner = Self.personClaims(from: trimmed).first {
                facts.append(Self.fact(.owner, claim: owner, span: trimmed, importance: .high, risk: .high, confidence: 0.48))
            }
            if Self.containsAny(trimmed, Self.decisionKeywords),
               Self.isReviewableStatement(trimmed, kind: .decision) {
                facts.append(Self.fact(.decision, claim: Self.compactClaim(trimmed), span: trimmed, importance: .high, risk: .medium, confidence: 0.56))
            }
            if Self.containsAny(trimmed, Self.actionKeywords),
               Self.isReviewableStatement(trimmed, kind: .actionItem) {
                facts.append(Self.fact(.actionItem, claim: Self.compactClaim(trimmed), span: trimmed, importance: .high, risk: .medium, confidence: 0.54))
            }
            if Self.containsAny(trimmed, Self.riskKeywords),
               Self.isReviewableStatement(trimmed, kind: .risk) {
                facts.append(Self.fact(.risk, claim: Self.compactClaim(trimmed), span: trimmed, importance: .high, risk: .medium, confidence: 0.54))
            }
            for term in Self.termClaims(from: trimmed) {
                facts.append(Self.fact(.term, claim: term, span: trimmed, importance: .low, risk: .low, confidence: 0.58))
            }
        return facts
    }

    private static func factReviewSentence(from sentence: String) -> String? {
        var trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        let systemLabels = [
            "已确认会议信息：",
            "已确认会议信息:",
            "已确认会议信息"
        ]
        if systemLabels.contains(trimmed) {
            return nil
        }
        if trimmed.hasPrefix("- ") {
            trimmed = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if Self.isLowValueReviewSentence(trimmed) {
            return nil
        }
        return trimmed.isEmpty ? nil : trimmed
    }

    func collectEvidence(
        for facts: [MeetingTruthFactCandidate],
        transcriptSources: [MeetingTruthTranscriptSource],
        materials: [MeetingTruthMaterial],
        visualEvidence: [MeetingTruthVisualEvidence],
        conflicts: [MeetingTruthConflict],
        confirmations: [MeetingTruthManualConfirmation]
    ) -> [MeetingTruthEvidenceAtom] {
        var atoms: [MeetingTruthEvidenceAtom] = []

        for fact in facts {
            let matchingSources = transcriptSources.filter { Self.text($0.text, matches: fact.claim, span: fact.sourceSpan) }
            if matchingSources.isEmpty {
                atoms.append(Self.atom(fact, channel: .asr, source: "可信逐字稿", text: fact.sourceSpan, cue: "", confidence: 0.46, weight: 0.16))
            } else {
                for source in matchingSources.prefix(4) {
                    atoms.append(Self.atom(fact, channel: .asr, source: source.name, text: Self.excerpt(source.text, around: fact.claim), cue: "", confidence: 0.58, weight: 0.12))
                }
            }

            for material in materials where !material.extractedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard Self.text(material.extractedText, matches: fact.claim, span: fact.sourceSpan) else { continue }
                let channel: MeetingTruthFactChannel = Self.isImageMaterial(material) ? .imageOCR : .material
                let weight = channel == .imageOCR ? 0.16 : 0.24
                atoms.append(Self.atom(fact, channel: channel, source: material.name, text: Self.excerpt(material.extractedText, around: fact.claim), cue: "", confidence: 0.68, weight: weight))
            }

            for evidence in visualEvidence {
                guard let cue = Self.visualCue(in: evidence, for: fact), !cue.isEmpty else { continue }
                atoms.append(Self.atom(fact, channel: .rawVision, source: evidence.materialName, text: evidence.summary, cue: cue, confidence: Self.confidenceScore(evidence.confidence), weight: 0.26))
            }

            for conflict in conflicts {
                let selected = conflict.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let claimMatchesSelected = !selected.isEmpty && Self.text(selected, matches: fact.claim, span: fact.sourceSpan)
                let claimMatchesRecommendation = Self.text(conflict.recommendation, matches: fact.claim, span: fact.sourceSpan)
                let claimMatchesCandidate = conflict.candidates.contains { Self.text($0.text, matches: fact.claim, span: fact.sourceSpan) }
                let contextMatches = Self.text(conflict.context, matches: fact.claim, span: fact.sourceSpan) || Self.text(fact.sourceSpan, matches: conflict.context, span: fact.claim)

                if claimMatchesSelected {
                    atoms.append(Self.atom(fact, channel: .human, source: "人工确认：\(conflict.kind.title)", text: selected, cue: "", confidence: 0.95, weight: 0.42))
                } else if claimMatchesRecommendation || claimMatchesCandidate {
                    atoms.append(Self.atom(fact, channel: .conflict, source: "冲突卡：\(conflict.kind.title)", text: conflict.evidence, cue: "", confidence: Self.confidenceScore(conflict.confidence), weight: 0.12))
                } else if contextMatches, fact.riskLevel == .high, !conflict.isResolved {
                    let alternatives = conflict.candidates.map(\.text).joined(separator: " / ")
                    atoms.append(Self.atom(fact, channel: .conflict, source: "未确认冲突：\(conflict.kind.title)", text: alternatives, cue: "", supports: false, confidence: 0.70, weight: 0.20))
                }
            }

            for confirmation in confirmations {
                guard let selected = confirmation.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines), !selected.isEmpty else { continue }
                guard confirmation.conflictID == fact.id || Self.text(selected, matches: fact.claim, span: fact.sourceSpan) else { continue }
                atoms.append(Self.atom(fact, channel: .human, source: "人工确认", text: selected, cue: "", confidence: 0.98, weight: 0.45))
            }
        }

        return Self.deduplicatedAtoms(atoms)
    }

    func decide(
        facts: [MeetingTruthFactCandidate],
        evidence: [MeetingTruthEvidenceAtom],
        config: MeetingTruthArbitrationConfig
    ) -> [MeetingTruthFactDecision] {
        facts.map { fact in
            let factEvidence = evidence.filter { $0.factID == fact.id }
            let supporting = factEvidence.filter(\.supportsClaim)
            let contradicting = factEvidence.filter { !$0.supportsClaim }
            let human = supporting.contains { $0.channel == .human }
            let material = supporting.contains { $0.channel == .material }
            let rawVision = supporting.contains { $0.channel == .rawVision }
            let imageOCR = supporting.contains { $0.channel == .imageOCR }
            let asrSourceCount = Set(supporting.filter { $0.channel == .asr }.map(\.sourceName)).count
            let multiASR = asrSourceCount >= 2
            let highRisk = fact.riskLevel == .high
            let personLike = fact.kind == .person || fact.kind == .owner
            let important = fact.importance == .high || fact.importance == .medium
            let supportScore = min(supporting.reduce(0) { $0 + $1.weight }, 1)
            let contradictionPenalty = min(contradicting.reduce(0) { $0 + $1.weight }, 0.35)
            let highRiskPenalty = highRisk ? min(config.highRiskPenalty, 0.25) : 0
            let confidence = min(max(fact.confidence + supportScore - contradictionPenalty - highRiskPenalty, 0), 1)
            let strongHighRiskSupport: Bool
            if personLike {
                strongHighRiskSupport = human || material || imageOCR
            } else {
                strongHighRiskSupport = human || material || rawVision || imageOCR
            }

            var missing: [String] = []
            if highRisk, !strongHighRiskSupport {
                if personLike {
                    missing.append("人名/负责人不能只靠 ASR 重复出现或单次原图读名采信，缺少材料/OCR 人名或人工确认")
                } else {
                    missing.append(imageOCR ? "只有 ASR/图片 OCR 基线，缺少文本材料、原图视觉、多 ASR 或人工确认" : "缺少文本材料、原图视觉、多 ASR 或人工确认")
                }
            }
            if fact.needsEvidence,
               !human,
               !material,
               !rawVision,
               !imageOCR,
               !multiASR {
                missing.append("只有逐字稿来源，没有跨通道复核")
            }
            if !contradicting.isEmpty {
                missing.append("存在未解决的反向候选或冲突证据")
            }

            let status: MeetingTruthFactDecisionStatus
            let requiresUserInput: Bool
            let reason: String

            if human {
                status = .confirmed
                requiresUserInput = false
                reason = "已有人工确认，可写入可信逐字稿和成果包。"
            } else if !contradicting.isEmpty, important {
                status = .conflicted
                requiresUserInput = true
                reason = "该事实存在跨来源冲突，需要用户确认后才能采用。"
            } else if !missing.isEmpty, highRisk {
                status = .needsUserInput
                requiresUserInput = true
                reason = "这是高风险事实，当前证据不足以自动高置信采用。"
            } else if !missing.isEmpty, important {
                status = .needsUserInput
                requiresUserInput = true
                reason = "这是重要事实，但缺少跨通道证据。"
            } else if confidence >= 0.68 || material || rawVision || imageOCR {
                status = .accepted
                requiresUserInput = false
                reason = Self.acceptanceReason(material: material, rawVision: rawVision, imageOCR: imageOCR, multiASR: multiASR)
            } else if fact.importance == .low {
                status = .unsupported
                requiresUserInput = false
                reason = "低重要性事实缺少足够证据，正式成果中默认省略。"
            } else {
                status = .lowConfidence
                requiresUserInput = false
                reason = "置信度偏低，未达到自动高置信采用标准。"
            }

            return MeetingTruthFactDecision(
                factID: fact.id,
                claim: fact.claim,
                kind: fact.kind,
                chosenText: fact.claim,
                status: status,
                confidence: status == .confirmed ? max(confidence, 0.96) : confidence,
                reason: reason,
                missingEvidence: missing,
                requiresUserInput: requiresUserInput,
                importance: fact.importance,
                riskLevel: fact.riskLevel,
                affectsOutputs: fact.affectsOutputs,
                userVisibleReason: Self.userVisibleReason(for: fact, missing: missing, status: status),
                noConfirmationConsequence: Self.noConfirmationConsequence(for: fact, status: status)
            )
        }
    }

    func questions(
        for decisions: [MeetingTruthFactDecision],
        facts: [MeetingTruthFactCandidate],
        evidence: [MeetingTruthEvidenceAtom]
    ) -> [MeetingTruthUserQuestion] {
        decisions
            .filter(\.requiresUserInput)
            .prefix(20)
            .map { decision in
                let fact = facts.first { $0.id == decision.factID }
                let relatedEvidence = evidence
                    .filter { $0.factID == decision.factID }
                    .sorted {
                        if $0.supportsClaim != $1.supportsClaim {
                            return $0.supportsClaim && !$1.supportsClaim
                        }
                        return $0.weight > $1.weight
                    }
                return MeetingTruthUserQuestion(
                    factID: decision.factID,
                    question: Self.questionText(for: decision),
                    currentClaim: decision.chosenText,
                    knownEvidence: Self.knownEvidenceText(for: decision),
                    suggestedAnswer: decision.chosenText,
                    sourceContext: fact?.sourceSpan,
                    decisionReason: decision.reason,
                    missingEvidence: decision.missingEvidence,
                    evidenceDetails: Self.questionEvidenceDetails(from: relatedEvidence),
                    importanceTitle: decision.importance.title,
                    riskTitle: decision.riskLevel.title,
                    affectsOutputs: decision.affectsOutputs,
                    userVisibleReason: decision.userVisibleReason,
                    noConfirmationConsequence: decision.noConfirmationConsequence
                )
            }
    }

    private static let amountPattern = #"(\d+(?:\.\d+)?\s*(?:万|万元|亿|亿元|千|k|K|%|％|人|个|项|天|周|月|年|小时|分钟|次|页|份|张|条|块|GB|MB|G|M))"#
    private static let datePattern = #"((?:\d{4}[年/-])?\d{1,2}[月/-]\d{1,2}[日号]?|(?:下周|本周|这周|明天|今天|昨天|月底|月中|周[一二三四五六日天])|Q[1-4]|[一二三四]季度)"#
    private static let projectPattern = #"([\p{Han}A-Za-z0-9][\p{Han}A-Za-z0-9_-]{1,24}(?:项目|系统|平台|方案|计划|规划|模型|引擎|接口|流程|赛道|应用|工作台|成果包))"#
    private static let latinTermPattern = #"\b[A-Za-z][A-Za-z0-9.+#/-]{1,24}\b"#
    private static let personPattern = #"(?:(?:由|请|让|安排|需要|负责人是|负责人为)\s*)?([\p{Han}]{2,4})(?:负责|补充|确认|跟进|提交|整理|推进|处理|对接|汇报|说|表示|建议|认为)"#
    private static let blockedPersonTerms: Set<String> = ["我们", "你们", "他们", "大家", "这个", "那个", "需要", "会议", "项目", "模型", "系统", "材料", "图片", "结果", "问题", "风险", "待办", "负责", "确认", "补充", "推进", "处理", "整理"]
    private static let nonPersonFunctionTerms: Set<String> = [
        "应当", "应该", "可以", "或者", "当然", "然后", "但是", "如果", "因为", "所以",
        "就是", "那么", "现在", "未来", "方面", "能力", "已经", "非常", "更多", "很多",
        "一些", "一个", "一下", "这里", "那里", "起来", "出来", "进去", "上来", "下去",
        "才能", "只是", "只有", "还要"
    ]
    private static let ownerKeywords = ["负责", "负责人", "owner", "Owner", "跟进", "对接"]
    private static let decisionKeywords = ["决定", "确认", "同意", "通过", "采用", "定为", "结论", "最终", "明确"]
    private static let actionKeywords = ["待办", "负责", "跟进", "推进", "补充", "提交", "整理", "完成", "对接", "下周", "本周", "明天", "月底"]
    private static let riskKeywords = ["风险", "问题", "阻塞", "延迟", "不确定", "待确认", "卡点", "依赖", "缺少"]
    private static let relativeDateClaims: Set<String> = ["今天", "昨天", "明天", "本周", "这周", "下周", "月底", "月中"]
    private static let lowValueClaims: Set<String> = [
        "今天", "昨天", "明天", "总结", "认识", "认知", "情况", "问题", "结果", "内容", "材料",
        "这个", "那个", "一个", "一些", "一下", "会议", "项目", "系统", "模型", "确认",
        "明确", "完成", "整理", "推进", "补充", "通过", "采用", "风险", "待办"
    ]
    private static let substanceKeywords = [
        "负责人", "负责", "提交", "交付", "完成", "截止", "上线", "验收", "通过", "采用",
        "决定", "结论", "预算", "金额", "客户", "合同", "方案", "项目", "系统", "平台",
        "风险", "阻塞", "依赖", "延期", "排期", "版本", "会议纪要", "行动项"
    ]
    private static let genericProjectSuffixes = ["方案", "流程", "模型", "计划", "规划", "接口", "平台", "系统", "项目", "引擎", "应用", "工作台", "成果包"]
    private static let projectNamingSignals = ["项目名", "系统名", "平台名", "正式名称", "代号", "名为", "叫做", "命名为", "确定为", "采用", "接入", "上线"]

    private static func fact(
        _ kind: MeetingTruthFactKind,
        claim: String,
        span: String,
        importance: MeetingTruthFactImportance,
        risk: MeetingTruthFactRiskLevel,
        confidence: Double
    ) -> MeetingTruthFactCandidate {
        let normalizedClaim = compactClaim(claim)
        return MeetingTruthFactCandidate(
            id: stableID(kind: kind, claim: normalizedClaim),
            kind: kind,
            claim: normalizedClaim,
            sourceSpan: compactClaim(span),
            sourceChannel: .asr,
            importance: importance,
            riskLevel: risk,
            confidence: confidence,
            needsEvidence: risk != .low || importance != .low,
            whyItMatters: whyItMatters(kind: kind),
            affectsOutputs: affectsOutputs(for: kind),
            gateStatus: .acceptedForAdjudication,
            gateReason: gateReason(kind: kind, claim: normalizedClaim, span: span),
            reviewPriority: reviewPriority(kind: kind, risk: risk)
        )
    }

    private static func projectNameClaims(from sentence: String) -> [String] {
        let regexClaims = matches(in: sentence, pattern: projectPattern)
        let quotedClaims = matches(in: sentence, pattern: #"[「『“"]([^」』”"]{2,24}(?:项目|系统|平台|方案|模型|流程|引擎|应用|工作台|成果包)?)[」』”"]"#)
        let latinClaims = termClaims(from: sentence)
            .filter { $0.range(of: #"[A-Z]"#, options: .regularExpression) != nil }
            .filter { _ in containsAny(sentence, ["项目", "系统", "平台", "产品", "方案", "模型", "接入", "上线", "候选"]) }
        return (regexClaims + quotedClaims + latinClaims)
            .map(compactClaim)
            .filter { isReviewableProjectName($0, in: sentence) }
    }

    private static func acceptedForAdjudication(_ fact: MeetingTruthFactCandidate) -> Bool {
        let claim = fact.claim.trimmingCharacters(in: .whitespacesAndNewlines)
        let span = fact.sourceSpan.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !claim.isEmpty, fact.affectsOutputs?.contains(.none) != true else { return false }
        if lowValueClaims.contains(normalized(claim)) { return false }
        switch fact.kind {
        case .person, .owner:
            return isLikelyPersonNameCandidate(claim)
        case .amount, .date:
            return true
        case .project:
            return isReviewableProjectName(claim, in: span)
        case .decision:
            return isReviewableDecisionSentence(span)
        case .actionItem:
            return isReviewableActionSentence(span)
        case .risk:
            return isReviewableRiskSentence(span)
        case .term:
            return isReviewableTerm(claim, in: span)
        }
    }

    private static func isReviewableProjectName(_ claim: String, in sentence: String) -> Bool {
        let normalizedClaim = normalized(claim)
        guard normalizedClaim.count >= 3 else { return false }
        if lowValueClaims.contains(normalizedClaim) { return false }
        if claim.range(of: #"[A-Za-z0-9]"#, options: .regularExpression) != nil {
            return true
        }
        if containsAny(sentence, projectNamingSignals),
           containsConcreteSignal(sentence) || sentence.contains("「") || sentence.contains("“") {
            return true
        }
        if isGenericProjectPhrase(claim) { return false }
        return false
    }

    private static func isGenericProjectPhrase(_ claim: String) -> Bool {
        let normalizedClaim = normalized(claim)
        if ["要挂模型", "混乱流程", "校验流程", "验证流程"].contains(normalizedClaim) {
            return true
        }
        if genericProjectSuffixes.contains(where: { suffix in
            normalizedClaim == normalized(suffix) || normalizedClaim.hasSuffix(normalized(suffix)) && normalizedClaim.count <= 6
        }) {
            let hasProperSignal = claim.range(of: #"[A-Za-z0-9]"#, options: .regularExpression) != nil ||
                claim.contains("「") ||
                claim.contains("“")
            return !hasProperSignal
        }
        return false
    }

    private static func isReviewableDecisionSentence(_ sentence: String) -> Bool {
        guard containsAny(sentence, ["决定", "结论", "通过", "采用", "定为", "同意"]) else { return false }
        return hasExplicitFactSubject(sentence)
    }

    private static func isReviewableActionSentence(_ sentence: String) -> Bool {
        guard containsAny(sentence, ["负责", "提交", "完成", "跟进", "对接", "交付", "截止", "上线", "验收"]) else { return false }
        let hasOwner = !personClaims(from: sentence).isEmpty || sentence.contains("负责人")
        let hasDeadline = !matches(in: sentence, pattern: datePattern).isEmpty || containsAny(sentence, ["前", "之前", "截止", "月底"])
        let hasObject = containsAny(sentence, ["报告", "材料", "方案", "版本", "清单", "纪要", "合同", "评估", "验证", "测试"])
        return hasOwner && (hasDeadline || hasObject)
    }

    private static func isReviewableRiskSentence(_ sentence: String) -> Bool {
        guard containsAny(sentence, ["风险", "阻塞", "延期", "延迟", "依赖", "缺少", "待确认", "卡点"]) else { return false }
        return hasExplicitFactSubject(sentence)
    }

    private static func isReviewableTerm(_ term: String, in sentence: String) -> Bool {
        guard term.range(of: #"[A-Z]"#, options: .regularExpression) != nil else { return false }
        return containsAny(sentence, ["项目", "系统", "平台", "模型", "术语", "候选", "写法", "识别", "转写", "冲突"])
    }

    private static func hasExplicitFactSubject(_ sentence: String) -> Bool {
        containsConcreteSignal(sentence) ||
        !projectNameClaims(from: sentence).isEmpty ||
        sentence.range(of: #"[A-Za-z][A-Za-z0-9.+#/-]{2,}"#, options: .regularExpression) != nil ||
        sentence.contains("「") ||
        sentence.contains("“")
    }

    private static func affectsOutputs(for kind: MeetingTruthFactKind) -> [MeetingTruthFactAffectsOutput] {
        switch kind {
        case .person, .owner:
            return [.participants, .actionItems, .minutes]
        case .amount, .date:
            return [.minutes, .actionItems]
        case .project, .term:
            return [.projectNames, .minutes]
        case .decision:
            return [.minutes]
        case .actionItem:
            return [.actionItems, .minutes]
        case .risk:
            return [.riskList, .minutes]
        }
    }

    private static func whyItMatters(kind: MeetingTruthFactKind) -> String {
        switch kind {
        case .person, .owner:
            return "人名或负责人会影响参会人和待办归属。"
        case .amount:
            return "金额或指标会影响正式纪要和风险判断。"
        case .date:
            return "日期或截止时间会影响待办和会议结论。"
        case .project, .term:
            return "项目名、系统名或专有术语写错会影响最终纪要可信度。"
        case .decision:
            return "会议决策会直接写入正式纪要。"
        case .actionItem:
            return "待办事项会进入会后行动清单。"
        case .risk:
            return "风险或问题会进入风险清单。"
        }
    }

    private static func gateReason(kind: MeetingTruthFactKind, claim: String, span: String) -> String {
        "\(kind.title) 会影响 \(affectsOutputs(for: kind).map(\.title).joined(separator: "、"))，进入证据裁决。"
    }

    private static func reviewPriority(kind: MeetingTruthFactKind, risk: MeetingTruthFactRiskLevel) -> Int {
        let base: Int
        switch kind {
        case .person, .owner, .amount, .date, .project:
            base = 90
        case .decision, .actionItem, .risk:
            base = 78
        case .term:
            base = 62
        }
        return risk == .high ? base + 8 : base
    }

    private static func atom(
        _ fact: MeetingTruthFactCandidate,
        channel: MeetingTruthFactChannel,
        source: String,
        text: String,
        cue: String,
        supports: Bool = true,
        confidence: Double,
        weight: Double
    ) -> MeetingTruthEvidenceAtom {
        MeetingTruthEvidenceAtom(
            id: stableEvidenceID(factID: fact.id, channel: channel, source: source, text: text, supports: supports),
            factID: fact.id,
            channel: channel,
            sourceName: source,
            supportsClaim: supports,
            text: compactClaim(text),
            visualCue: compactClaim(cue),
            confidence: confidence,
            weight: weight
        )
    }

    private static func sentences(from transcript: String) -> [String] {
        transcript
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(whereSeparator: { "\n。！？!?；;".contains($0) })
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func personClaims(from sentence: String) -> [String] {
        matches(in: sentence, pattern: personPattern)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { isLikelyPersonNameCandidate($0) }
    }

    private static func termClaims(from sentence: String) -> [String] {
        matches(in: sentence, pattern: latinTermPattern)
            .filter { $0.count >= 2 && $0.count <= 24 }
            .filter { !["http", "https", "json"].contains($0.lowercased()) }
    }

    private static func matches(in text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            let preferredRange = match.numberOfRanges > 1 ? match.range(at: 1) : match.range
            guard let swiftRange = Range(preferredRange, in: text) else { return nil }
            return String(text[swiftRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func visualCue(in evidence: MeetingTruthVisualEvidence, for fact: MeetingTruthFactCandidate) -> String? {
        let cues: [String]
        switch fact.kind {
        case .person, .owner:
            cues = participantVisualCues(in: evidence, for: fact)
        case .amount:
            cues = numberVisualCues(in: evidence, for: fact)
        case .date:
            cues = numberVisualCues(in: evidence, for: fact) + keywordVisualCues(in: evidence, for: fact)
        case .project, .term:
            cues = keywordVisualCues(in: evidence, for: fact)
        case .decision, .actionItem, .risk:
            cues = keywordVisualCues(in: evidence, for: fact) + actionVisualCues(in: evidence, for: fact)
        }
        guard !cues.isEmpty else { return nil }
        return cues.prefix(3).joined(separator: "；")
    }

    private static func participantVisualCues(
        in evidence: MeetingTruthVisualEvidence,
        for fact: MeetingTruthFactCandidate
    ) -> [String] {
        evidence.participants.compactMap { participant -> String? in
            let joined = [participant.name, participant.role, participant.organization, participant.evidence].joined(separator: " ")
            guard text(joined, matches: fact.claim, span: fact.sourceSpan) else { return nil }
            return participant.evidence.isEmpty ? participant.displayText : "\(participant.displayText)：\(participant.evidence)"
        }
    }

    private static func numberVisualCues(
        in evidence: MeetingTruthVisualEvidence,
        for fact: MeetingTruthFactCandidate
    ) -> [String] {
        evidence.extractedNumbers
            .filter { text($0, matches: fact.claim, span: fact.sourceSpan) }
            .map { "原图识别到数字/时间：\($0)" }
    }

    private static func keywordVisualCues(
        in evidence: MeetingTruthVisualEvidence,
        for fact: MeetingTruthFactCandidate
    ) -> [String] {
        evidence.keywords
            .filter { text($0, matches: fact.claim, span: fact.sourceSpan) }
            .map { "原图识别到重点项：\($0)" }
    }

    private static func actionVisualCues(
        in evidence: MeetingTruthVisualEvidence,
        for fact: MeetingTruthFactCandidate
    ) -> [String] {
        evidence.actionHints
            .filter { text($0, matches: fact.claim, span: fact.sourceSpan) || text(fact.claim, matches: $0, span: fact.sourceSpan) }
    }

    private static func text(_ text: String, matches claim: String, span: String) -> Bool {
        let normalizedText = normalized(text)
        let normalizedClaim = normalized(claim)
        guard !normalizedText.isEmpty, !normalizedClaim.isEmpty else { return false }
        if normalizedText.contains(normalizedClaim) || normalizedClaim.contains(normalizedText), min(normalizedText.count, normalizedClaim.count) >= 3 {
            return true
        }
        let keys = keywords(from: claim + " " + span)
        guard !keys.isEmpty else { return false }
        let hitCount = keys.filter { normalizedText.contains($0) }.count
        if normalizedClaim.count <= 8 {
            return hitCount >= 1
        }
        return hitCount >= min(2, keys.count)
    }

    private static func keywords(from text: String) -> [String] {
        let raw = matches(in: text, pattern: amountPattern) +
            matches(in: text, pattern: datePattern) +
            matches(in: text, pattern: projectPattern) +
            matches(in: text, pattern: latinTermPattern) +
            personClaims(from: text)
        var seen = Set<String>()
        return raw.compactMap { value in
            let normalizedValue = normalized(value)
            guard normalizedValue.count >= 2, !seen.contains(normalizedValue) else { return nil }
            seen.insert(normalizedValue)
            return normalizedValue
        }
    }

    private static func containsAny(_ text: String, _ keywords: [String]) -> Bool {
        keywords.contains { text.localizedCaseInsensitiveContains($0) }
    }

    private static func isLowValueReviewSentence(_ sentence: String) -> Bool {
        let normalizedSentence = normalized(sentence)
        guard !normalizedSentence.isEmpty else { return true }
        if lowValueClaims.contains(normalizedSentence) { return true }
        if normalizedSentence.count <= 2 { return true }
        if normalizedSentence.count <= 6,
           !containsConcreteSignal(sentence),
           !containsAny(sentence, substanceKeywords) {
            return true
        }
        let uniqueCount = Set(normalizedSentence).count
        if normalizedSentence.count >= 8, uniqueCount <= 2 {
            return true
        }
        return false
    }

    private static func isReviewableDate(_ claim: String, in sentence: String) -> Bool {
        let normalizedClaim = normalized(claim)
        let normalizedSentence = normalized(sentence)
        guard !lowValueClaims.contains(normalizedSentence) else { return false }
        if relativeDateClaims.contains(normalizedClaim),
           normalizedSentence.count <= 10,
           !containsAny(sentence, substanceKeywords) {
            return false
        }
        if normalizedClaim.range(of: #"\d"#, options: .regularExpression) != nil {
            return true
        }
        return containsConcreteSignal(sentence) || containsAny(sentence, substanceKeywords) || normalizedSentence.count >= 12
    }

    private static func isReviewableStatement(_ sentence: String, kind: MeetingTruthFactKind) -> Bool {
        let normalizedSentence = normalized(sentence)
        guard !lowValueClaims.contains(normalizedSentence) else { return false }
        if normalizedSentence.count < 8, !containsConcreteSignal(sentence) {
            return false
        }
        switch kind {
        case .decision:
            return containsConcreteSignal(sentence) || containsAny(sentence, ["决定", "结论", "通过", "采用", "定为", "同意", "方案", "项目", "系统", "平台"])
        case .actionItem:
            return containsConcreteSignal(sentence) || containsAny(sentence, ["负责", "负责人", "提交", "完成", "跟进", "对接", "截止", "下周", "本周", "明天", "月底"])
        case .risk:
            return containsConcreteSignal(sentence) || containsAny(sentence, ["风险", "阻塞", "延期", "延迟", "依赖", "缺少", "待确认", "卡点"])
        default:
            return true
        }
    }

    private static func containsConcreteSignal(_ text: String) -> Bool {
        !matches(in: text, pattern: amountPattern).isEmpty ||
        !matches(in: text, pattern: projectPattern).isEmpty ||
        !personClaims(from: text).isEmpty ||
        containsAny(text, ["负责人", "截止", "合同", "客户", "预算", "版本", "上线", "验收"])
    }

    private static func isLikelyPersonNameCandidate(_ candidate: String) -> Bool {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, trimmed.count <= 4 else { return false }
        if blockedPersonTerms.contains(trimmed) { return false }
        if blockedPersonTerms.contains(where: { trimmed.contains($0) }) { return false }
        if nonPersonFunctionTerms.contains(trimmed) { return false }
        if nonPersonFunctionTerms.contains(where: { trimmed.contains($0) }) { return false }
        if trimmed.hasSuffix("的") || trimmed.hasPrefix("就") { return false }
        if trimmed.count == 2, let last = trimmed.last, "总工姐哥董经理".contains(last) { return false }
        return true
    }

    private static func deduplicated(_ facts: [MeetingTruthFactCandidate]) -> [MeetingTruthFactCandidate] {
        var seen = Set<String>()
        var result: [MeetingTruthFactCandidate] = []
        for fact in facts {
            let key = "\(fact.kind.rawValue):\(normalized(fact.claim))"
            guard !seen.contains(key), !normalized(fact.claim).isEmpty else { continue }
            seen.insert(key)
            result.append(fact)
        }
        return result
    }

    private static func deduplicatedAtoms(_ atoms: [MeetingTruthEvidenceAtom]) -> [MeetingTruthEvidenceAtom] {
        var seen = Set<String>()
        var result: [MeetingTruthEvidenceAtom] = []
        for atom in atoms {
            let key = "\(atom.factID.uuidString):\(atom.channel.rawValue):\(atom.sourceName):\(atom.supportsClaim):\(normalized(atom.text))"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(atom)
        }
        return result
    }

    private static func acceptanceReason(material: Bool, rawVision: Bool, imageOCR: Bool, multiASR: Bool) -> String {
        var parts: [String] = []
        if material { parts.append("文本/PDF 材料命中") }
        if rawVision { parts.append("原图视觉证据命中") }
        if imageOCR { parts.append("图片 OCR 基线命中") }
        if multiASR { parts.append("多路 ASR 支撑") }
        return parts.isEmpty ? "达到事实复核置信度阈值。" : "\(parts.joined(separator: "、"))，可作为已采信事实。"
    }

    private static func userVisibleReason(
        for fact: MeetingTruthFactCandidate,
        missing: [String],
        status: MeetingTruthFactDecisionStatus
    ) -> String {
        if !missing.isEmpty {
            return missing.joined(separator: "；")
        }
        switch status {
        case .conflicted:
            return "证据之间存在冲突，不能自动写入成果包。"
        case .needsUserInput:
            return "这是会影响成果包的高风险事实，需要人工确认后才能写入。"
        case .accepted, .confirmed:
            return "已经有足够证据进入审计记录。"
        case .lowConfidence:
            return "证据不够稳定，后续只能标为待确认或省略。"
        case .unsupported:
            return "低价值或证据不足，不进入主确认队列。"
        }
    }

    private static func noConfirmationConsequence(
        for fact: MeetingTruthFactCandidate,
        status: MeetingTruthFactDecisionStatus
    ) -> String {
        let outputs = (fact.affectsOutputs ?? [.minutes]).map(\.title).joined(separator: "、")
        switch status {
        case .conflicted, .needsUserInput:
            return "不确认时暂不把这条写成已确认事实；相关 \(outputs) 只能标为待确认或省略。"
        case .lowConfidence:
            return "不确认时不会阻塞生成，但相关内容只能作为待确认提示。"
        case .accepted, .confirmed:
            return "无需人工处理，已进入审计记录。"
        case .unsupported:
            return "不进入主成果包。"
        }
    }

    private static func questionText(for decision: MeetingTruthFactDecision) -> String {
        switch decision.kind {
        case .person, .owner:
            return "负责人姓名不确定：\(decision.chosenText)"
        case .amount:
            return "金额或数字不确定：\(decision.chosenText)"
        case .date:
            return "日期或时间节点不确定：\(decision.chosenText)"
        case .project:
            return "项目名或系统名不确定：\(decision.chosenText)"
        case .decision:
            return "会议决策表述不确定：\(decision.chosenText)"
        case .actionItem:
            return "待办事项不确定：\(decision.chosenText)"
        case .risk:
            return "风险或问题表述不确定：\(decision.chosenText)"
        case .term:
            return "专有术语写法不确定：\(decision.chosenText)"
        }
    }

    private static func knownEvidenceText(for decision: MeetingTruthFactDecision) -> [String] {
        var lines = ["当前结论：\(decision.chosenText)", "裁决状态：\(decision.status.title)", "原因：\(decision.reason)"]
        if !decision.missingEvidence.isEmpty {
            lines.append("缺少证据：\(decision.missingEvidence.joined(separator: "；"))")
        }
        return lines
    }

    private static func questionEvidenceDetails(from evidence: [MeetingTruthEvidenceAtom]) -> [MeetingTruthQuestionEvidence] {
        evidence.prefix(8).map { atom in
            MeetingTruthQuestionEvidence(
                id: atom.id,
                channelTitle: atom.channel.title,
                sourceName: atom.sourceName,
                supportsClaim: atom.supportsClaim,
                text: atom.text,
                visualCue: atom.visualCue,
                confidence: atom.confidence
            )
        }
    }

    private static func confidenceScore(_ confidence: MeetingTruthConfidence) -> Double {
        switch confidence {
        case .high: 0.86
        case .medium: 0.68
        case .low: 0.45
        }
    }

    private static func isImageMaterial(_ material: MeetingTruthMaterial) -> Bool {
        material.kind == "图片"
    }

    private static func excerpt(_ text: String, around claim: String, limit: Int = 120) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        if let range = trimmed.range(of: claim, options: [.caseInsensitive, .diacriticInsensitive]) {
            let lower = trimmed.index(range.lowerBound, offsetBy: -min(40, trimmed.distance(from: trimmed.startIndex, to: range.lowerBound)))
            let upper = trimmed.index(range.upperBound, offsetBy: min(70, trimmed.distance(from: range.upperBound, to: trimmed.endIndex)))
            return String(trimmed[lower..<upper])
        }
        return "\(trimmed.prefix(limit))..."
    }

    private static func compactClaim(_ text: String) -> String {
        let trimmed = text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 96 ? "\(trimmed.prefix(96))..." : trimmed
    }

    private static func normalized(_ text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stableID(kind: MeetingTruthFactKind, claim: String) -> UUID {
        stableUUID("fact:\(kind.rawValue):\(normalized(claim))")
    }

    private static func stableEvidenceID(factID: UUID, channel: MeetingTruthFactChannel, source: String, text: String, supports: Bool) -> UUID {
        stableUUID("evidence:\(factID.uuidString):\(channel.rawValue):\(source):\(supports):\(normalized(text))")
    }

    private static func stableUUID(_ text: String) -> UUID {
        let first = fnv1a64(text)
        let second = fnv1a64("MeetingTruth:\(text)")
        let bytes: [UInt8] = [
            UInt8((first >> 56) & 0xff),
            UInt8((first >> 48) & 0xff),
            UInt8((first >> 40) & 0xff),
            UInt8((first >> 32) & 0xff),
            UInt8((first >> 24) & 0xff),
            UInt8((first >> 16) & 0xff),
            UInt8((first >> 8) & 0xff),
            UInt8(first & 0xff),
            UInt8((second >> 56) & 0xff),
            UInt8((second >> 48) & 0xff),
            UInt8((second >> 40) & 0xff),
            UInt8((second >> 32) & 0xff),
            UInt8((second >> 24) & 0xff),
            UInt8((second >> 16) & 0xff),
            UInt8((second >> 8) & 0xff),
            UInt8(second & 0xff)
        ]
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private static func fnv1a64(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }
}
