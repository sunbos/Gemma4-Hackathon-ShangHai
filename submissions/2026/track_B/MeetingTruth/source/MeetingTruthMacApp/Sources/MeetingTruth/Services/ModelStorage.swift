import Foundation

struct ModelStorage {
    let root: URL

    var assetsRoot: URL {
        root.appending(path: "Assets", directoryHint: .isDirectory)
    }

    var systemRoot: URL {
        root.appending(path: "System", directoryHint: .isDirectory)
    }

    var downloadsRoot: URL {
        systemRoot.appending(path: "Downloads", directoryHint: .isDirectory)
    }

    var runsRoot: URL {
        systemRoot.appending(path: "Runs", directoryHint: .isDirectory)
    }

    func assetDirectory(for model: ASRModelSpec) -> URL {
        assetsRoot
            .appending(path: sourceKey(for: model), directoryHint: .isDirectory)
            .appending(path: assetDirectoryName(for: model), directoryHint: .isDirectory)
    }

    func assetDirectoryName(for model: ASRModelSpec) -> String {
        switch model.id {
        case "qwen3-asr-timestamps":
            return "qwen3-asr"
        case "qwen3-asr-1.7b-timestamps":
            return "qwen3-asr-1.7b"
        default:
            return model.id
        }
    }

    func sharedAssetDirectory(repoID: String) -> URL {
        assetsRoot
            .appending(path: "huggingface", directoryHint: .isDirectory)
            .appending(path: safeRepositoryName(repoID), directoryHint: .isDirectory)
    }

    func hfHome(for runtime: String) -> URL {
        systemRoot
            .appending(path: runtime, directoryHint: .isDirectory)
            .appending(path: ".hf-cache", directoryHint: .isDirectory)
    }

    func legacyExternalDirectories(for model: ASRModelSpec, runtimes: [String]) -> [URL] {
        runtimes.map {
            root
                .appending(path: $0, directoryHint: .isDirectory)
                .appending(path: model.id, directoryHint: .isDirectory)
        }
    }

    func legacySherpaDirectory(folderName: String) -> URL {
        root
            .appending(path: RuntimeKind.sherpaONNX.rawValue, directoryHint: .isDirectory)
            .appending(path: folderName, directoryHint: .isDirectory)
    }

    func sourceKey(for model: ASRModelSpec) -> String {
        switch model.runtime {
        case .sherpaONNX:
            return "github"
        case .externalCLI:
            return "huggingface"
        case .mlxSwift:
            return "mlx"
        }
    }

    func expectedManifestURL(for model: ASRModelSpec) -> URL {
        assetDirectory(for: model).appending(path: ModelAssetManifest.fileName)
    }

    func writeManifest(_ manifest: ModelAssetManifest, for model: ASRModelSpec) throws {
        let target = assetDirectory(for: model)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let data = try JSONEncoder.localASRManifest.encode(manifest)
        try data.write(to: target.appending(path: ModelAssetManifest.fileName), options: .atomic)
    }

    func readManifest(at directory: URL) -> ModelAssetManifest? {
        let url = directory.appending(path: ModelAssetManifest.fileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.localASRManifest.decode(ModelAssetManifest.self, from: data)
    }

    func safeRepositoryName(_ repoID: String) -> String {
        repoID.replacingOccurrences(of: "/", with: "--")
    }
}

struct ModelAssetManifest: Codable, Hashable {
    static let fileName = "LOCAL_ASR_MODEL_MANIFEST.json"

    var schemaVersion: Int = 1
    var modelID: String
    var modelName: String
    var runtime: String
    var sourceType: String
    var source: String
    var downloadedAt: Date
    var localPath: String
    var requiredFiles: [String]
    var expectedSize: Int64? = nil
    var checksum: String? = nil
    var downloadSource: String? = nil
    var preparedAt: Date? = nil
    var validationStatus: String? = nil
    var errorMessage: String? = nil
    var notes: String?
}

private extension JSONEncoder {
    static var localASRManifest: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var localASRManifest: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
