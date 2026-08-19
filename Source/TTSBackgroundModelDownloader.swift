import Foundation
import HuggingFace
import MLXAudioTTS

/// Downloads model weights with a background `URLSession`, so a fetch started
/// during onboarding keeps running while the app is suspended and survives the
/// app being terminated.
///
/// ## Why this exists separately from ``TTSModelStore/ensureDownloaded(_:hfToken:progressHandler:)``
///
/// That path (and the Hugging Face client underneath it) downloads with
/// `URLSession.download(for:delegate:)`. iOS does not support the
/// completion-handler family — which the `async` variants are built on — on a
/// background session; those calls fail rather than continue in the background.
/// A background transfer has to be delegate-driven, which is what this type is.
///
/// ## What the app must do
///
/// Background sessions deliver their final callbacks to a *relaunched* app, so
/// the host app has to hand them back:
///
/// ```swift
/// func application(
///     _ application: UIApplication,
///     handleEventsForBackgroundURLSession identifier: String,
///     completionHandler: @escaping () -> Void
/// ) {
///     TTSBackgroundModelDownloader.shared.handleEventsForBackgroundURLSession(
///         identifier: identifier, completionHandler: completionHandler
///     )
/// }
/// ```
///
/// Without that hook the download still completes, but the system is not told
/// when the app has finished processing it.
///
/// ## Shape of a job
///
/// A model may need more than its own repository — MOSS keeps its audio codec
/// in a second one — so a job covers every repository the runtime reports as
/// required. File *discovery* happens in the foreground (a few kilobytes of
/// JSON); only the weights go through the background session.
public final class TTSBackgroundModelDownloader: NSObject, @unchecked Sendable {

    /// Shared instance. Background sessions are keyed by identifier and only
    /// one session per identifier may exist, so this is a singleton by
    /// necessity rather than by preference.
    public static let shared = TTSBackgroundModelDownloader()

    public static let sessionIdentifier = "technology.fil.ttsmlx.model-download"

    // MARK: - Public types

    public struct Progress: Sendable, Equatable {
        public let modelID: String
        public let completedBytes: Int64
        public let totalBytes: Int64
        public let filesCompleted: Int
        public let filesTotal: Int

        /// Byte-based where the server gave us sizes, file-based otherwise.
        /// Hugging Face reports sizes for LFS weights, which dominate, so the
        /// byte figure is normally the meaningful one.
        public var fractionCompleted: Double {
            if totalBytes > 0 {
                return min(1.0, Double(completedBytes) / Double(totalBytes))
            }
            guard filesTotal > 0 else { return 0 }
            return Double(filesCompleted) / Double(filesTotal)
        }
    }

    public enum State: Sendable, Equatable {
        case idle
        /// Discovering which files are needed. Foreground, quick.
        case preparing(modelID: String)
        case downloading(Progress)
        case finished(modelID: String)
        case failed(modelID: String, message: String)
    }

    public enum DownloadError: LocalizedError, Equatable {
        case noFilesFound(String)
        case metadataUnavailable(String, underlying: String)
        case insufficientStorage(requiredBytes: Int64, availableBytes: Int64)

        public var errorDescription: String? {
            switch self {
            case .noFilesFound(let repo):
                return "No downloadable files were listed for \(repo)."
            case .metadataUnavailable(let repo, let underlying):
                return "Could not list files for \(repo): \(underlying)"
            case .insufficientStorage(let required, let available):
                let formatter = ByteCountFormatter()
                formatter.countStyle = .file
                return "Not enough free space: needs about "
                    + "\(formatter.string(fromByteCount: required)), "
                    + "\(formatter.string(fromByteCount: available)) available."
            }
        }
    }

    /// Free space to leave untouched after the download, so a device that is
    /// nearly full does not end up with no room for the OS or the app's own
    /// data. Deliberately generous: a wedged device is worse than a refused
    /// download.
    public static let storageHeadroomBytes: Int64 = 300 * 1024 * 1024

    // MARK: - Stored state

    /// One file within a job.
    struct PlannedFile: Codable, Sendable, Equatable {
        let remoteURL: URL
        /// Absolute path the file must end up at for the loader to find it.
        let destination: URL
        let expectedBytes: Int64
    }

    struct Job: Codable, Sendable {
        let modelID: String
        var files: [PlannedFile]
        var completedURLs: Set<URL>

