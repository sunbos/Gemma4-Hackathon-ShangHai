import Foundation

struct MeetingTruthArbitrationEngine {
    func workflowNodes(
        transcriptSources: [MeetingTruthTranscriptSource],
        imageMaterials: [MeetingTruthMaterial],
        visualEvidence: [MeetingTruthVisualEvidence],
        conflicts: [MeetingTruthConflict],
        factCandidates: [MeetingTruthFactCandidate],
        factDecisions: [MeetingTruthFactDecision],
        userQuestions: [MeetingTruthUserQuestion],
        conclusionEvidence: [MeetingTruthConclusionEvidence]
    ) -> [MeetingTruthArbitrationWorkflowNode] {
        [
            MeetingTruthArbitrationWorkflowNode(
                title: "1. 多路 ASR",
                subtitle: "音频先转为候选文本",
                result: transcriptSources.count >= 2 ? "\(transcriptSources.count) 路候选可比对" : "至少需要 2 路候选",
                state: transcriptSources.count >= 2 ? .ready : .waiting
            ),
            MeetingTruthArbitrationWorkflowNode(
                title: "2. OCR 基线",
                subtitle: "本机只提取文字",
                result: "\(imageMaterials.filter { !$0.extractedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count) 张图片有 OCR 文本",
                state: imageMaterials.isEmpty ? .waiting : .ready
            ),
            MeetingTruthArbitrationWorkflowNode(
                title: "3. Gemma 原图理解",
                subtitle: "image_url 读取手写/版式/标记",
                result: visualEvidence.isEmpty ? "尚未形成视觉证据" : "\(visualEvidence.count) 条视觉证据",
                state: visualEvidence.isEmpty ? (imageMaterials.isEmpty ? .waiting : .warning) : .ready
            ),
            MeetingTruthArbitrationWorkflowNode(
                title: "4. 全文事实抽取",
                subtitle: "从可信逐字稿提取人名、数字、日期、项目、决策、待办",
                result: factCandidates.isEmpty ? "尚无事实账本" : "\(factCandidates.count) 个事实",
                state: factCandidates.isEmpty ? (conflicts.isEmpty ? .waiting : .warning) : .ready
            ),
            MeetingTruthArbitrationWorkflowNode(
                title: "5. 事实级裁决",
                subtitle: "以事实为中心匹配 ASR/OCR/原图/材料/人工确认",
                result: factDecisions.isEmpty ? "等待事实输入" : "\(factDecisions.filter { !$0.requiresUserInput }.count)/\(factDecisions.count) 已裁决",
                state: userQuestions.isEmpty ? (factDecisions.isEmpty ? .waiting : .ready) : .warning
            ),
            MeetingTruthArbitrationWorkflowNode(
                title: "6. 成果证据链",
                subtitle: "最终纪要保留来源",
                result: conclusionEvidence.isEmpty ? "尚未生成成果证据" : "\(conclusionEvidence.count) 条结论证据",
                state: conclusionEvidence.isEmpty ? .waiting : .ready
            )
        ]
    }

    func decisions(
        conflicts: [MeetingTruthConflict],
        transcriptSources: [MeetingTruthTranscriptSource],
        imageMaterials: [MeetingTruthMaterial],
        visualEvidence: [MeetingTruthVisualEvidence],
        materials: [MeetingTruthMaterial],
        confirmations: [MeetingTruthManualConfirmation],
        factCandidates: [MeetingTruthFactCandidate],
        evidenceAtoms: [MeetingTruthEvidenceAtom],
        factDecisions: [MeetingTruthFactDecision],
        config: MeetingTruthArbitrationConfig
    ) -> [MeetingTruthArbitrationDecision] {
        if !factDecisions.isEmpty {
            return factDecisions.prefix(18).map {
                decision(for: $0, evidenceAtoms: evidenceAtoms, config: config)
            }
        }

        return conflicts.prefix(12).map { conflict in
            decision(
                for: conflict,
                transcriptSources: transcriptSources,
                imageMaterials: imageMaterials,
                visualEvidence: visualEvidence,
                materials: materials,
                confirmations: confirmations,
                config: config
            )
        }
    }

