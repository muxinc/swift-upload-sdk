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
    private var lastSuccessfulByte: UInt64 = 0
    var beforeUpload: (() async throws -> Void)?
    var allowsExistingServerBytes = true
    private var attemptID = UUID()
    private let reporter: Reporter
    
    func addDelegate(withToken token: String, _ delegate: ChunkedFileUploaderDelegate) {
        if !Thread.isMainThread { DispatchQueue.main.sync { self.addDelegate(withToken: token, delegate) }; return }
        delegates.updateValue(delegate, forKey: token)
    }
    
    func removeDelegate(withToken: String) {
        if !Thread.isMainThread { DispatchQueue.main.sync { self.removeDelegate(withToken: withToken) }; return }
        delegates.removeValue(forKey: withToken)
    }
    
    /// If currently uploading, will pause the upload. If not uploading, this methd has no effect
    func pause() {
        if !Thread.isMainThread { DispatchQueue.main.sync { self.pause() }; return }
        attemptID = UUID()
        switch currentState {
        case .ready:
            currentState = .paused(Update(progress: Progress(totalUnitCount: 0), startTime: 0, updateTime: 0))
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
            recordSuccessfulChunk(endByte: lastSuccessfulByte)
            notifyStateFromMain(.paused(update.withCompletedUnitCount(lastSuccessfulByte)))
        }
        default: do {}
        }
    }
    
    /// Starts the upload if it wasn't already starting
    func start() {
        if !Thread.isMainThread { DispatchQueue.main.sync { self.start() }; return }
        switch currentState {
        case .ready: fallthrough
        case .paused(_):
            beginUpload()
        default:
            SDKLogger.logger?.info("start() ignored in state \(String(describing: self.currentState))")
        }
    }

    func start(duration: CMTime) {
        if !Thread.isMainThread { DispatchQueue.main.sync { self.start(duration: duration) }; return }
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
        if !Thread.isMainThread { DispatchQueue.main.sync { self.cancel() }; return }
        attemptID = UUID()
        currentWorkTask?.cancel()
        currentWorkTask = nil

        switch currentState {
        case .starting: fallthrough
        case .uploading(_): do {
            notifyStateFromMain(.canceled)
        }
        case .ready: fallthrough
        case .paused:
            currentState = .canceled
        default: do {}
        }
    }
    
    private func beginUpload() { beginUpload(duration: nil) }

    private func beginUpload(duration: CMTime?) {
        let token = UUID()
        attemptID = token
        currentState = .starting // Claim synchronously: repeated start() is idempotent.
        let attemptFile = file.fresh()
        currentWorkTask = Task.detached { [self] in
            let startedAt = Date()
            var reportingDuration = CMTime.zero
            var reportingSize: UInt64 = 0
            defer { attemptFile.close() }
            do {
                try await beforeUpload?()
                try Task.checkCancellation()
                let assetDuration: CMTime
                if let duration { assetDuration = duration }
                else { assetDuration = (try? await AVAsset(url: inputFileURL).load(.duration)) ?? .zero }
                let size = try FileManager.default.fileSizeOfItem(atPath: inputFileURL.path)
                reportingDuration = assetDuration
                reportingSize = size
                let result = try await Worker(uploadInfo: uploadInfo, inputFileURL: inputFileURL,
                    chunkedFile: attemptFile, allowsExistingServerBytes: allowsExistingServerBytes) {
                        [weak self] progress, startTime, eventTime, acknowledged in
                        let notify = {
                            guard let self, self.attemptID == token else { return }
                            if let acknowledged { self.recordSuccessfulChunk(endByte: acknowledged) }
                            self.notifyStateFromMain(.uploading(Update(progress: progress,
                                startTime: startTime, updateTime: eventTime)))
                        }
                        if Thread.isMainThread { notify() } else { DispatchQueue.main.sync(execute: notify) }
                    }.performUpload()
                reporter.reportUploadSuccess(inputDuration: assetDuration.seconds, inputSize: size,
                    options: uploadInfo.options, uploadEndTime: Date(timeIntervalSince1970: result.updateTime),
                    uploadStartTime: Date(timeIntervalSince1970: result.startTime), uploadURL: uploadInfo.uploadURL)
                await MainActor.run {
                    guard self.attemptID == token else { return }
                    self.notifyStateFromMain(.success(UploadResult(finalProgress: result.progress,
                        startTime: result.startTime, finishTime: result.updateTime)))
                }
            } catch {
                guard !(error is CancellationError), !Task.isCancelled else { return }
                reporter.reportUploadFailure(errorDescription: error.localizedDescription,
                    inputDuration: reportingDuration.seconds, inputSize: reportingSize,
                    options: uploadInfo.options, uploadEndTime: Date(), uploadStartTime: startedAt,
                    uploadURL: uploadInfo.uploadURL)
                await MainActor.run {
                    guard self.attemptID == token else { return }
                    self.notifyStateFromMain(.failure(InternalUploaderError(reason: error, lastByte: self.lastSuccessfulByte)))
                }
            }
        }
    }

    private func notifyStateFromMain(_ state: InternalUploadState) {
        currentState = state
        if case .uploading(let update) = state { lastReadCount = UInt64(max(0, update.progress.completedUnitCount)) }
        for delegate in Array(delegates.values) { delegate.chunkedFileUploader(self, stateUpdated: state) }
    }

    private func recordSuccessfulChunk(endByte: UInt64) {
        lastReadCount = endByte
        lastSuccessfulByte = endByte
    }

    func persistenceState(for state: InternalUploadState) -> InternalUploadState {
        switch state {
        case .uploading(let update):
            return .uploading(update.withCompletedUnitCount(lastSuccessfulByte))
        case .paused(let update):
            return .paused(update.withCompletedUnitCount(lastSuccessfulByte))
        case .ready, .starting, .canceled, .success, .failure:
            return state
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
        let fileSize = try? FileManager.default.fileSizeOfItem(atPath: inputFileURL.path)
        overallProgress.totalUnitCount = fileSize.flatMap { Int64(exactly: $0) } ?? -1
        overallProgress.completedUnitCount = Int64(clamping: persistenceEntry.lastSuccessfulByte)
        currentState = .paused(Update(
            progress: overallProgress,
            startTime: 0,
            updateTime: persistenceEntry.savedAt
        ))
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
        self.lastSuccessfulByte = startingByte
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

        func withCompletedUnitCount(_ completedUnitCount: UInt64) -> Update {
            let safeProgress = Progress(totalUnitCount: progress.totalUnitCount)
            let completed = Int64(clamping: completedUnitCount)
            safeProgress.completedUnitCount = progress.totalUnitCount >= 0
                ? min(completed, progress.totalUnitCount)
                : completed
            return Update(
                progress: safeProgress,
                startTime: startTime,
                updateTime: updateTime
            )
        }
    }
}

