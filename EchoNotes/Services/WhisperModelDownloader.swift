import Foundation
import UIKit

/// Downloads the Whisper model's files from Hugging Face over a background
/// `URLSession`, so the download keeps running when the user goes to the home
/// screen — and survives the app being suspended or even relaunched. Every
/// completed file stays on disk, so a retry (or a relaunch mid-download) only
/// fetches what's still missing.
///
/// This replaces WhisperKit's in-process downloader for the initial install:
/// that one's plain URLSession froze together with the app on suspension,
/// which is exactly the "stuck halfway" failure mode. The files come from the
/// same Hugging Face repository WhisperKit would fetch; loading still goes
/// through WhisperKit, pointed at the downloaded folder.
///
/// Flow: fetch the repo's file manifest (paths + sizes) → enqueue one
/// background download task per missing file → move each finished file into
/// place after verifying its size → report byte-accurate overall progress →
/// signal completion once every manifest file is present.
final class WhisperModelDownloader: NSObject, @unchecked Sendable {
    /// One instance per process: a background URLSession identifier must map
    /// to exactly one delegate, including when iOS relaunches the app just to
    /// deliver this session's events.
    static let shared = WhisperModelDownloader()

    // Callbacks are delivered on the main queue.
    var onProgress: ((Double) -> Void)?
    /// The finished model folder (contains config.json + *.mlmodelc).
    var onFinished: ((URL) -> Void)?
    var onFailed: ((String) -> Void)?

    // MARK: - Locations

    static let repo = "argmaxinc/whisperkit-coreml"
    /// Folder inside the repo; also the on-disk folder name under the base.
    static let modelFolderName = "openai_whisper-large-v3-v20240930_626MB"
    /// Fixed download root (shared with EnrichmentModelManager for deletion):
    /// Application Support/WhisperModels/.
    static let downloadBase = URL.applicationSupportDirectory
        .appending(path: "WhisperModels", directoryHint: .isDirectory)

    var modelFolder: URL {
        Self.downloadBase.appending(path: Self.modelFolderName, directoryHint: .isDirectory)
    }

    private var manifestFileURL: URL {
        Self.downloadBase.appending(path: ".download-manifest.json")
    }

    private static let sessionIdentifier = "com.shreyashg.echonotes.whisper-download"

    // MARK: - State (guarded by `lock`)

    private struct FileEntry: Codable {
        /// Path relative to the repo root (starts with the model folder name).
        let path: String
        /// Actual content size in bytes (LFS-resolved).
        let size: Int64
    }

    private let lock = NSLock()
    private var manifest: [FileEntry] = []
    /// Manifest paths not yet verified on disk.
    private var remaining: Set<String> = []
    /// In-flight bytes per URLSession task identifier.
    private var inFlightBytes: [Int: Int64] = [:]
    private var completedBytes: Int64 = 0
    private var totalBytes: Int64 = 0
    private var active = false
    private var failureReported = false
    private var lastReportedPermille = -1

    /// Stored when iOS relaunches the app for this session's events; called
    /// after the final event so the system can snapshot and suspend us again.
    private var backgroundEventsCompletionHandler: (() -> Void)?

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        // Ceiling for one file including connectivity waits; a genuinely
        // stalled transfer errors out instead of hanging forever.
        config.timeoutIntervalForResource = 4 * 60 * 60
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    override private init() {
        super.init()
        // A relaunch mid-download must be able to verify replayed file events
        // against the manifest before anyone calls startOrResume().
        if let data = try? Data(contentsOf: manifestFileURL),
           let stored = try? JSONDecoder().decode([FileEntry].self, from: data) {
            lock.lock()
            adoptManifestLocked(stored)
            lock.unlock()
        }
    }

    // MARK: - Public surface

    var isDownloading: Bool {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    /// A download was started at some point and hasn't finished: there's a
    /// persisted manifest with files still missing. Used to auto-resume.
    var hasPartialDownload: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !manifest.isEmpty else { return false }
        return manifest.contains { entryNeedsDownload($0) }
    }

    /// Fraction downloaded so far (byte-accurate), for seeding the UI when a
    /// resumed download reattaches.
    var currentProgress: Double {
        lock.lock()
        defer { lock.unlock() }
        return progressLocked()
    }

