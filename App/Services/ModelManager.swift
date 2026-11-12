import Foundation
import PocketMindCore

/// Installs, verifies and removes AI models.
///
/// This file contains the app's ONLY networking code. A download happens solely when the
/// user taps "Download" for a specific model and confirms the size and host. Every
/// request is restricted to the model host, uses an ephemeral session with no cookies or
/// cache, and is written to the on-device network log shown in the privacy dashboard.
@MainActor
final class ModelManager: NSObject, ObservableObject {
    enum InstallState: Equatable {
        case notInstalled
        case downloading(progress: Double)
        case verifying
        case installed
        case failed(String)
    }

    @Published private(set) var states: [String: InstallState] = [:]

    private let directory: URL
    private let store: Store
    private let settings: AppSettings
    private let freeDiskSpace: () -> Int64
    private var tasks: [String: URLSessionDownloadTask] = [:]
    private var sessions: [String: URLSession] = [:]

    init(directory: URL, store: Store, settings: AppSettings, freeDiskSpace: @escaping () -> Int64) {
        self.directory = directory
        self.store = store
        self.settings = settings
        self.freeDiskSpace = freeDiskSpace
        super.init()
        refresh()
    }

    // MARK: State

    func fileURL(for model: ModelDescriptor) -> URL { directory.appendingPathComponent(model.fileName) }

    func isInstalled(_ model: ModelDescriptor) -> Bool {
        // A file only gets its final name after its checksum has been verified.
        FileManager.default.fileExists(atPath: fileURL(for: model).path)
    }

    func state(of model: ModelDescriptor) -> InstallState { states[model.id] ?? .notInstalled }

    func refresh() {
        for model in ModelCatalog.all {
            if case .downloading = states[model.id] { continue }
            if case .verifying = states[model.id] { continue }
            if isInstalled(model) {
                states[model.id] = .installed
            } else if case .failed = states[model.id] {
                continue
            } else {
                states[model.id] = .notInstalled
            }
        }
        // Keep the selections pointing at something that exists.
        if activeWhisperModel == nil { settings.whisperModelID = ModelCatalog.whisper.first(where: isInstalled)?.id ?? "" }
        if activeLanguageModel == nil { settings.languageModelID = ModelCatalog.languageModels.first(where: isInstalled)?.id ?? "" }
    }

    var installedBytes: Int64 { Vault.directorySize(directory) }

    var activeWhisperModel: ModelDescriptor? {
        ModelCatalog.whisper.first { $0.id == settings.whisperModelID && isInstalled($0) }
    }

    var activeLanguageModel: ModelDescriptor? {
        ModelCatalog.languageModels.first { $0.id == settings.languageModelID && isInstalled($0) }
    }

    func compatibility(of model: ModelDescriptor) -> ModelCompatibility {
        ModelCatalog.compatibility(of: model, physicalMemory: ProcessInfo.processInfo.physicalMemory,
                                   freeDisk: freeDiskSpace(), isInstalled: isInstalled(model))
    }

    // MARK: Download

