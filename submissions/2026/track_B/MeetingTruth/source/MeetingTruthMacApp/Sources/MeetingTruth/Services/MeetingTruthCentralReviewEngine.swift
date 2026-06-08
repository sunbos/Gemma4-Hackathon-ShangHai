import Foundation

struct MeetingTruthCentralReviewEngine {
    func buildLedger(
        model: String,
        transcriptSources: [MeetingTruthTranscriptSource],
        materials: [MeetingTruthMaterial],
        visualEvidence: [MeetingTruthVisualEvidence],
        conflicts: [MeetingTruthConflict],
        confirmations: [MeetingTruthManualConfirmation],
        factCandidates: [MeetingTruthFactCandidate],
        evidenceAtoms: [MeetingTruthEvidenceAtom],
        factDecisions: [MeetingTruthFactDecision],
        analysis: MeetingAnalysis?
    ) -> MeetingTruthCentralReviewLedger {
        let observations = visualObservations(materials: materials, visualEvidence: visualEvidence)
        let claims = centralClaims(
            factCandidates: factCandidates,
            evidenceAtoms: evidenceAtoms,
            factDecisions: factDecisions,
            confirmations: confirmations
        )
        let gaps = reviewGaps(
            claims: claims,
            observations: observations,
            materials: materials,
            visualEvidence: visualEvidence,
            conflicts: conflicts
        )
        let packageAuditNotes = packageAuditNotes(analysis: analysis, claims: claims)

        return MeetingTruthCentralReviewLedger(
            model: model,
            inputSummary: inputSummary(
                transcriptSources: transcriptSources,
                materials: materials,
                visualEvidence: visualEvidence,
                confirmations: confirmations
            ),
            visualObservations: observations,
            claims: claims,
            gaps: gaps,
            packageAuditNotes: packageAuditNotes,
            completionStandard: [
                "原图视觉证据必须来自 image_url，不得把 OCR 基线伪装成多模态结论。",
                "人名、金额、日期、负责人、截止时间、项目名等高风险事实必须有跨来源证据或人工确认。",
                "每个正式结论必须能追溯到 ASR、材料、原图视觉或人工确认之一。",
                "证据不足时输出人工确认问题，而不是让模型猜测。"
            ]
        )
    }

    private func inputSummary(
        transcriptSources: [MeetingTruthTranscriptSource],
        materials: [MeetingTruthMaterial],
        visualEvidence: [MeetingTruthVisualEvidence],
        confirmations: [MeetingTruthManualConfirmation]
    ) -> [String] {
        [
            "\(transcriptSources.count) 路 ASR 候选，其中 \(transcriptSources.filter(\.hasTimestamp).count) 路含时间戳",
            "\(materials.filter { $0.kind == "图片" }.count) 张图片原图，\(materials.filter { $0.kind == "图片" && !$0.extractedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count) 张带 OCR 基线",
            "\(materials.filter { $0.kind != "图片" }.count) 份文本/PDF/术语材料",
            "\(visualEvidence.count) 条 Gemma 原图视觉观察",
            "\(confirmations.filter { $0.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }.count) 条人工确认"
        ]
    }

    private func visualObservations(
        materials: [MeetingTruthMaterial],
        visualEvidence: [MeetingTruthVisualEvidence]
    ) -> [MeetingTruthVisualObservation] {
        let imageMaterials = materials.filter { $0.kind == "图片" }
        let observations = visualEvidence.map { evidence in
            let material = imageMaterials.first { $0.id == evidence.materialID || $0.name == evidence.materialName }
            return MeetingTruthVisualObservation(
                materialID: material?.id ?? evidence.materialID,
                materialName: evidence.materialName,
                materialRole: materialRole(for: material, evidence: evidence),
                summary: evidence.summary,
                layoutCues: evidence.layoutCues,
                visualMarks: evidence.visualMarks,
                participantEvidence: evidence.participants,
                actionHints: evidence.actionHints,
                ocrBaseline: material?.extractedText ?? "",
                ocrContrast: evidence.ocrContrast,
                confidence: evidence.confidence
            )
        }

        let missingRawVision = imageMaterials
            .filter { material in
                !visualEvidence.contains { $0.materialID == material.id || $0.materialName == material.name }
            }
            .map { material in
                MeetingTruthVisualObservation(
                    materialID: material.id,
                    materialName: material.name,
                    materialRole: materialRole(for: material, evidence: nil),
                    summary: "图片已导入，但尚未完成 Gemma 原图理解。",
                    layoutCues: [],
                    visualMarks: [],
                    participantEvidence: [],
                    actionHints: [],
                    ocrBaseline: material.extractedText,
                    ocrContrast: material.extractedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "当前既没有 OCR 基线，也没有原图视觉证据。"
                        : "当前只有 OCR 基线，缺少原图版式、手写、箭头、圈注和空间关系理解。",
                    confidence: .low
                )
            }

        return observations + missingRawVision
    }

