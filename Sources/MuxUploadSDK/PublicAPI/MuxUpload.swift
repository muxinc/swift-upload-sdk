//
//  MuxUpload.swift
//  Mux Upload SDK
//
//  Created by Emily Dixon on 2/7/23.
//

import Foundation

///
/// Uploads a video file to a previously-created Mux Video Direct Upload.
///
/// This class is part of a full-stack workflow for uploading video files to Mux Video. In order to use this object you must first have
/// created a [Direct Upload](https://docs.mux.com/guides/video/upload-files-directly) on your server backend.
/// Then, use the PUT URL created there to upload your video file.
///
/// For example:
/// ```swift
/// let upload = MuxUpload(
///   uploadURL: myMuxUploadURL,
///   videoFileURL: myVideoFileURL,
/// )
///
/// upload.progressHandler = { state in
///   self.uploadScreenState = .uploading(state)
/// }
///
/// upload.resultHandler = { result in
///   switch result {
///     case .success(let success):
///     self.uploadScreenState = .done(success)
///     self.upload = nil
///     NSLog("Upload Success!")
///     case .failure(let error):
///     self.uploadScreenState = .failure(error)
///     NSLog("!! Upload error: \(error.localizedDescription)")
///   }
/// }
///
/// self.upload = upload
/// upload.start()
/// ```
///
/// Uploads created by this SDK are globally managed by default, and can be resumed after failures or even after process death. For more information on
/// this topic, see ``UploadManager``
///
public final class MuxUpload : Hashable, Equatable {
 
    private let uploadInfo: UploadInfo
    private let manageBySDK: Bool
    private let id: String = UUID().uuidString
    private let uploadManager: UploadManager
    
    private var lastSeenStatus: Status = Status(progress: Progress(totalUnitCount: 0), updatedTime: 0, startTime: 0, isPaused: false)
    
    internal var fileWorker: ChunkedFileUploader?

    /**
     Represents the state of an upload in progress.
     */
    public struct Status : Sendable, Hashable {
        public let progress: Progress?
        public let updatedTime: TimeInterval
        public let startTime: TimeInterval
        public let isPaused: Bool
    }

    /**
     An fatal error that ocurred during the upload process. The last-known state of the upload is available, as well as the Error that stopped the upload
     */
    public struct UploadError : Error {
        public let lastStatus: Status
        public let code: MuxErrorCase
        public let message: String
        public let reason: Error?

        var localizedDescription: String {
            get {
                return "Error \(code): \(message). Caused by:\n\t\(String(describing: reason))"
            }
        }

    }

    /// Creates a new `MuxUpload` with the given confguration
    /// - Parameters
    ///   - uploadURL: the PUT URL for your direct upload
    ///   - videoFileURL: A URL to the input video file
    ///   - retriesPerChunk: The number of times each chunk of the file upload can be retried before failure is declared
    ///   - optOutOfEventTracking: This SDK collects performance and reliability data that helps make the Upload SDK the best it can be. If you do not wish to share this information with Mux, you may pass `true` for this parameter
    public convenience init(
        uploadURL: URL,
        videoFileURL: URL,
        chunkSize: Int = 8 * 1024 * 1024, // Google recommends at least 8M
        retriesPerChunk: Int = 3,
        optOutOfEventTracking: Bool = false
    ) {
        let uploadInfo = UploadInfo(
            uploadURL: uploadURL,
            videoFile: videoFileURL,
            chunkSize: chunkSize,
            retriesPerChunk: retriesPerChunk,
            optOutOfEventTracking: optOutOfEventTracking
        )

        self.init(
            uploadInfo: uploadInfo,
            uploadManager: .shared
        )
    }

    /**
     Handles state updates for this upload in your app.
     */
    public typealias StateHandler = (Status) -> Void

    /**
     If set will receive progress updates for this upload,
     updates will not be received less than 100ms apart
     */
    public var progressHandler: StateHandler?

    public struct Success : Sendable, Hashable {
        public let finalState: Status
    }

    /**
     The current status of the upload. This object is updated periodically. To listen for changes, use ``progressHandler``
     */
    public var uploadStatus: Status { get { return lastSeenStatus } }