        var isComplete: Bool { completedURLs.count >= files.count }
    }

    private let lock = NSLock()
    private var job: Job?
    /// Per-task byte counts, so progress does not depend on task identifiers
    /// being stable across a relaunch.
    private var bytesByURL: [URL: Int64] = [:]
    private var systemCompletionHandler: (@Sendable () -> Void)?
    private var continuations: [UUID: AsyncStream<State>.Continuation] = [:]
    private var lastState: State = .idle

    private let fileManager: FileManager
    private let metadataSession: URLSession
    private let jobFileURL: URL
    /// Resume blobs, one file per download URL. Kept out of the job manifest
    /// because they are opaque and can run to tens of kilobytes.
    private let resumeDirectory: URL

    private var _session: URLSession?

    /// Built on demand rather than as a `lazy var`, because `cancel()` calls
    /// `invalidateAndCancel()` — which kills a session permanently. A lazy
    /// property would hand back the dead one on the next download.
    ///
    /// Only one live session may exist per identifier, hence the caching.
    private var session: URLSession {
        lock.lock()
        if let existing = _session {
            lock.unlock()
            return existing
        }
        lock.unlock()

        let configuration = URLSessionConfiguration.background(
            withIdentifier: Self.sessionIdentifier
        )
        // Weights are large and the user may be on cellular during onboarding;
        // let the system schedule this rather than deferring it indefinitely.
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.allowsCellularAccess = true
        let created = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)

