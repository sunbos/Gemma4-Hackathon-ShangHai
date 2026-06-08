import Foundation

enum ModelRegistry {
    static let initialModels: [ASRModelSpec] = [
        ASRModelSpec(
            id: "qwen3-asr-1.7b-timestamps",
            name: "Qwen3-ASR 1.7B · 官方权重 · 时间戳",
            family: "Qwen",
            runtime: .externalCLI,
            runtimeModelName: "Qwen/Qwen3-ASR-1.7B",
            downloadURL: nil,
            sizeLabel: "1.7B + aligner",
            languageFocus: "多语言/中文方言/时间戳",
            hotwordSupport: .planned,
            defaultForChineseMeetings: false,
            notes: "官方 Hugging Face 1.7B 权重，启用 Qwen forced aligner 输出时间戳；用于 MeetingTruth/Gemma 的可追溯定位锚点。",
            status: .downloadable,
            progress: 0,
            localPath: nil
        ),
        ASRModelSpec(
            id: "glm-asr-nano-2512",
            name: "GLM-ASR-Nano-2512",
            family: "Z.ai",
            runtime: .externalCLI,
            runtimeModelName: "zai-org/GLM-ASR-Nano-2512",
            downloadURL: nil,
            sizeLabel: "1.5B",
            languageFocus: "普通话/粤语/低音量/复杂场景",
            hotwordSupport: .planned,
            defaultForChineseMeetings: true,
            notes: "Transformers 路线，作为中文高精度候选和 MeetingTruth 辅助参考转写。",
            status: .downloadable,
            progress: 0,
            localPath: nil
        ),
        ASRModelSpec(
            id: "mimo-v2-5-asr-mlx",
            name: "MiMo-V2.5-ASR MLX 4-bit",
            family: "Xiaomi MiMo",
            runtime: .externalCLI,
            runtimeModelName: "mlx-community/MiMo-V2.5-ASR-MLX",
            downloadURL: nil,
            sizeLabel: "8B 4-bit",
            languageFocus: "中文方言/中英混说/多人/噪声",
            hotwordSupport: .planned,
            defaultForChineseMeetings: true,
            notes: "Apple Silicon MLX 4-bit 路线，作为 MeetingTruth 中文会议主底稿候选。",
            status: .downloadable,
            progress: 0,
            localPath: nil
        )
    ]
}
