import Foundation
import Testing
import HuggingFace
@testable import TTSMLX

/// Unit coverage for the parts of background downloading that do not need a
/// device: URL construction, destination paths, file selection, and job
/// persistence. Suspend/resume behaviour itself can only be verified on
/// hardware.
@Suite("TTSBackgroundModelDownloader", .serialized)
struct TTSBackgroundModelDownloaderTests {

    // MARK: - Destinations

    /// The whole scheme depends on files landing exactly where the runtime
    /// loader looks. If these diverge, a "successful" background download is
    /// followed by the loader downloading everything again in the foreground.
    @Test("destination matches the layout the runtime loader reads")
    func destinationMatchesRuntimeLayout() {
        let directory = TTSBackgroundModelDownloader.destinationDirectory(
            for: "mlx-community/MOSS-TTS-Nano-100M"
        )
        let expected = HubCache.default.cacheDirectory
            .appendingPathComponent("mlx-audio", isDirectory: true)
            .appendingPathComponent("mlx-community_MOSS-TTS-Nano-100M", isDirectory: true)
        #expect(directory.standardizedFileURL == expected.standardizedFileURL)
    }

    /// TTSModelStore looks up installed models under the same
    /// `mlx-audio/<repo with underscores>` key, so a background download must
    /// register as installed afterwards.
    @Test("a completed download registers as installed")
    func completedDownloadIsDiscoverable() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let modelID = "mlx-community/MOSS-TTS-Nano-100M"
        let directory = root
            .appendingPathComponent("mlx-audio", isDirectory: true)
            .appendingPathComponent(modelID.replacingOccurrences(of: "/", with: "_"), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("{}".utf8).write(to: directory.appendingPathComponent("config.json"))
        try Data(repeating: 0, count: 16)
            .write(to: directory.appendingPathComponent("model.safetensors"))

        let store = TTSModelStore(cacheRoots: [root])
        let installed = await store.isInstalled(modelID)
        #expect(installed, "store did not see the downloaded model")
    }

    // MARK: - URLs

