import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: LabStore

    var body: some View {
        Form {
            Section("模型缓存") {
                HStack {
                    TextField("模型目录", text: $store.modelCachePath)
                    Button {
                        store.applyModelCachePathFromSettings()
                    } label: {
                        Label("应用", systemImage: "checkmark.circle")
                    }
                }
                Text(store.resolvedModelCacheURL.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("模型默认按 runtime 分目录保存，便于离线迁移和版本回滚。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("默认转写参数") {
                Toggle("准确率优先", isOn: $store.preferAccuracy)
                Toggle("默认启用 VAD", isOn: $store.useVAD)
                Toggle("默认尝试说话人分离", isOn: $store.runDiarization)
            }

            Section("Gemma 4 可信整理") {
                Picker("配置预设", selection: meetingPresetBinding) {
                    Text("自定义").tag("custom")
                    ForEach(MeetingAIPreset.builtInPresets) { preset in
                        Text(preset.title).tag(preset.id)
                    }
                }
                TextField("Base URL", text: meetingBaseURLBinding)
                SecureField("API Key", text: meetingAPIKeyBinding)
                TextField("模型", text: meetingModelBinding)
                Toggle("转写完成后自动生成会议整理", isOn: autoGenerateBinding)
                VStack(alignment: .leading, spacing: 6) {
                    Text("默认整理偏好")
                        .font(.headline)
                    Text("用于控制纪要、摘要、要点和待办的组织方式。它只影响表达结构，不会覆盖人工确认、中枢复核和证据链结果。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(alignment: .top, spacing: 8) {
                        Text("议题归纳式")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.blue.opacity(0.12), in: Capsule())
                        VStack(alignment: .leading, spacing: 3) {
                            Text("按会议主题组织内容，每个主题下整理讨论要点、关键结论、依据和待办。不按转写顺序机械分段。")
                            Text("不编造未出现的信息；不覆盖人工确认；证据不足标记待确认。")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    TextField("自定义整理说明", text: defaultOrganizationInstructionsBinding, axis: .vertical)
                        .lineLimit(3...7)
                    Text("自定义说明只影响整理风格，不会改变事实核验结果。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(alignment: .top, spacing: 10) {
                    Label(settingsValidationSummary, systemImage: settingsValidationSystemImage)
                        .font(.caption)
                        .foregroundStyle(settingsValidationColor)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button {
                        store.validateMeetingAISettings()
                    } label: {
                        Label(store.isValidatingMeetingAI ? "校验中" : "测试连接/校验模型", systemImage: "network.badge.shield.half.filled")
                    }
                    .disabled(store.isValidatingMeetingAI)
                }

                if let lastValidatedAt = store.meetingAISettings.lastValidatedAt {
                    Text("上次校验：\(LabStore.historyDateFormatter.string(from: lastValidatedAt))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("生成长度与上下文")
                        .font(.headline)
                    Text("控制模型生成内容的长度、读取转写的范围和生成速度。会议越长，建议选择读取范围更大的方案。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("生成长度与上下文", selection: meetingTokenPlanBinding) {
                        ForEach(MeetingTokenPlan.allCases, id: \.self) { plan in
                            Text(plan.title).tag(plan)
                        }
                    }
                    Text(store.meetingAISettings.tokenPlan.userDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                DisclosureGroup("技术参数") {
                    Text("最大输出 \(store.meetingAISettings.resolvedMaxTokens) token；最多读取 \(store.meetingAISettings.resolvedInputCharacterLimit) 个转写字符；温度 \(store.meetingAISettings.resolvedTemperature, specifier: "%.2f")。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if store.meetingAISettings.tokenPlan == .custom {
                    Stepper("最大输出 Token：\(store.meetingAISettings.customMaxTokens)", value: customMaxTokensBinding, in: 600...131072, step: 1024)
                    Stepper("最大输入字符：\(store.meetingAISettings.customInputCharacterLimit)", value: customInputCharacterLimitBinding, in: 4000...131072, step: 4096)
                    HStack {
                        Text("温度")
                        Slider(value: customTemperatureBinding, in: 0...1)
                        Text(store.meetingAISettings.customTemperature, format: .number.precision(.fractionLength(2)))
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                    Text("高保真参数可按正式纪要需要微调；读取更多上下文通常更完整，也会更慢。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text("可先选择预设，再按需手工修改 Base URL、API Key 和模型。只要字段被手工改动且不再匹配预设，预设会自动显示为“自定义”。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("正式演示推荐使用 Gemma 4 12B；Gemma 4 E4B 保留为轻量测试和低配机器备用。模型字段可填写任意 OpenAI-compatible endpoint 支持的名称。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("本机 LM Studio / Ollama / OpenAI-compatible 服务通常不用 API Key；远程云端服务才需要填写。请求默认不发送思考模式参数，避免端点因 thinking 字段不兼容而失败。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var settingsValidationSummary: String {
        store.meetingAISettings.validationDisplaySummary
    }

    private var settingsValidationSystemImage: String {
        if store.meetingAISettings.validationPassed { return "checkmark.seal" }
        if store.meetingAISettings.isMissingRequiredAPIKey { return "key.slash" }
        return "info.circle"
    }

    private var settingsValidationColor: Color {
        if store.meetingAISettings.validationPassed { return .green }
        if store.meetingAISettings.isMissingRequiredAPIKey { return .orange }
        return .secondary
    }

    private var meetingBaseURLBinding: Binding<String> {
        Binding(
            get: { store.meetingAISettings.baseURL },
            set: { baseURL in
                updateMeetingSettings { settings in
                    settings.baseURL = baseURL
                }
            }
        )
    }

    private var meetingAPIKeyBinding: Binding<String> {
        Binding(
            get: { store.meetingAISettings.apiKey },
            set: { apiKey in
                updateMeetingSettings { settings in
                    settings.apiKey = apiKey
                }
            }
        )
    }

    private var meetingModelBinding: Binding<String> {
        Binding(
            get: { store.meetingAISettings.model },
            set: { model in
                updateMeetingSettings { settings in
                    settings.model = model
                }
            }
        )
    }

    private var meetingPresetBinding: Binding<String> {
        Binding(
            get: { store.meetingAISettings.matchingPresetID ?? "custom" },
            set: { selectedID in
                guard selectedID != "custom",
                      let preset = MeetingAIPreset.builtInPresets.first(where: { $0.id == selectedID }) else { return }
                store.applyMeetingAIPreset(preset)
            }
        )
    }

    private var meetingTokenPlanBinding: Binding<MeetingTokenPlan> {
        Binding(
            get: { store.meetingAISettings.tokenPlan },
            set: { plan in
                updateMeetingSettings(resetValidation: false) { settings in
                    settings.tokenPlan = plan
                }
            }
        )
    }

    private var autoGenerateBinding: Binding<Bool> {
        Binding(
            get: { store.meetingAISettings.autoGenerateAfterTranscription },
            set: { enabled in
                updateMeetingSettings(resetValidation: false) { settings in
                    settings.autoGenerateAfterTranscription = enabled
                }
            }
        )
    }

    private var defaultOrganizationInstructionsBinding: Binding<String> {
        Binding(
            get: { store.meetingAISettings.defaultOrganizationInstructions },
            set: { instructions in
                updateMeetingSettings(resetValidation: false) { settings in
                    settings.defaultOrganizationInstructions = instructions
                }
            }
        )
    }

    private var customMaxTokensBinding: Binding<Int> {
        Binding(
            get: { store.meetingAISettings.customMaxTokens },
            set: { tokens in
                updateMeetingSettings(resetValidation: false) { settings in
                    settings.customMaxTokens = tokens
                }
            }
        )
    }

    private var customTemperatureBinding: Binding<Double> {
        Binding(
            get: { store.meetingAISettings.customTemperature },
            set: { temperature in
                updateMeetingSettings(resetValidation: false) { settings in
                    settings.customTemperature = temperature
                }
            }
        )
    }

    private var customInputCharacterLimitBinding: Binding<Int> {
        Binding(
            get: { store.meetingAISettings.customInputCharacterLimit },
            set: { limit in
                updateMeetingSettings(resetValidation: false) { settings in
                    settings.customInputCharacterLimit = limit
                }
            }
        )
    }

    private func updateMeetingSettings(resetValidation: Bool = true, _ update: (inout MeetingAISettings) -> Void) {
        var settings = store.meetingAISettings
        update(&settings)
        if resetValidation {
            settings.validationPassed = false
            settings.validationSummary = settings.isMissingRequiredAPIKey
                ? "远程端点通常需要 API Key；本机 localhost 端点可以留空。"
                : "配置已修改；需要确认服务可用时再测试连接。"
            settings.lastValidatedAt = nil
        }
        store.meetingAISettings = settings
    }
}
