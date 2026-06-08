import AVFoundation
import Foundation

protocol ASRRuntimeAdapter: Sendable {
    var runtime: RuntimeKind { get }

    func transcribe(
        audioPath: String,
        model: ASRModelSpec,
        cacheDirectory: URL,
        hotwords: [String],
        useVAD: Bool,
        preferAccuracy: Bool,
        terminologyPostProcessing: Bool,
        longAudioCacheEnabled: Bool,
        longAudioChunkSeconds: Int,
        acceleratorDevice: String?,
        progress: @escaping @Sendable (ASRProgressUpdate) -> Void
    ) async throws -> ASRTranscriptionResult
}

struct HuggingFaceASRAdapter: ASRRuntimeAdapter {
    let runtime: RuntimeKind = .externalCLI

    func transcribe(
        audioPath: String,
        model: ASRModelSpec,
        cacheDirectory: URL,
        hotwords: [String],
        useVAD: Bool,
        preferAccuracy: Bool,
        terminologyPostProcessing: Bool,
        longAudioCacheEnabled: Bool,
        longAudioChunkSeconds: Int,
        acceleratorDevice: String?,
        progress: @escaping @Sendable (ASRProgressUpdate) -> Void
    ) async throws -> ASRTranscriptionResult {
        guard let modelID = model.runtimeModelName else {
            throw ASREngineError.missingRuntimeModelName(model.name)
        }
        let modelReference = model.localPath ?? modelID

        let start = ContinuousClock.now
        progress(ASRProgressUpdate(stage: "启动 HuggingFace", fraction: 0.05, elapsed: 0, estimatedRemaining: nil, partialText: ""))

        let script = try resolveHFScriptPath()
        if model.id.hasPrefix("mimo-v2-5-asr-mlx") {
            return try await runMiMoMLX(
                audioPath: audioPath,
                modelRoot: modelReference,
                cacheDirectory: cacheDirectory,
                longAudioCacheEnabled: longAudioCacheEnabled,
                longAudioChunkSeconds: longAudioChunkSeconds,
                progress: progress,
                start: start
            )
        }
        if model.id.contains("qwen3-asr") {
            if modelReference.lowercased().contains("gguf") || model.id.contains("mlx") {
                throw cleanUnsupportedRuntimeError()
            }
            return try await runQwenASR(
                audioPath: audioPath,
                modelID: modelReference,
                cacheDirectory: cacheDirectory,
                hotwords: hotwords,
                terminologyPostProcessing: terminologyPostProcessing,
                longAudioCacheEnabled: longAudioCacheEnabled,
                longAudioChunkSeconds: longAudioChunkSeconds,
                returnTimestamps: model.id.contains("timestamps"),
                progress: progress,
                start: start
            )
        }
        if isCleanUnsupportedRuntime(model) {
            throw cleanUnsupportedRuntimeError()
        }

        let kind = model.id.contains("glm") ? "glm" : model.id.contains("mimo") ? "mimo" : "auto"
        try await ensureExternalRuntime(
            runtime: "hf-asr",
            setupScriptName: "setup_hf_asr_runtime.sh",
            probeCode: """
            import transformers, torch, soundfile
            from transformers import GlmAsrForConditionalGeneration
            """,
            label: "HuggingFace/PyTorch",
            progress: progress
        )
        let process = Process()
        process.executableURL = RuntimePaths.pythonExecutable(preferredRuntime: "hf-asr")
        process.arguments = [
            script.path,
            "--model-kind", kind,
            "--model-id", modelReference,
            "--audio", audioPath,
            "--hotwords-json", jsonArrayString(hotwords),
            "--chunk-seconds", "\(optimizedHFChunkSeconds(for: model.id, requested: longAudioChunkSeconds, audioPath: audioPath))",
            "--overlap-seconds", "1.5"
        ]
        if model.id.contains("glm") {
            process.arguments?.append("--max-new-tokens")
            process.arguments?.append("\(optimizedGLMMaxNewTokens(requestedChunkSeconds: longAudioChunkSeconds, audioPath: audioPath))")
        }
        if longAudioCacheEnabled {
            process.arguments?.append("--cache-dir")
            process.arguments?.append(cacheDirectory.appending(path: "Runs", directoryHint: .isDirectory).path)
        }
        if terminologyPostProcessing {
            process.arguments?.append("--enable-corrections")
        }
        process.environment = externalEnvironment(cacheDirectory: cacheDirectory, runtime: "hf-asr")

        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error

        let stdoutCollector = OutputPipeCollector()
        let stderrCollector = ProgressPipeCollector(progress: progress)
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            stdoutCollector.append(data)
        }
        error.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            stderrCollector.append(data)
        }

        try process.run()
        progress(ASRProgressUpdate(stage: "加载大模型/转写", fraction: 0.25, elapsed: seconds(since: start), estimatedRemaining: nil, partialText: ""))
        process.waitUntilExit()
        output.fileHandleForReading.readabilityHandler = nil
        error.fileHandleForReading.readabilityHandler = nil
        stdoutCollector.finish(with: output.fileHandleForReading.readDataToEndOfFile())
        stderrCollector.finish()

        let stdout = stdoutCollector.text
        let stderr = stderrCollector.text + (String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")

        guard process.terminationStatus == 0 else {
            if stderr.contains("No module named") || stderr.contains("缺少 HuggingFace") {
                throw ASREngineError.adapterNotImplemented("缺少 HuggingFace/PyTorch 推理引擎。请运行：./script/setup_hf_asr_runtime.sh")
            }
            throw ASREngineError.adapterNotImplemented(stderr.isEmpty ? "\(model.name) 推理失败。" : stderr)
        }

        let decoded = try decodeJSONOutput(HFOutput.self, from: stdout, context: model.name)
        let elapsed = seconds(since: start)
        let rtf = decoded.duration > 0 ? elapsed / decoded.duration : 0
        let speed = elapsed > 0 ? decoded.duration / elapsed : 0
        progress(ASRProgressUpdate(stage: "完成", fraction: 1, elapsed: elapsed, estimatedRemaining: 0, partialText: decoded.text))

        return ASRTranscriptionResult(
            text: decoded.text,
            metrics: ASRTranscriptionMetrics(
                duration: decoded.duration,
                transcribeTime: elapsed,
                rtf: rtf,
                speed: speed,
                acceleratorDevice: decoded.device,
                acceleratorFallbackReason: decoded.mpsFallbackReason
            )
        )
    }

    private func resolveHFScriptPath() throws -> URL {
        if let url = RuntimePaths.projectFile("Scripts/asr/hf_asr_transcribe.py") {
            return url
        }

        throw ASREngineError.adapterNotImplemented("找不到 hf_asr_transcribe.py 推理脚本。")
    }

    private func jsonArrayString(_ values: [String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: values, options: []),
              let string = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return string
    }

    fileprivate static func progressUpdate(from line: String) -> ASRProgressUpdate? {
        let prefix = "LOCAL_ASR_PROGRESS "
        guard line.hasPrefix(prefix),
              let data = String(line.dropFirst(prefix.count)).data(using: .utf8),
              let event = try? JSONDecoder().decode(ProgressEvent.self, from: data) else {
            return nil
        }
        return ASRProgressUpdate(
            stage: event.stage,
            fraction: event.fraction,
            elapsed: event.elapsed,
            estimatedRemaining: event.estimatedRemaining,
            partialText: event.partialText,
            segmentIndex: event.segmentIndex,
            segmentCount: event.totalSegments,
            cachedSegmentCount: event.cachedSegments,
            segmentStart: event.segmentStart,
            segmentEnd: event.segmentEnd
        )
    }

    private func isCleanUnsupportedRuntime(_ model: ASRModelSpec) -> Bool {
        model.id.contains("funasr")
            || model.id == "dolphin"
            || model.id == "omnilingual-asr"
            || model.id.hasPrefix("vibevoice-asr")
            || model.id == "canary-qwen-2-5b"
            || model.id == "mimo-v2-5-asr"
            || model.id.contains("mimo-v2-5-asr-gguf")
    }

    private func cleanUnsupportedRuntimeError() -> ASREngineError {
        ASREngineError.adapterNotImplemented("当前 clean 版未包含该 ASR runtime。请使用三路推荐 ASR，或导入候选转写体验 MeetingTruth。")
    }

    private func audioDurationSeconds(_ audioPath: String) -> Double {
        let asset = AVURLAsset(url: URL(fileURLWithPath: audioPath))
        let seconds = CMTimeGetSeconds(asset.duration)
        return seconds.isFinite && seconds > 0 ? seconds : 120
    }

    private func ensureExternalRuntime(
        runtime: String,
        setupScriptName: String,
        probeCode: String,
        label: String,
        progress: @escaping @Sendable (ASRProgressUpdate) -> Void
    ) async throws {
        if externalRuntimeProbe(runtime: runtime, code: probeCode) {
            return
        }
        guard let setupScript = RuntimePaths.projectFile("script/\(setupScriptName)") else {
            throw ASREngineError.adapterNotImplemented("缺少 \(label) 推理依赖安装脚本：script/\(setupScriptName)")
        }

        progress(ASRProgressUpdate(stage: "配置 \(label) 推理依赖", fraction: 0.03, elapsed: 0, estimatedRemaining: nil, partialText: ""))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [setupScript.path]
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()

        if externalRuntimeProbe(runtime: runtime, code: probeCode) {
            return
        }

        let stdout = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let details = (stderr.isEmpty ? stdout : stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        throw ASREngineError.adapterNotImplemented(details.isEmpty ? "\(label) 推理依赖未就绪，请重新准备模型。" : details)
    }

    private func externalRuntimeProbe(runtime: String, code: String) -> Bool {
        let process = Process()
        process.executableURL = RuntimePaths.pythonExecutable(preferredRuntime: runtime)
        process.arguments = ["-c", code]
        process.environment = externalEnvironment(cacheDirectory: RuntimePaths.workspaceRoot, runtime: runtime)
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func runQwenASR(
        audioPath: String,
        modelID: String,
        cacheDirectory: URL,
        hotwords: [String],
        terminologyPostProcessing: Bool,
        longAudioCacheEnabled: Bool,
        longAudioChunkSeconds: Int,
        returnTimestamps: Bool,
        progress: @escaping @Sendable (ASRProgressUpdate) -> Void,
        start: ContinuousClock.Instant
    ) async throws -> ASRTranscriptionResult {
        let script = try resolveHFScriptPath()
        try await ensureExternalRuntime(
            runtime: "qwen-asr",
            setupScriptName: "setup_qwen_asr_runtime.sh",
            probeCode: "import qwen_asr, torch, soundfile",
            label: "Qwen3-ASR",
            progress: progress
        )
        let process = Process()
        process.executableURL = RuntimePaths.pythonExecutable(preferredRuntime: "qwen-asr")
        process.arguments = [
            script.path,
            "--model-kind", "qwen",
            "--model-id", modelID,
            "--audio", audioPath,
            "--hotwords-json", jsonArrayString(hotwords),
            "--chunk-seconds", "\(max(longAudioChunkSeconds, 5))",
            "--overlap-seconds", "1.5"
        ]
        if returnTimestamps {
            process.arguments?.append("--return-timestamps")
            if let forcedAlignerPath = localForcedAlignerPath(for: modelID) {
                process.arguments?.append("--forced-aligner")
                process.arguments?.append(forcedAlignerPath)
            }
        }
        if longAudioCacheEnabled {
            process.arguments?.append("--cache-dir")
            process.arguments?.append(cacheDirectory.appending(path: "Runs", directoryHint: .isDirectory).path)
        }
        if terminologyPostProcessing {
            process.arguments?.append("--enable-corrections")
        }
        process.environment = externalEnvironment(cacheDirectory: cacheDirectory, runtime: "qwen-asr")

        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error

        let stdoutCollector = OutputPipeCollector()
        let stderrCollector = ProgressPipeCollector(progress: progress)
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            stdoutCollector.append(data)
        }
        error.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            stderrCollector.append(data)
        }

        progress(ASRProgressUpdate(stage: "启动 Qwen3-ASR", fraction: 0.05, elapsed: 0, estimatedRemaining: nil, partialText: ""))
        try process.run()
        progress(ASRProgressUpdate(stage: "加载 Qwen3-ASR/转写", fraction: 0.25, elapsed: seconds(since: start), estimatedRemaining: nil, partialText: ""))
        process.waitUntilExit()
        output.fileHandleForReading.readabilityHandler = nil
        error.fileHandleForReading.readabilityHandler = nil
        stdoutCollector.finish(with: output.fileHandleForReading.readDataToEndOfFile())
        stderrCollector.finish()

        let stdout = stdoutCollector.text
        let stderr = stderrCollector.text + (String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")

        guard process.terminationStatus == 0 else {
            if stderr.contains("No module named") {
                throw ASREngineError.adapterNotImplemented("缺少 Qwen3-ASR 推理引擎。请运行：./script/setup_qwen_asr_runtime.sh")
            }
            throw ASREngineError.adapterNotImplemented(stderr.isEmpty ? "Qwen3-ASR 推理失败。" : stderr)
        }

        let decoded = try decodeJSONOutput(HFOutput.self, from: stdout, context: "Qwen3-ASR")
        let elapsed = seconds(since: start)
        let rtf = decoded.duration > 0 ? elapsed / decoded.duration : 0
        let speed = elapsed > 0 ? decoded.duration / elapsed : 0
        progress(ASRProgressUpdate(stage: "完成", fraction: 1, elapsed: elapsed, estimatedRemaining: 0, partialText: decoded.text))

        return ASRTranscriptionResult(
            text: decoded.text,
            metrics: ASRTranscriptionMetrics(duration: decoded.duration, transcribeTime: elapsed, rtf: rtf, speed: speed)
        )
    }

    private func localForcedAlignerPath(for modelReference: String) -> String? {
        let url = URL(fileURLWithPath: modelReference)
            .appending(path: "Qwen3-ForcedAligner-0.6B", directoryHint: .isDirectory)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        return url.path
    }

    private func runMiMoMLX(
        audioPath: String,
        modelRoot: String,
        cacheDirectory: URL,
        longAudioCacheEnabled: Bool,
        longAudioChunkSeconds: Int,
        progress: @escaping @Sendable (ASRProgressUpdate) -> Void,
        start: ContinuousClock.Instant
    ) async throws -> ASRTranscriptionResult {
        guard let script = RuntimePaths.projectFile("Scripts/asr/mimo_mlx_transcribe.py") else {
            throw ASREngineError.adapterNotImplemented("找不到 mimo_mlx_transcribe.py 推理脚本。")
        }
        try await ensureExternalRuntime(
            runtime: "mimo-mlx",
            setupScriptName: "setup_mimo_mlx_runtime.sh",
            probeCode: """
            from importlib.metadata import version
            import json
            import mlx.core
            import mlx_audio
            from mlx_audio.stt import load
            import mlx_audio.stt.models.qwen2_audio
            import soundfile
            assert version("mlx-audio") == "0.4.3"
            assert version("transformers") == "5.8.1"
            from importlib.metadata import distribution
            dist = distribution("mlx-audio")
            direct_url = next((dist.locate_file(file) for file in (dist.files or []) if str(file).endswith("direct_url.json")), None)
            assert direct_url is not None and direct_url.exists()
            payload = json.loads(direct_url.read_text(encoding="utf-8"))
            assert payload.get("vcs_info", {}).get("commit_id") == "6241c57d61663725bb8a0ca1e1695c89ab6c09c0"
            """,
            label: "MiMo MLX",
            progress: progress
        )

        let process = Process()
        process.executableURL = RuntimePaths.pythonExecutable(preferredRuntime: "mimo-mlx")
        process.arguments = [
            script.path,
            "--model-path", modelRoot,
            "--audio", audioPath,
            "--language", "zh",
            "--chunk-seconds", "\(optimizedMiMoChunkSeconds(requested: longAudioChunkSeconds, audioPath: audioPath, prefersLongChunks: false))",
            "--overlap-seconds", "3.0",
            "--max-new-tokens", "\(optimizedMiMoMaxNewTokens(audioPath: audioPath, requestedChunkSeconds: longAudioChunkSeconds))"
        ]
        if longAudioCacheEnabled {
            process.arguments?.append("--cache-dir")
            process.arguments?.append(cacheDirectory.appending(path: "Runs", directoryHint: .isDirectory).path)
        }
        process.environment = externalEnvironment(cacheDirectory: cacheDirectory, runtime: "mimo-mlx")

        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        let stdoutCollector = OutputPipeCollector()
        let stderrCollector = ProgressPipeCollector(progress: progress)
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            stdoutCollector.append(data)
        }
        error.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            stderrCollector.append(data)
        }

        progress(ASRProgressUpdate(stage: "启动 MiMo MLX adapter", fraction: 0.05, elapsed: 0, estimatedRemaining: nil, partialText: ""))
        try process.run()
        progress(ASRProgressUpdate(stage: "加载 MiMo MLX", fraction: 0.2, elapsed: seconds(since: start), estimatedRemaining: nil, partialText: ""))
        process.waitUntilExit()
        output.fileHandleForReading.readabilityHandler = nil
        error.fileHandleForReading.readabilityHandler = nil
        stdoutCollector.finish(with: output.fileHandleForReading.readDataToEndOfFile())
        stderrCollector.finish()

        let stdout = stdoutCollector.text
        let stderr = stderrCollector.text + (String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")

        guard process.terminationStatus == 0 else {
            if stderr.contains("No module named") || stderr.contains("缺少 MiMo MLX") {
                throw ASREngineError.adapterNotImplemented("缺少 MiMo MLX 推理引擎。请运行：./script/setup_mimo_mlx_runtime.sh")
            }
            throw ASREngineError.adapterNotImplemented(userReadableMiMoMLXFailure(stderr))
        }

        guard let decoded = try? decodeJSONOutput(HFOutput.self, from: stdout, context: "MiMo MLX") else {
            throw ASREngineError.adapterNotImplemented("MiMo MLX 输出无法解析：\(stdout)")
        }

        let elapsed = seconds(since: start)
        let rtf = decoded.duration > 0 ? elapsed / decoded.duration : 0
        let speed = elapsed > 0 ? decoded.duration / elapsed : 0
        progress(ASRProgressUpdate(stage: "完成", fraction: 1, elapsed: elapsed, estimatedRemaining: 0, partialText: decoded.text))

        return ASRTranscriptionResult(
            text: decoded.text,
            metrics: ASRTranscriptionMetrics(
                duration: decoded.duration,
                transcribeTime: elapsed,
                rtf: rtf,
                speed: speed,
                acceleratorDevice: decoded.device,
                acceleratorFallbackReason: decoded.mpsFallbackReason
            )
        )
    }

    private func optimizedMiMoChunkSeconds(requested: Int, audioPath: String, prefersLongChunks: Bool) -> Int {
        let duration = audioDurationSeconds(audioPath)
        let maximum = prefersLongChunks ? 45 : 30
        let requested = min(max(requested, 15), maximum)
        guard duration.isFinite, duration > 0 else {
            return requested
        }

        if duration <= Double(requested) + 5 {
            return min(max(requested, Int(ceil(duration + 5))), maximum)
        }
        return requested
    }

    private func optimizedMiMoMaxNewTokens(audioPath: String, requestedChunkSeconds: Int) -> String {
        let chunkSeconds = optimizedMiMoChunkSeconds(requested: requestedChunkSeconds, audioPath: audioPath, prefersLongChunks: false)
        let estimated = max(96, min(384, chunkSeconds * 12))
        return "\(estimated)"
    }

    private func userReadableMiMoMLXFailure(_ stderr: String) -> String {
        let details = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if details.contains("Qwen2Tokenizer has no attribute tokenizer") ||
            details.contains("chat_template is not set") {
            return "MiMo MLX 推理环境版本不匹配。新版已加入兼容补丁，请重新打开应用后重试。"
        }
        if details.contains("Model type qwen2 not supported") {
            return "MiMo MLX 推理环境缺少 qwen2 兼容入口。请在模型管理中重新检查，或重新打开应用后重试。"
        }
        if details.contains("Traceback") {
            let lastLine = details
                .split(separator: "\n")
                .last
                .map(String.init) ?? "Python 推理返回异常。"
            return "MiMo MLX 推理失败：\(lastLine)"
        }
        return details.isEmpty ? "MiMo MLX 推理失败。" : details
    }

    private func optimizedHFChunkSeconds(for modelID: String, requested: Int, audioPath: String) -> Int {
        if modelID.contains("glm") {
            return optimizedGLMChunkSeconds(requested: requested, audioPath: audioPath)
        }
        return max(requested, 5)
    }

    private func optimizedGLMChunkSeconds(requested: Int, audioPath: String) -> Int {
        let duration = audioDurationSeconds(audioPath)
        let maximum = 30
        let requested = min(max(requested, 15), maximum)
        guard duration.isFinite, duration > 0 else {
            return requested
        }
        if duration <= Double(requested) + 5 {
            return min(max(requested, Int(ceil(duration + 5))), maximum)
        }
        return requested
    }

    private func optimizedGLMMaxNewTokens(requestedChunkSeconds: Int, audioPath: String) -> Int {
        let chunkSeconds = optimizedGLMChunkSeconds(requested: requestedChunkSeconds, audioPath: audioPath)
        return max(256, min(500, chunkSeconds * 16))
    }

    private func seconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = start.duration(to: ContinuousClock.now)
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    private func externalEnvironment(cacheDirectory: URL, runtime: String) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["HF_HOME"] = cacheDirectory
            .appending(path: runtime, directoryHint: .isDirectory)
            .appending(path: ".hf-cache", directoryHint: .isDirectory)
            .path
        environment["HF_HUB_ENABLE_HF_TRANSFER"] = "0"
        environment["HF_HUB_DISABLE_XET"] = "1"
        environment["HF_HUB_DOWNLOAD_TIMEOUT"] = "30"
        let existingPath = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(existingPath)"
        return environment
    }
}