        lock.lock()
        // Another thread may have won the race; keep whichever landed first.
        if let existing = _session {
            lock.unlock()
            created.invalidateAndCancel()
            return existing
        }
        _session = created
        lock.unlock()
        return created
    }

    init(
        fileManager: FileManager = .default,
        metadataSession: URLSession = .shared,
        stateDirectory: URL? = nil
    ) {
        self.fileManager = fileManager
        self.metadataSession = metadataSession
        let root = stateDirectory
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let directory = root.appendingPathComponent("TTSMLX", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        self.jobFileURL = directory.appendingPathComponent("background-download.json")
        self.resumeDirectory = directory.appendingPathComponent("resume", isDirectory: true)
        try? fileManager.createDirectory(at: resumeDirectory, withIntermediateDirectories: true)
        super.init()
        let restored = Self.loadJob(at: jobFileURL, fileManager: fileManager)
        self.job = restored
        // Reflect a job that outlived the previous launch, so a view
        // subscribing after relaunch shows the download rather than idle.
        if let restored {
            for file in restored.files where restored.completedURLs.contains(file.remoteURL) {
                bytesByURL[file.remoteURL] = file.expectedBytes
            }
            lastState = restored.isComplete
                ? .finished(modelID: restored.modelID)
                : .downloading(progressSnapshot(for: restored))
        }
    }

    // MARK: - Observing

    /// Stream of state changes. The current state is replayed immediately, so a
    /// view that subscribes after a relaunch sees the in-flight download.
    public func events() -> AsyncStream<State> {
        AsyncStream { continuation in
            let id = UUID()
            lock.lock()
            continuations[id] = continuation
            let current = lastState
            lock.unlock()
            continuation.yield(current)
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.continuations[id] = nil
                self.lock.unlock()
            }
        }
    }

    public var state: State {
        lock.lock()
        defer { lock.unlock() }
        return lastState
    }

    /// True when a job is recorded and not yet complete — i.e. the app should
    /// reattach rather than start over.
    public var hasPendingJob: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let job else { return false }
        return !job.isComplete
    }

    private func emit(_ state: State) {
        lock.lock()
        lastState = state
        let targets = Array(continuations.values)
        lock.unlock()
        for continuation in targets {
            continuation.yield(state)
        }
    }

    // MARK: - Starting a download

    /// Plans and starts a background download of everything `descriptor` needs
    /// to generate offline, including any companion repositories.
    ///
    /// Returns once the transfers are *enqueued*, not when they finish —
    /// observe ``events()`` for completion. Safe to call again after a
    /// relaunch: an already-complete job returns immediately, and an in-flight
    /// one is left alone rather than restarted.
    @discardableResult
    public func startDownload(
        for descriptor: TTSModelDescriptor,
        hfToken: String? = nil
    ) async throws -> Bool {
        let existing = lock.withLock { job }

        if let existing, existing.modelID == descriptor.id {
            if existing.isComplete {
                emit(.finished(modelID: descriptor.id))
                return false
            }
            // Tasks from a previous launch are still owned by the system.
            let running = await session.allTasks
            if !running.isEmpty {
                emit(.downloading(progressSnapshot(for: existing)))
                return false
            }
        }

        emit(.preparing(modelID: descriptor.id))

        let repositories = [descriptor.id] + Self.companionRepositories(for: descriptor)
        var planned: [PlannedFile] = []
        for repository in repositories {
            planned.append(contentsOf: try await planFiles(for: repository, hfToken: hfToken))
        }
        guard !planned.isEmpty else {
            throw DownloadError.noFilesFound(descriptor.id)
        }

        // Skip anything already on disk at the right size, so a resumed
        // onboarding does not refetch hundreds of megabytes.
        let outstanding = planned.filter { !isAlreadyDownloaded($0) }
        let alreadyDone = Set(planned.filter { isAlreadyDownloaded($0) }.map(\.remoteURL))

        let newJob = Job(modelID: descriptor.id, files: planned, completedURLs: alreadyDone)
        lock.withLock {
            job = newJob
            bytesByURL = [:]
            for file in planned where alreadyDone.contains(file.remoteURL) {
                bytesByURL[file.remoteURL] = file.expectedBytes
            }
        }
        persist(newJob)

        guard !outstanding.isEmpty else {
            emit(.finished(modelID: descriptor.id))
            return false
        }

        // Refuse rather than fill the disk. Failing here is recoverable; a
        // device with no free space is not.
        let required = outstanding.map(\.expectedBytes).reduce(0, +)
        if required > 0, let available = Self.availableCapacityBytes() {
            guard available - required >= Self.storageHeadroomBytes else {
                let error = DownloadError.insufficientStorage(
                    requiredBytes: required, availableBytes: available
                )
                emit(.failed(modelID: descriptor.id, message: error.localizedDescription))
                throw error
            }
        }

        for file in outstanding {
            let task: URLSessionDownloadTask
            if let resumeData = loadResumeData(for: file.remoteURL) {
                // Continues from the bytes already on disk. If the system has
                // since discarded the partial file the task fails, and
                // didCompleteWithError re-enqueues it from scratch.
                task = session.downloadTask(withResumeData: resumeData)
            } else {
                var request = URLRequest(url: file.remoteURL)
                if let hfToken, !hfToken.isEmpty {
                    request.setValue("Bearer \(hfToken)", forHTTPHeaderField: "Authorization")
                }
                task = session.downloadTask(with: request)
            }
            task.resume()
        }

        emit(.downloading(progressSnapshot(for: newJob)))
        return true
    }

    /// Cancels in-flight transfers and forgets the job.
    ///
    /// Resume blobs are left in place: iOS supplies them through
    /// `didCompleteWithError` as the tasks unwind, so a later `startDownload`
    /// for the same files continues rather than starting over.
    public func cancel() {
        session.invalidateAndCancel()
        lock.lock()
        _session = nil
        job = nil
        bytesByURL = [:]
        lock.unlock()
        try? fileManager.removeItem(at: jobFileURL)
        emit(.idle)
    }

    /// Hand back the completion handler iOS gives the app when it relaunches to
    /// deliver background events. See the type documentation.
    public func handleEventsForBackgroundURLSession(
        identifier: String,
        completionHandler: @escaping @Sendable () -> Void
    ) {
        guard identifier == Self.sessionIdentifier else { return }
        lock.lock()
        systemCompletionHandler = completionHandler
        lock.unlock()
        // Touch the session so it reconnects to the system's tasks.
        _ = session
    }

    // MARK: - Planning

    static func companionRepositories(for descriptor: TTSModelDescriptor) -> [String] {
        TTSModelRegistry.companionRepositories(
            modelType: descriptor.metadata?.modelType,
            architectures: descriptor.metadata?.architectures ?? [],
            repo: descriptor.id
        )
    }

    /// Destination directory a repository's files must land in for the runtime
    /// loader to treat it as already downloaded.
    static func destinationDirectory(for repository: String) -> URL {
        HubCache.default.cacheDirectory
            .appendingPathComponent("mlx-audio", isDirectory: true)
            .appendingPathComponent(
                repository.replacingOccurrences(of: "/", with: "_"), isDirectory: true
            )
    }

    static func downloadURL(repository: String, filename: String) -> URL? {
        URL(string: "https://huggingface.co/\(repository)/resolve/main/\(filename)")
    }

    /// Files worth fetching. Mirrors the runtime's own download globs plus
    /// `*.model`, which is how SentencePiece tokenizers arrive.
    static func isWanted(_ filename: String) -> Bool {
        guard !filename.hasPrefix("."), !filename.contains("/") else { return false }
        let wanted = ["safetensors", "json", "txt", "wav", "model"]
        return wanted.contains((filename as NSString).pathExtension.lowercased())
    }

    private func planFiles(for repository: String, hfToken: String?) async throws -> [PlannedFile] {
        guard let url = URL(string: "https://huggingface.co/api/models/\(repository)") else {
            throw DownloadError.noFilesFound(repository)
        }
        var request = URLRequest(url: url)
        if let hfToken, !hfToken.isEmpty {
            request.setValue("Bearer \(hfToken)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        do {
            (data, _) = try await metadataSession.data(for: request)
        } catch {
            throw DownloadError.metadataUnavailable(repository, underlying: error.localizedDescription)
        }

        struct RepoInfo: Decodable {
            struct Sibling: Decodable { let rfilename: String }
            let siblings: [Sibling]?
        }
        let info: RepoInfo
        do {
            info = try JSONDecoder().decode(RepoInfo.self, from: data)
        } catch {
            throw DownloadError.metadataUnavailable(repository, underlying: error.localizedDescription)
        }

        let directory = Self.destinationDirectory(for: repository)
        let names = (info.siblings ?? []).map(\.rfilename).filter(Self.isWanted)
        guard !names.isEmpty else { throw DownloadError.noFilesFound(repository) }

        // Sizes come from a HEAD per file. These are cheap next to the payload
        // and give byte-accurate progress; a failure just means this file
        // contributes to the file-count fraction instead.
        return await withTaskGroup(of: PlannedFile?.self) { group in
            for name in names {
                guard let remote = Self.downloadURL(repository: repository, filename: name) else { continue }
                let destination = directory.appendingPathComponent(name)
                group.addTask { [metadataSession] in
                    var head = URLRequest(url: remote)
                    head.httpMethod = "HEAD"
                    if let hfToken, !hfToken.isEmpty {
                        head.setValue("Bearer \(hfToken)", forHTTPHeaderField: "Authorization")
                    }
                    let length: Int64
                    if let (_, response) = try? await metadataSession.data(for: head),
                       let http = response as? HTTPURLResponse {
                        length = max(0, http.expectedContentLength)
                    } else {
                        length = 0
                    }
                    return PlannedFile(remoteURL: remote, destination: destination, expectedBytes: length)
                }
            }
            var planned: [PlannedFile] = []
            for await file in group {
                if let file { planned.append(file) }
            }
            return planned
        }
    }

    private func isAlreadyDownloaded(_ file: PlannedFile) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: file.destination.path),
              let size = attributes[.size] as? Int64 else { return false }
        // With no expected size, presence is the best signal available.
        return file.expectedBytes > 0 ? size == file.expectedBytes : size > 0
    }

    // MARK: - Persistence

    private static func loadJob(at url: URL, fileManager: FileManager) -> Job? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Job.self, from: data)
    }

    private func persist(_ job: Job) {
        guard let data = try? JSONEncoder().encode(job) else { return }
        try? data.write(to: jobFileURL, options: .atomic)
    }

    /// Space the volume will give us, as iOS reports it for "important"
    /// downloads — this accounts for purgeable content, unlike
    /// `volumeAvailableCapacity`, and so reflects what the app can actually
    /// use.
    static func availableCapacityBytes(
        at url: URL = URL(fileURLWithPath: NSHomeDirectory())
    ) -> Int64? {
        guard let values = try? url.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ) else { return nil }
        return values.volumeAvailableCapacityForImportantUsage
    }

    /// Stable filename for a URL's resume blob. Hashing keeps it filesystem
    /// safe and bounded regardless of how long the URL is.
    private func resumeFileURL(for remote: URL) -> URL {
        var hash: UInt64 = 5381
        for byte in Array(remote.absoluteString.utf8) {
            hash = (hash &* 33) ^ UInt64(byte)
        }
        return resumeDirectory.appendingPathComponent(String(hash, radix: 16) + ".resume")
    }

    private func loadResumeData(for remote: URL) -> Data? {
        let url = resumeFileURL(for: remote)
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return data
    }

    private func storeResumeData(_ data: Data, for remote: URL) {
        try? data.write(to: resumeFileURL(for: remote), options: .atomic)
    }

    private func clearResumeData(for remote: URL) {
        try? fileManager.removeItem(at: resumeFileURL(for: remote))
    }

    // Test seams for the resume-blob store; the storage itself is private
    // because callers have no reason to touch it.
    func resumeDataForTesting(_ remote: URL) -> Data? { loadResumeData(for: remote) }
    func storeResumeDataForTesting(_ data: Data, for remote: URL) { storeResumeData(data, for: remote) }
    func clearResumeDataForTesting(_ remote: URL) { clearResumeData(for: remote) }

    private func progressSnapshot(for job: Job) -> Progress {
        lock.lock()
        let counted = bytesByURL
        lock.unlock()
        let completedBytes = counted.values.reduce(0, +)
        let totalBytes = job.files.map(\.expectedBytes).reduce(0, +)
        return Progress(
            modelID: job.modelID,
            completedBytes: completedBytes,
            totalBytes: totalBytes,
            filesCompleted: job.completedURLs.count,
            filesTotal: job.files.count
        )
    }
}

