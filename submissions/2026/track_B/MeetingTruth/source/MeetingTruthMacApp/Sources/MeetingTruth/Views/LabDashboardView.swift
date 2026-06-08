import SwiftUI

struct LabDashboardView: View {
    @EnvironmentObject private var store: LabStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HeaderView(
                    title: "本地转写",
                    subtitle: "选择音频，用三路预设 ASR 在本机生成候选转写。"
                )

                AudioPickerPanel()
                ActiveTaskPanel()
                ErrorPanel()
                PrimaryTranscriptPanel()

                HStack(alignment: .top, spacing: 16) {
                    ModelSelectionPanel()
                }

                ResultsPreviewPanel()
            }
            .padding(24)
        }
    }
}

private struct ErrorPanel: View {
    @EnvironmentObject private var store: LabStore

    var body: some View {
        if let error = store.lastError {
            Surface {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("需要处理")
                            .font(.headline)
                        Text(error)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button {
                        store.lastError = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }
}

private struct AudioPickerPanel: View {
    @EnvironmentObject private var store: LabStore

    var body: some View {
        Surface {
            HStack(spacing: 14) {
                Image(systemName: "waveform")
                    .font(.title2)
                    .foregroundStyle(.blue)
                    .frame(width: 34)

                VStack(alignment: .leading, spacing: 4) {
                    Text("测试音频")
                        .font(.headline)
                    Text(store.selectedAudioPath.isEmpty ? "选择一段真实中文会议音频，结果会更有判断价值。" : store.selectedAudioPath)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Button {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.audio, .mpeg4Audio, .wav, .aiff]
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK {
                        if let url = panel.url {
                            store.importAudioForTesting(from: url)
                        }
                    }
                } label: {
                    Label("选择音频", systemImage: "folder")
                }
            }
        }
    }
}

private struct ActiveTaskPanel: View {
    @EnvironmentObject private var store: LabStore

    var body: some View {
        Surface {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(store.activeTaskTitle, systemImage: "bolt.horizontal.circle")
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

                if !store.liveTranscript.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("实时转写片段")
                            .font(.subheadline.weight(.semibold))
                        Text(store.liveTranscript)
                            .lineLimit(4)
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
}

private struct ModelSelectionPanel: View {
    @EnvironmentObject private var store: LabStore

    var body: some View {
        Surface {
            VStack(alignment: .leading, spacing: 12) {
                Text("选择模型")
                    .font(.headline)

                ForEach(store.experimentModels) { model in
                    Toggle(isOn: Binding(
                        get: { store.selectedModelIDs.contains(model.id) },
                        set: { _ in store.toggleModel(model) }
                    )) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.name)
                                    .lineLimit(1)
                                Text(store.experimentAvailabilityReason(for: model))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer()
                            if !store.canSelectForExperiment(model) {
                                Button {
                                    store.prepareCleanASRModel(model)
                                } label: {
                                    Label(cleanPrepareTitle(for: model), systemImage: cleanPrepareIcon(for: model))
                                        .labelStyle(.titleAndIcon)
                                }
                                .buttonStyle(.bordered)
                                .disabled(model.status == .downloading)
                            }
                            Text(store.experimentAvailabilityTitle(for: model))
                                .font(.caption)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(availabilityColor(for: model).opacity(0.14))
                                .foregroundStyle(availabilityColor(for: model))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    .disabled(!store.canSelectForExperiment(model))
                    Divider()
                }

                Text("纯净版只展示三路预设 ASR；只有本机文件完整且推理 adapter 已接入的路线可以勾选运行。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func availabilityColor(for model: ASRModelSpec) -> Color {
        if store.canSelectForExperiment(model) { return .green }
        if model.status == .downloading { return .orange }
        if model.localPath == nil { return .secondary }
        if model.validationSummary?.contains("不完整") == true { return .orange }
        return .secondary
    }

    private func cleanPrepareTitle(for model: ASRModelSpec) -> String {
        if model.status == .downloading { return "准备中" }
        if model.localPath == nil { return "下载" }
        return "重新准备"
    }

    private func cleanPrepareIcon(for model: ASRModelSpec) -> String {
        model.status == .downloading ? "clock" : "arrow.down.circle"
    }
}

private struct ResultsPreviewPanel: View {
    @EnvironmentObject private var store: LabStore

    var body: some View {
        Surface {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("最近结果")
                        .font(.headline)
                    Spacer()
                    Button("查看历史") {
                        store.selectedSection = .results
                    }
                }

                if store.runs.isEmpty {
                    EmptyStateView(
                        systemImage: "chart.bar.doc.horizontal",
                        title: "还没有对比结果",
                        message: "选择音频和模型后开始对比，这里会显示 RTF、速度、错误率和文本预览。"
                    )
                } else {
                    ForEach(store.runs.prefix(3)) { run in
                        Button {
                            store.selectedSection = .results
                        } label: {
                            ResultRow(run: run)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

private struct PrimaryTranscriptPanel: View {
    @EnvironmentObject private var store: LabStore

    var body: some View {
        if let run = store.primaryTranscriptRun {
            Surface {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("转写结果")
                                .font(.headline)
                            Text(run.modelName)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            store.selectedSection = .results
                        } label: {
                            Label("查看详情", systemImage: "doc.text")
                        }
                    }

                    Text(run.cleanTranscriptPreview)
                        .textSelection(.enabled)
                        .lineSpacing(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(.quaternary.opacity(0.35))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }
}