    /**
     Handles the final result of this upload in your app
     */
    public typealias ResultHandler = (Result<Success, UploadError>) -> Void

    /**
     If set will be notified when this upload is successfully
     completed or if there's an error
     */
    public var resultHandler: ResultHandler?
    
    /**
     True if this upload is currently in progress and not paused
     */
    public var inProgress: Bool { get { fileWorker != nil && !complete } }
    
    /**
     True if this upload was completed
     */
    public var complete: Bool { get { lastSeenStatus.progress?.completedUnitCount ?? 0 > 0 && lastSeenStatus.progress?.fractionCompleted ?? 0 >= 1.0 } }
    
    /**
    URL to the file that will be uploaded
     */
    public var videoFile: URL { get { return uploadInfo.videoFile } }
    
    /**
     The remote endpoint that this object uploads to
     */
    public var uploadURL: URL { get { return uploadInfo.uploadURL } }
    
    /**
     Begins the upload. You can control what happens when the upload is already started. If `forceRestart` is true, the upload will be restarted. Otherwise, nothing will happen. The default is not to restart
     */
    public func start(forceRestart: Bool = false) {
        // Use an existing globally-managed upload if desired & one exists
        if self.manageBySDK && fileWorker == nil {
            // See if there's anything in progress already
            fileWorker = uploadManager.findUploaderFor(videoFile: videoFile)
        }
        if fileWorker != nil && !forceRestart {
            MuxUploadSDK.logger?.warning("start() called but upload is already in progress")
            fileWorker?.addDelegate(
                withToken: id,
                InternalUploaderDelegate { [self] state in handleStateUpdate(state) }
            )
            fileWorker?.start()
            return
        }
        
        // Start a new upload
        if forceRestart {
            cancel()
        }
        let completedUnitCount = UInt64({ self.lastSeenStatus.progress?.completedUnitCount ?? 0 }())
        let fileWorker = ChunkedFileUploader(uploadInfo: uploadInfo, startingAtByte: completedUnitCount)
        fileWorker.addDelegate(
            withToken: id,
            InternalUploaderDelegate { [self] state in handleStateUpdate(state) }
        )
        fileWorker.start()
        uploadManager.registerUploader(fileWorker, withId: id)
        self.fileWorker = fileWorker
    }
    
    /**
     Suspends the execution of this upload. Temp files and state will not be changed. The upload will remain paused in this state
     even after process death.
     Use ``start(forceRestart:)``, passing `false` to start the process over where it was left.
     Use ``cancel()`` to remove this upload completely
     */
    public func pause() {
        fileWorker?.pause()
    }
    
    /**
     Cancels an ongoing download. State and Delegates will be cleared. Your delegates will recieve no further calls
     */
    public func cancel() {
        fileWorker?.cancel()
        uploadManager.acknowledgeUpload(ofFile: videoFile)
        
        lastSeenStatus = Status(progress: nil, updatedTime: 0, startTime: 0, isPaused: true)
        progressHandler = nil
        resultHandler = nil
    }
    
    private func handleStateUpdate(_ state: ChunkedFileUploader.InternalUploadState) {
        switch state {
        case .success(let result): do {
            if let notifySuccess = resultHandler {
                let finalStatus = Status(progress: result.finalProgress, updatedTime: result.finishTime, startTime: result.startTime, isPaused: false)
                notifySuccess(Result<Success, UploadError>.success(Success(finalState: finalStatus)))
            }
            fileWorker?.removeDelegate(withToken: id)
            fileWorker = nil
        }
        case .failure(let error): do {
            if let notifyFailure = resultHandler {
                let parsedError = error.parseAsUploadError(lastSeenUploadStatus: lastSeenStatus)
                if case .cancelled = parsedError.code {
                    MuxUploadSDK.logger?.info("task canceled")
                    let canceledStatus = MuxUpload.Status(
                        progress: lastSeenStatus.progress,
                        updatedTime: lastSeenStatus.updatedTime,
                        startTime: lastSeenStatus.startTime,
                        isPaused: true
                    )
                    if let notifyProgress = progressHandler { notifyProgress(canceledStatus) }
                } else {
                    notifyFailure(Result.failure(parsedError))
                }
            }
            fileWorker?.removeDelegate(withToken: id)
            fileWorker = nil
        }
        case .uploading(let update): do {
            if let notifyProgress = progressHandler {
                let status = Status(
                    progress: update.progress,
                    updatedTime: update.updateTime,
                    startTime: update.startTime, isPaused: false
                )
                lastSeenStatus = status
                notifyProgress(status)
            }
        }
        default: do {}
        }
    }
    
