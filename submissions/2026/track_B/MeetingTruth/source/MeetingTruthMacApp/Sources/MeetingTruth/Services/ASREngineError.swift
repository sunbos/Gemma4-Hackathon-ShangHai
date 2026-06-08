import Foundation

enum ASREngineError: LocalizedError {
    case missingRuntimeModelName(String)
    case unsupportedRuntime(String)
    case adapterNotImplemented(String)

    var errorDescription: String? {
        switch self {
        case .missingRuntimeModelName(let modelName):
            return "\(modelName) 缺少 runtimeModelName，无法启动本机推理。"
        case .unsupportedRuntime(let runtime):
            return "当前提交包未接入 \(runtime) 推理。"
        case .adapterNotImplemented(let message):
            return message
        }
    }
}