    @Test("download URLs point at raw file content, not the HTML page")
    func downloadURLUsesResolveEndpoint() throws {
        let url = try #require(TTSBackgroundModelDownloader.downloadURL(
            repository: "mlx-community/MOSS-TTS-Nano-100M", filename: "model.safetensors"
        ))
        #expect(url.absoluteString ==
                "https://huggingface.co/mlx-community/MOSS-TTS-Nano-100M/resolve/main/model.safetensors")
    }

    // MARK: - File selection

    @Test("selects weights, config and tokenizers; skips noise")
    func fileSelectionMatchesRuntimeNeeds() {
        for name in ["model.safetensors", "config.json", "tokenizer.model",
                     "tokenizer_config.json", "special_tokens_map.json", "vocab.txt"] {
            #expect(TTSBackgroundModelDownloader.isWanted(name), "\(name) should be downloaded")
        }
        // `.model` matters specifically: MOSS ships a SentencePiece tokenizer
        // that the runtime's default globs skip, which is how a model can look
        // downloaded and still fail to load.
        #expect(TTSBackgroundModelDownloader.isWanted("tokenizer.model"))

        for name in [".gitattributes", "README.md", "assets/sample.wav", "figure.png"] {
            #expect(!TTSBackgroundModelDownloader.isWanted(name), "\(name) should be skipped")
        }
    }

    // MARK: - Companions

    /// A prefetch that grabs only the model repo leaves MOSS fetching its codec
    /// on first generation, which is exactly the stall onboarding is meant to
    /// avoid.
    @Test("MOSS reports its codec as a companion repository")
    func mossDeclaresCodecCompanion() throws {
        let entry = try #require(
            TTSMLX.modelCatalog.first(where: { $0.id == "mlx-community/MOSS-TTS-Nano-100M" })
        )
        let descriptor = try #require(entry.descriptor)
        let companions = TTSBackgroundModelDownloader.companionRepositories(for: descriptor)
        #expect(companions == ["mlx-community/MOSS-Audio-Tokenizer-Nano"],
                "got \(companions)")
    }

    @Test("models without a companion report none")
    func singleRepoModelsHaveNoCompanions() throws {
        let soprano = try #require(
            TTSMLX.supportedModels.first(where: { $0.id.contains("Soprano") })
        )
        #expect(TTSBackgroundModelDownloader.companionRepositories(for: soprano).isEmpty)
    }

    // MARK: - Job persistence

    /// The job file is what lets a relaunched app map a finished background
    /// task back to its destination. Task identifiers do not survive a
    /// relaunch, so the mapping is keyed by URL and must round-trip.
    @Test("job survives encode/decode with its URL keying intact")
    func jobRoundTrips() throws {
        let remote = try #require(URL(string: "https://huggingface.co/r/resolve/main/model.safetensors"))
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("model.safetensors")
        let job = TTSBackgroundModelDownloader.Job(
            modelID: "r",
            files: [.init(remoteURL: remote, destination: destination, expectedBytes: 1234)],
            completedURLs: []
        )

        let data = try JSONEncoder().encode(job)
        let decoded = try JSONDecoder().decode(TTSBackgroundModelDownloader.Job.self, from: data)

        #expect(decoded.modelID == job.modelID)
        #expect(decoded.files == job.files)
        #expect(!decoded.isComplete)

        var completed = decoded
        completed.completedURLs.insert(remote)
        #expect(completed.isComplete, "a job with every file done should report complete")
    }

    @Test("progress prefers bytes and falls back to file counts")
    func progressFractionHandlesMissingSizes() {
        let byBytes = TTSBackgroundModelDownloader.Progress(
            modelID: "m", completedBytes: 50, totalBytes: 200, filesCompleted: 0, filesTotal: 4
        )
        #expect(abs(byBytes.fractionCompleted - 0.25) < 1e-9)

        // Servers that omit Content-Length leave totalBytes at zero; progress
        // should still advance rather than sit at 0%.
        let byFiles = TTSBackgroundModelDownloader.Progress(
            modelID: "m", completedBytes: 0, totalBytes: 0, filesCompleted: 3, filesTotal: 4
        )
        #expect(abs(byFiles.fractionCompleted - 0.75) < 1e-9)

        let empty = TTSBackgroundModelDownloader.Progress(
            modelID: "m", completedBytes: 0, totalBytes: 0, filesCompleted: 0, filesTotal: 0
        )
        #expect(empty.fractionCompleted == 0, "must not divide by zero")
    }

    // MARK: - Relaunch behaviour

    /// After the app is terminated and relaunched, the downloader must report
    /// the in-flight job rather than `.idle` — otherwise onboarding shows a
    /// fresh "Download" button while the transfer is still running, and a user
    /// tapping it would re-plan the whole job.
    @Test("a restored job reports as in-flight, not idle")
    func restoredJobIsReportedInFlight() throws {
        let stateDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stateDirectory) }

        let done = try #require(URL(string: "https://huggingface.co/r/resolve/main/config.json"))
        let pending = try #require(URL(string: "https://huggingface.co/r/resolve/main/model.safetensors"))
        let job = TTSBackgroundModelDownloader.Job(
            modelID: "r",
            files: [
                .init(remoteURL: done, destination: stateDirectory.appendingPathComponent("config.json"),
                      expectedBytes: 100),
                .init(remoteURL: pending, destination: stateDirectory.appendingPathComponent("model.safetensors"),
                      expectedBytes: 900),
            ],
            completedURLs: [done]
        )
        let jobFile = stateDirectory
            .appendingPathComponent("TTSMLX", isDirectory: true)
            .appendingPathComponent("background-download.json")
        try FileManager.default.createDirectory(
            at: jobFile.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try JSONEncoder().encode(job).write(to: jobFile)

        let downloader = TTSBackgroundModelDownloader(stateDirectory: stateDirectory)
        #expect(downloader.hasPendingJob, "restored job should be pending")

        guard case .downloading(let progress) = downloader.state else {
            Issue.record("expected .downloading, got \(downloader.state)")
            return
        }
        #expect(progress.modelID == "r")
        #expect(progress.filesCompleted == 1)
        #expect(progress.filesTotal == 2)
        // The finished file's bytes count toward progress on restore.
        #expect(abs(progress.fractionCompleted - 0.1) < 1e-9,
                "got \(progress.fractionCompleted)")
    }

    @Test("a fully finished job restores as finished")
    func restoredCompleteJobIsFinished() throws {
        let stateDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let jobFile = stateDirectory
            .appendingPathComponent("TTSMLX", isDirectory: true)
            .appendingPathComponent("background-download.json")
        try FileManager.default.createDirectory(
            at: jobFile.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: stateDirectory) }

        let only = try #require(URL(string: "https://huggingface.co/r/resolve/main/config.json"))
        let job = TTSBackgroundModelDownloader.Job(
            modelID: "r",
            files: [.init(remoteURL: only,
                          destination: stateDirectory.appendingPathComponent("config.json"),
                          expectedBytes: 10)],
            completedURLs: [only]
        )
        try JSONEncoder().encode(job).write(to: jobFile)

        let downloader = TTSBackgroundModelDownloader(stateDirectory: stateDirectory)
        #expect(!downloader.hasPendingJob)
        #expect(downloader.state == .finished(modelID: "r"))
    }

    @Test("no job on disk means idle")
    func freshDownloaderIsIdle() {
        let stateDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        let downloader = TTSBackgroundModelDownloader(stateDirectory: stateDirectory)
        #expect(downloader.state == .idle)
        #expect(!downloader.hasPendingJob)
    }

    // MARK: - Storage

    /// The check exists so a nearly-full device refuses the download instead of
    /// filling the volume. A wedged device is worse than a refused download.
    @Test("reports available capacity for important usage")
    func availableCapacityIsReadable() throws {
        let available = try #require(
            TTSBackgroundModelDownloader.availableCapacityBytes(),
            "volume capacity should be readable on this platform"
        )
        #expect(available > 0)
    }

    @Test("insufficient-storage error states both figures")
    func insufficientStorageMessageIsActionable() {
        let error = TTSBackgroundModelDownloader.DownloadError.insufficientStorage(
            requiredBytes: 400_000_000, availableBytes: 100_000_000
        )
        let message = try? #require(error.errorDescription)
        #expect(message?.contains("400") == true || message?.contains("0.4") == true,
                "should name the requirement: \(message ?? "nil")")
        #expect(message?.lowercased().contains("available") == true)
    }

    /// Headroom must be big enough that a "successful" download does not leave
    /// the device with nothing free.
    @Test("keeps a meaningful storage headroom")
    func headroomIsSubstantial() {
        #expect(TTSBackgroundModelDownloader.storageHeadroomBytes >= 200 * 1024 * 1024)
    }

    // MARK: - Resume

    /// Resume blobs are keyed per download URL and must survive a relaunch —
    /// that is the whole point of writing them to disk rather than memory.
    @Test("resume data round-trips per URL and is cleared on completion")
    func resumeDataRoundTrips() throws {
        let stateDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stateDirectory) }

        let downloader = TTSBackgroundModelDownloader(stateDirectory: stateDirectory)
        let a = try #require(URL(string: "https://huggingface.co/r/resolve/main/model.safetensors"))
        let b = try #require(URL(string: "https://huggingface.co/r/resolve/main/config.json"))

        #expect(downloader.resumeDataForTesting(a) == nil, "nothing stored yet")

        downloader.storeResumeDataForTesting(Data("partial-a".utf8), for: a)
        downloader.storeResumeDataForTesting(Data("partial-b".utf8), for: b)

        #expect(downloader.resumeDataForTesting(a) == Data("partial-a".utf8))
        #expect(downloader.resumeDataForTesting(b) == Data("partial-b".utf8),
                "blobs must not collide across URLs")

        // A second instance is what a relaunch looks like.
        let relaunched = TTSBackgroundModelDownloader(stateDirectory: stateDirectory)
        #expect(relaunched.resumeDataForTesting(a) == Data("partial-a".utf8),
                "resume data must survive a relaunch")

        relaunched.clearResumeDataForTesting(a)
        #expect(relaunched.resumeDataForTesting(a) == nil)
        #expect(relaunched.resumeDataForTesting(b) == Data("partial-b".utf8),
                "clearing one file must not disturb another")
    }
}
