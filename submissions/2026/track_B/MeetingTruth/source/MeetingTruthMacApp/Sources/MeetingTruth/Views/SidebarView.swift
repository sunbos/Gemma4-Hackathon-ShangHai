import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var store: LabStore

    var body: some View {
        List(selection: $store.selectedSection) {
            Section("ASR") {
                Label("本地转写", systemImage: LabSection.lab.systemImage)
                    .tag(LabSection.lab)
                Label("模型管理", systemImage: LabSection.models.systemImage)
                    .tag(LabSection.models)
                Label("历史记录", systemImage: LabSection.results.systemImage)
                    .tag(LabSection.results)
                Label("设置", systemImage: LabSection.settings.systemImage)
                    .tag(LabSection.settings)
            }

            meetingTruthSection

            Section("已选模型") {
                ForEach(store.cleanASRModels.filter { store.selectedModelIDs.contains($0.id) }) { model in
                    SidebarModelRow(model: model)
                        .tag(LabSection.models)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 220, ideal: 260)
    }

    private var meetingTruthSection: some View {
        Section("MeetingTruth") {
            Label(LabSection.meetingTruth.title, systemImage: LabSection.meetingTruth.systemImage)
                .tag(LabSection.meetingTruth)
            Label(LabSection.meetingTruthWorkflowCompare.title, systemImage: LabSection.meetingTruthWorkflowCompare.systemImage)
                .tag(LabSection.meetingTruthWorkflowCompare)
            Label(LabSection.meetingTruthToolAB.title, systemImage: LabSection.meetingTruthToolAB.systemImage)
                .tag(LabSection.meetingTruthToolAB)
            Label(LabSection.meetingTruthProcessingTrace.title, systemImage: LabSection.meetingTruthProcessingTrace.systemImage)
                .tag(LabSection.meetingTruthProcessingTrace)
            Label(LabSection.meetingTruthDetail.title, systemImage: LabSection.meetingTruthDetail.systemImage)
                .tag(LabSection.meetingTruthDetail)
        }
    }
}

private struct SidebarModelRow: View {
    let model: ASRModelSpec

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: model.status == .ready ? "checkmark.circle" : "clock")
                .foregroundStyle(model.status == .ready ? .green : .secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.name)
                    .lineLimit(1)
                Text(model.runtime.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}