    /// Starts a fresh download, or resumes an interrupted one — only missing
    /// files are fetched, files already on disk are kept. Safe to call while
    /// already running (no-op). Completion/failure arrive via the callbacks.
    func startOrResume() {
        lock.lock()
        if active {
            lock.unlock()
            return
        }
        active = true
        failureReported = false
        lock.unlock()

        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.prepareAndEnqueue()
        }
    }

    /// Cancels any in-flight transfers and forgets the manifest. Partial
    /// files are the caller's to remove (they live under `downloadBase`).
    func reset() {
        lock.lock()
        active = false
        failureReported = false
        manifest = []
        remaining = []
        inFlightBytes = [:]
        completedBytes = 0
        totalBytes = 0
        lastReportedPermille = -1
        lock.unlock()
        try? FileManager.default.removeItem(at: manifestFileURL)
        session.getAllTasks { tasks in
            tasks.forEach { $0.cancel() }
        }
    }

    /// App-delegate entry point for `handleEventsForBackgroundURLSession`.
    /// Recreates the session (which replays pending delegate events) and
    /// stores the completion handler for `urlSessionDidFinishEvents`.
    func handleBackgroundSessionEvents(identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == Self.sessionIdentifier else {
            completionHandler()
            return
        }
        lock.lock()
        backgroundEventsCompletionHandler = completionHandler
        lock.unlock()
        _ = session // force creation so events are delivered
    }

    // MARK: - Setup

    private func prepareAndEnqueue() async {
        // WhisperKit's old downloader left partials in a different layout
        // (WhisperModels/models/…); they'd never be finished, only waste space.
        let legacy = Self.downloadBase.appending(path: "models", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: legacy)

        var files: [FileEntry]
        lock.lock()
        files = manifest
        lock.unlock()

        if files.isEmpty {
            do {
                files = try await fetchManifest()
            } catch {
                fail("Couldn't reach the model server. Check your connection and tap Retry.")
                return
            }
            do {
                try FileManager.default.createDirectory(at: Self.downloadBase, withIntermediateDirectories: true)
                try JSONEncoder().encode(files).write(to: manifestFileURL, options: .atomic)
            } catch {
                fail("Couldn't prepare storage for the model download.")
                return
            }
        }

        lock.lock()
        adoptManifestLocked(files)
        let missing = remaining
        let fraction = progressLocked()
        lock.unlock()

        if missing.isEmpty {
            finishIfComplete()
            return
        }
        dispatchProgress(fraction)

        // Tasks that survived a relaunch keep running; only enqueue files
        // that aren't already in flight.
        let (_, _, downloads) = await session.tasks
        var inFlight: Set<String> = []
        for task in downloads where task.state == .running || task.state == .suspended {
            if let path = task.taskDescription, missing.contains(path) {
                inFlight.insert(path)
                if task.state == .suspended { task.resume() }
            } else {
                task.cancel() // stale task from a superseded manifest
            }
        }

        for path in missing.subtracting(inFlight).sorted() {
            guard let url = resolveURL(for: path) else {
                fail("Couldn't build a download address for \(path).")
                return
            }
            let task = session.downloadTask(with: url)
            task.taskDescription = path
            task.resume()
        }
    }

    /// Recomputes remaining/completed byte counts from the manifest and what
    /// is actually on disk. Caller holds the lock.
    private func adoptManifestLocked(_ files: [FileEntry]) {
        manifest = files
        totalBytes = files.reduce(0) { $0 + $1.size }
        remaining = []
        completedBytes = 0
        for entry in files {
            if entryNeedsDownload(entry) {
                remaining.insert(entry.path)
            } else {
                completedBytes += entry.size
            }
        }
    }

    /// True when the file isn't on disk with exactly the manifest's size.
    private func entryNeedsDownload(_ entry: FileEntry) -> Bool {
        let destination = Self.downloadBase.appending(path: entry.path)
        let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? -1
        return size != entry.size
    }

    // MARK: - Manifest fetch

    /// Lists every file under the model folder via the Hugging Face tree API
    /// (following pagination), with LFS-resolved sizes.
    private func fetchManifest() async throws -> [FileEntry] {
        struct TreeEntry: Decodable {
            let type: String
            let path: String
            let size: Int64?
            let lfs: LFS?
            struct LFS: Decodable { let size: Int64? }
        }

        var entries: [FileEntry] = []
        var next = URL(string: "https://huggingface.co/api/models/\(Self.repo)/tree/main/\(Self.modelFolderName)?recursive=true")
        var pages = 0
        while let url = next, pages < 20 {
            pages += 1
            var request = URLRequest(url: url)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 30
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let page = try JSONDecoder().decode([TreeEntry].self, from: data)
            entries += page
                .filter { $0.type == "file" }
                .map { FileEntry(path: $0.path, size: $0.lfs?.size ?? $0.size ?? 0) }
            next = nextPageURL(from: http)
        }
        guard !entries.isEmpty else { throw URLError(.resourceUnavailable) }
        return entries
    }

    /// RFC 5988 `Link: <url>; rel="next"` pagination header, if present.
    private func nextPageURL(from response: HTTPURLResponse) -> URL? {
        guard let link = response.value(forHTTPHeaderField: "Link") else { return nil }
        for part in link.components(separatedBy: ",") {
            guard part.contains("rel=\"next\""),
                  let start = part.firstIndex(of: "<"),
                  let end = part.firstIndex(of: ">") else { continue }
            let urlString = String(part[part.index(after: start)..<end])
            return URL(string: urlString)
        }
        return nil
    }

    private func resolveURL(for path: String) -> URL? {
        let encoded = path
            .components(separatedBy: "/")
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0 }
            .joined(separator: "/")
        return URL(string: "https://huggingface.co/\(Self.repo)/resolve/main/\(encoded)")
    }

    // MARK: - Progress / terminal states

    /// Caller holds the lock.
    private func progressLocked() -> Double {
        guard totalBytes > 0 else { return 0 }
        let inFlight = inFlightBytes.values.reduce(0, +)
        return min(1, Double(completedBytes + inFlight) / Double(totalBytes))
    }

    private func finishIfComplete() {
        lock.lock()
        let done = remaining.isEmpty && !manifest.isEmpty && !failureReported
        if done { active = false }
        let folder = modelFolder
        lock.unlock()
        guard done else { return }
        try? FileManager.default.removeItem(at: manifestFileURL)
        DispatchQueue.main.async { [weak self] in
            self?.onProgress?(1)
            self?.onFinished?(folder)
        }
    }

    private func fail(_ message: String) {
        lock.lock()
        if failureReported {
            lock.unlock()
            return
        }
        failureReported = true
        active = false
        inFlightBytes = [:]
        lock.unlock()
        // Stop the rest of the fleet; completed files stay for the retry.
        session.getAllTasks { tasks in
            tasks.forEach { $0.cancel() }
        }
        DispatchQueue.main.async { [weak self] in
            self?.onFailed?(message)
        }
    }

    private func dispatchProgress(_ fraction: Double) {
        DispatchQueue.main.async { [weak self] in
            self?.onProgress?(fraction)
        }
    }
}

