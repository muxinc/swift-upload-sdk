//
//  FileWorker.swift
//  Mux Upload SDK
//
//  Created by Emily Dixon on 2/14/23.
//

import Foundation

/// Uploads a single chunk. Starts an internal Task on creation,
/// which can be accessed with ``makeUploadTaskIfNeeded``.
///
/// This class takes care of retries and backoff on a per-chunk basis
/// This class provides no thread safety to the outside world
class ChunkWorker {
    let uploadURL: URL
    let maxRetries: Int
    let chunkProgress: Progress
    
    private let chunkStartTime = Date().timeIntervalSince1970
    private let progressLock = NSLock()
    private var lastSeenUpdate: Update = Update(progress: Progress(totalUnitCount: 10), bytesSinceLastUpdate: 0, chunkStartTime: 0, eventTime: 0)
    private var progressDelegate: ProgressHandler?
    
    private var uploadTask: Task<Success, Error>?
    private lazy var urlSession: URLSession = {
        URLSession(
            configuration: .default,
            delegate: makeProgressReportingTaskDelegate(),
            delegateQueue: .main
        )
    }()
    
    func addDelegate(_ delegatePair: @escaping ProgressHandler) {
        self.progressDelegate = delegatePair
    }
    
    func makeUploadTaskIfNeeded(
        chunk: FileChunk
    ) -> Task<Success, Error> {
        guard let uploadTask else {
            let uploadTask = makeUploadTask(chunk: chunk)
            self.uploadTask = uploadTask
            return uploadTask
        }
        
        return uploadTask
    }
    
    func cancel() {
        if let uploadTask = uploadTask {
            uploadTask.cancel()
        }
    }
    
