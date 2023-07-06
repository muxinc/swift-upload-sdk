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
    
    let uploadInfo: UploadInfo
    var currentState: InternalUploadState { get { _currentState } }
    
    private var delegates: [String : ChunkedFileUploaderDelegate] = [:]
    
    private let file: ChunkedFile
    private var currentWorkTask: Task<(), Never>? = nil
    private var _currentState: InternalUploadState = .ready
    private var overallProgress: Progress = Progress()
    private var lastReadCount: UInt64 = 0
    private let reporter = Reporter()
    
    func addDelegate(withToken token: String, _ delegate: ChunkedFileUploaderDelegate) {
        delegates.updateValue(delegate, forKey: token)
    }
    
    func removeDelegate(withToken: String) {
        delegates.removeValue(forKey: withToken)
    }
    
    /// If currently uploading, will pause the upload. If not uploading, this methd has no effect
    func pause() {
        switch _currentState {
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
        switch _currentState {
        case .ready, .paused:
            _currentState = .starting
            beginUpload()
        case .starting, .uploading, .canceled, .success, .failure:
            MuxUploadSDK.logger?.info("start() ignored in state \(String(describing: self._currentState))")
        }
    }
    
    /// Cancels the upload. It can't be restarted
    func cancel() {
        currentWorkTask?.cancel()
        currentWorkTask = nil
        cleanupResources()
        
        switch _currentState {
        case .starting, .uploading:
            notifyStateFromMain(.canceled)
        case .ready, .canceled, .success, .failure, .paused:
            break
        }
    }
    
    private func beginUpload() {
        let task = Task.detached { [self] in
            do {
                // It's fine if it's already open, that's handled by ignoring the call
                let fileSize = try FileManager.default.fileSizeOfItem(
                    atPath: uploadInfo.videoFile.path
                )
                let result = try await makeWorker().performUpload()
                file.close()

                let success = UploadResult(
                    finalProgress: result.progress,
                    startTime: result.startTime,
                    finishTime: result.updateTime
                )

                let asset = AVAsset(url: uploadInfo.videoFile)

                var duration: CMTime
                if #available(iOS 15, *) {
                    duration = try await asset.load(.duration)
                } else {
                    await asset.loadValues(forKeys: ["duration"])
                    duration = asset.duration
                }

                if !uploadInfo.optOutOfEventTracking {
                    reporter.report(
                        startTime: success.startTime,
                        endTime: success.finishTime,
                        fileSize: fileSize,
                        videoDuration: duration.seconds,
                        uploadURL: uploadInfo.uploadURL
                    )
                }

                notifyStateFromWorker(.success(success))
            } catch {
                file.close()
                if error is CancellationError {
                    MuxUploadSDK.logger?.debug("Task finished due to cancellation in state \(String(describing: self.currentState))")
                    if case let .uploading(update) = self.currentState {
                        self._currentState = .paused(update)
                    }
                } else {
                    MuxUploadSDK.logger?.debug("Task finished due to error in state \(String(describing: self.currentState))")
                    let uploadError = InternalUploaderError(reason: error, lastByte: lastReadCount)
                    notifyStateFromWorker(.failure(uploadError))
                }
            }
        }
        currentWorkTask = task
    }
    
    private func makeWorker() -> Worker {
        return Worker(
            uploadInfo: uploadInfo,
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
        _currentState = state
        
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
    
    convenience init(uploadInfo: UploadInfo, startingAtByte: UInt64 = 0) {
        self.init(
            uploadInfo: uploadInfo,
            file: ChunkedFile(chunkSize: uploadInfo.chunkSize),
            startingByte: startingAtByte
        )
    }
    
    init(uploadInfo: UploadInfo, file: ChunkedFile, startingByte: UInt64 = 0) {
        self.uploadInfo = uploadInfo
        self.file = file
        self.lastReadCount = startingByte
    }
    
    enum InternalUploadState {
        case ready, starting, uploading(Update), canceled, paused(Update), success(UploadResult), failure(Error)
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
    private let chunkedFile: ChunkedFile
    private let overallProgress: Progress
    private let progressHandler: ProgressHandler
    private let startingReadCount: UInt64
    
    func performUpload() async throws -> ChunkedFileUploader.Update {
        try chunkedFile.openFile(fileURL: uploadInfo.videoFile)
        try chunkedFile.seekTo(byte: startingReadCount)
        
        let startTime = Date().timeIntervalSince1970
        let fileSize = try FileManager.default.fileSizeOfItem(
            atPath: uploadInfo.videoFile.path
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
            
            let chunk = try chunkedFile.readNextChunk().get()
            readBytes = chunk.size()
            
            let wideChunkSize = Int64(chunk.size())
            let chunkProgress = Progress(totalUnitCount: wideChunkSize)
            //overallProgress.addChild(chunkProgress, withPendingUnitCount: wideChunkSize)
            
            let chunkWorker = ChunkWorker(
                uploadURL: uploadInfo.uploadURL,
                fileChunk: chunk,
                chunkProgress: chunkProgress,
                maxRetries: uploadInfo.retriesPerChunk
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
            
            let chunkResult = try await chunkWorker.getTask().value
            MuxUploadSDK.logger?.info("Completed Chunk:\n \(String(describing: chunkResult))")
        } while (readBytes == uploadInfo.chunkSize)
        
        MuxUploadSDK.logger?.info("Finished uploading file: \(self.uploadInfo.videoFile.relativeString)")
        
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
        chunkedFile: ChunkedFile,
        progress: Progress,
        startByte: UInt64,
        _ progressHandler: @escaping ProgressHandler
    ) {
        self.uploadInfo = uploadInfo
        self.chunkedFile = chunkedFile
        self.progressHandler = progressHandler
        self.overallProgress = progress
        self.startingReadCount = startByte
    }
}
