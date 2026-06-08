import AppKit
import SwiftUI

private func copyToClipboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

private func formatBytes(_ bytes: Int64) -> String {
    guard bytes > 0 else { return "--" }
    let units = ["B", "KB", "MB", "GB", "TB"]
    var value = Double(bytes)
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

struct ModelLibraryView: View {
    var body: some View {
        CleanModelPreparationView()
    }
}

private struct CleanModelPreparationView: View {
    @EnvironmentObject private var store: LabStore

    private var models: [ASRModelSpec] {
        store.cleanASRModels
    }

    private var readyCount: Int {
        models.filter(store.canSelectForExperiment).count
    }

    private var downloadingModel: ASRModelSpec? {
        models.first { $0.status == .downloading }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HeaderView(
                    title: "模型准备",
                    subtitle: "完整本地 ASR 转写需要先准备模型；如果只是体验 MeetingTruth 核验流程，可以直接回到会议整理加载示例数据。"
                )

                CleanModelReadinessHeader(
                    readyCount: readyCount,
                    totalCount: models.count,
                    downloadingModel: downloadingModel,
                    activeTaskTitle: store.activeTaskTitle,
                    activeTaskProgress: store.activeTaskProgress
                )

                if let lastError = store.lastError {
                    Surface {
                        HStack(alignment: .top, spacing: 10) {
                            Label(lastError, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Button {
                                copyToClipboard(lastError)
                            } label: {
                                Label("复制", systemImage: "doc.on.doc")
                            }
                        }
                    }
                }

                Surface {
                    Label("模型下载失败不会阻塞 MeetingTruth 示例演示。进入「会议整理」点击「加载示例」，仍可体验检查转写冲突、人工确认、多模态中枢复核、处理链路追踪和成果生成。", systemImage: "play.rectangle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 12) {
                    ForEach(models) { model in
                        CleanModelPreparationCard(model: model)
                    }
                }

                HStack {
                    Button {
                        store.rescanModelAssets()
                    } label: {
                        Label("重新检查本机模型", systemImage: "arrow.clockwise")
                    }
                    Spacer()
                    Text("模型文件会保存在本机应用支持目录中，转写时不需要重新下载。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)
        }
    }
}

private struct CleanModelReadinessHeader: View {
    @EnvironmentObject private var store: LabStore
    let readyCount: Int
    let totalCount: Int
    let downloadingModel: ASRModelSpec?
    let activeTaskTitle: String
    let activeTaskProgress: Double

    var body: some View {
        Surface {
            HStack(alignment: .center, spacing: 18) {
                Image(systemName: readyCount == totalCount ? "checkmark.seal.fill" : "square.and.arrow.down")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(readyCount == totalCount ? .green : .blue)
                    .frame(width: 40)

                VStack(alignment: .leading, spacing: 6) {
                    Text(readyCount == totalCount ? "三个模型都已准备好" : "已准备 \(readyCount)/\(totalCount)")
                        .font(.title3.weight(.semibold))
                    Text(headerNote)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let downloadingModel {
                        if activeTaskProgress <= 0.05 {
                            ProgressView()
                                .controlSize(.small)
                                .frame(maxWidth: 360, alignment: .leading)
                        } else {
                            ProgressView(value: activeTaskProgress)
                                .frame(maxWidth: 360)
                        }
                        Text("\(downloadingModel.name)：\(activeTaskTitle)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer()
                Button {
                    store.prepareAllCleanASRModels()
                } label: {
                    Label(readyCount == totalCount ? "重新检查" : "一键准备", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(downloadingModel != nil)
            }
        }
    }

    private var headerNote: String {
        if downloadingModel != nil {
            return "正在下载或配置模型，请保持网络和电脑唤醒；进度会在下方对应卡片里同步更新。"
        }
        if readyCount == totalCount {
            return "现在可以回到本地转写，直接选择录音开始。"
        }
        return "点击一键准备后会自动完成三路预设模型的下载、依赖安装和文件校验。"
    }
}

private struct CleanModelPreparationCard: View {
    @EnvironmentObject private var store: LabStore
    let model: ASRModelSpec

    private var isRunnable: Bool {
        store.canSelectForExperiment(model)
    }

    private var isDownloading: Bool {
        model.status == .downloading
    }

    private var hasIncompleteLocalFiles: Bool {
        model.localPath != nil && model.validationSummary?.contains("不完整") == true
    }

    private var preparationFailure: ModelPreparationFailure? {
        store.modelPreparationFailures[model.id]
    }

    var body: some View {
        Surface {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: leadingIcon)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(statusColor)
                        .frame(width: 34, height: 34)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text(model.name)
                                .font(.headline)
                                .lineLimit(2)
                            CleanStatusBadge(title: statusTitle, color: statusColor)
                        }
                        Text(userPurpose)
                            .font(.callout)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            CleanInfoChip(title: "大小", value: cleanSizeLabel)
                            CleanInfoChip(title: "方式", value: cleanRouteLabel)
                        }
                    }

                    Spacer(minLength: 12)

                    Button {
                        store.selectedModelID = model.id
                        store.downloadSelectedModel()
                    } label: {
                        Label(actionTitle, systemImage: actionIcon)
                            .frame(minWidth: 108)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isDownloading || (isRunnable && !hasIncompleteLocalFiles))
                }

                if isDownloading {
                    visibleDownloadProgress
                } else if let preparationFailure {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(preparationFailure.summary, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(preparationFailure.recoverySuggestions, id: \.self) { suggestion in
                                Label(suggestion, systemImage: "wrench.and.screwdriver")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                } else if model.status == .failed {
                    Label("上次准备失败。可以直接重试；如果仍失败，再展开技术详情查看原始日志。", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if hasIncompleteLocalFiles {
                    Label("本地文件不完整，建议重新准备这个模型。", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if isRunnable {
                    Label("已完成下载、依赖准备和文件校验。", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else if model.localPath != nil {
                    Label(store.experimentAvailabilityReason(for: model), systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                DisclosureGroup("技术详情") {
                    VStack(alignment: .leading, spacing: 8) {
                        CleanDetailLine(title: "模型引用", value: model.runtimeModelName ?? model.family)
                        CleanDetailLine(title: "运行方式", value: model.optimizationRoute)
                        CleanDetailLine(title: "本机支持", value: model.platformSupport)
                        if let localPath = model.localPath {
                            CleanDetailLine(title: "本地路径", value: localPath)
                        }
                        if let validation = model.validationSummary {
                            CleanDetailLine(title: "校验结果", value: validation)
                        }
                        if let preparationFailure {
                            CleanDetailLine(title: "失败摘要", value: preparationFailure.summary)
                            CleanDetailLine(title: "修复建议", value: preparationFailure.recoverySuggestions.joined(separator: "\n"))
                            CleanDetailLine(title: "开发者详情", value: preparationFailure.developerDetails)
                        }
                        HStack {
                            if model.runtime == .externalCLI {
                                Button {
                                    store.validateExternalModelConfiguration(for: model.id)
                                } label: {
                                    Label("重新校验", systemImage: "checkmark.shield")
                                }
                            }
                            Button {
                                copyToClipboard(modelDebugReport)
                            } label: {
                                Label("复制状态", systemImage: "doc.on.doc")
                            }
                        }
                        .font(.caption)
                    }
                    .padding(.top, 8)
                }
                .font(.caption)
            }
        }
    }

    private var visibleDownloadProgress: some View {
        VStack(alignment: .leading, spacing: 8) {
            if usesIndeterminateProgress {
                ProgressView()
                    .controlSize(.small)
            } else {
                ProgressView(value: model.progress)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                CleanInfoChip(title: "阶段", value: downloadStageTitle)
                CleanInfoChip(title: "已下载", value: formatBytes(model.downloadMetrics.downloadedBytes))
                CleanInfoChip(title: "总大小", value: formatBytes(model.downloadMetrics.totalBytes))
                CleanInfoChip(title: "速度", value: speedLabel)
                CleanInfoChip(title: "剩余", value: store.remainingTimeLabel)
            }
            Text(downloadProgressSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var userPurpose: String {
        switch model.id {
        case "qwen3-asr-1.7b-timestamps":
            return "负责带时间戳的转写，方便 MeetingTruth 回看原文位置。"
        case "glm-asr-nano-2512":
            return "中文大模型对照路线，用来补充不同模型的听写判断。"
        case "mimo-v2-5-asr-mlx":
            return "Apple Silicon 优先路线，适合正式会议长音频主转写。"
        default:
            return model.notes
        }
    }

    private var statusTitle: String {
        if isRunnable { return "已准备" }
        if isDownloading && store.currentStage.contains("验证") { return "校验中" }
        if isDownloading && (store.currentStage.contains("下载") || store.activeTaskTitle.contains("下载")) { return "下载中" }
        if isDownloading { return "准备中" }
        if model.status == .failed { return "失败" }
        if hasIncompleteLocalFiles { return "文件不完整" }
        if model.localPath != nil { return "需重试" }
        return "未准备"
    }

    private var statusColor: Color {
        if isRunnable { return .green }
        if isDownloading { return .orange }
        if model.status == .failed || hasIncompleteLocalFiles { return .red }
        if model.localPath != nil { return .orange }
        return .blue
    }

    private var leadingIcon: String {
        if isRunnable { return "checkmark.seal" }
        if isDownloading { return "clock.arrow.circlepath" }
        if model.status == .failed || hasIncompleteLocalFiles || model.localPath != nil { return "exclamationmark.triangle" }
        return "arrow.down.circle"
    }

    private var actionTitle: String {
        if isDownloading { return "准备中" }
        if model.status == .failed || hasIncompleteLocalFiles || model.localPath != nil { return "重试" }
        if isRunnable { return "已准备好" }
        return "下载准备"
    }

    private var actionIcon: String {
        if isDownloading { return "clock" }
        if isRunnable { return "checkmark.circle" }
        if model.status == .failed || hasIncompleteLocalFiles { return "arrow.clockwise" }
        return "arrow.down.circle"
    }

    private var cleanSizeLabel: String {
        model.localPath == nil ? model.installedSizeLabel : model.installedSizeLabel
    }

    private var cleanRouteLabel: String {
        switch model.id {
        case "qwen3-asr-1.7b-timestamps":
            return "时间戳"
        case "glm-asr-nano-2512":
            return "中文对照"
        case "mimo-v2-5-asr-mlx":
            return "主转写"
        default:
            return model.runtime.rawValue
        }
    }

    private var speedLabel: String {
        guard model.downloadMetrics.speedBytesPerSecond > 0 else { return "--" }
        return "\(formatBytes(Int64(model.downloadMetrics.speedBytesPerSecond)))/s"
    }

    private var usesIndeterminateProgress: Bool {
        model.downloadMetrics.downloadedBytes == 0 &&
            model.downloadMetrics.speedBytesPerSecond == 0 &&
            model.progress <= 0.05
    }

    private var downloadStageTitle: String {
        let stage = store.currentStage.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stage.isEmpty, stage != "准备下载" {
            return stage
        }
        if store.activeTaskTitle.contains("配置") {
            return "配置依赖"
        }
        if store.activeTaskTitle.contains("读取") {
            return "读取清单"
        }
        return "准备下载"
    }

    private var downloadProgressSummary: String {
        if usesIndeterminateProgress {
            return "\(store.activeTaskTitle)。这一步可能在安装依赖、连接下载源或读取模型文件清单，完成后会切换成字节进度。"
        }
        return store.activeTaskTitle
    }

    private var modelDebugReport: String {
        [
            "模型：\(model.name) (\(model.id))",
            "状态：\(statusTitle)",
            "运行时：\(model.runtime.rawValue)",
            "来源：\(model.sourceDescription ?? model.runtimeModelName ?? "未知")",
            "本地路径：\(model.localPath ?? "未识别")",
            "校验：\(model.validationSummary ?? "未校验")",
            "失败摘要：\(preparationFailure?.summary ?? "无")",
            "开发者详情：\(preparationFailure?.developerDetails ?? "无")"
        ].joined(separator: "\n")
    }
}

private struct CleanStatusBadge: View {
    let title: String
    let color: Color

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.14))
            .foregroundStyle(color)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct CleanInfoChip: View {
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .fontWeight(.medium)
                .lineLimit(1)
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct CleanDetailLine: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

