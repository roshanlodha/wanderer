import Foundation

final class LocalMLXModelManager {
    struct RemoteFile: Decodable {
        let rfilename: String
        let size: Int?
    }

    struct ModelInfo: Decodable {
        let siblings: [RemoteFile]?
    }

    enum DownloadError: LocalizedError {
        case invalidModelID
        case cannotCreateStorage
        case downloadFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidModelID:
                return "Invalid model ID"
            case .cannotCreateStorage:
                return "Unable to create on-device model storage"
            case .downloadFailed(let message):
                return "Model download failed: \(message)"
            }
        }
    }

    static let shared = LocalMLXModelManager()

    private init() {}

    func modelDirectory(for modelID: String) throws -> URL {
        let sanitized = modelID
            .replacingOccurrences(of: "/", with: "__")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !sanitized.isEmpty else {
            throw DownloadError.invalidModelID
        }

        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw DownloadError.cannotCreateStorage
        }

        let dir = appSupport
            .appendingPathComponent("MLXModels", isDirectory: true)
            .appendingPathComponent(sanitized, isDirectory: true)

        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func isModelDownloaded(modelID: String) -> Bool {
        guard let dir = try? modelDirectory(for: modelID) else {
            return false
        }

        let configExists = FileManager.default.fileExists(atPath: dir.appendingPathComponent("config.json").path)
        let tokenizerExists = FileManager.default.fileExists(atPath: dir.appendingPathComponent("tokenizer.json").path)

        let contents = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let hasWeights = contents.contains { $0.hasSuffix(".safetensors") }

        return configExists && (tokenizerExists || hasWeights) && hasWeights
    }

    func estimatedSizeString(modelID: String) async -> String? {
        guard let files = try? await fetchDownloadableFiles(modelID: modelID) else {
            return nil
        }

        let totalBytes = files.reduce(0) { partial, file in
            partial + (file.size ?? 0)
        }

        guard totalBytes > 0 else {
            return nil
        }

        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(totalBytes))
    }

    func fetchDownloadableFiles(modelID: String) async throws -> [RemoteFile] {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw DownloadError.invalidModelID
        }

        let encodedModelID = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? trimmed
        guard let url = URL(string: "https://huggingface.co/api/models/\(encodedModelID)") else {
            throw DownloadError.invalidModelID
        }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw DownloadError.downloadFailed("Could not fetch model metadata")
        }

        let info = try JSONDecoder().decode(ModelInfo.self, from: data)
        let siblings = info.siblings ?? []

        let allowedExtensions = [
            ".json", ".txt", ".model", ".safetensors", ".tiktoken", ".merges", ".vocab"
        ]

        return siblings.filter { file in
            let lower = file.rfilename.lowercased()
            return allowedExtensions.contains(where: { lower.hasSuffix($0) })
        }
    }

    func downloadModel(
        modelID: String,
        progress: @escaping @MainActor (Double, String) -> Void
    ) async throws {
        let files = try await fetchDownloadableFiles(modelID: modelID)
        guard !files.isEmpty else {
            throw DownloadError.downloadFailed("No downloadable model files found")
        }

        let targetDir = try modelDirectory(for: modelID)
        var completed = 0

        for file in files {
            try Task.checkCancellation()
            let relativePath = file.rfilename
            let relativeDir = (relativePath as NSString).deletingLastPathComponent
            let fileName = (relativePath as NSString).lastPathComponent

            let destinationDir = targetDir.appendingPathComponent(relativeDir, isDirectory: true)
            try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)
            let destination = destinationDir.appendingPathComponent(fileName)

            if !FileManager.default.fileExists(atPath: destination.path) {
                let encodedPath = relativePath
                    .split(separator: "/")
                    .map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
                    .joined(separator: "/")

                let encodedModelID = modelID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? modelID
                guard let fileURL = URL(string: "https://huggingface.co/\(encodedModelID)/resolve/main/\(encodedPath)") else {
                    throw DownloadError.downloadFailed("Invalid file URL for \(relativePath)")
                }

                let (data, response) = try await URLSession.shared.data(from: fileURL)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    throw DownloadError.downloadFailed("Failed to download \(relativePath)")
                }

                try data.write(to: destination, options: .atomic)
            }

            completed += 1
            let ratio = Double(completed) / Double(max(files.count, 1))
            await progress(ratio, relativePath)
        }
    }
}