// MARK: - URLSessionDownloadDelegate

extension TTSBackgroundModelDownloader: URLSessionDownloadDelegate {

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let remote = downloadTask.originalRequest?.url else { return }

        lock.lock()
        let plan = job?.files.first(where: { $0.remoteURL == remote })
        lock.unlock()
        guard let plan else { return }

        // Must move synchronously: the temporary file is deleted as soon as
        // this delegate call returns.
        do {
            try fileManager.createDirectory(
                at: plan.destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if fileManager.fileExists(atPath: plan.destination.path) {
                try fileManager.removeItem(at: plan.destination)
            }
            try fileManager.moveItem(at: location, to: plan.destination)
        } catch {
            let modelID = lock.withLock { job?.modelID } ?? plan.destination.lastPathComponent
            emit(.failed(
                modelID: modelID,
                message: "Could not save \(plan.destination.lastPathComponent): \(error.localizedDescription)"
            ))
            return
        }

        clearResumeData(for: remote)

        lock.lock()
        job?.completedURLs.insert(remote)
        bytesByURL[remote] = plan.expectedBytes > 0 ? plan.expectedBytes : (bytesByURL[remote] ?? 0)
        let snapshot = job
        lock.unlock()

        guard let snapshot else { return }
        persist(snapshot)
        if snapshot.isComplete {
            emit(.finished(modelID: snapshot.modelID))
        } else {
            emit(.downloading(progressSnapshot(for: snapshot)))
        }
    }

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let remote = downloadTask.originalRequest?.url else { return }
        lock.lock()
        bytesByURL[remote] = totalBytesWritten
        let snapshot = job
        lock.unlock()
        guard let snapshot, !snapshot.isComplete else { return }
        emit(.downloading(progressSnapshot(for: snapshot)))
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        let nsError = error as NSError
        guard let remote = task.originalRequest?.url else { return }

        // iOS hands back resume data whenever a download stops part-way —
        // including when it cancels transfers because the user force-quit the
        // app. Persisting it here is what makes the next launch continue from
        // the bytes already fetched instead of starting over.
        if let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            storeResumeData(resumeData, for: remote)
        }

        // A user-initiated cancel is deliberate, not a failure to report.
        if nsError.code == NSURLErrorCancelled { return }

        // Stale resume data is the common recoverable failure: the partial file
        // was purged, so start this one over rather than failing the job.
        if nsError.code == NSURLErrorCannotOpenFile || nsError.code == NSURLErrorFileDoesNotExist {
            clearResumeData(for: remote)
            session.downloadTask(with: URLRequest(url: remote)).resume()
            return
        }

        let modelID = lock.withLock { job?.modelID } ?? "unknown"
        emit(.failed(modelID: modelID, message: error.localizedDescription))
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.lock()
        let handler = systemCompletionHandler
        systemCompletionHandler = nil
        lock.unlock()
        guard let handler else { return }
        DispatchQueue.main.async { handler() }
    }
}
