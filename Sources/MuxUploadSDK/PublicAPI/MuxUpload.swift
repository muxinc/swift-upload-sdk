//
//  MuxUpload.swift
//  Mux Upload SDK
//
//  Created by Emily Dixon on 2/7/23.
//

import AVFoundation
import Foundation

public typealias UploadResult = Result<MuxUpload.Success, MuxUpload.UploadError>

///
/// Uploads a media asset to Mux using a previously-created
/// Direct Upload signed URL.
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

    var input: UploadInput {
        didSet {
            if oldValue.status != input.status {
                inputStatusHandler?(inputStatus)
            }
        }
    }

    private var internalStatus: UploadInput.Status {
        input.status
    }

    private var uploadInfo: UploadInfo? {
        input.uploadInfo
    }

    /// Indicates the status of the upload input as it goes
    /// through its lifecycle
    public enum InputStatus {
        /// Upload initialized and not yet started
        case ready(AVAsset)
        /// Upload started by a call to ``MuxUpload.start(forceRestart:``
        case started(AVAsset)
        /// Upload is being prepared for transport to the
        /// server. If input standardization was enabled,
        /// this stage includes the inspection and standardization
        /// of input formats
        case preparing(AVAsset)
        /// SDK is waiting for confirmation to continue the
        /// upload despite being unable to standardize input
        case awaitingUploadConfirmation(AVAsset)
        /// Transport of upload inputs is in progress
        case uploadInProgress(AVAsset, Status)
        /// Upload has been paused
        case uploadPaused(AVAsset, Status)
        /// Upload has succeeded
        case uploadSucceeded(AVAsset, Status, UploadResult)
        /// Upload has failed
        case uploadFailed(AVAsset, Status, UploadResult)
    }

    /// Current status of the upload input as it goes through
    /// its lifecycle
    public var inputStatus: InputStatus {
        switch input.status {
        case .ready(let sourceAsset, _):
            return InputStatus.ready(sourceAsset)
        case .started(let sourceAsset, _):
            return InputStatus.started(sourceAsset)
        case .underInspection(let sourceAsset, _):
            return InputStatus.preparing(sourceAsset)
        case .standardizing(let sourceAsset, _):
            return InputStatus.preparing(sourceAsset)
        case .standardizationSucceeded(let sourceAsset, _):
            return InputStatus.preparing(sourceAsset)
        case .standardizationFailed(let sourceAsset, _):
            return InputStatus.preparing(sourceAsset)
        case .awaitingUploadConfirmation(let uploadInfo):
            return InputStatus.awaitingUploadConfirmation(
                uploadInfo.sourceAsset()
            )
        case .uploadInProgress(let uploadInfo):
            return InputStatus.uploadInProgress(
                uploadInfo.sourceAsset(),
                uploadStatus
            )
        case .uploadPaused(let uploadInfo):
            return InputStatus.uploadPaused(
                uploadInfo.sourceAsset(),
                uploadStatus
            )
        case .uploadSucceeded(let uploadInfo):
            return InputStatus.uploadSucceeded(
                uploadInfo.sourceAsset(),
                uploadStatus,
                .success(.init(finalState: uploadStatus))
            )
        case .uploadFailed(let uploadInfo):
            #warning("Separate error property")
            return InputStatus.uploadFailed(
                uploadInfo.sourceAsset(),
                uploadStatus,
                .failure(.init(lastStatus: uploadStatus, code: MuxErrorCase.unknown, message: "", reason: nil))
            )
        }
    }

    /**
     Handles a change in the input status of the upload
     */
    public typealias InputStatusHandler = (InputStatus) -> ()

    /**
     If set will be notified of a change to a new input status
     */
    public var inputStatusHandler: InputStatusHandler?

    private let manageBySDK: Bool
    var id: String {
        uploadInfo!.id
    }
    private let uploadManager: UploadManager
    private let inputInspector: UploadInputInspector = UploadInputInspector()
    private let inputStandardizer: UploadInputStandardizer = UploadInputStandardizer()
    
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

    /// Initializes a MuxUpload from a local file URL with
    /// the given configuration
    /// - Parameters:
    ///    - uploadURL: the URL of your direct upload, see
    ///    the [direct upload guide](https://docs.mux.com/api-reference#video/operation/create-direct-upload)
    ///     - videoFileURL: the file:// URL of the upload
    ///     input
    ///     - chunkSize: the size of chunks when uploading,
    ///     at least 8M is recommended
    ///     - retriesPerChunk: number of retry attempts for
    ///     a failed chunk upload request
    ///     - inputStandardization: enable or disable input
    ///     standardization by the SDK locally
    ///     - eventTracking: options to opt out of event
    ///     tracking
    @available(*, deprecated, renamed: "init(uploadURL:inputFileURL:options:)")
    public convenience init(
        uploadURL: URL,
        videoFileURL: URL,
        chunkSize: Int = 8 * 1024 * 1024, // Google recommends at least 8M
        retriesPerChunk: Int = 3,
        inputStandardization: UploadOptions.InputStandardization = .default,
        eventTracking: UploadOptions.EventTracking = .default
    ) {
        self.init(
            input: UploadInput(
                asset: AVAsset(url: videoFileURL),
                info: UploadInfo(
                    id: UUID().uuidString,
                    uploadURL: uploadURL,
                    options: UploadOptions(
                        inputStandardization: inputStandardization,
                        transport: UploadOptions.Transport(
                            chunkSize: chunkSize,
                            retriesPerChunk: retriesPerChunk
                        ),
                        eventTracking: eventTracking
                    )
                )
            ),
            uploadManager: .shared
        )
    }

    /// Initializes a MuxUpload from a local file URL
    ///
    /// - Parameters:
    ///    - uploadURL: the URL of your direct upload, see
    ///    the [direct upload guide](https://docs.mux.com/api-reference#video/operation/create-direct-upload)
    ///    [response](https://docs.mux.com/api-reference#video/operation/create-direct-upload)
    ///     - inputFileURL: the file:// URL of the upload
    ///     input
    ///     - options: options used to control the direct
    ///    upload of the input to Mux
    public convenience init(
        uploadURL: URL,
        inputFileURL: URL,
        options: UploadOptions = .default
    ) {
        self.init(
            input: UploadInput(
                asset: AVAsset(
                    url: inputFileURL
                ),
                info: UploadInfo(
                    uploadURL: uploadURL,
                    options: options
                )
            ),
            manage: true,
            uploadManager: .shared
        )
    }

    init(
        input: UploadInput,
        manage: Bool = true,
        uploadManager: UploadManager
    ) {
        self.input = input
        self.manageBySDK = manage
        self.uploadManager = uploadManager
    }

    internal convenience init(
        wrapping uploader: ChunkedFileUploader,
        uploadManager: UploadManager
    ) {
        self.init(
            input: UploadInput(
                status: .uploadInProgress(
                    uploader.uploadInfo
                )
            ),
            uploadManager: .shared
        )
        self.fileWorker = uploader

        handleStateUpdate(uploader.currentState)
        uploader.addDelegate(
            withToken: id,
            InternalUploaderDelegate { [weak self] state in self?.handleStateUpdate(state) }
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
    public var videoFile: URL? {
        return (input.sourceAsset as? AVURLAsset)?.url
    }
    
    /**
     The remote endpoint that this object uploads to
     */
    public var uploadURL: URL? { return uploadInfo?.uploadURL }
    // TODO: Computed Properties for some other UploadInfo properties
    
    /**
     Begins the upload. You can control what happens when the upload is already started. If `forceRestart` is true, the upload will be restarted. Otherwise, nothing will happen. The default is not to restart
     */
    public func start(forceRestart: Bool = false) {
        // Use an existing globally-managed upload if desired & one exists
        if self.manageBySDK && fileWorker == nil {
            // See if there's anything in progress already
            fileWorker = uploadManager.findUploader(
                uploadID: id
            )
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
    }

    private func startUpload(
        forceRestart: Bool
    ) {
        if self.manageBySDK {
            // See if there's anything in progress already
            fileWorker = uploadManager.findUploader(
                uploadID: id
            )
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
        let fileWorker = ChunkedFileUploader(
            uploadInfo: input.uploadInfo!,
            fileInputURL: videoFile!,
            file: ChunkedFile(chunkSize: input.uploadInfo.options.transport.chunkSize),
            startingByte: completedUnitCount
        )
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
        uploadManager.acknowledgeUpload(id: id)
        
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
}

extension MuxUpload.UploadError {
    internal init(
        lastStatus: MuxUpload.Status
    ) {
        self.lastStatus = lastStatus
        self.code = MuxErrorCase.unknown
        self.message = ""
        self.reason = nil
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
                lastStatus: lastSeenUploadStatus
            )
        }
    }
}