protocol ChunkedFileUploaderDelegate {
    /// Called when the state of a ``ChunkedFileUploader`` changes or updates state
    func chunkedFileUploader(_ uploader: ChunkedFileUploader, stateUpdated state: ChunkedFileUploader.InternalUploadState)
}

struct InternalUploaderError : Error {
    let reason: Error
    let lastByte: UInt64

    var isMissingInputFile: Bool {
        reason.uploadFileIsMissing
    }

    var localizedDescription: String { "Failed to upload file because of:\n\t\(reason.localizedDescription)\n" }
}

/// Uploads chunks from the given ``ChunkedFile`` until it reaches the end of the file, fails, or is canceled
/// This object is not resuable. If you want to resume where you left off, the ``ChunkedFile`` must be seeked to that position
fileprivate actor Worker {
    private let uploadInfo: UploadInfo
    private let inputFileURL: URL
    private let chunkedFile: ChunkedFile
    private let progressHandler: ProgressHandler
    private let allowsExistingServerBytes: Bool
    
    func performUpload() async throws -> ChunkedFileUploader.Update {
        try chunkedFile.openFile(fileURL: inputFileURL)
        let size = try FileManager.default.fileSizeOfItem(atPath: inputFileURL.path)
        guard size > 0, size < Int64.max else { throw UploadRecoveryError.payloadChanged }
        let startTime = Date().timeIntervalSince1970
        func report(_ completed: UInt64, acknowledged: UInt64?) {
            let progress = Progress(totalUnitCount: Int64(size))
            progress.completedUnitCount = Int64(min(completed, size))
            progressHandler(progress, startTime, Date().timeIntervalSince1970, acknowledged)
        }
        func query() async throws -> ChunkWorker.Success {
            let chunk = FileChunk(startByte: 0, endByte: 0, totalFileSize: size, chunkData: Data())
            return try await ChunkWorker(uploadURL: uploadInfo.uploadURL, chunkProgress: Progress(),
                maxRetries: uploadInfo.options.transport.retryLimitPerChunk).directUpload(chunk: chunk) as! ChunkWorker.Success
        }

        // A local checkpoint can lag behind an accepted request or its final response.
        var response = try await query()
        guard allowsExistingServerBytes || (response.nextByte == 0 && !response.isComplete) else {
            throw UploadRecoveryError.newUploadRequired
        }
        var next = response.nextByte
        report(next, acknowledged: next)
        var stalled = 0
        while !response.isComplete {
            try Task.checkCancellation()
            if next == size {
                response = try await query()
            } else {
                try chunkedFile.seekTo(byte: next)
                let chunk = try chunkedFile.readNextChunk().get()
                guard chunk.totalFileSize == size, !chunk.chunkData.isEmpty else { throw UploadRecoveryError.payloadChanged }
                let worker = ChunkWorker(uploadURL: uploadInfo.uploadURL,
                    chunkProgress: Progress(totalUnitCount: Int64(chunk.size())),
                    maxRetries: uploadInfo.options.transport.retryLimitPerChunk)
                worker.addDelegate { update in
                    report(chunk.startByte + UInt64(max(0, update.progress.completedUnitCount)), acknowledged: nil)
                }
                response = try await worker.directUpload(chunk: chunk) as! ChunkWorker.Success
            }
            stalled = response.nextByte <= next && !response.isComplete ? stalled + 1 : 0
            guard stalled < max(1, uploadInfo.options.transport.retryLimitPerChunk) else {
                throw UploadRecoveryError.invalidAcknowledgement
            }
            next = response.nextByte
            report(next, acknowledged: next)
        }
        let progress = Progress(totalUnitCount: Int64(size))
        progress.completedUnitCount = Int64(size)
        return ChunkedFileUploader.Update(progress: progress, startTime: startTime, updateTime: Date().timeIntervalSince1970)
    }

    typealias ProgressHandler = (Progress, TimeInterval, TimeInterval, UInt64?) ->  Void
    
    init(
        uploadInfo: UploadInfo,
        inputFileURL: URL,
        chunkedFile: ChunkedFile,
        allowsExistingServerBytes: Bool = true,
        _ progressHandler: @escaping ProgressHandler
    ) {
        self.uploadInfo = uploadInfo
        self.inputFileURL = inputFileURL
        self.chunkedFile = chunkedFile
        self.progressHandler = progressHandler
        self.allowsExistingServerBytes = allowsExistingServerBytes
    }
}

enum ChunkedFileUploaderError: Error {
    case unexpectedChunkResult
}
