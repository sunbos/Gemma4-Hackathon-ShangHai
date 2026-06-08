import AppKit
import SwiftUI

private func copyComponentText(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

struct HeaderView: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.largeTitle.weight(.semibold))
            Text(subtitle)
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct Surface<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.separator.opacity(0.35), lineWidth: 1)
            }
    }
}

struct StatusBadge: View {
    let status: ModelStatus

    var body: some View {
        Text(status.title)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.16))
            .foregroundStyle(color)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var color: Color {
        switch status {
        case .ready: .green
        case .downloadable: .blue
        case .downloading: .orange
        case .queued: .purple
        case .planned: .secondary
        case .failed: .red
        }
    }
}

struct CapabilityBadge: View {
    let title: String
    let color: Color

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.16))
            .foregroundStyle(color)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

struct MetricPill: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

struct ResultRow: View {
    let run: ComparisonRun

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(run.modelName)
                        .font(.headline)
                    Text(run.runtime)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(run.status)
                    .frame(width: 110, alignment: .leading)
                    .foregroundStyle(run.status == "完成" ? .green : .secondary)

                Label(run.reviewerVerdict.title, systemImage: run.reviewerVerdict.systemImage)
                    .labelStyle(.titleOnly)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(verdictColor)
                    .frame(width: 90, alignment: .leading)

                Text(deviceLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(deviceColor)
                    .frame(width: 74, alignment: .leading)

                Text(run.reviewerScore.map(String.init) ?? "-")
                    .monospacedDigit()
                    .foregroundStyle(run.reviewerScore == nil ? .tertiary : .primary)
                    .frame(width: 56, alignment: .trailing)

                metric(run.rtf, suffix: "")
                    .frame(width: 80, alignment: .trailing)
                metric(run.speed, suffix: "x")
                    .frame(width: 90, alignment: .trailing)
            }

            if !run.cleanTranscriptPreview.isEmpty {
                Text(run.cleanTranscriptPreview)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if let warning = run.automaticQualityWarning {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                    Spacer()
                }
            }

            if let errorMessage = run.errorMessage {
                HStack(alignment: .top, spacing: 8) {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                    Spacer()
                    Button {
                        copyComponentText(resultDebugReport(errorMessage: errorMessage))
                    } label: {
                        Label("复制错误", systemImage: "exclamationmark.doc")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .help("复制错误")
                }
            }

            if let duration = run.duration, let transcribeTime = run.transcribeTime {
                Text("音频 \(duration, specifier: "%.1f")s · 转写 \(transcribeTime, specifier: "%.2f")s\(segmentSummary)\(run.equivalenceGroup.map { " · \($0)" } ?? "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 10)
    }

    private func metric(_ value: Double?, suffix: String) -> some View {
        Group {
            if let value {
                Text("\(value, specifier: "%.3f")\(suffix)")
                    .monospacedDigit()
            } else {
                Text("-")
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func resultDebugReport(errorMessage: String) -> String {
        [
            "模型：\(run.modelName) (\(run.modelID))",
            "状态：\(run.status)",
            "运行时：\(run.runtime)",
            "错误：\(errorMessage)"
        ].joined(separator: "\n")
    }

    private var verdictColor: Color {
        switch run.reviewerVerdict {
        case .best: .yellow
        case .sameGood: .blue
        case .acceptable: .green
        case .flawed: .orange
        case .missed: .red
        case .unrated: .secondary
        }
    }

    private var deviceLabel: String {
        if let device = run.acceleratorDevice, !device.isEmpty {
            return device.uppercased()
        }
        if run.runtime.contains("sherpa") { return "ONNX" }
        return "-"
    }

    private var deviceColor: Color {
        if run.acceleratorFallbackReason != nil { return .orange }
        switch run.acceleratorDevice?.lowercased() {
        case "mps": return .green
        case "cpu": return .blue
        default: return .secondary
        }
    }

    private var segmentSummary: String {
        guard let segmentCount = run.segmentCount else { return "" }
        if let cached = run.cachedSegmentCount, cached > 0 {
            return " · 片段 \(segmentCount) · 缓存 \(cached)"
        }
        return " · 片段 \(segmentCount)"
    }
}

struct EmptyStateView: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
    }
}
