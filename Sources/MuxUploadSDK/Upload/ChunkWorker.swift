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
    
    private var chunkStartTime: TimeInterval? = nil
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
            chunkStartTime = Date().timeIntervalSince1970
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
    
    private func makeUploadTask(
        chunk: FileChunk
    ) -> Task<Success, Error> {
        return Task { [self] in
            var retries = 0
            var requestError: Error?
            let repsonseValidator = ChunkResponseValidator()

            repeat {
                do {
                    let chunkActor = ChunkActor(
                        uploadURL: uploadURL,
                        chunk: chunk,
                        chunkStartTime: Date().timeIntervalSince1970,
                        urlSession: urlSession
                    )
                    
                    let resp = try await chunkActor.upload()
                    
                    let httpResponse = resp as! HTTPURLResponse
                    SDKLogger.logger?.info("ChunkWorker: Upload chunk with response: \(String(describing: httpResponse.statusCode))")
                    switch repsonseValidator.validate(statusCode: httpResponse.statusCode) {
                    case .error: do {
                        // Throw and break out if the request can't be retried
                        throw HttpError(
                            statusCode: httpResponse.statusCode,
                            statusMsg: httpResponse.description
                        )
                    }
                    case .retry: do {
                        requestError = HttpError(
                            statusCode: httpResponse.statusCode,
                            statusMsg: httpResponse.description
                        )
                        // Retry if there's still some retries
                        continue
                    }
                    case .proceed: do {
                        // Chunk was uploaded successfully so we're done
                        return Success(finalState: lastSeenUpdate, tries: retries + 1)
                    }
                    } // switch responseValidator.validate()
                } catch {
                    SDKLogger.logger?.error("Failed to upload a chunk with error: \(error.localizedDescription)")
                    retries += 1
                    requestError = error
                }
            } while(retries < maxRetries)
            
            // Out of retries. Notify failure
            throw ChunkWorkerError(lastSeenProgress: lastSeenUpdate, reason: requestError)
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
                chunkStartTime: chunkStartTime ?? 0,
                eventTime: Date().timeIntervalSince1970
            )
            lastSeenUpdate = update
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

        let contentRangeValue = "bytes \(startByte)-\(endByte)/\(chunk.totalFileSize)"
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
    static let retryableHTTPStatusCodes = [408, 502, 503, 504]
    
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