    /// Starts a download. Call only after the user has confirmed it.
    func download(_ model: ModelDescriptor) {
        guard tasks[model.id] == nil, !isInstalled(model) else { return }
        guard compatibility(of: model).isInstallable else {
            states[model.id] = .failed("This model is not compatible with this device.")
            return
        }
        guard model.url.scheme == "https", ModelCatalog.isAllowedHost(model.url.host) else {
            states[model.id] = .failed("The download address is not on the allowed host list.")
            return
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.allowsCellularAccess = !settings.wifiOnlyDownloads
        configuration.allowsExpensiveNetworkAccess = !settings.wifiOnlyDownloads
        configuration.waitsForConnectivity = false
        configuration.httpAdditionalHeaders = ["User-Agent": "PocketMind"]

        let delegate = DownloadDelegate(modelID: model.id, owner: self)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        var request = URLRequest(url: model.url)
        request.httpMethod = "GET"
        let task = session.downloadTask(with: request)
        tasks[model.id] = task
        sessions[model.id] = session
        states[model.id] = .downloading(progress: 0)
        logNetwork(host: model.url.host ?? "unknown", purpose: "Started download of \(model.name)", bytes: 0)
        task.resume()
    }

    func cancelDownload(_ model: ModelDescriptor) {
        tasks[model.id]?.cancel()
        cleanUp(modelID: model.id)
        states[model.id] = .notInstalled
    }

    func delete(_ model: ModelDescriptor) {
        try? FileManager.default.removeItem(at: fileURL(for: model))
        states[model.id] = .notInstalled
        refresh()
    }

    private func cleanUp(modelID: String) {
        tasks[modelID] = nil
        sessions[modelID]?.finishTasksAndInvalidate()
        sessions[modelID] = nil
    }

    private func logNetwork(host: String, purpose: String, bytes: Int64) {
        try? store.logNetwork(host: host, purpose: purpose, bytes: bytes)
    }

    // MARK: Delegate callbacks (hopped to the main actor)

    fileprivate func downloadProgressed(modelID: String, fraction: Double) {
        guard tasks[modelID] != nil else { return }
        states[modelID] = .downloading(progress: fraction)
    }

    fileprivate func redirected(modelID: String, host: String, allowed: Bool) {
        logNetwork(host: host, purpose: allowed ? "Redirected to model file host" : "Blocked redirect to a host that is not allowed", bytes: 0)
    }

    fileprivate func downloadFailed(modelID: String, message: String) {
        guard tasks[modelID] != nil else { return } // cancelled by the user
        cleanUp(modelID: modelID)
        states[modelID] = .failed(message)
    }

    /// `staged` is the downloaded file, already moved into the models directory under a
    /// temporary name. It becomes usable only if its SHA-256 matches the catalog.
    fileprivate func downloadFinished(modelID: String, staged: URL, bytes: Int64, host: String) {
        cleanUp(modelID: modelID)
        guard let model = ModelCatalog.descriptor(id: modelID) else {
            try? FileManager.default.removeItem(at: staged)
            return
        }
        logNetwork(host: host, purpose: "Downloaded \(model.name)", bytes: bytes)
        states[modelID] = .verifying
        let destination = fileURL(for: model)
        Task {
            let result = await Task.detached(priority: .utility) { () -> Result<Void, Error> in
                do {
                    let digest = try Checksum.sha256Hex(of: staged)
                    guard digest == model.sha256 else {
                        try? FileManager.default.removeItem(at: staged)
                        return .failure(EngineError.modelLoadFailed(
                            "The downloaded file failed its integrity check and was deleted."))
                    }
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.moveItem(at: staged, to: destination)
                    return .success(())
                } catch {
                    try? FileManager.default.removeItem(at: staged)
                    return .failure(error)
                }
            }.value
            switch result {
            case .success:
                self.states[modelID] = .installed
                self.refresh()
            case .failure(let error):
                self.states[modelID] = .failed(error.localizedDescription)
            }
        }
    }

    fileprivate var stagingDirectory: URL { directory }
}

/// URLSession delegate for one model download. It refuses redirects to hosts outside the
/// allow list, reports progress, and moves the finished file out of the system's
/// temporary location before the callback returns.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let modelID: String
    private weak var owner: ModelManager?
    private let stagingDirectory: URL
    private var finished = false

    @MainActor
    init(modelID: String, owner: ModelManager) {
        self.modelID = modelID
        self.owner = owner
        self.stagingDirectory = owner.stagingDirectory
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let host = request.url?.host ?? "unknown"
        let allowed = request.url?.scheme == "https" && ModelCatalog.isAllowedHost(request.url?.host)
        let modelID = self.modelID
        Task { @MainActor [weak owner] in owner?.redirected(modelID: modelID, host: host, allowed: allowed) }
        completionHandler(allowed ? request : nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let expected = totalBytesExpectedToWrite > 0
            ? totalBytesExpectedToWrite
            : (ModelCatalog.descriptor(id: modelID)?.sizeBytes ?? 1)
        let fraction = min(1, Double(totalBytesWritten) / Double(max(1, expected)))
        let modelID = self.modelID
        Task { @MainActor [weak owner] in owner?.downloadProgressed(modelID: modelID, fraction: fraction) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let modelID = self.modelID
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            finished = true
            Task { @MainActor [weak owner] in
                owner?.downloadFailed(modelID: modelID, message: "The server answered with status \(status).")
            }
            return
        }
        // The file at `location` is deleted when this method returns, so move it now.
        let staged = stagingDirectory.appendingPathComponent(modelID + ".download")
        do {
            try? FileManager.default.removeItem(at: staged)
            try FileManager.default.moveItem(at: location, to: staged)
            let bytes = (try? FileManager.default.attributesOfItem(atPath: staged.path)[.size] as? NSNumber)?.int64Value ?? 0
            let host = downloadTask.response?.url?.host ?? "unknown"
            finished = true
            Task { @MainActor [weak owner] in
                owner?.downloadFinished(modelID: modelID, staged: staged, bytes: bytes, host: host)
            }
        } catch {
            finished = true
            let message = error.localizedDescription
            Task { @MainActor [weak owner] in owner?.downloadFailed(modelID: modelID, message: message) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, !finished else { return }
        if (error as NSError).code == NSURLErrorCancelled { return }
        let modelID = self.modelID
        let message = error.localizedDescription
        Task { @MainActor [weak owner] in owner?.downloadFailed(modelID: modelID, message: message) }
    }
}
