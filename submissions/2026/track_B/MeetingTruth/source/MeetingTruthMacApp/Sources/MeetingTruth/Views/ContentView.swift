import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: LabStore

    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            DetailRouterView()
        }
        .toolbar {
            ToolbarItemGroup {
                if store.selectedSection == .meetingTruthDetail {
                    Button {
                        store.resolveMeetingTruthConflictsWithGemma()
                    } label: {
                        Label(store.isResolvingMeetingTruthConflicts ? "校验中" : "运行 Gemma 4 校验", systemImage: "sparkles")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isResolvingMeetingTruthConflicts || store.meetingTruthConflicts.isEmpty)
                } else if store.selectedSection == .meetingTruth || store.selectedSection == .meetingTruthWorkflowCompare || store.selectedSection == .meetingTruthToolAB {
                    EmptyView()
                } else if store.selectedSection == .meetingTruthProcessingTrace {
                    EmptyView()
                } else {
                    Button {
                        store.downloadSelectedModel()
                    } label: {
                        Label("下载模型", systemImage: "arrow.down.circle")
                    }

                    if store.isRunning {
                        Button {
                            store.cancelCurrentTask()
                        } label: {
                            Label("停止任务", systemImage: "stop.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                    } else {
                        Button {
                            store.runComparison()
                        } label: {
                            Label("开始对比", systemImage: "play.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(store.selectedAudioPath.isEmpty)
                    }
                }
            }
        }
    }
}

struct DetailRouterView: View {
    @EnvironmentObject private var store: LabStore

    var body: some View {
        switch store.selectedSection {
        case .meetingTruth:
            MeetingTruthWorkspaceView()
        case .meetingTruthWorkflowCompare:
            MeetingTruthWorkflowCompareView()
        case .meetingTruthToolAB:
            MeetingTruthToolCallingABView()
        case .meetingTruthProcessingTrace:
            MeetingTruthProcessingTraceView()
        case .meetingTruthDetail:
            MeetingTruthView()
        case .lab:
            LabDashboardView()
        case .models:
            ModelLibraryView()
        case .hotwords:
            HotwordsView()
        case .results:
            ResultsView()
        case .settings:
            SettingsView()
        }
    }
}
