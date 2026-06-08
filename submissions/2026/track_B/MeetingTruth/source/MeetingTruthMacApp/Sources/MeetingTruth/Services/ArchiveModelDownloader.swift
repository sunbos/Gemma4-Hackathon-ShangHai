import Foundation

final class ArchiveModelDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: @Sendable (DownloadMetrics) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?
    private var archiveURL: URL?
    private var targetDirectory: URL?
    private var archiveDirectory: URL?
    private let lock = NSLock()
    private var didResume = false

    private var lastProgressTime = Date()
    private var lastProgressBytes: Int64 = 0

    init(progress: @escaping @Sendable (DownloadMetrics) -> Void) {
        self.progress = progress
    }

    func downloadAndExtract(from url: URL, into targetDirectory: URL, archiveDirectory: URL) async throws -> URL {
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true, attributes: nil)
        try FileManager.default.createDirectory(at: archiveDirectory, withIntermediateDirectories: true, attributes: nil)

        let archiveName = url.lastPathComponent
        let archiveURL = archiveDirectory.appending(path: archiveName)

        if FileManager.default.fileExists(atPath: archiveURL.path) {
            do {
                try extractArchive(archiveURL: archiveURL, targetDirectory: targetDirectory, archiveDirectory: archiveDirectory)
                progress(DownloadMetrics(downloadedBytes: 1, totalBytes: 1, speedBytesPerSecond: 0, estimatedRemainingSeconds: 0))
                return targetDirectory
            } catch {
                try? FileManager.default.removeItem(at: archiveURL)
            }
        }

        try await downloadArchiveWithResume(from: url, to: archiveURL)
        try extractArchive(archiveURL: archiveURL, targetDirectory: targetDirectory, archiveDirectory: archiveDirectory)
        progress(DownloadMetrics(downloadedBytes: 1, totalBytes: 1, speedBytesPerSecond: 0, estimatedRemainingSeconds: 0))
        return targetDirectory
    }

    private func downloadArchiveWithResume(from url: URL, to archiveURL: URL) async throws {
        let partialURL = archiveURL.appendingPathExtension("part")
        let expectedBytes = await remoteContentLength(for: url)

        try await Task.detached(priority: .userInitiated) { [progress] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            process.arguments = [
                "-L",
                "--fail",
                "--continue-at", "-",
                "--output", partialURL.path,
                url.absoluteString
            ]
            process.standardOutput = Pipe()
            process.standardError = Pipe()

            try process.run()

            var lastBytes = Self.fileSize(at: partialURL)
            var lastDate = Date()
            while process.isRunning {
                let currentBytes = Self.fileSize(at: partialURL)
                let now = Date()
                let elapsed = now.timeIntervalSince(lastDate)
                let speed = elapsed > 0 ? Double(max(currentBytes - lastBytes, 0)) / elapsed : 0
                let remaining = speed > 0 && expectedBytes > 0 ? Double(max(expectedBytes - currentBytes, 0)) / speed : nil
                progress(
                    DownloadMetrics(
                        downloadedBytes: currentBytes,
                        totalBytes: expectedBytes,
                        speedBytesPerSecond: speed,
                        estimatedRemainingSeconds: remaining
                    )
                )
                lastBytes = currentBytes
                lastDate = now
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                throw ArchiveDownloadError.downloadFailed(archiveURL.lastPathComponent)
            }

            if FileManager.default.fileExists(atPath: archiveURL.path) {
                try FileManager.default.removeItem(at: archiveURL)
            }
            try FileManager.default.moveItem(at: partialURL, to: archiveURL)
        }.value
    }

    private func remoteContentLength(for url: URL) async -> Int64 {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              let value = http.value(forHTTPHeaderField: "Content-Length"),
              let bytes = Int64(value) else {
            return 0
        }
        return bytes
    }

    private static func fileSize(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else {
            progress(DownloadMetrics(downloadedBytes: totalBytesWritten, totalBytes: 0, speedBytesPerSecond: 0, estimatedRemainingSeconds: nil))
            return
        }

        let now = Date()
        let elapsed = now.timeIntervalSince(lastProgressTime)
        let byteDelta = totalBytesWritten - lastProgressBytes
        let speed = elapsed > 0 ? Double(byteDelta) / elapsed : 0
        let remaining = speed > 0 ? Double(totalBytesExpectedToWrite - totalBytesWritten) / speed : nil
        lastProgressTime = now
        lastProgressBytes = totalBytesWritten

        progress(
            DownloadMetrics(
                downloadedBytes: totalBytesWritten,
                totalBytes: totalBytesExpectedToWrite,
                speedBytesPerSecond: speed,
                estimatedRemainingSeconds: remaining
            )
        )
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            guard let archiveURL, let targetDirectory, let archiveDirectory else {
                throw ArchiveDownloadError.missingDestination
            }

            if FileManager.default.fileExists(atPath: archiveURL.path) {
                try FileManager.default.removeItem(at: archiveURL)
            }
            try FileManager.default.moveItem(at: location, to: archiveURL)
            try extractArchive(archiveURL: archiveURL, targetDirectory: targetDirectory, archiveDirectory: archiveDirectory)
            progress(DownloadMetrics(downloadedBytes: 1, totalBytes: 1, speedBytesPerSecond: 0, estimatedRemainingSeconds: 0))
            resume(returning: targetDirectory)
        } catch {
            resume(throwing: error)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            resume(throwing: error)
        }
        session.invalidateAndCancel()
    }

    private func extractArchive(archiveURL: URL, targetDirectory: URL, archiveDirectory: URL) throws {
        let tempDirectory = archiveDirectory.appending(path: "\(archiveURL.deletingPathExtension().lastPathComponent)-extract-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let process = Process()
        if archiveURL.pathExtension.lowercased() == "zip" {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-q", archiveURL.path, "-d", tempDirectory.path]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = ["-xf", archiveURL.path, "-C", tempDirectory.path]
        }
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw ArchiveDownloadError.extractionFailed(archiveURL.lastPathComponent)
        }

        try replaceTargetContents(from: normalizedExtractRoot(tempDirectory), to: targetDirectory)
    }

    private func normalizedExtractRoot(_ tempDirectory: URL) -> URL {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: tempDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ), children.count == 1 else {
            return tempDirectory
        }

        let child = children[0]
        let values = try? child.resourceValues(forKeys: [.isDirectoryKey])
        return values?.isDirectory == true ? child : tempDirectory
    }

    private func replaceTargetContents(from source: URL, to target: URL) throws {
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let children = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
        for child in children {
            try FileManager.default.moveItem(at: child, to: target.appending(path: child.lastPathComponent))
        }
    }

    private func resume(returning url: URL) {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else { return }
        didResume = true
        continuation?.resume(returning: url)
        continuation = nil
    }

    private func resume(throwing error: Error) {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else { return }
        didResume = true
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

enum ArchiveDownloadError: LocalizedError {
    case missingDestination
    case extractionFailed(String)
    case downloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingDestination:
            "下载目标目录缺失。"
        case .extractionFailed(let archive):
            "模型归档 \(archive) 解压失败。"
        case .downloadFailed(let archive):
            "模型归档 \(archive) 下载失败，已保留 .part 文件，下次会继续尝试。"
        }
    }
}
