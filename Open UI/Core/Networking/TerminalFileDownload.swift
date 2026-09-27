import Foundation
import CryptoKit
import os

nonisolated enum TerminalFileError: LocalizedError {
    case tooLarge, busy, unavailable(Int), changedAccount
    var errorDescription: String? {
        switch self {
        case .tooLarge: return "This file exceeds the 256 MB download limit. Open it in the web app instead."
        case .busy: return "Two files are already downloading. Wait for one to finish and try again."
        case .changedAccount: return "Your connection changed. Open this chat again before loading the file."
        case .unavailable(let status):
            switch status {
            case 401, 403: return "You no longer have access to this file. Check your sign-in and terminal permissions."
            case 404: return "The file or terminal is no longer available."
            case 409: return "This terminal needs the original saved chat session."
            default: return "The terminal could not provide the file (HTTP \(status)). Try again when it is connected."
            }
        }
    }
}

/// The cache and any active viewer share ownership; eviction never removes a
/// file from under Quick Look or the system share sheet.
nonisolated final class DownloadedTerminalFile: Sendable {
    let url: URL
    let byteCount: Int64
    init(url: URL, byteCount: Int64) { self.url = url; self.byteCount = byteCount }
    deinit { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
}

/// Ephemeral, account-scoped cache. No work is scheduled until an explicit action.
actor TerminalFileDownloads {
    static let shared = TerminalFileDownloads()
    nonisolated static let maximumFileBytes: Int64 = 256 * 1024 * 1024
    private struct Entry { let file: DownloadedTerminalFile; var accessed: Date }
    private var entries: [String: Entry] = [:]
    private var active = Set<String>()
    private let directory: URL

    init(directory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("TerminalAttachments", isDirectory: true)) {
        self.directory = directory
        // These files are temporary and never restored across launches.
        try? FileManager.default.removeItem(at: directory)
    }

    func file(request: URLRequest, session: URLSession, scope: String, identity: String, name: String,
              progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> DownloadedTerminalFile {
        try Task.checkCancellation()
        let key = SHA256.hash(data: Data((scope + "\0" + identity).utf8)).map { String(format: "%02x", $0) }.joined()
        let now = Date()
        entries = entries.filter { now.timeIntervalSince($0.value.accessed) < 600 }
        if var entry = entries[key] {
            entry.accessed = now
            entries[key] = entry
            return entry.file
        }
        guard active.count < 2, active.insert(key).inserted else { throw TerminalFileError.busy }
        defer { active.remove(key) }
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(name)
        let bytes: Int64
        do {
            try await TerminalDownloadTransfer.download(request: request, session: session, destination: destination, progress: progress)
            try Task.checkCancellation()
            bytes = Int64(try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            guard bytes <= Self.maximumFileBytes else { throw TerminalFileError.tooLarge }
        }
        catch { try? FileManager.default.removeItem(at: folder); throw error }
        let file = DownloadedTerminalFile(url: destination, byteCount: bytes)
        entries[key] = Entry(file: file, accessed: now)
        // Cache at most 512 MB; in-flight transfers are limited to two 256 MB files.
        while entries.values.reduce(Int64(0), { $0 + $1.file.byteCount }) > 512 * 1024 * 1024,
              let oldest = entries.min(by: { $0.value.accessed < $1.value.accessed })?.key {
            entries.removeValue(forKey: oldest)
        }
        return file
    }
}

/// A delegate-based download delivers progress (the async convenience method's
/// per-task delegate does not). Each transfer has a serial delegate queue.
nonisolated private final class TerminalDownloadTransfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    struct Control { var cancelled = false; var task: URLSessionTask? }
    let control: OSAllocatedUnfairLock<Control>
    let destination: URL
    let authenticationDelegate: (any URLSessionDelegate)?
    let progress: @Sendable (Int64, Int64) -> Void
    let completion: @Sendable (Result<Void, Error>) -> Void
    private var failure: Error?
    private var lastProgress = Date.distantPast

    init(control: OSAllocatedUnfairLock<Control>, destination: URL, authenticationDelegate: (any URLSessionDelegate)?,
         progress: @escaping @Sendable (Int64, Int64) -> Void, completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        self.control = control
        self.destination = destination
        self.authenticationDelegate = authenticationDelegate
        self.progress = progress
        self.completion = completion
    }

    static func download(request: URLRequest, session: URLSession, destination: URL,
                         progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        let control = OSAllocatedUnfairLock(initialState: Control())
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let delegate = TerminalDownloadTransfer(control: control, destination: destination,
                    authenticationDelegate: session.delegate, progress: progress) { continuation.resume(with: $0) }
                let transferSession = URLSession(configuration: session.configuration, delegate: delegate, delegateQueue: nil)
                let task = transferSession.downloadTask(with: request)
                let cancelled = control.withLock { $0.task = task; return $0.cancelled }
                task.resume()
                if cancelled { task.cancel() }
            }
        } onCancel: {
            control.withLock { $0.cancelled = true; $0.task?.cancel() }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { failure = TerminalFileError.unavailable(status); return }
        do { try FileManager.default.moveItem(at: location, to: destination) }
        catch { failure = error }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        control.withLock { $0.task = nil }
        session.finishTasksAndInvalidate()
        if let error = failure ?? error { completion(.failure(error)) }
        else { completion(.success(())) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if max(totalBytesWritten, totalBytesExpectedToWrite) > TerminalFileDownloads.maximumFileBytes {
            failure = TerminalFileError.tooLarge
            downloadTask.cancel()
        }
        let now = Date()
        if now.timeIntervalSince(lastProgress) >= 0.1 || totalBytesWritten == totalBytesExpectedToWrite {
            lastProgress = now
            progress(totalBytesWritten, totalBytesExpectedToWrite)
        }
    }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let authenticate = authenticationDelegate?.urlSession(_:didReceive:completionHandler:) {
            authenticate(session, challenge, completionHandler)
        } else { completionHandler(.performDefaultHandling, nil) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // A file download must not send credentials/custom headers to a redirect target.
        completionHandler(nil)
    }
}

extension APIClient {
    func downloadTerminalAttachment(_ file: TerminalFileAttachment, messageId: String, scope: String,
                                    progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> DownloadedTerminalFile {
        guard network.conversationCacheScope == scope else { throw TerminalFileError.changedAccount }
        var request = try network.buildRequest(
            path: "/api/v1/terminals/\(file.serverId)/files/view",
            queryItems: [URLQueryItem(name: "path", value: file.path)], timeout: 300
        )
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue(file.sessionId, forHTTPHeaderField: "X-Session-Id")
        let result = try await TerminalFileDownloads.shared.file(
            request: request, session: network.session, scope: scope,
            identity: messageId + "\0" + file.id, name: file.name, progress: progress
        )
        guard network.conversationCacheScope == scope else { throw TerminalFileError.changedAccount }
        return result
    }
}
