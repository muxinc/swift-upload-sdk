//
//  ChunkedFileUploader.swift
//  
//
//  Created by Emily Dixon on 2/23/23.
//

import AVFoundation
import Foundation

/// Uploads a file in chunks according to the input configuration. Retries are handled according to the input ``UploadInfo``
/// This object is not externally thread-safe. Access its methods only from the main thread
/// If you need to start this over again from the beginning, make a new object (and cancel your old one)
class ChunkedFileUploader {

    private(set) var currentState: InternalUploadState = .ready
    let uploadInfo: UploadInfo
    let inputFileURL: URL
    private var delegates: [String : ChunkedFileUploaderDelegate] = [:]
    
    private let file: ChunkedFile
    private var currentWorkTask: Task<(), Never>? = nil
    private var overallProgress: Progress = Progress()
    private var lastReadCount: UInt64 = 0
    private let reporter: Reporter
    
    func addDelegate(withToken token: String, _ delegate: ChunkedFileUploaderDelegate) {
        delegates.updateValue(delegate, forKey: token)
    }
    
    func removeDelegate(withToken: String) {
        delegates.removeValue(forKey: withToken)
    }
    
    /// If currently uploading, will pause the upload. If not uploading, this methd has no effect
    func pause() {
        switch currentState {
        case .starting: do {
            currentWorkTask?.cancel()
            currentWorkTask = nil
            notifyStateFromMain(
                .paused(
                    Update(
                        progress: Progress(totalUnitCount: 0),
                        startTime: 0,
                        updateTime: 0
                    )
                )
            )
        }
        case .uploading(let update): do {
            currentWorkTask?.cancel()
            currentWorkTask = nil
            notifyStateFromMain(.paused(update))
        }
        default: do {}
        }
    }
    
    /// Starts the upload if it wasn't already starting
    func start() {
        switch currentState {
        case .ready: fallthrough
        case .paused(_):
            beginUpload()
        default:
            SDKLogger.logger?.info("start() ignored in state \(String(describing: self.currentState))")
        }
    }

    func start(duration: CMTime) {
        switch currentState {
        case .ready: fallthrough
        case .paused(_):
            beginUpload(duration: duration)
        default:
            SDKLogger.logger?.info("start() ignored in state \(String(describing: self.currentState))")
        }
    }
    
    /// Cancels the upload. It can't be restarted
    func cancel() {
        currentWorkTask?.cancel()
        currentWorkTask = nil
        cleanupResources()

        switch currentState {
        case .starting: fallthrough
        case .uploading(_): do {
            notifyStateFromMain(.canceled)
        }
        default: do {}
        }
    }
    
