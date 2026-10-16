import Foundation

struct ModelStatus: Sendable, Equatable {
    var root: URL
    var bytes: Int64
    var valid: Bool
}

/// The model directory is what the container mounts at `/data/models`: it holds the Triton model
/// `nemotron-voicechat` with its `config.pbtxt` and the weights under `1/`. NGC unpacks a version into
/// a folder of its own, so a directory that only holds that folder counts too.
enum ModelDirectory {
    static let completeFraction = 0.99

    static func inspect(_ directory: URL, fileManager: FileManager = .default) -> ModelStatus {
        let nested = directory.appendingPathComponent(VoiceRequirements.modelFolder, isDirectory: true)
        let root = [directory, nested].first { hasTriton($0, fileManager) } ?? (isDirectory(nested, fileManager) ? nested : directory)
        let bytes = size(of: root, fileManager)
        let triton = root.appendingPathComponent(VoiceRequirements.tritonModel, isDirectory: true)
        let config = fileManager.fileExists(atPath: triton.appendingPathComponent("config.pbtxt").path)
        let weights = (try? fileManager.contentsOfDirectory(atPath: triton.appendingPathComponent("1").path))?
            .contains { $0.hasSuffix(".safetensors") } ?? false
        let enough = Double(bytes) >= Double(VoiceRequirements.modelBytes) * completeFraction
        return ModelStatus(root: root, bytes: bytes, valid: config && weights && enough)
    }

    private static func hasTriton(_ directory: URL, _ fileManager: FileManager) -> Bool {
        isDirectory(directory.appendingPathComponent(VoiceRequirements.tritonModel, isDirectory: true), fileManager)
    }

    private static func isDirectory(_ url: URL, _ fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    static func size(of directory: URL, _ fileManager: FileManager = .default) -> Int64 {
        guard
            let walker = fileManager.enumerator(
                at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: [])
        else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), values.isRegularFile == true
            else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }
}