    private func decision(
        for factDecision: MeetingTruthFactDecision,
        evidenceAtoms: [MeetingTruthEvidenceAtom],
        config: MeetingTruthArbitrationConfig
    ) -> MeetingTruthArbitrationDecision {
        let atoms = evidenceAtoms.filter { $0.factID == factDecision.factID }
        let supporting = atoms.filter(\.supportsClaim).map(evidenceItem)
        let contradicting = atoms.filter { !$0.supportsClaim }.map(evidenceItem)
        let decision: MeetingTruthArbitrationDecision.Decision
        switch factDecision.status {
        case .accepted, .confirmed:
            decision = .accept
        case .unsupported:
            decision = .reject
        case .lowConfidence, .conflicted, .needsUserInput:
            decision = .review
        }
        let threshold = factDecision.riskLevel == .high
            ? min(config.humanReviewThreshold + 0.08, 0.95)
            : config.humanReviewThreshold
        let breakdown = [
            "事实状态：\(factDecision.status.title)",
            "事实置信度：\(Self.percent(factDecision.confidence))",
            supporting.isEmpty ? "缺少正向证据" : "正向证据 \(supporting.count) 条",
            contradicting.isEmpty ? nil : "反向证据 \(contradicting.count) 条",
            factDecision.missingEvidence.isEmpty ? nil : "缺口：\(factDecision.missingEvidence.joined(separator: "；"))"
        ].compactMap { $0 }

        return MeetingTruthArbitrationDecision(
            id: factDecision.factID,
            claim: factDecision.chosenText,
            subject: "\(factDecision.kind.title) · \(factDecision.status.title)",
            riskType: factDecision.kind.conflictKind,
            decision: decision,
            score: factDecision.confidence,
            threshold: threshold,
            confidence: Self.confidence(from: factDecision.confidence),
            supportingEvidence: supporting,
            contradictingEvidence: contradicting,
            scoreBreakdown: breakdown,
            parameterEffect: "当前由事实账本驱动：高风险事实必须有材料、原图视觉、多 ASR 或人工确认之一，否则进入追问队列。",
            gemmaRole: "Gemma 4 的核心角色是围绕事实账本做跨模态语义复核和成果组织；OCR 只是文字基线，rawVision 才代表原图视觉事实。",
            needsHumanReview: factDecision.requiresUserInput
        )
    }

    private func evidenceItem(from atom: MeetingTruthEvidenceAtom) -> MeetingTruthEvidenceItem {
        let text = atom.visualCue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? atom.text
            : "\(atom.text)\n视觉线索：\(atom.visualCue)"
        return MeetingTruthEvidenceItem(
            channel: atom.channel.evidenceItemChannel,
            source: atom.sourceName,
            text: text,
            weight: atom.weight,
            supportsClaim: atom.supportsClaim
        )
    }