    private func beginUpload() {
        let task = Task.detached { [self] in

            let asset = AVAsset(url: inputFileURL)

            var duration: CMTime

            do {
                if #available(iOS 15, *) {
                    duration = try await asset.load(.duration)
                } else {
                    await asset.loadValues(forKeys: ["duration"])
                    duration = asset.duration
                }
            } catch {
                // Cannot get duration, assume it is zero
                duration = CMTime.zero
            }

            do {
                let fileSize = try FileManager.default.fileSizeOfItem(
                    atPath: inputFileURL.path
                )
                let result = try await makeWorker().performUpload()
                file.close()

                let success = UploadResult(
                    finalProgress: result.progress,
                    startTime: result.startTime,
                    finishTime: result.updateTime
                )

                reporter.reportUploadSuccess(
                    inputDuration: duration.seconds,
                    inputSize: fileSize,
                    options: uploadInfo.options,
                    uploadEndTime: Date(
                        timeIntervalSince1970: success.finishTime
                    ),
                    uploadStartTime: Date(
                        timeIntervalSince1970: success.startTime
                    ),
                    uploadURL: uploadInfo.uploadURL
                )
                notifyStateFromWorker(.success(success))
            } catch {
                handle(
                    error: error,
                    duration: duration
                )
            }
        }
        currentWorkTask = task
    }

    private func handle(
        error: Error,
        duration: CMTime
    ) {
        file.close()
        if error is CancellationError {
            SDKLogger.logger?.debug("Task finished due to cancellation in state \(String(describing: self.currentState))")
            if case let .uploading(update) = self.currentState {
                self.currentState = .paused(update)
            }
        } else {
            SDKLogger.logger?.debug("Task finished due to error in state \(String(describing: self.currentState))")
            let uploadError = InternalUploaderError(reason: error, lastByte: lastReadCount)

            let lastUpdate: Update?
            if case InternalUploadState.uploading(let update) = currentState {
                lastUpdate = update
            } else {
                lastUpdate = nil
            }

            // This modifies currentState, so capture
            // the last update first
            notifyStateFromWorker(.failure(uploadError))

            // FIXME: Will only work if currentState
            // was uploading before the upload failed
            // may miss some edge cases
            if let lastUpdate {
                let fileSize = (try? FileManager.default.fileSizeOfItem(atPath: inputFileURL.path)) ?? 0

                let startTime = Date(
                    timeIntervalSince1970: lastUpdate.startTime
                )
                // When failing assume transport ends
                // when error is received
                let endTime = Date()

                reporter.reportUploadFailure(
                    errorDescription: uploadError.localizedDescription,
                    inputDuration: duration.seconds,
                    inputSize: fileSize,
                    options: uploadInfo.options,
                    uploadEndTime: endTime,
                    uploadStartTime: startTime,
                    uploadURL: uploadInfo.uploadURL
                )
            }
        }
    }

    private func beginUpload(duration: CMTime) {
        let task = Task.detached { [self] in
            do {
                // It's fine if it's already open, that's handled by ignoring the call
                let fileSize = try FileManager.default.fileSizeOfItem(
                    atPath: inputFileURL.path
                )
                let result = try await makeWorker().performUpload()
                file.close()

                let success = UploadResult(
                    finalProgress: result.progress,
                    startTime: result.startTime,
                    finishTime: result.updateTime
                )

                reporter.reportUploadSuccess(
                    inputDuration: duration.seconds,
                    inputSize: fileSize,
                    options: uploadInfo.options,
                    uploadEndTime: Date(
                        timeIntervalSince1970: success.finishTime
                    ),
                    uploadStartTime: Date(
                        timeIntervalSince1970: success.startTime
                    ),
                    uploadURL: uploadInfo.uploadURL
                )
                notifyStateFromWorker(.success(success))
            } catch {
                file.close()
                if error is CancellationError {
                    SDKLogger.logger?.debug("Task finished due to cancellation in state \(String(describing: self.currentState))")
                    if case let .uploading(update) = self.currentState {
                        self.currentState = .paused(update)
                    }
                } else {
                    SDKLogger.logger?.debug("Task finished due to error in state \(String(describing: self.currentState))")
                    let uploadError = InternalUploaderError(reason: error, lastByte: lastReadCount)

                    let lastUpdate: Update?
                    if case InternalUploadState.uploading(let update) = currentState {
                        lastUpdate = update
                    } else {
                        lastUpdate = nil
                    }

                    // This modifies currentState, so capture
                    // the last update first
                    notifyStateFromWorker(.failure(uploadError))

                    // FIXME: Will only work if currentState
                    // was uploading before the upload failed
                    // may miss some edge cases
                    if let lastUpdate {
                        let fileSize = try? FileManager.default.fileSizeOfItem(
                            atPath: inputFileURL.path
                        )

                        let startTime = Date(
                            timeIntervalSince1970: lastUpdate.startTime
                        )
                        // When failing assume transport ends
                        // when error is received
                        let endTime = Date()

                        reporter.reportUploadFailure(
                            errorDescription: uploadError.localizedDescription,
                            inputDuration: duration.seconds,
                            inputSize: fileSize ?? 0,
                            options: uploadInfo.options,
                            uploadEndTime: endTime,
                            uploadStartTime: startTime,
                            uploadURL: uploadInfo.uploadURL
                        )
                    }
                }
            }
        }
        currentWorkTask = task
    }
    
    private func makeWorker() -> Worker {
        return Worker(
            uploadInfo: uploadInfo,
            inputFileURL: inputFileURL,
            chunkedFile: file,
            progress: overallProgress,
            startByte: lastReadCount
        ) { progress, startTime, eventTime in
            let update = Update(
                progress: progress,
                startTime: startTime,
                updateTime: eventTime
            )
            // ChunkWorker delivers callbacks on the main dispatch queue, making this safe
            self.notifyStateFromMain(.uploading(update))
        }
    }
    
    private func cleanupResources() {
        // TODO: Make sure everything is taken care of here
        currentWorkTask?.cancel()
        currentWorkTask = nil
        file.close()
    }
    
    // do thing: need ChunkWorkers, need starting method, need to open the file and stuff
    
    /// Notify delegates of state updates. This method *must* be called from the main thread. See ``notifyStateFromWorker``
    private func notifyStateFromMain(_ state: InternalUploadState) {
        currentState = state
        
        if case .uploading(let update) = state {
            let count = update.progress.completedUnitCount
            lastReadCount = UInt64(count)
        }
        
        for delegate in delegates.values {
            delegate.chunkedFileUploader(self, stateUpdated: state)
        }
    }
    
    /// Notify delegates of state updates from a background worker
    private func notifyStateFromWorker(_ state: InternalUploadState) {
        DispatchQueue.main.async {
            self.notifyStateFromMain(state)
        }
    }

    convenience init(
        persistenceEntry: PersistenceEntry
    ) {
        self.init(
            uploadInfo: persistenceEntry.uploadInfo,
            inputFileURL: persistenceEntry.inputFileURL,
            file: ChunkedFile(chunkSize: persistenceEntry.uploadInfo.options.transport.chunkSizeInBytes),
            startingByte: persistenceEntry.lastSuccessfulByte
        )
    }
    
    init(
        uploadInfo: UploadInfo,
        inputFileURL: URL,
        file: ChunkedFile,
        startingByte: UInt64 = 0
    ) {
        self.uploadInfo = uploadInfo
        self.file = file
        self.lastReadCount = startingByte
        self.inputFileURL = inputFileURL
        self.reporter = Reporter.shared
    }
    
    enum InternalUploadState {
        case ready, starting, uploading(Update), canceled, paused(Update), success(UploadResult), failure(Error)

        var progress: Progress? {
            switch self {
            case .ready, .starting, .canceled:
                return nil
            case .uploading(let update):
                return update.progress
            case .paused(let update):
                return update.progress
            case .success(let result):
                return result.finalProgress
            case .failure:
                return nil
            }
        }
    }
    
    struct UploadResult {
        let finalProgress: Progress
        let startTime: TimeInterval
        let finishTime: TimeInterval
    }
    
    struct Update {
        let progress: Progress
        let startTime: TimeInterval
        let updateTime: TimeInterval
    }
}