private func decodeJSONOutput<T: Decodable>(_ type: T.Type, from stdout: String, context: String) throws -> T {
    let decoder = JSONDecoder()
    if let decoded = try? decoder.decode(type, from: Data(stdout.utf8)) {
        return decoded
    }

    for line in stdout.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") else { continue }
        if let decoded = try? decoder.decode(type, from: Data(trimmed.utf8)) {
            return decoded
        }
    }

    throw ASREngineError.adapterNotImplemented("\(context) 输出无法解析为 JSON：\(stdout)")
}

private struct HFOutput: Decodable {
    let text: String
    let duration: Double
    let device: String?
    let mpsFallbackReason: String?
}

private final class ProgressPipeCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var storage = ""
    private let progress: @Sendable (ASRProgressUpdate) -> Void

    init(progress: @escaping @Sendable (ASRProgressUpdate) -> Void) {
        self.progress = progress
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ data: Data) {
        lock.lock()
        buffer.append(data)
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: 10) {
            let lineData = buffer.prefix(upTo: newline)
            buffer.removeSubrange(...newline)
            let line = String(data: lineData, encoding: .utf8) ?? ""
            storage += line + "\n"
            lines.append(line)
        }
        lock.unlock()

        for line in lines {
            if let update = HuggingFaceASRAdapter.progressUpdate(from: line) {
                progress(update)
            }
        }
    }

    func finish() {
        lock.lock()
        let line = String(data: buffer, encoding: .utf8) ?? ""
        buffer.removeAll()
        if !line.isEmpty {
            storage += line
        }
        lock.unlock()

        if let update = HuggingFaceASRAdapter.progressUpdate(from: line) {
            progress(update)
        }
    }
}