    private func decision(
        for conflict: MeetingTruthConflict,
        transcriptSources: [MeetingTruthTranscriptSource],
        imageMaterials: [MeetingTruthMaterial],
        visualEvidence: [MeetingTruthVisualEvidence],
        materials: [MeetingTruthMaterial],
        confirmations: [MeetingTruthManualConfirmation],
        config: MeetingTruthArbitrationConfig
    ) -> MeetingTruthArbitrationDecision {
        let claim = conflict.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? conflict.selectedText!
            : conflict.recommendation
        let normalizedClaim = Self.normalized(claim)
        let highRisk = isHighRisk(conflict.kind)
        let asrSupport = asrSupportScore(claim: normalizedClaim, conflict: conflict, transcriptSources: transcriptSources)
        let visualMatches = visualEvidenceItems(claim: normalizedClaim, visualEvidence: visualEvidence, weight: config.visualEvidenceWeight)
        let ocrMatches = ocrEvidenceItems(claim: normalizedClaim, imageMaterials: imageMaterials, weight: config.ocrEvidenceWeight)
        let materialMatches = materialEvidenceItems(claim: normalizedClaim, materials: materials, weight: config.textMaterialWeight)
        let humanMatches = humanEvidenceItems(conflict: conflict, confirmations: confirmations)

        var supporting: [MeetingTruthEvidenceItem] = []
        supporting.append(contentsOf: asrSupport.items)
        supporting.append(contentsOf: visualMatches)
        supporting.append(contentsOf: ocrMatches)
        supporting.append(contentsOf: materialMatches)
        supporting.append(contentsOf: humanMatches)

        let contradicting = contradictingEvidenceItems(
            claim: normalizedClaim,
            conflict: conflict,
            weight: config.asrConsensusWeight
        )

        let asrScore = asrSupport.score * config.asrConsensusWeight
        let visualScore = visualMatches.reduce(0) { $0 + $1.weight }
        let ocrScore = min(config.ocrEvidenceWeight, ocrMatches.reduce(0) { $0 + $1.weight })
        let materialScore = min(config.textMaterialWeight, materialMatches.reduce(0) { $0 + $1.weight })
        let humanScore = humanMatches.reduce(0) { $0 + $1.weight }
        let visualPromotion = config.allowVisualToPromoteMissingASRTerms && asrSupport.score == 0 && !visualMatches.isEmpty
            ? min(config.visualEvidenceWeight * 0.35, 0.12)
            : 0
        let riskPenalty = highRisk ? config.highRiskPenalty : 0
        let contradictionPenalty = min(Double(contradicting.count) * 0.04, 0.16)
        let rawScore = asrScore + visualScore + ocrScore + materialScore + humanScore + visualPromotion - riskPenalty - contradictionPenalty
        let score = min(max(rawScore, 0), 1)
        let reviewThreshold = config.strictHighRiskReview && highRisk
            ? min(config.humanReviewThreshold + 0.08, 0.95)
            : config.humanReviewThreshold
        let needsReview = score < reviewThreshold || conflict.requiresHumanReview || (highRisk && config.strictHighRiskReview && humanMatches.isEmpty)
        let decision: MeetingTruthArbitrationDecision.Decision = needsReview ? .review : .accept
        let confidence: MeetingTruthConfidence = score >= 0.82 ? .high : (score >= 0.58 ? .medium : .low)

        let breakdown = [
            "ASR 共识 +\(Self.percent(asrScore))",
            "原图视觉 +\(Self.percent(visualScore))",
            "OCR +\(Self.percent(ocrScore))",
            "文本材料 +\(Self.percent(materialScore))",
            humanScore > 0 ? "人工确认 +\(Self.percent(humanScore))" : nil,
            visualPromotion > 0 ? "视觉补足缺失 ASR +\(Self.percent(visualPromotion))" : nil,
            highRisk ? "高风险字段 -\(Self.percent(riskPenalty))" : nil,
            contradictionPenalty > 0 ? "反证 -\(Self.percent(contradictionPenalty))" : nil
        ].compactMap { $0 }

        return MeetingTruthArbitrationDecision(
            id: conflict.id,
            claim: claim.isEmpty ? "暂无稳定结论" : claim,
            subject: "\(conflict.kind.title) · \(conflict.timestamp)",
            riskType: conflict.kind,
            decision: decision,
            score: score,
            threshold: reviewThreshold,
            confidence: confidence,
            supportingEvidence: supporting,
            contradictingEvidence: contradicting,
            scoreBreakdown: breakdown,
            parameterEffect: parameterEffect(
                asrScore: asrScore,
                visualScore: visualScore,
                ocrScore: ocrScore,
                threshold: reviewThreshold,
                score: score
            ),
            gemmaRole: "Gemma 4 负责解释 ASR 候选、OCR 文本、原图视觉证据和材料之间的语义关系；仲裁引擎负责把证据权重、风险惩罚和人工确认阈值显式化。",
            needsHumanReview: needsReview
        )
    }

    private func asrSupportScore(
        claim: String,
        conflict: MeetingTruthConflict,
        transcriptSources: [MeetingTruthTranscriptSource]
    ) -> (score: Double, items: [MeetingTruthEvidenceItem]) {
        let candidateMatches = conflict.candidates.filter { candidate in
            Self.text(candidate.text, containsNormalized: claim) || Self.text(claim, containsNormalized: candidate.text)
        }
        let sourceMatches = transcriptSources.filter { Self.text($0.text, containsNormalized: claim) }
        let denominator = max(conflict.candidates.count, transcriptSources.count, 1)
        let matchCount = max(candidateMatches.count, sourceMatches.count)
        let score = min(Double(matchCount) / Double(denominator), 1)
        let items = (candidateMatches.map {
            MeetingTruthEvidenceItem(channel: .asr, source: $0.source, text: $0.text, weight: 0.08, supportsClaim: true)
        } + sourceMatches.prefix(2).map {
            MeetingTruthEvidenceItem(channel: .asr, source: $0.name, text: "转写中出现该结论", weight: 0.06, supportsClaim: true)
        })
        return (score, Array(items.prefix(4)))
    }

    private func visualEvidenceItems(
        claim: String,
        visualEvidence: [MeetingTruthVisualEvidence],
        weight: Double
    ) -> [MeetingTruthEvidenceItem] {
        let matches = visualEvidence.filter { evidence in
            let joined = ([evidence.summary, evidence.ocrContrast] + evidence.iterationTerms + evidence.actionHints + evidence.layoutCues + evidence.visualMarks)
                .joined(separator: " ")
            return Self.text(joined, containsNormalized: claim) ||
                evidence.iterationTerms.contains { Self.text(claim, containsNormalized: $0) }
        }
        let perItemWeight = matches.isEmpty ? 0 : min(weight / Double(max(matches.count, 1)), weight)
        return matches.prefix(3).map { evidence in
            let cues = (evidence.layoutCues + evidence.visualMarks + evidence.iterationTerms).prefix(4).joined(separator: "、")
            return MeetingTruthEvidenceItem(
                channel: .visual,
                source: evidence.materialName,
                text: cues.isEmpty ? evidence.summary : cues,
                weight: perItemWeight,
                supportsClaim: true
            )
        }
    }