    private func centralClaims(
        factCandidates: [MeetingTruthFactCandidate],
        evidenceAtoms: [MeetingTruthEvidenceAtom],
        factDecisions: [MeetingTruthFactDecision],
        confirmations: [MeetingTruthManualConfirmation]
    ) -> [MeetingTruthCentralClaim] {
        let factsByID = Dictionary(uniqueKeysWithValues: factCandidates.map { ($0.id, $0) })
        let confirmationByFactID = Dictionary(
            uniqueKeysWithValues: confirmations.compactMap { confirmation -> (UUID, MeetingTruthManualConfirmation)? in
                guard confirmation.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return nil }
                return (confirmation.conflictID, confirmation)
            }
        )

        return factDecisions.map { decision in
            let fact = factsByID[decision.factID]
            let atoms = evidenceAtoms.filter { $0.factID == decision.factID }
            let supporting = atoms.filter(\.supportsClaim).map(centralEvidence)
            let contradicting = atoms.filter { !$0.supportsClaim }.map(centralEvidence)
            let confirmation = confirmationByFactID[decision.factID]
            let status = centralStatus(for: decision, hasManualConfirmation: confirmation != nil)
            return MeetingTruthCentralClaim(
                factID: decision.factID,
                kind: decision.kind,
                claim: decision.claim,
                proposedCanonicalText: confirmation?.selectedText ?? decision.chosenText,
                sourceSpan: fact?.sourceSpan ?? decision.claim,
                status: status,
                confidence: decision.confidence,
                importance: decision.importance,
                riskLevel: decision.riskLevel,
                supportingEvidence: supporting,
                contradictingEvidence: contradicting,
                missingEvidence: decision.missingEvidence,
                humanQuestion: decision.requiresUserInput ? humanQuestion(for: decision, evidence: supporting + contradicting) : nil,
                decisionReason: decision.reason
            )
        }
    }

    private func centralEvidence(from atom: MeetingTruthEvidenceAtom) -> MeetingTruthCentralEvidence {
        MeetingTruthCentralEvidence(
            channel: centralChannel(from: atom.channel),
            sourceName: atom.sourceName,
            text: atom.text,
            visualCue: atom.visualCue,
            supportsClaim: atom.supportsClaim,
            confidence: atom.confidence,
            priority: priority(for: atom.channel)
        )
    }

    private func reviewGaps(
        claims: [MeetingTruthCentralClaim],
        observations: [MeetingTruthVisualObservation],
        materials: [MeetingTruthMaterial],
        visualEvidence: [MeetingTruthVisualEvidence],
        conflicts: [MeetingTruthConflict]
    ) -> [MeetingTruthReviewGap] {
        var gaps: [MeetingTruthReviewGap] = []

        for claim in claims where claim.requiresHumanReview {
            gaps.append(
                MeetingTruthReviewGap(
                    kind: claim.riskLevel == .high ? .unsupportedHighRiskFact : .noCrossModalEvidence,
                    title: claim.kind.title,
                    detail: claim.missingEvidence.isEmpty ? claim.decisionReason : claim.missingEvidence.joined(separator: "；"),
                    relatedClaimID: claim.id,
                    requiresHumanReview: true
                )
            )
        }

        for observation in observations where !observation.hasRawVisionOnlySignal {
            gaps.append(
                MeetingTruthReviewGap(
                    kind: .noRawVision,
                    title: observation.materialName,
                    detail: observation.ocrContrast,
                    relatedClaimID: nil,
                    requiresHumanReview: !materials.filter { $0.kind == "图片" }.isEmpty && visualEvidence.isEmpty
                )
            )
        }

        for observation in observations where observation.hasRawVisionOnlySignal && !observation.ocrBaseline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            gaps.append(
                MeetingTruthReviewGap(
                    kind: .ocrRawVisionMismatch,
                    title: observation.materialName,
                    detail: observation.ocrContrast.isEmpty ? "OCR 只提供文字，原图还提供版式/标记/空间关系。" : observation.ocrContrast,
                    relatedClaimID: nil,
                    requiresHumanReview: false
                )
            )
        }

        for conflict in conflicts where !conflict.isResolved && conflict.requiresHumanReview {
            gaps.append(
                MeetingTruthReviewGap(
                    kind: .unsupportedHighRiskFact,
                    title: conflict.kind.title,
                    detail: conflict.evidence.isEmpty ? "冲突尚未人工确认。" : conflict.evidence,
                    relatedClaimID: nil,
                    requiresHumanReview: true
                )
            )
        }

        return deduplicated(gaps)
    }

    private func packageAuditNotes(
        analysis: MeetingAnalysis?,
        claims: [MeetingTruthCentralClaim]
    ) -> [String] {
        guard let analysis else {
            return ["成果包尚未生成；生成前必须通过中央复核账本门禁。"]
        }
        var notes: [String] = []
        let acceptedCount = claims.filter { !$0.requiresHumanReview && $0.status != .rejected }.count
        notes.append("成果包生成时可用事实：\(acceptedCount) 条。")
        if analysis.evidenceNotes.isEmpty {
            notes.append("成果包缺少 evidenceNotes，需要生成后复检补证据链。")
        } else {
            notes.append("成果包包含 \(analysis.evidenceNotes.count) 条证据说明。")
        }
        if !analysis.actionItems.isEmpty {
            let incompleteActions = analysis.actionItems.filter {
                ($0.owner ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                ($0.due ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            if !incompleteActions.isEmpty {
                notes.append("\(incompleteActions.count) 条待办缺负责人或截止时间，需保留待确认状态。")
            }
        }
        return notes
    }

    private func materialRole(for material: MeetingTruthMaterial?, evidence: MeetingTruthVisualEvidence?) -> String {
        let text = [
            material?.name ?? "",
            material?.detail ?? "",
            evidence?.summary ?? "",
            evidence?.layoutCues.joined(separator: " ") ?? "",
            evidence?.visualMarks.joined(separator: " ") ?? ""
        ].joined(separator: " ").lowercased()

        if text.contains("白板") || text.contains("whiteboard") { return "白板/现场图" }
        if text.contains("群聊") || text.contains("截图") || text.contains("chat") { return "群聊/截图补充" }
        if text.contains("纪要") || text.contains("手写") || text.contains("笔记") { return "手写会议纪要" }
        if text.contains("表格") || text.contains("table") { return "表格材料" }
        return "图片会议材料"
    }

    private func centralStatus(
        for decision: MeetingTruthFactDecision,
        hasManualConfirmation: Bool
    ) -> MeetingTruthCentralVerdictStatus {
        if hasManualConfirmation || decision.status == .confirmed { return .accepted }
        switch decision.status {
        case .accepted:
            return .accepted
        case .confirmed:
            return .accepted
        case .lowConfidence:
            return .needsHumanReview
        case .conflicted:
            return .conflicted
        case .unsupported:
            return .rejected
        case .needsUserInput:
            return decision.missingEvidence.isEmpty ? .needsHumanReview : .missing
        }
    }

    private func centralChannel(from channel: MeetingTruthFactChannel) -> MeetingTruthCentralEvidenceChannel {
        switch channel {
        case .asr: .asr
        case .imageOCR: .imageOCR
        case .rawVision: .rawVision
        case .material: .material
        case .human: .human
        case .conflict: .conflict
        }
    }

    private func priority(for channel: MeetingTruthFactChannel) -> Int {
        switch channel {
        case .human: 100
        case .material: 80
        case .rawVision: 76
        case .imageOCR: 48
        case .asr: 44
        case .conflict: 38
        }
    }

    private func humanQuestion(
        for decision: MeetingTruthFactDecision,
        evidence: [MeetingTruthCentralEvidence]
    ) -> String {
        let sources = evidence
            .sorted { $0.priority > $1.priority }
            .prefix(3)
            .map { "\($0.channel.title)：\($0.sourceName)" }
            .joined(separator: "；")
        let basis = sources.isEmpty ? "当前缺少可采信证据" : "已有证据：\(sources)"
        return "请确认「\(decision.chosenText)」是否为真实\(decision.kind.title)。\(basis)。"
    }

    private func deduplicated(_ gaps: [MeetingTruthReviewGap]) -> [MeetingTruthReviewGap] {
        var seen = Set<String>()
        return gaps.filter { gap in
            let key = "\(gap.kind.rawValue)|\(gap.title)|\(gap.detail)"
            guard !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
    }
}
