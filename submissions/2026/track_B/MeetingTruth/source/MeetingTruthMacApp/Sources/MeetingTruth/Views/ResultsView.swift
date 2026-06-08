import AppKit
import SwiftUI

private func copyResultText(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

private func meetingAnalysisMarkdown(_ analysis: MeetingAnalysis) -> String {
    var lines = ["# 会议整理", "", "## 摘要", analysis.summary, "", "## 主要观点"]
    lines += analysis.keyPoints.map { "- \($0)" }
    lines += ["", "## 思维框架"]
    for node in analysis.mindMap {
        appendMindMapMarkdown(node, depth: 0, to: &lines)
    }
    lines += ["", "## Mermaid 思维导图", "```mermaid", "mindmap", "  root((会议))"]
    for node in analysis.mindMap {
        appendMermaidMindMap(node, depth: 2, to: &lines)
    }
    lines += ["```", "", "## 会议纪要"]
    lines += analysis.minutes.map { "- \($0)" }
    lines += ["", "## 待办事项"]
    lines += analysis.actionItems.isEmpty
        ? ["- 暂无明确待办"]
        : analysis.actionItems.map { "- \($0.task)（\($0.owner ?? "未指定负责人") · \($0.due ?? "未指定时间")）" }
    return lines.joined(separator: "\n")
}

private func appendMindMapMarkdown(_ node: MindMapNode, depth: Int, to lines: inout [String]) {
    lines.append("\(String(repeating: "  ", count: depth))- \(node.title)")
    for child in node.children {
        appendMindMapMarkdown(child, depth: depth + 1, to: &lines)
    }
}

private func appendMermaidMindMap(_ node: MindMapNode, depth: Int, to lines: inout [String]) {
    let indent = String(repeating: "  ", count: depth)
    lines.append("\(indent)\(node.title.replacingOccurrences(of: "\n", with: " "))")
    for child in node.children {
        appendMermaidMindMap(child, depth: depth + 1, to: &lines)
    }
}

struct ResultsView: View {
    @EnvironmentObject private var store: LabStore
    @State private var selectedRunID: UUID?

    private var selectedRun: ComparisonRun? {
        if let selectedRunID, let run = store.runs.first(where: { $0.id == selectedRunID }) {
            return run
        }
        return store.runs.first(where: { !$0.cleanTranscriptPreview.isEmpty }) ?? store.runs.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HeaderView(
                    title: "结果对比",
                    subtitle: "把同一段音频在不同模型上的速度、准确率和文本质量放在一起看。"
                )

                RunProgressPanel()
                HistoryPanel(selectedRunID: $selectedRunID)

                if store.runs.isEmpty && store.runHistory.isEmpty {
                    EmptyStateView(
                        systemImage: "chart.bar.xaxis",
                        title: "暂无结果",
                        message: "从实验台运行一次模型对比后，这里会形成可回看的历史记录。"
                    )
                } else {
                    if store.isLoadingHistory {
                        HistoryLoadingPanel()
                    } else if !store.runs.isEmpty {
                        ReviewSummaryPanel()
                        AccelerationSummaryPanel()

                        if let run = selectedRun {
                            MeetingAnalysisPanel(run: run)
                            TranscriptPanel(run: run)
                        }

                        Surface {
                            LazyVStack(spacing: 0) {
                                ResultHeader()
                                Divider()
                                ForEach(store.runs) { run in
                                    Button {
                                        selectedRunID = run.id
                                    } label: {
                                        ResultRow(run: run)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    Divider()
                                }
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
    }
}

private struct MeetingAnalysisPanel: View {
    @EnvironmentObject private var store: LabStore
    @State private var refinementInstructions = ""
    @State private var selectedAnalysisID: UUID?
    let run: ComparisonRun

    private var currentRun: ComparisonRun {
        store.runs.first(where: { $0.id == run.id }) ?? run
    }

    private var analysisHistory: [MeetingAnalysis] {
        if !currentRun.meetingAnalysisHistory.isEmpty {
            return currentRun.meetingAnalysisHistory
        }
        if let current = currentRun.meetingAnalysis {
            return [current]
        }
        return []
    }

    private var selectedAnalysis: MeetingAnalysis? {
        if let selectedAnalysisID,
           let analysis = analysisHistory.first(where: { $0.id == selectedAnalysisID }) {
            return analysis
        }
        return analysisHistory.first
    }

    var body: some View {
        Surface {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("会议整理", systemImage: "sparkles")
                            .font(.headline)
                        Text(statusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let analysis = selectedAnalysis {
                        Button {
                            copyResultText(meetingAnalysisMarkdown(analysis))
                        } label: {
                            Label("复制整理", systemImage: "doc.on.doc")
                        }
                    }
                    Button {
                        store.generateMeetingAnalysis(for: currentRun.id)
                    } label: {
                        Label(store.isGeneratingMeetingAnalysis ? "生成中" : "生成摘要/纪要/待办", systemImage: "wand.and.stars")
                    }
                    .disabled(currentRun.cleanTranscriptPreview.isEmpty || store.isGeneratingMeetingAnalysis)
                }

                if store.isGeneratingMeetingAnalysis {
                    ProgressView()
                }

                if !analysisHistory.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("整理版本")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text("\(analysisHistory.count) 个版本")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(analysisHistory, id: \.id) { analysis in
                                    Button {
                                        selectedAnalysisID = analysis.id
                                        refinementInstructions = analysis.refinementInstructions
                                    } label: {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(LabStore.historyDateFormatter.string(from: analysis.generatedAt))
                                                .font(.caption.weight(.semibold))
                                            Text(analysis.refinementInstructions.isEmpty ? "默认整理" : "带纠偏要求")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                            Text(analysis.model)
                                                .font(.caption2)
                                                .foregroundStyle(.tertiary)
                                                .lineLimit(1)
                                        }
                                        .frame(width: 190, alignment: .leading)
                                        .padding(10)
                                        .background {
                                            RoundedRectangle(cornerRadius: 8)
                                                .fill(analysis.id == (selectedAnalysis?.id ?? analysisHistory.first?.id) ? Color.blue.opacity(0.14) : Color.secondary.opacity(0.08))
                                        }
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    TextField(
                        "补充背景/纠偏要求：例如“这次会议主要在讨论模型配置，不是交易；按产品功能、配置校验、后续待办三块整理”",
                        text: $refinementInstructions,
                        axis: .vertical
                    )
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...5)

                    HStack {
                        Text("如果结构不准，在这里补充会议背景、纠正主题或指定大框，再重新生成。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            store.generateMeetingAnalysis(
                                for: currentRun.id,
                                refinementInstructions: refinementInstructions
                            )
                        } label: {
                            Label("按要求重新生成", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .disabled(currentRun.cleanTranscriptPreview.isEmpty || store.isGeneratingMeetingAnalysis)
                    }
                }

                if let analysis = selectedAnalysis, analysis.hasContent {
                    VStack(alignment: .leading, spacing: 16) {
                        AnalysisBlock(title: "摘要", systemImage: "text.alignleft") {
                            Text(analysis.summary)
                                .textSelection(.enabled)
                                .lineSpacing(5)
                        }

                        AnalysisBlock(title: "主要观点", systemImage: "list.bullet.rectangle") {
                            BulletList(items: analysis.keyPoints)
                        }

                        AnalysisBlock(title: "思维框架", systemImage: "point.3.connected.trianglepath.dotted") {
                            MeetingMindMapCanvas(nodes: analysis.mindMap, rootTitle: "会议")
                        }

                        AnalysisBlock(title: "会议纪要", systemImage: "doc.text") {
                            BulletList(items: analysis.minutes)
                        }

                        AnalysisBlock(title: "待办事项", systemImage: "checklist") {
                            if analysis.actionItems.isEmpty {
                                Text("暂无明确待办")
                                    .foregroundStyle(.secondary)
                            } else {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(analysis.actionItems) { item in
                                        HStack(alignment: .top, spacing: 8) {
                                            Image(systemName: "circle")
                                                .font(.caption)
                                                .foregroundStyle(.blue)
                                                .padding(.top, 3)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(item.task)
                                                    .textSelection(.enabled)
                                                Text(actionMeta(for: item))
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                } else {
                    EmptyStateView(
                        systemImage: "sparkles.rectangle.stack",
                        title: "还没有会议整理",
                        message: "选择一条有文本的转写结果后，可以生成摘要、主要观点、思维框架、会议纪要和待办事项。"
                    )
                    .frame(minHeight: 120)
                }
            }
        }
    }

    private var statusText: String {
        if let analysis = selectedAnalysis {
            return "\(analysis.model) · \(analysis.tokenPlan.title) · \(LabStore.historyDateFormatter.string(from: analysis.generatedAt))"
        }
        return store.meetingAnalysisStatus
    }

    private func actionMeta(for item: MeetingActionItem) -> String {
        let owner = item.owner ?? "未指定负责人"
        let due = item.due ?? "未指定时间"
        return "\(owner) · \(due)"
    }

}

private struct AnalysisBlock<Content: View>: View {
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

private struct BulletList: View {
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 8) {
                    Text("•")
                        .foregroundStyle(.blue)
                    Text(item)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

private struct HistoryPanel: View {
    @EnvironmentObject private var store: LabStore
    @Binding var selectedRunID: UUID?

    var body: some View {
        if !store.runHistory.isEmpty {
            Surface {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("历史记录", systemImage: "clock.arrow.circlepath")
                            .font(.headline)
                        Spacer()
                        Text("\(store.runHistory.count) 次")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 10) {
                            ForEach(store.runHistory) { entry in
                                Button {
                                    store.selectHistory(entry)
                                    selectedRunID = nil
                                } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(LabStore.historyDateFormatter.string(from: entry.createdAt))
                                            .font(.caption.weight(.semibold))
                                        Text(entry.title)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Text(URL(fileURLWithPath: entry.audioPath).lastPathComponent)
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1)
                                    }
                                    .frame(width: 220, alignment: .leading)
                                    .padding(10)
                                    .background {
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(entry.id == store.selectedHistoryID ? Color.blue.opacity(0.14) : Color.secondary.opacity(0.08))
                                    }
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct HistoryLoadingPanel: View {
    @EnvironmentObject private var store: LabStore

    var body: some View {
        Surface {
            HStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 4) {
                    Text("正在载入历史记录")
                        .font(.headline)
                    Text(store.currentStage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }
}

private struct RunProgressPanel: View {
    @EnvironmentObject private var store: LabStore

    var body: some View {
        Surface {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(store.activeTaskTitle, systemImage: "timer")
                        .font(.headline)
                    Spacer()
                    if store.isRunning {
                        Button {
                            store.cancelCurrentTask()
                        } label: {
                            Label("停止", systemImage: "stop.circle")
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    }
                    Text("\(Int(store.activeTaskProgress * 100))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                ProgressView(value: store.activeTaskProgress)

                HStack(spacing: 14) {
                    MetricPill(title: "阶段", value: store.currentStage)
                    MetricPill(title: "已用时", value: store.elapsedTimeLabel)
                    MetricPill(title: "预计剩余", value: store.remainingTimeLabel)
                }

                if store.isRunning, !store.liveTranscript.isEmpty {
                    Text(store.liveTranscript)
                        .lineLimit(3)
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(.quaternary.opacity(0.35))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }
}

private struct TranscriptPanel: View {
    @EnvironmentObject private var store: LabStore
    @State private var isExpanded = false
    let run: ComparisonRun

    private let previewCharacterLimit = 5_000

    private var currentRun: ComparisonRun {
        store.runs.first(where: { $0.id == run.id }) ?? run
    }

    private var transcriptText: String {
        currentRun.cleanTranscriptPreview
    }

    private var isLongTranscript: Bool {
        transcriptText.count > previewCharacterLimit
    }

    private var displayedTranscript: String {
        guard isLongTranscript, !isExpanded else { return transcriptText }
        return String(transcriptText.prefix(previewCharacterLimit))
    }

    var body: some View {
        Surface {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("完整转写")
                            .font(.headline)
                    Text(run.modelName)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let group = currentRun.equivalenceGroup {
                        Button {
                            store.markEquivalentGroupAsSameGood(for: group)
                        } label: {
                            Label(group, systemImage: "equal.circle")
                        }
                    }
                    Button {
                        copyResultText(currentRun.cleanTranscriptPreview)
                    } label: {
                        Label("复制", systemImage: "doc.on.doc")
                    }
                    .disabled(currentRun.cleanTranscriptPreview.isEmpty)

                    Button {
                        store.rerunRun(currentRun.id)
                    } label: {
                        Label("原参数重跑当前", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(store.isRunning)

                    if let errorMessage = currentRun.errorMessage, !errorMessage.isEmpty {
                        Button {
                            copyResultText(debugReport(errorMessage: userReadableError(errorMessage)))
                        } label: {
                            Label("复制错误", systemImage: "exclamationmark.doc")
                        }
                    }

                    Button {
                        exportTranscript()
                    } label: {
                        Label("导出", systemImage: "square.and.arrow.down")
                    }
                    .disabled(currentRun.cleanTranscriptPreview.isEmpty)
                }

                ReviewControls(run: currentRun)
                AccelerationDetailPanel(run: currentRun)

                if let warning = currentRun.automaticQualityWarning {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(warning)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                        Spacer()
                    }
                    .padding(10)
                    .background(Color.orange.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                if transcriptText.isEmpty {
                    EmptyStateView(
                        systemImage: "doc.text.magnifyingglass",
                        title: currentRun.status,
                        message: currentRun.errorMessage.map(userReadableError) ?? "这个模型还没有生成可显示的转写文本。请先选择已完成配置的 Qwen3 或 GLM 模型运行。"
                    )
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        if isLongTranscript {
                            HStack {
                                Label(
                                    isExpanded ? "已展开全文" : "显示前 \(previewCharacterLimit) 字",
                                    systemImage: isExpanded ? "doc.text" : "doc.text.magnifyingglass"
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                Spacer()
                                Button {
                                    isExpanded.toggle()
                                } label: {
                                    Label(isExpanded ? "收起" : "展开全文", systemImage: isExpanded ? "chevron.up" : "chevron.down")
                                }
                                .buttonStyle(.bordered)
                            }
                        }

                        if isExpanded || !isLongTranscript {
                            Text(displayedTranscript)
                                .font(.body)
                                .textSelection(.enabled)
                                .lineSpacing(6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Text(displayedTranscript)
                                .font(.body)
                                .lineSpacing(6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(14)
                    .background(.quaternary.opacity(0.35))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .onChange(of: currentRun.id) { _, _ in
            isExpanded = false
        }
    }

    private func exportTranscript() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(run.modelName)-transcript.md"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        var body = """
        # \(currentRun.modelName) 转写结果

        - 状态：\(currentRun.status)
        - Runtime：\(currentRun.runtime)
        - RTF：\(currentRun.rtf.map { String(format: "%.4f", $0) } ?? "-")
        - 速度：\(currentRun.speed.map { String(format: "%.2fx", $0) } ?? "-")
        - 音频时长：\(currentRun.duration.map { String(format: "%.1fs", $0) } ?? "-")
        - 转写耗时：\(currentRun.transcribeTime.map { String(format: "%.2fs", $0) } ?? "-")
        - 加速设备：\(currentRun.acceleratorDevice ?? "-")
        - MPS 回退：\(currentRun.acceleratorFallbackReason ?? "-")
        - 分段数：\(currentRun.segmentCount.map(String.init) ?? "-")
        - 缓存命中：\(currentRun.cachedSegmentCount.map(String.init) ?? "-")
        - 人工标签：\(currentRun.reviewerVerdict.title)
        - 人工评分：\(currentRun.reviewerScore.map(String.init) ?? "-")
        - 相似分组：\(currentRun.equivalenceGroup ?? "-")
        - 备注：\(currentRun.reviewerNote.isEmpty ? "-" : currentRun.reviewerNote)

        \(currentRun.cleanTranscriptPreview)
        """
        if let analysis = currentRun.meetingAnalysis {
            body += "\n\n---\n\n\(meetingAnalysisMarkdown(analysis))"
        }

        try? body.write(to: url, atomically: true, encoding: .utf8)
    }

    private func debugReport(errorMessage: String) -> String {
        [
            "模型：\(currentRun.modelName) (\(currentRun.modelID))",
            "状态：\(currentRun.status)",
            "运行时：\(currentRun.runtime)",
            "错误：\(errorMessage)"
        ].joined(separator: "\n")
    }

    private func userReadableError(_ message: String) -> String {
        if currentRun.modelID == "mimo-v2-5-asr-mlx" ||
            message.contains("MiMo MLX") ||
            message.contains("LOCAL_ASR_PROGRESS") ||
            message.contains("Generating MLX transcript") {
            return "MiMo MLX 当前生成路线会卡在片段生成阶段，已从新版转写队列禁用。请使用 Qwen3 或 GLM 跑转写。"
        }
        if message.contains("Traceback") {
            return message
                .split(separator: "\n")
                .last
                .map(String.init) ?? "本地推理返回异常。"
        }
        return message
    }
}

private struct AccelerationSummaryPanel: View {
    @EnvironmentObject private var store: LabStore

    private var completedRuns: [ComparisonRun] {
        store.runs.filter { $0.transcribeTime != nil }
    }

    private var fastestRun: ComparisonRun? {
        completedRuns.min { ($0.rtf ?? .greatestFiniteMagnitude) < ($1.rtf ?? .greatestFiniteMagnitude) }
    }

    var body: some View {
        Surface {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("加速概览", systemImage: "bolt.fill")
                        .font(.headline)
                    Spacer()
                    if let fastestRun {
                        Text("最快：\(fastestRun.modelName)")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 10) {
                    MetricPill(title: "MPS", value: "\(deviceCount("mps"))")
                    MetricPill(title: "CPU", value: "\(deviceCount("cpu"))")
                    MetricPill(title: "回退", value: "\(completedRuns.filter { $0.acceleratorFallbackReason != nil }.count)")
                    MetricPill(title: "最佳 RTF", value: fastestRun?.rtf.map { String(format: "%.3f", $0) } ?? "-")
                    MetricPill(title: "最佳速度", value: fastestRun?.speed.map { String(format: "%.2fx", $0) } ?? "-")
                }

                if !completedRuns.isEmpty {
                    VStack(spacing: 8) {
                        ForEach(completedRuns) { run in
                            AccelerationBar(run: run, bestRTF: fastestRun?.rtf)
                        }
                    }
                }
            }
        }
    }

    private func deviceCount(_ device: String) -> Int {
        completedRuns.filter { $0.acceleratorDevice?.lowercased() == device }.count
    }
}

private struct AccelerationDetailPanel: View {
    let run: ComparisonRun

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                MetricPill(title: "设备", value: run.acceleratorDevice?.uppercased() ?? runtimeDeviceHint)
                MetricPill(title: "RTF", value: run.rtf.map { String(format: "%.3f", $0) } ?? "-")
                MetricPill(title: "速度", value: run.speed.map { String(format: "%.2fx", $0) } ?? "-")
                MetricPill(title: "耗时", value: run.transcribeTime.map { String(format: "%.2fs", $0) } ?? "-")
            }

            if let reason = run.acceleratorFallbackReason {
                Label(reason, systemImage: "arrow.uturn.backward.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
            }
        }
    }

    private var runtimeDeviceHint: String {
        if run.runtime.contains("sherpa") { return "CPU/ONNX" }
        return "-"
    }
}

private struct AccelerationBar: View {
    let run: ComparisonRun
    let bestRTF: Double?

    private var normalizedWidth: Double {
        guard let rtf = run.rtf, rtf > 0, let bestRTF, bestRTF > 0 else { return 0.05 }
        return min(max(bestRTF / rtf, 0.05), 1.0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(run.modelName)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Spacer()
                Text("\(run.acceleratorDevice?.uppercased() ?? "-") · \(run.rtf.map { String(format: "%.3f", $0) } ?? "-") RTF")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.quaternary.opacity(0.45))
                    RoundedRectangle(cornerRadius: 4)
                        .fill(barColor)
                        .frame(width: max(proxy.size.width * normalizedWidth, 4))
                }
            }
            .frame(height: 8)
        }
    }

    private var barColor: Color {
        if run.acceleratorFallbackReason != nil { return .orange }
        switch run.acceleratorDevice?.lowercased() {
        case "mps": return .green
        case "cpu": return .blue
        default: return .secondary
        }
    }
}

private struct ReviewSummaryPanel: View {
    @EnvironmentObject private var store: LabStore

    var body: some View {
        Surface {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "checklist")
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("人工评审")
                            .font(.headline)
                        Text(store.reviewSummary)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button {
                        store.rerunAutomaticQualityFailures()
                    } label: {
                        Label("原参数重跑异常项", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.bordered)
                    .disabled(store.isRunning || automaticIssueCount == 0)
                }

                HStack(spacing: 10) {
                    ForEach(summaryMetrics, id: \.title) { item in
                        MetricPill(title: item.title, value: item.value)
                    }
                }
            }
        }
    }

    private var summaryMetrics: [(title: String, value: String)] {
        [
            ("已评分", "\(store.runs.filter { $0.reviewerVerdict != .unrated }.count)/\(store.runs.count)"),
            ("一样文本", "\(Set(store.runs.compactMap(\.equivalenceGroup)).count) 组"),
            ("未识别", "\(store.runs.filter { $0.reviewerVerdict == .missed || $0.status == "无文本" || $0.status == "失败" }.count)"),
            ("自动异常", "\(automaticIssueCount)")
        ]
    }

    private var automaticIssueCount: Int {
        store.runs.filter {
            $0.automaticQualityWarning != nil ||
            $0.reviewerVerdict == .missed ||
            $0.status == "无文本" ||
            $0.status == "失败"
        }.count
    }
}

private struct ReviewControls: View {
    @EnvironmentObject private var store: LabStore
    let run: ComparisonRun

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("人工标签", selection: verdictBinding) {
                ForEach(TranscriptVerdict.allCases, id: \.self) { verdict in
                    Label(verdict.title, systemImage: verdict.systemImage)
                        .tag(verdict)
                }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 12) {
                Stepper(value: scoreBinding, in: 0...5) {
                    Text("评分 \(run.reviewerScore.map(String.init) ?? "未评分")")
                        .monospacedDigit()
                }
                .frame(width: 170, alignment: .leading)

                if let group = run.equivalenceGroup {
                    Button {
                        store.markEquivalentGroupAsSameGood(for: group)
                    } label: {
                        Label("整组一样好", systemImage: "equal.circle")
                    }
                }

                TextField("备注：例如漏字、错专有名词、断句好", text: noteBinding)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private var verdictBinding: Binding<TranscriptVerdict> {
        Binding(
            get: { currentRun.reviewerVerdict },
            set: { store.updateReview(for: run.id, verdict: $0) }
        )
    }

    private var scoreBinding: Binding<Int> {
        Binding(
            get: { currentRun.reviewerScore ?? 0 },
            set: { store.updateScore(for: run.id, score: $0) }
        )
    }

    private var noteBinding: Binding<String> {
        Binding(
            get: { currentRun.reviewerNote },
            set: { store.updateNote(for: run.id, note: $0) }
        )
    }

    private var currentRun: ComparisonRun {
        store.runs.first(where: { $0.id == run.id }) ?? run
    }
}

private struct ResultHeader: View {
    var body: some View {
        HStack {
            Text("模型").frame(maxWidth: .infinity, alignment: .leading)
            Text("状态").frame(width: 110, alignment: .leading)
            Text("人工").frame(width: 90, alignment: .leading)
            Text("设备").frame(width: 74, alignment: .leading)
            Text("评分").frame(width: 56, alignment: .trailing)
            Text("RTF").frame(width: 80, alignment: .trailing)
            Text("速度").frame(width: 90, alignment: .trailing)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.vertical, 8)
    }
}