    func directUpload(
        chunk: FileChunk
    ) async throws -> Sendable {
        var attempts = 0
        var requestError: Error?
        repeat {
            try Task.checkCancellation()
            attempts += 1
            var delay = min(pow(2, Double(attempts - 1)) * 0.25, 5)
            do {
                let actor = ChunkActor(uploadURL: uploadURL, chunk: chunk,
                    chunkStartTime: chunkStartTime, urlSession: urlSession)
                let response = try await actor.upload() as! HTTPURLResponse
                switch ChunkResponseValidator().validate(statusCode: response.statusCode) {
                case .proceed:
                    let complete = [200, 201].contains(response.statusCode)
                    let next: UInt64
                    if complete { next = chunk.totalFileSize }
                    else if let range = response.value(forHTTPHeaderField: "Range") {
                        let parts = range.replacingOccurrences(of: "bytes=", with: "").split(separator: "-")
                        guard parts.count == 2, parts[0] == "0", let end = UInt64(parts[1]),
                              end < chunk.totalFileSize else { throw UploadRecoveryError.invalidAcknowledgement }
                        next = end + 1
                    } else { next = 0 }
                    return Success(finalState: progressSnapshot(), tries: attempts,
                                   nextByte: next, isComplete: complete)
                case .retry:
                    requestError = HttpError(statusCode: response.statusCode, statusMsg: "Upload temporarily unavailable")
                    if let value = response.value(forHTTPHeaderField: "Retry-After"), let seconds = Double(value), seconds.isFinite, seconds >= 0 {
                        delay = min(max(seconds, delay), 60)
                    }
                case .error:
                    throw HttpError(statusCode: response.statusCode, statusMsg: "Upload request rejected")
                }
            } catch {
                if Task.isCancelled || error.isCancellation { throw CancellationError() }
                if error.uploadRequiresNewURL { throw ChunkWorkerError(lastSeenProgress: progressSnapshot(), reason: error) }
                requestError = error
            }
            if attempts < max(1, maxRetries) {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        } while attempts < max(1, maxRetries)
        throw ChunkWorkerError(lastSeenProgress: progressSnapshot(), reason: requestError)
    }

    private func progressSnapshot() -> Update {
        progressLock.withLock {
            let progress = Progress(totalUnitCount: lastSeenUpdate.progress.totalUnitCount)
            progress.completedUnitCount = lastSeenUpdate.progress.completedUnitCount
            return Update(progress: progress, bytesSinceLastUpdate: lastSeenUpdate.bytesSinceLastUpdate,
                          chunkStartTime: lastSeenUpdate.chunkStartTime, eventTime: lastSeenUpdate.eventTime)
        }
    }

    private func makeUploadTask(
        chunk: FileChunk
    ) -> Task<Success, Error> {
        return Task { [self] in
            return try await self.directUpload(chunk: chunk) as! ChunkWorker.Success
        }
    }
    
    
    /// This delegate is expected to be called on the main dispatch queue
    private func makeProgressReportingTaskDelegate() -> ProgressReportingURLSessionTaskDelegate {
        return ProgressReportingURLSessionTaskDelegate(forURL: uploadURL) { [self] bytesSent, uploadedBytes, totalBytes in
            let progress = chunkProgress
            progress.completedUnitCount = uploadedBytes
            progress.totalUnitCount = Int64(totalBytes)
            
            let update = Update(
                progress: progress,
                bytesSinceLastUpdate: bytesSent,
                chunkStartTime: chunkStartTime,
                eventTime: Date().timeIntervalSince1970
            )
            progressLock.withLock { lastSeenUpdate = update }
            if let delegate = progressDelegate {
                delegate(update)
            }
        }
    }
    
    typealias ProgressHandler = (Update) -> Void
    
    struct ChunkWorkerError : Error {
        let lastSeenProgress: Update
        let reason: Error?
        
        var localizedDescription: String {
            return "Failed to upload chunk because of:\n\t\(String(describing: reason?.localizedDescription))"
        }
    }
    
    struct Update : Sendable {
        let progress: Foundation.Progress
        let bytesSinceLastUpdate: Int64
        let chunkStartTime: TimeInterval
        let eventTime: TimeInterval
    }
    
    struct Success : Sendable {
        let finalState: Update
        let tries: Int
        let nextByte: UInt64
        let isComplete: Bool
    }
    
    convenience init(
        uploadInfo: UploadInfo,
        chunkProgress: Progress
    ) {
        self.init(
            uploadURL: uploadInfo.uploadURL,
            chunkProgress: chunkProgress,
            maxRetries: uploadInfo.options.transport.retryLimitPerChunk
        )
    }
    
    init(
        uploadURL: URL,
        chunkProgress: Progress,
        maxRetries: Int
    ) {
        self.uploadURL = uploadURL
        self.maxRetries = maxRetries
        self.chunkProgress = chunkProgress
    }
}

/// Uploads a specific chunk to the given URL
/// Just like with ChunkWorker, this is a single-use object.
fileprivate actor ChunkActor {
    let uploadURL: URL
    let chunk: FileChunk
    let chunkStartTime: TimeInterval
    let urlSession: URLSession
    
    func upload() async throws -> URLResponse {
        let startByte = "\(chunk.startByte)"
        let endByte: String
        if chunk.endByte == 0 {
            endByte = "0"
        } else {
            endByte = "\(chunk.endByte - 1)"
        }
        
        let contentRangeValue = chunk.chunkData.isEmpty
            ? "bytes */\(chunk.totalFileSize)"
            : "bytes \(startByte)-\(endByte)/\(chunk.totalFileSize)"
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "PUT"
        request.setValue("video/*", forHTTPHeaderField: "Content-Type")
        request.setValue(contentRangeValue, forHTTPHeaderField: "Content-Range")
        
        let (_, response) = try await urlSession.upload(for: request, from: chunk.chunkData)
        return response
    }
    
    init(uploadURL: URL, chunk: FileChunk, chunkStartTime: TimeInterval, urlSession: URLSession) {
        self.uploadURL = uploadURL
        self.chunk = chunk
        self.chunkStartTime = chunkStartTime
        self.urlSession = urlSession
    }
}

fileprivate class ProgressReportingURLSessionTaskDelegate : NSObject, URLSessionDataDelegate {
    let outerDelegate: ProgressReportHandler
    let forURL: URL
    
    init(forURL: URL, reportingTo: @escaping ProgressReportHandler) {
        self.outerDelegate = reportingTo
        self.forURL = forURL
    }
    
    typealias ProgressReportHandler = (Int64, Int64, Int64) -> Void
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        if task.currentRequest?.url == forURL {
            outerDelegate(bytesSent, totalBytesSent, totalBytesExpectedToSend)
        }
    }
}

class ChunkResponseValidator {
    static let acceptableHTTPStatusCodes = [200, 201, 202, 204, 308]
    static let retryableHTTPStatusCodes = [408, 429, 500, 502, 503, 504]
    
    func validate(statusCode: Int) -> Disposition {
        if ChunkResponseValidator.acceptableHTTPStatusCodes.contains(statusCode) {
            return .proceed
        } else if ChunkResponseValidator.retryableHTTPStatusCodes.contains(statusCode) {
            return .retry
        } else {
            return .error
        }
    }
    
    enum Disposition {
        case retry, proceed, error
    }
}