private final class OutputPipeCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: storage, encoding: .utf8) ?? ""
    }

    func append(_ data: Data) {
        lock.lock()
        storage.append(data)
        lock.unlock()
    }

    func finish(with data: Data) {
        guard !data.isEmpty else { return }
        append(data)
    }
}

private struct ProgressEvent: Decodable {
    let stage: String
    let fraction: Double
    let elapsed: Double
    let estimatedRemaining: Double?
    let partialText: String
    let segmentIndex: Int?
    let totalSegments: Int?
    let cachedSegments: Int?
    let segmentStart: Double?
    let segmentEnd: Double?
}

enum RuntimePaths {
    static var appSupportRoot: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: MeetingTruthConfig.supportDirectoryName, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static var workspaceRoot: URL {
        let root = appSupportRoot.appending(path: "RuntimeWorkspace", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func prepareBundledWorkspace() {
        guard let resourceRoot = bundledRuntimePayloadRoot() ?? developerRuntimePayloadRoot() else { return }
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)

        for name in ["Scripts", "script", "TestRuns"] {
            let source = resourceRoot.appending(path: name, directoryHint: .isDirectory)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            let destination = workspaceRoot.appending(path: name, directoryHint: .isDirectory)
            try? fileManager.removeItem(at: destination)
            try? fileManager.copyItem(at: source, to: destination)
        }
    }

    static func pythonExecutable(preferredRuntime: String) -> URL {
        var candidates: [URL] = []
        if let runtime = projectFile(".runtime/\(preferredRuntime)/bin/python") {
            candidates.append(runtime)
        }
        if let runtime = projectFile(".runtime/\(preferredRuntime)/bin/python3") {
            candidates.append(runtime)
        }
        if let configured = ProcessInfo.processInfo.environment["LOCAL_ASR_PYTHON311"], !configured.isEmpty {
            candidates.append(URL(fileURLWithPath: configured))
        }
        candidates.append(contentsOf: [
            "/opt/homebrew/bin/python3.11",
            "/usr/local/bin/python3.11",
            "/opt/homebrew/bin/python3.12",
            "/usr/local/bin/python3.12",
            "/opt/homebrew/bin/python3.10",
            "/usr/local/bin/python3.10"
        ].map(URL.init(fileURLWithPath:)))
        candidates.append(URL(fileURLWithPath: "/usr/bin/python3"))

        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) } ?? URL(fileURLWithPath: "/usr/bin/python3")
    }

    static func projectFile(_ relativePath: String) -> URL? {
        for root in candidateProjectRoots() {
            let candidate = root.appending(path: relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private static func candidateProjectRoots() -> [URL] {
        var roots: [URL] = []
        roots.append(workspaceRoot)
        if let developerRoot = developerRuntimePayloadRoot() {
            roots.append(developerRoot)
        }
        if let resourceRoot = bundledRuntimePayloadRoot() {
            roots.append(resourceRoot)
        }
        roots.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath))

        var cursor = Bundle.main.bundleURL
        for _ in 0..<8 {
            roots.append(cursor)
            cursor.deleteLastPathComponent()
        }

        return unique(roots)
    }

    private static func bundledRuntimePayloadRoot() -> URL? {
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let payload = resourceURL.appending(path: "RuntimePayload", directoryHint: .isDirectory)
        return FileManager.default.fileExists(atPath: payload.path) ? payload : nil
    }

    private static func developerRuntimePayloadRoot() -> URL? {
        var cursor = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<8 {
            let package = cursor.appending(path: "Package.swift")
            let scripts = cursor.appending(path: "Scripts/asr", directoryHint: .isDirectory)
            if FileManager.default.fileExists(atPath: package.path),
               FileManager.default.fileExists(atPath: scripts.path) {
                return cursor
            }
            cursor.deleteLastPathComponent()
        }
        return nil
    }

    private static func unique(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        var result: [URL] = []
        for url in urls {
            let path = url.standardizedFileURL.path
            if seen.insert(path).inserted {
                result.append(url.standardizedFileURL)
            }
        }
        return result
    }
}
