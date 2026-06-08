import SwiftUI

struct MeetingTruthProcessingTraceView: View {
    @EnvironmentObject private var store: LabStore

    private var run: MeetingTruthProcessingRun {
        store.meetingTruthProcessingRun
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    summary
                    flowDiagram(proxy: proxy)
                    anchors
                    toolTimeline
                }
                .padding(24)
                .padding(.top, 4)
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                stickyAnchorBar(proxy: proxy)
            }
            .onAppear {
                proxy.scrollTo(store.meetingTruthProcessingTraceFocus, anchor: .top)
            }
            .onChange(of: store.meetingTruthProcessingTraceFocus) { _, anchor in
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(anchor, anchor: .top)
                }
            }
        }
    }

    private var header: some View {
        Surface {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 34))
                    .foregroundStyle(.blue)

                VStack(alignment: .leading, spacing: 6) {
                    Text("处理链路追踪")
                        .font(.title.weight(.semibold))
                    Text("按步骤查看处理来源、输入输出和开发者细节；本地安全校验会单独显示，不会当作工具调用。")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 6) {
                    MeetingTruthTraceBadge(text: run.finalStatus, color: run.errors.isEmpty ? .green : .orange)
                    Text(run.durationLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("run_id: \(run.runID)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var summary: some View {
        Surface {
            VStack(alignment: .leading, spacing: 12) {
                Label("本轮概览", systemImage: "list.bullet.rectangle")
                    .font(.headline)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    traceMetric("模型调用", "\(run.modelCalls)", "Gemma 普通调用或 function calling")
                    traceMetric("多模态", "\(run.multimodalCalls)", "Gemma 多模态 / 原图理解")
                    traceMetric("OCR", "\(run.ocrCalls)", "OCR / 图片文字识别")
                    traceMetric("人工确认", "\(run.userActions)", "人工确认")
                    ForEach(run.summaryMetrics.prefix(8)) { metric in
                        traceMetric(metric.title, metric.value, metric.detail)
                    }
                }
            }
        }
    }

    private func stickyAnchorBar(proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("链路导航", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.caption.weight(.semibold))
                Text(store.meetingTruthProcessingTraceFocus.title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(run.anchors) { anchor in
                        Button {
                            jump(to: anchor.kind, proxy: proxy)
                        } label: {
                            HStack(spacing: 5) {
                                Text("\(anchor.kind.sequence)")
                                    .font(.caption2.weight(.bold))
                                    .frame(width: 18, height: 18)
                                    .background(anchor.kind == store.meetingTruthProcessingTraceFocus ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12))
                                    .clipShape(Circle())
                                Text(anchor.kind.title)
                                    .font(.caption2.weight(.semibold))
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(anchor.kind == store.meetingTruthProcessingTraceFocus ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08))
                            .foregroundStyle(anchor.kind == store.meetingTruthProcessingTraceFocus ? .primary : .secondary)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.bottom, 1)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.secondary.opacity(0.12))
                .frame(height: 1)
        }
    }

    private func flowDiagram(proxy: ScrollViewProxy) -> some View {
        Surface {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label("链路流程图", systemImage: "arrow.triangle.branch")
                        .font(.headline)
                    Spacer()
                    Text("点击节点跳到步骤详情")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(anchorRows.enumerated()), id: \.offset) { rowIndex, row in
                        HStack(alignment: .center, spacing: 8) {
                            ForEach(Array(row.enumerated()), id: \.element.id) { itemIndex, anchor in
                                MeetingTruthFlowNode(
                                    anchor: anchor,
                                    isFocused: anchor.kind == store.meetingTruthProcessingTraceFocus,
                                    color: statusColor(anchor.status),
                                    triggerText: anchor.triggers.map(triggerTitle).joined(separator: " / "),
                                    action: {
                                        jump(to: anchor.kind, proxy: proxy)
                                    }
                                )

                                if itemIndex < row.count - 1 {
                                    MeetingTruthFlowConnector(color: connectorColor(from: anchor, to: row[itemIndex + 1]))
                                }
                            }
                        }

                        if rowIndex < anchorRows.count - 1 {
                            MeetingTruthFlowRowConnector(
                                fromTitle: row.last?.kind.title ?? "",
                                toTitle: anchorRows[rowIndex + 1].first?.kind.title ?? ""
                            )
                        }
                    }
                }

                HStack(spacing: 10) {
                    flowLegend("完成", .green)
                    flowLegend("有警告", .orange)
                    flowLegend("失败", .red)
                    flowLegend("未开始", .secondary)
                }
            }
        }
    }

    private var anchorRows: [[MeetingTruthProcessingAnchor]] {
        stride(from: 0, to: run.anchors.count, by: 4).map { start in
            Array(run.anchors[start..<min(start + 4, run.anchors.count)])
        }
    }

    private func jump(to anchor: MeetingTruthProcessingAnchorKind, proxy: ScrollViewProxy) {
        store.meetingTruthProcessingTraceFocus = anchor
        withAnimation(.easeInOut(duration: 0.22)) {
            proxy.scrollTo(anchor, anchor: .top)
        }
    }

    private func connectorColor(from lhs: MeetingTruthProcessingAnchor, to rhs: MeetingTruthProcessingAnchor) -> Color {
        if lhs.status == .failed || rhs.status == .failed { return .red }
        if lhs.status == .warning || rhs.status == .warning { return .orange }
        if lhs.status == .completed && rhs.status == .completed { return .green }
        return .secondary
    }

    private func flowLegend(_ title: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var anchors: some View {
        Surface {
            VStack(alignment: .leading, spacing: 12) {
                Label("步骤处理来源", systemImage: "point.3.filled.connected.trianglepath.dotted")
                    .font(.headline)

                ForEach(run.anchors) { anchor in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(anchor.kind.sequence). \(anchor.kind.title)")
                                .font(.subheadline.weight(.semibold))
                            MeetingTruthTraceBadge(text: anchor.status.title, color: statusColor(anchor.status))
                            Spacer()
                            Text(anchor.durationLabel)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Text(anchor.kind.plainExplanation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        traceRow("处理来源", anchor.triggers.map(triggerTitle).joined(separator: " / "))
                        traceRow("输入摘要", anchor.inputs.joined(separator: "\n"))
                        traceRow("处理摘要", anchor.processing.joined(separator: "\n"))
                        traceRow("输出摘要", anchor.outputs.joined(separator: "\n"))

                        if !anchor.issues.isEmpty {
                            traceRow("错误和警告", anchor.issues.map { "\($0.kind.title)：\($0.message)；影响：\($0.impact.title)" }.joined(separator: "\n"))
                        }

                        DisclosureGroup("开发者详情") {
                            VStack(alignment: .leading, spacing: 8) {
                                traceRow("下一步", anchor.nextStep)
                                traceRow("工具输入/输出摘要", anchor.technicalDetails.joined(separator: "\n"))
                                if let raw = anchor.rawDetails, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    traceRow("原始 JSON", raw)
                                }
                            }
                            .padding(.top, 6)
                        }
                        .font(.caption)
                    }
                    .padding(10)
                    .background(anchor.kind == store.meetingTruthProcessingTraceFocus ? Color.blue.opacity(0.08) : Color.secondary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .id(anchor.kind)
                }
            }
        }
    }

    private var toolTimeline: some View {
        Surface {
            VStack(alignment: .leading, spacing: 12) {
                Label("工具链时间线", systemImage: "function")
                    .font(.headline)

                if run.toolTimeline.isEmpty {
                    EmptyStateView(
                        systemImage: "function",
                        title: "还没有工具链时间线",
                        message: "只有证据检索、候选评分、中枢复核等工具链步骤会显示工具调用详情。"
                    )
                    .frame(minHeight: 160)
                } else {
                    ForEach(run.toolTimeline) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(item.stepName)
                                    .font(.subheadline.weight(.semibold))
                                MeetingTruthTraceBadge(text: item.status.title, color: statusColor(item.status))
                                Spacer()
                                Text(item.durationLabel)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }

                            let usesGemmaToolCall = item.triggers.contains(.gemmaFunctionCalling)
                            traceRow("处理来源", item.triggers.map(triggerTitle).joined(separator: " / "))
                            traceRow(usesGemmaToolCall ? "tool_call" : "执行输入", item.inputSummary)
                            traceRow(usesGemmaToolCall ? "tool_response" : "执行结果", item.outputSummary)
                            traceRow("模型与耗时", item.modelUsage)

                            if let raw = item.rawJSON, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                DisclosureGroup("原始 JSON") {
                                    Text(raw)
                                        .font(.caption.monospaced())
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .padding(.top, 6)
                                }
                                .font(.caption)
                            }
                        }
                        .padding(10)
                        .background(.secondary.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }

    private func traceMetric(_ title: String, _ value: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.secondary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func traceRow(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text.isEmpty ? "暂无" : text)
                .font(.caption)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func triggerTitle(_ trigger: MeetingTruthProcessingTrigger) -> String {
        switch trigger {
        case .swiftRules:
            return "Swift 规则"
        case .gemmaText:
            return "Gemma 普通调用"
        case .gemmaMultimodal:
            return "Gemma 多模态"
        case .gemmaFunctionCalling:
            return "Gemma function calling"
        case .localToolFunction:
            return "本地工具函数"
        case .ocr:
            return "OCR"
        case .userConfirmation:
            return "用户确认"
        }
    }

    private func statusColor(_ status: MeetingTruthProcessingStageStatus) -> Color {
        switch status {
        case .notStarted:
            return .secondary
        case .running:
            return .blue
        case .completed:
            return .green
        case .warning:
            return .orange
        case .failed:
            return .red
        }
    }
}

private struct MeetingTruthTraceBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct MeetingTruthFlowNode: View {
    let anchor: MeetingTruthProcessingAnchor
    let isFocused: Bool
    let color: Color
    let triggerText: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Text("\(anchor.kind.sequence)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(color)
                        .clipShape(Circle())
                    Text(anchor.kind.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }

                Text(triggerText.isEmpty ? "处理来源待记录" : triggerText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    MeetingTruthTraceBadge(text: anchor.status.title, color: color)
                    if anchor.warningCount + anchor.errorCount > 0 {
                        MeetingTruthTraceBadge(text: "\(anchor.warningCount + anchor.errorCount) 条提示", color: .orange)
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(10)
            .frame(width: 215, height: 112, alignment: .topLeading)
            .background(isFocused ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.06))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isFocused ? Color.accentColor.opacity(0.70) : color.opacity(0.24), lineWidth: isFocused ? 2 : 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

private struct MeetingTruthFlowConnector: View {
    let color: Color

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(color.opacity(0.42))
                .frame(height: 2)
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.bold))
                .foregroundStyle(color.opacity(0.70))
                .frame(width: 12)
        }
        .frame(width: 34)
        .accessibilityHidden(true)
    }
}

private struct MeetingTruthFlowRowConnector: View {
    let fromTitle: String
    let toTitle: String

    var body: some View {
        HStack(spacing: 8) {
            Spacer()
            VStack(spacing: 3) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.22))
                    .frame(width: 2, height: 18)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                Text("\(fromTitle) → \(toTitle)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 220)
            Spacer()
        }
        .accessibilityHidden(true)
    }
}