    private func ocrEvidenceItems(
        claim: String,
        imageMaterials: [MeetingTruthMaterial],
        weight: Double
    ) -> [MeetingTruthEvidenceItem] {
        let matches = imageMaterials.filter { Self.text($0.extractedText, containsNormalized: claim) }
        let perItemWeight = matches.isEmpty ? 0 : min(weight / Double(max(matches.count, 1)), weight)
        return matches.prefix(2).map {
            MeetingTruthEvidenceItem(
                channel: .ocr,
                source: $0.name,
                text: Self.truncated($0.extractedText, limit: 72),
                weight: perItemWeight,
                supportsClaim: true
            )
        }
    }

    private func materialEvidenceItems(
        claim: String,
        materials: [MeetingTruthMaterial],
        weight: Double
    ) -> [MeetingTruthEvidenceItem] {
        let matches = materials.filter { $0.kind != "图片" && Self.text($0.extractedText, containsNormalized: claim) }
        let perItemWeight = matches.isEmpty ? 0 : min(weight / Double(max(matches.count, 1)), weight)
        return matches.prefix(2).map {
            MeetingTruthEvidenceItem(
                channel: .material,
                source: $0.name,
                text: Self.truncated($0.extractedText, limit: 72),
                weight: perItemWeight,
                supportsClaim: true
            )
        }
    }

    private func humanEvidenceItems(
        conflict: MeetingTruthConflict,
        confirmations: [MeetingTruthManualConfirmation]
    ) -> [MeetingTruthEvidenceItem] {
        guard let confirmation = confirmations.first(where: { $0.conflictID == conflict.id }),
              let selected = confirmation.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !selected.isEmpty else {
            return []
        }
        return [
            MeetingTruthEvidenceItem(
                channel: .human,
                source: "人工确认",
                text: selected,
                weight: 0.40,
                supportsClaim: true
            )
        ]
    }

    private func contradictingEvidenceItems(
        claim: String,
        conflict: MeetingTruthConflict,
        weight: Double
    ) -> [MeetingTruthEvidenceItem] {
        let contradicting = conflict.candidates.filter { candidate in
            !Self.text(candidate.text, containsNormalized: claim) &&
            !Self.text(claim, containsNormalized: candidate.text)
        }
        let perItemWeight = contradicting.isEmpty ? 0 : min(weight / Double(max(contradicting.count, 1)), weight)
        return contradicting.prefix(3).map {
            MeetingTruthEvidenceItem(
                channel: .asr,
                source: $0.source,
                text: $0.text,
                weight: perItemWeight,
                supportsClaim: false
            )
        }
    }

    private func isHighRisk(_ kind: MeetingTruthConflictKind) -> Bool {
        switch kind {
        case .amount, .person, .date, .project, .system, .actionItem, .decision:
            return true
        case .terminology, .ordinaryExpression:
            return false
        }
    }

    private func parameterEffect(asrScore: Double, visualScore: Double, ocrScore: Double, threshold: Double, score: Double) -> String {
        let strongest: String
        if visualScore >= asrScore && visualScore >= ocrScore {
            strongest = "当前主要由图片原图权重影响"
        } else if asrScore >= ocrScore {
            strongest = "当前主要由 ASR 共识权重影响"
        } else {
            strongest = "当前主要由 OCR 基线权重影响"
        }
        return "\(strongest)；分数 \(Self.percent(score)) / 阈值 \(Self.percent(threshold))。调高人工确认阈值会让更多结论进入人工确认，调高原图权重会放大手写和版式证据。"
    }

    private static func text(_ text: String, containsNormalized term: String) -> Bool {
        let normalizedText = normalized(text)
        let normalizedTerm = normalized(term)
        guard !normalizedText.isEmpty, !normalizedTerm.isEmpty else { return false }
        if normalizedText.contains(normalizedTerm) { return true }
        if normalizedTerm.count >= 3, normalizedText.contains(String(normalizedTerm.prefix(3))) { return true }
        return false
    }

    private static func normalized(_ text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func truncated(_ text: String, limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > limit ? "\(trimmed.prefix(limit))..." : trimmed
    }

    private static func confidence(from value: Double) -> MeetingTruthConfidence {
        if value >= 0.82 { return .high }
        if value >= 0.58 { return .medium }
        return .low
    }

    private static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}