// MARK: - URLSessionDownloadDelegate

extension WhisperModelDownloader: URLSessionDownloadDelegate {
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        lock.lock()
        inFlightBytes[downloadTask.taskIdentifier] = totalBytesWritten
        let fraction = progressLocked()
        let permille = Int(fraction * 1000)
        let shouldReport = permille != lastReportedPermille
        lastReportedPermille = permille
        lock.unlock()
        if shouldReport { dispatchProgress(fraction) }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let path = downloadTask.taskDescription else { return }

        lock.lock()
        let expectedSize = manifest.first { $0.path == path }?.size
        lock.unlock()
        guard let expectedSize else { return } // stale task from an old manifest

        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        let attributes = try? FileManager.default.attributesOfItem(atPath: location.path)
        let actualSize = (attributes?[.size] as? NSNumber)?.int64Value ?? -1
        guard status == 200, actualSize == expectedSize else {
            fail("A model file didn't download correctly. Tap Retry to continue the download.")
            return
        }

        // The temp file vanishes when this method returns — move it now.
        let destination = Self.downloadBase.appending(path: path)
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            fail("Couldn't save a downloaded model file. Check free storage and tap Retry.")
            return
        }

        lock.lock()
        remaining.remove(path)
        inFlightBytes.removeValue(forKey: downloadTask.taskIdentifier)
        completedBytes += expectedSize
        let allDone = remaining.isEmpty
        lock.unlock()
        if allDone { finishIfComplete() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return } // success is handled in didFinishDownloadingTo
        if (error as NSError).code == NSURLErrorCancelled { return } // our own cancel cascade
        fail("The download was interrupted. Tap Retry to continue where it left off.")
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.lock()
        let handler = backgroundEventsCompletionHandler
        backgroundEventsCompletionHandler = nil
        lock.unlock()
        DispatchQueue.main.async { handler?() }
    }
}
