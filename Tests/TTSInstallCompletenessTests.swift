import Foundation
import Testing
@testable import TTSMLX

@Suite("Model store: a half-downloaded directory is not an install")
struct TTSInstallCompletenessTests {
    func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ttsmlx-install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func write(_ name: String, bytes: Int, in directory: URL) throws {
        let url = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: url)
    }

    @Test("descriptor file list: every listed file must be present and non-empty")
    func descriptorFiles() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let descriptor = TTSModelDescriptor(id: "x/y", files: ["config.json", "model.safetensors", "voices/a.safetensors"])
        #expect(!TTSModelStore.isCompleteInstall(at: directory, descriptor: descriptor))
        try write("config.json", bytes: 2, in: directory)
        try write("model.safetensors", bytes: 0, in: directory)
        try write("voices/a.safetensors", bytes: 5, in: directory)
        #expect(!TTSModelStore.isCompleteInstall(at: directory, descriptor: descriptor), "zero-byte weights are a killed download")
        try write("model.safetensors", bytes: 10, in: directory)
        #expect(TTSModelStore.isCompleteInstall(at: directory, descriptor: descriptor))
    }

    @Test("snapshot manifest: files matching the runtime's patterns must be present")
    func manifest() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let descriptor = TTSModelDescriptor(id: "x/y")
        let manifest: [String: Any] = ["revision": "abc", "files": [["rfilename": "config.json"], ["rfilename": "model.safetensors"], ["rfilename": "README.md"]]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: directory.appendingPathComponent(".mlx-audio-snapshot.json"))
        try write("config.json", bytes: 2, in: directory)
        #expect(!TTSModelStore.isCompleteInstall(at: directory, descriptor: descriptor))
        try write("model.safetensors", bytes: 10, in: directory)
        #expect(TTSModelStore.isCompleteInstall(at: directory, descriptor: descriptor), "README.md is outside the patterns and not required")
    }

    @Test("an in-progress marker means the download never finished, whatever the files say")
    func marker() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let descriptor = TTSModelDescriptor(id: "x/y", files: ["config.json", "model.safetensors"])
        try write("config.json", bytes: 2, in: directory)
        try write("model.safetensors", bytes: 10, in: directory)
        #expect(TTSModelStore.isCompleteInstall(at: directory, descriptor: descriptor))
        try TTSModelStore.markDownloadInProgress(at: directory, fileManager: .default)
        #expect(!TTSModelStore.isCompleteInstall(at: directory, descriptor: descriptor))
        TTSModelStore.clearDownloadInProgress(at: directory, fileManager: .default)
        #expect(TTSModelStore.isCompleteInstall(at: directory, descriptor: descriptor))
    }

    @Test("without any list: config.json plus non-empty weights")
    func fallback() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let descriptor = TTSModelDescriptor(id: "x/y")
        try write("config.json", bytes: 2, in: directory)
        #expect(!TTSModelStore.isCompleteInstall(at: directory, descriptor: descriptor))
        try write("weights.safetensors", bytes: 1, in: directory)
        #expect(TTSModelStore.isCompleteInstall(at: directory, descriptor: descriptor))
    }
}