protocol ChunkedFileUploaderDelegate {
    /// Called when the state of a ``ChunkedFileUploader`` changes or updates state
    func chunkedFileUploader(_ uploader: ChunkedFileUploader, stateUpdated state: ChunkedFileUploader.InternalUploadState)
}

struct InternalUploaderError : Error {
    let reason: Error
    let lastByte: UInt64
    
    var localizedDescription: String { "Failed to upload file because of:\n\t\(reason.localizedDescription)\n" }
}

/// Uploads chunks from the given ``ChunkedFile`` until it reaches the end of the file, fails, or is canceled
/// This object is not resuable. If you want to resume where you left off, the ``ChunkedFile`` must be seeked to that position
fileprivate actor Worker {
    private let uploadInfo: UploadInfo
    private let inputFileURL: URL
    private let chunkedFile: ChunkedFile
    private let overallProgress: Progress
    private let progressHandler: ProgressHandler
    private let startingReadCount: UInt64
    
    func performUpload() async throws -> ChunkedFileUploader.Update {
        try chunkedFile.openFile(fileURL: inputFileURL)
        try chunkedFile.seekTo(byte: startingReadCount)
        
        let startTime = Date().timeIntervalSince1970
        let fileSize = try FileManager.default.fileSizeOfItem(
            atPath: inputFileURL.path
        )
        let wideFileSize: Int64

        // Prevent overflow if UInt64 exceeds Int64.max
        if fileSize >= Int64.max {
            wideFileSize = Int64.max
        } else {
            wideFileSize = Int64(fileSize)
        }

        overallProgress.totalUnitCount = wideFileSize
        overallProgress.isCancellable = false
        overallProgress.completedUnitCount = Int64(startingReadCount)
        
        var readBytes: Int
        repeat {
            try Task.checkCancellation()

            guard case let Result.success(chunk) = chunkedFile.readNextChunk() else {
                // TODO: report error accurately
                throw ChunkWorker.ChunkWorkerError.init(
                    lastSeenProgress: ChunkWorker.Update(
                        progress: overallProgress,
                        bytesSinceLastUpdate: 0,
                        chunkStartTime: Date().timeIntervalSince1970,
                        eventTime: Date().timeIntervalSince1970
                    ), 
                    reason: nil
                )
            }

            readBytes = chunk.size()
            
            let wideChunkSize = Int64(chunk.size())
            let chunkProgress = Progress(totalUnitCount: wideChunkSize)
            //overallProgress.addChild(chunkProgress, withPendingUnitCount: wideChunkSize)
            
            let chunkWorker = ChunkWorker(
                uploadURL: uploadInfo.uploadURL,
                fileChunk: chunk,
                chunkProgress: chunkProgress,
                maxRetries: uploadInfo.options.transport.retryLimitPerChunk
            )
            chunkWorker.addDelegate {[self] update in
                // Called on the main thread
                overallProgress.completedUnitCount += update.bytesSinceLastUpdate
                progressHandler(
                    self.overallProgress,
                    startTime,
                    update.eventTime
                )
            }
            
            // Problem is in line bellow, task will retain the reference to a chunk read from file and will
            // not release it until the for loop is exited, we need to find a way to implicitly release task memory
            // withouth breaking the for loop.
            let chunkResult = try await chunkWorker.getTask().value
            SDKLogger.logger?.info("Completed Chunk:\n \(String(describing: chunkResult))")
        } while (readBytes == uploadInfo.options.transport.chunkSizeInBytes)

        SDKLogger.logger?.info("Finished uploading file: \(self.inputFileURL.relativeString)")

        let finalState = ChunkedFileUploader.Update(
            progress: overallProgress,
            startTime: startTime,
            updateTime: Date().timeIntervalSince1970
        )
        return finalState
    }
    
    typealias ProgressHandler = (Progress, TimeInterval, TimeInterval) ->  Void
    
    init(
        uploadInfo: UploadInfo,
        inputFileURL: URL,
        chunkedFile: ChunkedFile,
        progress: Progress,
        startByte: UInt64,
        _ progressHandler: @escaping ProgressHandler
    ) {
        self.uploadInfo = uploadInfo
        self.inputFileURL = inputFileURL
        self.chunkedFile = chunkedFile
        self.progressHandler = progressHandler
        self.overallProgress = progress
        self.startingReadCount = startByte
    }
}
