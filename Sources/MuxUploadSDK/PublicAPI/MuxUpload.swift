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

    private var uploadInfo: UploadInfo {
        input.uploadInfo
    }

    private var inspectionResult: UploadInputFormatInspectionResult?

    /// Indicates the status of the upload input as it goes
    /// through its lifecycle
    public enum InputStatus {
        /// Upload initialized and not yet started
        case ready(AVAsset)
        /// Upload started by a call to ``MuxUpload.start(forceRestart:)``
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
        case uploadInProgress(AVAsset, TransportStatus)
        /// Upload has been paused
        case uploadPaused(AVAsset, TransportStatus)
        /// Upload has succeeded
        case uploadSucceeded(AVAsset, MuxUpload.Success)
        /// Upload has failed
        case uploadFailed(AVAsset, MuxUpload.UploadError)
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
        case .standardizationSucceeded(let sourceAsset, _, _):
            return InputStatus.preparing(sourceAsset)
        case .standardizationFailed(let sourceAsset, _):
            return InputStatus.preparing(sourceAsset)
        case .awaitingUploadConfirmation(let uploadInfo):
            return InputStatus.awaitingUploadConfirmation(
                uploadInfo.sourceAsset()
            )
        case .uploadInProgress(let uploadInfo, let transportStatus):
            return InputStatus.uploadInProgress(
                uploadInfo.sourceAsset(),
                transportStatus
            )
        case .uploadPaused(let uploadInfo, let transportStatus):
            return InputStatus.uploadPaused(
                uploadInfo.sourceAsset(),
                transportStatus
            )
        case .uploadSucceeded(let uploadInfo, let success):
            return InputStatus.uploadSucceeded(
                uploadInfo.sourceAsset(),
                success
            )
        case .uploadFailed(let uploadInfo, let error):
            return InputStatus.uploadFailed(
                uploadInfo.sourceAsset(),
                error
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

    /**
     Confirms upload if input standardization did not succeed
     */
    public typealias NonStandardInputHandler = () -> Bool

    /**
     If set will be executed by the SDK when input standardization
     hadn't succeeded, return <doc:true> to continue the upload
     or return <doc:false> to cancel the upload
     */
    public var nonStandardInputHandler: NonStandardInputHandler?

    private let manageBySDK: Bool
    var id: String {
        uploadInfo.id
    }
    private let uploadManager: UploadManager
    private let inputInspector: UploadInputInspector
    private let inputStandardizer: UploadInputStandardizer = UploadInputStandardizer()
    
    internal var fileWorker: ChunkedFileUploader?

    /**
     Represents the state of an upload in progress.
     */
    public struct TransportStatus : Sendable, Hashable {
        /**
         The percentage of file bytes received by the server
         accepting the upload
         */
        public let progress: Progress?
        /**
         A timestamp indicating when this status was generated
         */
        public let updatedTime: TimeInterval
        /**
         The start time of the upload, nil if the upload
         has never been started
         */
        public let startTime: TimeInterval?
        /**
         Indicates if the upload has been paused
         */
        public let isPaused: Bool
    }

    /**
     An fatal error that ocurred during the upload process. The last-known state of the upload is available, as well as the Error that stopped the upload
     */
    public struct UploadError : Error {
        public let lastStatus: TransportStatus?
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
        let asset = AVAsset(url: videoFileURL)
        self.init(
            input: UploadInput(
                asset: asset,
                info: UploadInfo(
                    id: UUID().uuidString,
                    uploadURL: uploadURL,
                    options: UploadOptions(
                        inputStandardization: inputStandardization,
                        transport: UploadOptions.Transport(
                            chunkSizeInBytes: chunkSize,
                            retriesPerChunk: retriesPerChunk
                        ),
                        eventTracking: eventTracking
                    )
                )
            ),
            uploadManager: .shared,
            inputInspector: .shared
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
        let asset = AVAsset(
            url: inputFileURL
        )
        self.init(
            input: UploadInput(
                asset: asset,
                info: UploadInfo(
                    uploadURL: uploadURL,
                    options: options
                )
            ),
            manage: true,
            uploadManager: .shared,
            inputInspector: .shared
        )
    }

    init(
        input: UploadInput,
        manage: Bool = true,
        uploadManager: UploadManager,
        inputInspector: AVFoundationUploadInputInspector = .shared
    ) {
        self.input = input
        self.manageBySDK = manage
        self.uploadManager = uploadManager
        self.inputInspector = inputInspector
        // TODO: Same for UploadInputStandardizer when it gets wired in
    }

    init(
        input: UploadInput,
        manage: Bool = true,
        uploadManager: UploadManager,
        inputInspector: UploadInputInspector
    ) {
        self.input = input
        self.manageBySDK = manage
        self.uploadManager = uploadManager
        self.inputInspector = inputInspector
        // TODO: Same for UploadInputStandardizer when it gets wired in
    }

    internal convenience init(
        wrapping uploader: ChunkedFileUploader,
        uploadManager: UploadManager
    ) {
        self.init(
            input: UploadInput(
                status: .uploadInProgress(
                    uploader.uploadInfo,
                    TransportStatus(
                        progress: uploader.currentState.progress ?? Progress(),
                        updatedTime: 0,
                        startTime: 0,
                        isPaused: false
                    )
                )
            ),
            uploadManager: .shared,
            inputInspector: .shared
        )
        self.fileWorker = uploader

        handleStateUpdate(uploader.currentState)
        uploader.addDelegate(
            withToken: id,
            InternalUploaderDelegate { [weak self] state in
                guard let self = self else {
                    return
                }

                self.handleStateUpdate(state)
            }
        )
    }

    /**
     Handles state updates for this upload in your app.
     */
    public typealias StateHandler = (TransportStatus) -> Void

    /**
     If set will receive progress updates for this upload,
     updates will not be received less than 100ms apart
     */
    public var progressHandler: StateHandler?

    public struct Success : Sendable, Hashable {
        public let finalState: TransportStatus
    }

    /**
     The current status of the upload. This object is updated periodically. To listen for changes, use ``progressHandler``
     */
    public var uploadStatus: TransportStatus? {
        input.transportStatus
    }

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
    public var inProgress: Bool {
        if case InputStatus.uploadInProgress = inputStatus {
            return true
        } else {
            return false
        }
    }
    
    /**
     True if this upload was completed
     */
    public var complete: Bool {
        if case InputStatus.uploadSucceeded = inputStatus {
            return true
        } else if case InputStatus.uploadFailed = inputStatus {
            return true
        } else {
            return false
        }
    }
    
    /**
    URL to the file that will be uploaded, will return nil until
     the upload has been prepared
     */
    public var videoFile: URL? {
        return fileWorker?.inputFileURL
    }
    
    /**
     The remote endpoint that this object uploads to
     */
    public var uploadURL: URL {
        return uploadInfo.uploadURL
    }
    // TODO: Computed Properties for some other UploadInfo properties
    
    /**
     Begins the upload. You can control what happens when the upload is already started. If `forceRestart` is true, the upload will be restarted. Otherwise, nothing will happen. The default is not to restart
     */
    public func start(forceRestart: Bool = false) {

        let videoFile = (input.sourceAsset as! AVURLAsset).url

        if self.manageBySDK {
            // See if there's anything in progress already
            fileWorker = uploadManager.findChunkedFileUploader(inputFileURL: videoFile)
        }
        if fileWorker != nil && !forceRestart {
            MuxUploadSDK.logger?.warning("start() called but upload is already in progress")
            fileWorker?.addDelegate(
                withToken: id,
                InternalUploaderDelegate {
                    [self] state in handleStateUpdate(state)
                }
            )
            fileWorker?.start()
            return
        }

        // Start a new upload

        if case UploadInput.Status.ready = input.status {
            input.status = .started(input.sourceAsset, uploadInfo)
            startInspection(videoFile: videoFile)
        } else if forceRestart {
            cancel()
        }
    }

    func startInspection(
        videoFile: URL
    ) {
        if !uploadInfo.options.inputStandardization.isEnabled {
            startNetworkTransport(videoFile: videoFile)
        } else {
            let inputStandardizationStartTime = Date()
            let reporter = Reporter.shared

            // For consistency report non-std
            // input size. Should the std size
            // be reported too?
            // FIXME: if file size is zero, should
            // instead throw an error since upload
            // will likely fail
            let inputSize = (try? FileManager.default.fileSizeOfItem(
                atPath: videoFile.path
            )) ?? 0

            input.status = .underInspection(input.sourceAsset, uploadInfo)
            inputInspector.performInspection(
                sourceInput: input.sourceAsset
            ) { inspectionResult in
                self.inspectionResult = inspectionResult

                switch inspectionResult {
                case .inspectionFailure:
                    // Request upload confirmation
                    // before proceeding. If handler unset,
                    // by default do not cancel upload if
                    // input standardization fails
                    let shouldCancelUpload = self.nonStandardInputHandler?() ?? false

                    reporter.reportUploadInputStandardizationFailure(
                        errorDescription: "Input inspection failure",
                        inputDuration: inspectionResult.sourceInputDuration.seconds,
                        inputSize: inputSize,
                        nonStandardInputReasons: [],
                        options: self.uploadInfo.options,
                        standardizationEndTime: Date(),
                        standardizationStartTime: inputStandardizationStartTime,
                        uploadCanceled: shouldCancelUpload,
                        uploadURL: self.uploadURL
                    )

                    if !shouldCancelUpload {
                        self.startNetworkTransport(
                            videoFile: videoFile
                        )
                    } else {
                        self.fileWorker?.cancel()
                        self.uploadManager.acknowledgeUpload(id: self.id)
                        self.input.processUploadCancellation()
                    }

                    self.startNetworkTransport(videoFile: videoFile)
                case .standard:
                    self.startNetworkTransport(videoFile: videoFile)
                case .nonstandard(
                    let reasons, _
                ):
                    print("""
                    Detected Nonstandard Reasons

                    \(dump(reasons, indent: 4))

                    """
                    )

                    // TODO: inject Date() for testing purposes
                    let outputFileName = "upload-\(Date().timeIntervalSince1970)"

                    let outputDirectory = FileManager.default.temporaryDirectory
                    let outputURL = URL(
                        fileURLWithPath: outputFileName,
                        relativeTo: outputDirectory
                    )
                    let maximumResolution = self.input
                        .uploadInfo
                        .options
                        .inputStandardization
                        .maximumResolution

                    self.inputStandardizer.standardize(
                        id: self.id,
                        sourceAsset: AVAsset(url: videoFile),
                        maximumResolution: maximumResolution,
                        outputURL: outputURL
                    ) { sourceAsset, standardizedAsset, error in

                        if let error {
                            // Request upload confirmation
                            // before proceeding. If handler unset,
                            // by default do not cancel upload if
                            // input standardization fails
                            let shouldCancelUpload = self.nonStandardInputHandler?() ?? false

                            reporter.reportUploadInputStandardizationFailure(
                                errorDescription: error.localizedDescription,
                                inputDuration: inspectionResult.sourceInputDuration.seconds,
                                inputSize: inputSize,
                                nonStandardInputReasons: reasons,
                                options: self.uploadInfo.options,
                                standardizationEndTime: Date(),
                                standardizationStartTime: inputStandardizationStartTime,
                                uploadCanceled: shouldCancelUpload,
                                uploadURL: self.uploadURL
                            )

                            if !shouldCancelUpload {
                                self.startNetworkTransport(
                                    videoFile: videoFile
                                )
                            } else {
                                self.fileWorker?.cancel()
                                self.uploadManager.acknowledgeUpload(id: self.id)
                                self.input.processUploadCancellation()
                            }
                        } else {
                            reporter.reportUploadInputStandardizationSuccess(
                                inputDuration: inspectionResult.sourceInputDuration.seconds,
                                inputSize: inputSize,
                                options: self.uploadInfo.options,
                                nonStandardInputReasons: reasons,
                                standardizationEndTime: Date(),
                                standardizationStartTime: inputStandardizationStartTime,
                                uploadURL: self.uploadURL
                            )

                            self.startNetworkTransport(
                                videoFile: outputURL,
                                duration: inspectionResult.sourceInputDuration
                            )
                        }

                        self.inputStandardizer.acknowledgeCompletion(id: self.id)
                    }
                }
            }
        }
    }

    func startNetworkTransport(
        videoFile: URL
    ) {
        let completedUnitCount = UInt64(uploadStatus?.progress?.completedUnitCount ?? 0)

        let fileWorker = ChunkedFileUploader(
            uploadInfo: input.uploadInfo,
            inputFileURL: videoFile,
            file: ChunkedFile(chunkSize: input.uploadInfo.options.transport.chunkSizeInBytes),
            startingByte: completedUnitCount
        )
        fileWorker.addDelegate(
            withToken: id,
            InternalUploaderDelegate { [self] state in handleStateUpdate(state) }
        )
        fileWorker.start()
        self.fileWorker = fileWorker
<<<<<<< HEAD
        uploadManager.registerUpload(self)
=======
        let transportStatus = TransportStatus(
            progress: fileWorker.currentState.progress ?? Progress(),
            updatedTime: Date().timeIntervalSince1970,
            startTime: Date().timeIntervalSince1970,
            isPaused: false
        )
        self.input.processStartNetworkTransport(
            startingTransportStatus: transportStatus
        )
        inputStatusHandler?(inputStatus)
>>>>>>> 071c77b (Input standardization 2 (#41))
    }

    func startNetworkTransport(
        videoFile: URL,
        duration: CMTime
    ) {
        let completedUnitCount = UInt64(uploadStatus?.progress?.completedUnitCount ?? 0)

        let fileWorker = ChunkedFileUploader(
            uploadInfo: input.uploadInfo,
            inputFileURL: videoFile,
            file: ChunkedFile(chunkSize: input.uploadInfo.options.transport.chunkSizeInBytes),
            startingByte: completedUnitCount
        )
        fileWorker.addDelegate(
            withToken: id,
            InternalUploaderDelegate { [self] state in handleStateUpdate(state) }
        )
        fileWorker.start(duration: duration)
        uploadManager.registerUpload(self)
        self.fileWorker = fileWorker
        let transportStatus = TransportStatus(
            progress: fileWorker.currentState.progress ?? Progress(),
            updatedTime: Date().timeIntervalSince1970,
            startTime: Date().timeIntervalSince1970,
            isPaused: false
        )
        self.input.processStartNetworkTransport(
            startingTransportStatus: transportStatus
        )
        inputStatusHandler?(inputStatus)
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
        input.processUploadCancellation()
        progressHandler = nil
        resultHandler = nil
    }
    
    private func handleStateUpdate(_ state: ChunkedFileUploader.InternalUploadState) {
        switch state {
        case .success(let result): do {
            let transportStatus = TransportStatus(
                progress: result.finalProgress,
                updatedTime: result.finishTime,
                startTime: result.startTime,
                isPaused: false
            )
            let successDetails = MuxUpload.Success(finalState: transportStatus)
            input.processUploadSuccess(transportStatus: transportStatus)
            resultHandler?(Result<Success, UploadError>.success(successDetails))
            fileWorker?.removeDelegate(withToken: id)
            fileWorker = nil
        }
        case .failure(let error): do {
            let parsedError = error.parseAsUploadError(
                lastSeenUploadStatus: input.transportStatus ?? TransportStatus(
                    progress: nil,
                    updatedTime: Date().timeIntervalSince1970,
                    startTime: 0,
                    isPaused: false
                )
            )
            input.processUploadFailure(error: parsedError)
            if case .cancelled = parsedError.code {
                // This differs from what MuxUpload does
                // when cancelled with an external API call
                MuxUploadSDK.logger?.info("task canceled")
                let canceledStatus = MuxUpload.TransportStatus(
                    progress: input.transportStatus?.progress,
                    updatedTime: input.transportStatus?.updatedTime ?? Date().timeIntervalSince1970,
                    startTime: input.transportStatus?.startTime ?? Date().timeIntervalSince1970,
                    isPaused: true
                )
                progressHandler?(canceledStatus)
            } else {
                resultHandler?(Result.failure(parsedError))
            }
            fileWorker?.removeDelegate(withToken: id)
            fileWorker = nil
        }
        case .uploading(let update): do {
            let status = TransportStatus(
                progress: update.progress,
                updatedTime: update.updateTime,
                startTime: update.startTime,
                isPaused: false
            )
            if update.progress.totalUnitCount == update.progress.completedUnitCount {
                input.processUploadSuccess(
                    transportStatus: status
                )
            } else {
                input.status = .uploadInProgress(
                    input.uploadInfo,
                    status
                )
            }
            progressHandler?(status)
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
        lastStatus: MuxUpload.TransportStatus
    ) {
        self.lastStatus = lastStatus
        self.code = MuxErrorCase.unknown
        self.message = ""
        self.reason = nil
    }
}

fileprivate class InternalUploaderDelegate : ChunkedFileUploaderDelegate {
    let outerDelegate: (ChunkedFileUploader.InternalUploadState) -> Void

    init(
        outerDelegate: @escaping (ChunkedFileUploader.InternalUploadState) -> Void
    ) {
        self.outerDelegate = outerDelegate
    }

    func chunkedFileUploader(_ uploader: ChunkedFileUploader, stateUpdated state: ChunkedFileUploader.InternalUploadState) {
        outerDelegate(state)
    }
}

extension MuxUpload.UploadError: Equatable {
    public static func == (lhs: MuxUpload.UploadError, rhs: MuxUpload.UploadError) -> Bool {
        return lhs.message == rhs.message &&
                lhs.lastStatus == rhs.lastStatus &&
                lhs.code == rhs.code &&
                lhs.reason?.localizedDescription == rhs.reason?.localizedDescription
    }
}

public extension Error {
    func asMuxUploadError() -> MuxUpload.UploadError? {
        return self as? MuxUpload.UploadError
    }
}

extension Error {
    /// Parses Errors thrown by this SDK, wrapping the internal error types in a public error
    func parseAsUploadError(lastSeenUploadStatus: MuxUpload.TransportStatus) -> MuxUpload.UploadError {
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