    /// Two`MuxUpload`s with the same ``MuxUpload/videoFile`` and ``MuxUpload/uploadURL`` are considered equivalent
    public static func == (lhs: MuxUpload, rhs: MuxUpload) -> Bool {
        lhs.videoFile == rhs.videoFile
        && lhs.uploadURL == rhs.uploadURL
    }
    
    /// This object's hash is computed based on its ``MuxUpload/videoFile`` and its ``MuxUpload/uploadURL``
    public func hash(into hasher: inout Hasher) {
        hasher.combine(videoFile)
        hasher.combine(uploadURL)
    }
   
    
    private init (uploadInfo: UploadInfo, manage: Bool = true, uploadManager: UploadManager) {
        self.uploadInfo = uploadInfo
        self.manageBySDK = manage
        self.uploadManager = uploadManager
    }
    
    internal convenience init(wrapping uploader: ChunkedFileUploader, uploadManager: UploadManager) {
        self.init(uploadInfo: uploader.uploadInfo, manage: true, uploadManager: uploadManager)
        self.fileWorker = uploader
        
        handleStateUpdate(uploader.currentState)
        uploader.addDelegate(
            withToken: self.id,
            InternalUploaderDelegate { [weak self] state in self?.handleStateUpdate(state) }
        )
    }
}

fileprivate struct InternalUploaderDelegate : ChunkedFileUploaderDelegate {
    let outerDelegate: (ChunkedFileUploader.InternalUploadState) -> Void
    
    func chunkedFileUploader(_ uploader: ChunkedFileUploader, stateUpdated state: ChunkedFileUploader.InternalUploadState) {
        outerDelegate(state)
    }
}

public extension Error {
    func asMuxUploadError() -> MuxUpload.UploadError? {
        return self as? MuxUpload.UploadError
    }
}

extension Error {
    /// Parses Errors thrown by this SDK, wrapping the internal error types in a public error
    func parseAsUploadError(lastSeenUploadStatus: MuxUpload.Status) -> MuxUpload.UploadError {
        let error = self
        if (error.asCancellationError()) != nil {
            return MuxUpload.UploadError(
                lastStatus: lastSeenUploadStatus,
                code: MuxErrorCase.cancelled,
                message: "Cancelled by user",
                reason: self
            )
        } else if (error.asChunkWorkerError()) != nil {
            if let realCause = error.asHttpError() {
                return MuxUpload.UploadError(
                    lastStatus: lastSeenUploadStatus,
                    code: MuxErrorCase.http,
                    message: "Http Failed: \(realCause.statusCode): \(realCause.statusMsg)",
                    reason: self
                )
            } else {
                return MuxUpload.UploadError(
                    lastStatus: lastSeenUploadStatus,
                    code: MuxErrorCase.connection,
                    message: "Connection error",
                    reason: self
                )
            }
        } else if let realError = error.asInternalUploaderError() {
            // All UploaderError does is wrap ChunkedFile and ChunkWorker errors
            return realError.reason.parseAsUploadError(lastSeenUploadStatus: lastSeenUploadStatus)
        } else if let realError = error.asChunkedFileError() {
            switch realError {
            case .fileHandle(_): return MuxUpload.UploadError(
                lastStatus: lastSeenUploadStatus,
                code: MuxErrorCase.file,
                message: "Couldn't read file for upload",
                reason: self
            )
            case .invalidState(let msg): return MuxUpload.UploadError(
                lastStatus: lastSeenUploadStatus,
                code: MuxErrorCase.unknown,
                message: "Internal error: \(msg)",
                reason: nil
            )
            }
        } else {
            return MuxUpload.UploadError(
                lastStatus: lastSeenUploadStatus,
                code: MuxErrorCase.unknown,
                message: "unknown",
                reason: nil
            )
        }
    }
}
