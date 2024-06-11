//
//  DirectUpload.swift
//  Mux Upload SDK
//
//  Created by Emily Dixon on 2/7/23.
//

import AVFoundation
import Foundation

/// Indicates whether a finished upload failed due to an error
/// or succeeded along with details
public typealias DirectUploadResult = Result<DirectUpload.SuccessDetails, DirectUploadError>

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
/// let upload = DirectUpload(
///   uploadURL: myDirectUploadURL,
///   inputFileURL: myInputFileURL,
/// )
///
/// upload.progressHandler = { state in
///   print("Upload Progress: \(state.progress.fractionCompleted ?? 0)")
/// }
///
/// upload.resultHandler = { result in
///   switch result {
///     case .success(let success):
///       print("Upload Success!")
///     case .failure(let error):
///       print("Upload Error: \(error.localizedDescription)")
///   }
/// }
///
/// upload.start()
/// ```
///
/// Uploads created by this SDK are globally managed by default, 
/// and can be resumed after failures or after an application
/// restart or termination. For more see ``UploadManager``.
public final class DirectUpload {

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

    /// The status of the upload input as the upload goes
    /// through its lifecycle
    public enum InputStatus {
        /// Upload initialized and not yet started
        case ready(AVAsset)
        /// Upload started by a call to ``DirectUpload.start(forceRestart:)``
        case started(AVAsset)
        /// Upload is being prepared for transport to the
        /// server. If input standardization was requested,
        /// this stage includes the inspection and standardization
        /// of input formats
        case preparing(AVAsset)
        /// SDK is waiting for confirmation to continue the
        /// upload despite being unable to standardize input
        case awaitingConfirmation(AVAsset)
        /// Transport of upload inputs is in progress
        case transportInProgress(AVAsset, TransportStatus)
        /// Upload has been paused
        case paused(AVAsset, TransportStatus)
        /// Direct upload has succeeded and all inputs
        /// transported or upload failed with a fatal error
        case finished(AVAsset, DirectUploadResult)
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
        case .awaitingUploadConfirmation(let sourceAsset, _):
            return InputStatus.awaitingConfirmation(
                sourceAsset
            )
        case .uploadInProgress(let sourceAsset, _, let transportStatus):
            return InputStatus.transportInProgress(
                sourceAsset,
                transportStatus
            )
        case .uploadPaused(let sourceAsset, _, let transportStatus):
            return InputStatus.paused(
                sourceAsset,
                transportStatus
            )
        case .uploadSucceeded(let sourceAsset, _, let success):
            return InputStatus.finished(
                sourceAsset,
                .success(success)
            )
        case .uploadFailed(let sourceAsset, _, let error):
            return InputStatus.finished(
                sourceAsset,
                .failure(error)
            )
        }
    }


    /// AVAsset containing the input source
    public var inputAsset: AVAsset {
        switch input.status {
        case .ready(let sourceAsset, _):
            return sourceAsset
        case .started(let sourceAsset, _):
            return sourceAsset
        case .underInspection(let sourceAsset, _):
            return sourceAsset
        case .standardizing(let sourceAsset, _):
            return sourceAsset
        case .standardizationSucceeded(let sourceAsset, _, _):
            return sourceAsset
        case .standardizationFailed(let sourceAsset, _):
            return sourceAsset
        case .awaitingUploadConfirmation(let sourceAsset, _):
            return sourceAsset
        case .uploadInProgress(let sourceAsset, _, _):
            return sourceAsset
        case .uploadPaused(let sourceAsset, _, _):
            return sourceAsset
        case .uploadSucceeded(let sourceAsset, _, _):
            return sourceAsset
        case .uploadFailed(let sourceAsset, _, _):
            return sourceAsset
        }
    }

    /// Handles a change in the input status of the upload
    public typealias InputStatusHandler = (InputStatus) -> ()

    /// Sets a handler that gets notified when the status of
    /// the upload changes
    public var inputStatusHandler: InputStatusHandler?

    /// Confirms if upload should proceed when input
    /// standardization does not succeed
    public typealias NonStandardInputHandler = () -> Bool

    /// Sets a handler that will be executed by the SDK
    /// when input standardization doesn't succeed. Return
    /// <doc:true> to continue the upload
    public var nonStandardInputHandler: NonStandardInputHandler?

    private let manageBySDK: Bool
    var id: String {
        uploadInfo.id
    }
    private let uploadManager: DirectUploadManager
    private let inputInspector: UploadInputInspector
    private let inputStandardizer: UploadInputStandardizer = UploadInputStandardizer()
    
    internal var fileWorker: ChunkedFileUploader?

    /// Represents the state of an upload when it is being 
    /// sent to Mux over the network
    public struct TransportStatus : Sendable, Hashable {
        /// The percentage of file bytes received at the 
        /// upload destination
        public let progress: Progress?
        /// Timestamp from when this update was generated
        public let updatedTime: TimeInterval
        /// The start time of the upload, nil if the upload
        /// has never been started
        public let startTime: TimeInterval?
        /// Indicates if the upload has been paused
        public let isPaused: Bool
    }

    /// Initializes a DirectUpload from a local file URL
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
        options: DirectUploadOptions = .default
    ) {
        let asset = AVURLAsset(
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
        uploadManager: DirectUploadManager,
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
        uploadManager: DirectUploadManager,
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
        uploadManager: DirectUploadManager
    ) {
        self.init(
            input: UploadInput(
                status: .uploadInProgress(
                    AVURLAsset(url: uploader.inputFileURL),
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

    
    /// Handles updates when upload data is sent over the network
    public typealias StateHandler = (TransportStatus) -> Void

    /// Sets handler that receives progress updates when
    /// the upload transits over the network. Updates will
    /// not be received less than 100ms apart
    public var progressHandler: StateHandler?

    /// Details of a successfully completed ``DirectUpload``
    public struct SuccessDetails : Sendable, Hashable {
        public let finalState: TransportStatus
    }

    /// Current status of the upload while it is in transit.
    /// To listen for changes, use ``progressHandler``
    /// - SeeAlso: progressHandler
    public var uploadStatus: TransportStatus? {
        input.transportStatus
    }

    /// Handles completion of the uploads execution
    /// - SeeAlso: resultHandler
    public typealias ResultHandler = (DirectUploadResult) -> Void

    /// Sets handler that is notified when the upload completes
    /// execution or if it fails due to an error
    /// - SeeAlso: ResultHandler
    public var resultHandler: ResultHandler?

    /// Indicates if the upload is currently in progress
    /// and not paused
    public var inProgress: Bool {
        if case InputStatus.transportInProgress = inputStatus {
            return true
        } else {
            return false
        }
    }

    /// Indicates if the upload has been completed
    public var complete: Bool {
        if case InputStatus.finished = inputStatus {
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
    
    /// URL of the remote upload destination
    public var uploadURL: URL {
        return uploadInfo.uploadURL
    }

    /// Starts the upload.
    /// - Parameter forceRestart: if true, the upload will be
    /// restarted. If false the upload will resume from where
    /// it left off if paused, otherwise the upload will change.
    public func start(forceRestart: Bool = false) {
        if self.manageBySDK {
            // See if there's anything in progress already
            fileWorker = uploadManager.findChunkedFileUploader(
                inputFileURL: input.sourceAsset.url
            )
        }
        if fileWorker != nil && !forceRestart {
            SDKLogger.logger?.warning("start() called but upload is already in progress")
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
            startInspection(sourceAsset: input.sourceAsset)
        } else if forceRestart {
            cancel()
        }
    }

    func startInspection(
        sourceAsset: AVURLAsset
    ) {
        if !uploadInfo.options.inputStandardization.isRequested {
            startNetworkTransport(videoFile: sourceAsset.url)
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
                atPath: input.sourceAsset.url.absoluteString
            )) ?? 0

            input.status = .underInspection(input.sourceAsset, uploadInfo)
            inputInspector.performInspection(
                sourceInput: input.sourceAsset, 
                maximumResolution: uploadInfo.options.inputStandardization.maximumResolution
            ) { inspectionResult, inputDuration, inspectionError in
                self.inspectionResult = inspectionResult

                switch (inspectionResult, inspectionError) {
                case (.none, .none):
                    // Corner case
                    self.handleInspectionFailure(
                        inspectionError: UploadInputInspectionError.inspectionFailure,
                        inputDuration: inputDuration,
                        inputSize: inputSize,
                        inputStandardizationStartTime: inputStandardizationStartTime,
                        sourceAsset: sourceAsset
                    )
                case (.none, .some(let error)):
                    self.handleInspectionFailure(
                        inspectionError: error,
                        inputDuration: inputDuration,
                        inputSize: inputSize,
                        inputStandardizationStartTime: inputStandardizationStartTime,
                        sourceAsset: sourceAsset
                    )
                case (.some(let result), .none):
                    if result.isStandardInput {

                        if result.rescalingDetails.needsRescaling {
                            SDKLogger.logger?.debug(
                                "Detected Input Needs Rescaling"
                            )

                            // TODO: inject Date() for testing purposes
                            let outputFileName = "upload-\(Date().timeIntervalSince1970)"

                            let outputDirectory = FileManager.default.temporaryDirectory
                            let outputURL = URL(
                                fileURLWithPath: outputFileName,
                                relativeTo: outputDirectory
                            )

                            self.inputStandardizer.standardize(
                                id: self.id,
                                sourceAsset: sourceAsset,
                                rescalingDetails: result.rescalingDetails,
                                outputURL: outputURL
                            ) { sourceAsset, standardizedAsset, error in

                                if let _ = error {
                                    // Request upload confirmation
                                    // before proceeding. If handler unset,
                                    // by default do not cancel upload if
                                    // input standardization fails
                                    let shouldCancelUpload = self.nonStandardInputHandler?() ?? false

                                    if !shouldCancelUpload {
                                        self.startNetworkTransport(
                                            videoFile: sourceAsset.url
                                        )
                                    } else {
                                        self.fileWorker?.cancel()
                                        self.uploadManager.acknowledgeUpload(id: self.id)
                                        self.input.processUploadCancellation()
                                    }
                                } else {
                                    self.startNetworkTransport(
                                        videoFile: outputURL,
                                        duration: inputDuration
                                    )
                                }

                                self.inputStandardizer.acknowledgeCompletion(id: self.id)
                            }

                        } else {
                            self.startNetworkTransport(
                                videoFile: sourceAsset.url
                            )
                        }
                    } else {
                        SDKLogger.logger?.debug(
                            """
                            Detected Nonstandard Reasons

                            \(dump(result.nonStandardInputReasons, indent: 4))

                            """
                        )

                        // TODO: inject Date() for testing purposes
                        let outputFileName = "upload-\(Date().timeIntervalSince1970)"

                        let outputDirectory = FileManager.default.temporaryDirectory
                        let outputURL = URL(
                            fileURLWithPath: outputFileName,
                            relativeTo: outputDirectory
                        )

                        self.inputStandardizer.standardize(
                            id: self.id,
                            sourceAsset: sourceAsset,
                            rescalingDetails: result.rescalingDetails,
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
                                    inputDuration: inputDuration.seconds,
                                    inputSize: inputSize,
                                    nonStandardInputReasons: result.nonStandardInputReasons,
                                    options: self.uploadInfo.options,
                                    standardizationEndTime: Date(),
                                    standardizationStartTime: inputStandardizationStartTime,
                                    uploadCanceled: shouldCancelUpload,
                                    uploadURL: self.uploadURL
                                )

                                if !shouldCancelUpload {
                                    self.startNetworkTransport(
                                        videoFile: sourceAsset.url
                                    )
                                } else {
                                    self.fileWorker?.cancel()
                                    self.uploadManager.acknowledgeUpload(id: self.id)
                                    self.input.processUploadCancellation()
                                }
                            } else {
                                reporter.reportUploadInputStandardizationSuccess(
                                    inputDuration: inputDuration.seconds,
                                    inputSize: inputSize,
                                    options: self.uploadInfo.options,
                                    nonStandardInputReasons: result.nonStandardInputReasons,
                                    standardizationEndTime: Date(),
                                    standardizationStartTime: inputStandardizationStartTime,
                                    uploadURL: self.uploadURL
                                )

                                self.startNetworkTransport(
                                    videoFile: outputURL,
                                    duration: inputDuration
                                )
                            }

                            self.inputStandardizer.acknowledgeCompletion(id: self.id)
                        }
                    }
                case (.some(_), .some(let error)):
                    self.handleInspectionFailure(
                        inspectionError: error,
                        inputDuration: inputDuration,
                        inputSize: inputSize,
                        inputStandardizationStartTime: inputStandardizationStartTime,
                        sourceAsset: sourceAsset
                    )
                }
            }
        }
    }

    func handleInspectionFailure(
        inspectionError: Error,
        inputDuration: CMTime,
        inputSize: UInt64,
        inputStandardizationStartTime: Date,
        sourceAsset: AVURLAsset
    ) {
        let reporter = Reporter.shared
        // Request upload confirmation
        // before proceeding. If handler unset,
        // by default do not cancel upload if
        // input standardization fails
        let shouldCancelUpload = self.nonStandardInputHandler?() ?? false

        reporter.reportUploadInputStandardizationFailure(
            errorDescription: "Input inspection failure",
            inputDuration: inputDuration.seconds,
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
                videoFile: sourceAsset.url
            )
        } else {
            self.fileWorker?.cancel()
            self.uploadManager.acknowledgeUpload(id: self.id)
            self.input.processUploadCancellation()
        }
    }

    func readyForTransport() -> Bool {
        switch inputStatus {
        case .ready:
            return false
        case .started:
            return true
        case .preparing:
            return true
        case .awaitingConfirmation:
            return true
        case .transportInProgress:
            return false
        case .paused:
            return false
        case .finished:
            return false
        }
    }

    func startNetworkTransport(
        videoFile: URL
    ) {
        guard readyForTransport() else {
            return
        }

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
        self.fileWorker = fileWorker
        uploadManager.registerUpload(self)
        fileWorker.start()
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

    func startNetworkTransport(
        videoFile: URL,
        duration: CMTime
    ) {
        
        guard readyForTransport() else {
            return
        }

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
        self.fileWorker = fileWorker
        uploadManager.registerUpload(self)
        fileWorker.start(duration: duration)
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
    
    
    /// Suspends upload execution. Temporary files will be
    /// kept unchanged and the upload can be resumed by calling
    /// ``start(forceRestart:)`` with forceRestart set to `false`
    /// to resume the upload from where it left off.
    ///
    /// Call ``cancel()`` to permanently halt the upload.
    /// - SeeAlso cancel()
    public func pause() {
        fileWorker?.pause()
    }
    
    /// Cancels an upload that has already been started.
    /// Any delegates or handlers set prior to this will
    /// receive no further updates.
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
            let successDetails = DirectUpload.SuccessDetails(finalState: transportStatus)
            input.processUploadSuccess(transportStatus: transportStatus)
            resultHandler?(Result<SuccessDetails, DirectUploadError>.success(successDetails))
            fileWorker?.removeDelegate(withToken: id)
            fileWorker = nil
        }
        case .failure(let error): do {
            let parsedError = parseAsUploadError(
                lastSeenUploadStatus: input.transportStatus ?? TransportStatus(
                    progress: nil,
                    updatedTime: Date().timeIntervalSince1970,
                    startTime: 0,
                    isPaused: false
                ),
                error: error
            )
            input.processUploadFailure(error: parsedError)
            if case .cancelled = parsedError.kind {
                // This differs from what DirectUpload does
                // when cancelled with an external API call
                SDKLogger.logger?.info("task canceled")
                let canceledStatus = DirectUpload.TransportStatus(
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
                    input.sourceAsset,
                    input.uploadInfo,
                    status
                )
            }
            progressHandler?(status)
        }
        default: do {}
        }
    }
}

extension DirectUploadError {
    internal init(
        lastStatus: DirectUpload.TransportStatus
    ) {
        self.lastStatus = lastStatus
        self.kind = .unknown
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

extension DirectUploadError: Equatable {
    public static func == (lhs: DirectUploadError, rhs: DirectUploadError) -> Bool {
        return lhs.message == rhs.message &&
                lhs.lastStatus == rhs.lastStatus &&
                lhs.kind == rhs.kind &&
                lhs.reason?.localizedDescription == rhs.reason?.localizedDescription
    }
}

extension DirectUpload {
    /// Parses Errors thrown by this SDK, wrapping the internal error types in a public error
    func parseAsUploadError(
        lastSeenUploadStatus: DirectUpload.TransportStatus,
        error: Error
    ) -> DirectUploadError {
        if (error.asCancellationError()) != nil {
            return DirectUploadError(
                lastStatus: lastSeenUploadStatus,
                kind: .cancelled,
                message: "Cancelled by user",
                reason: error
            )
        } else if (error.asChunkWorkerError()) != nil {
            if let realCause = error.asHttpError() {
                return DirectUploadError(
                    lastStatus: lastSeenUploadStatus,
                    kind: .http,
                    message: "Http Failed: \(realCause.statusCode): \(realCause.statusMsg)",
                    reason: error
                )
            } else {
                return DirectUploadError(
                    lastStatus: lastSeenUploadStatus,
                    kind: .connection,
                    message: "Connection error",
                    reason: error
                )
            }
        } else if let realError = error.asInternalUploaderError() {
            // All DirectUploadError does is wrap ChunkedFile
            // and ChunkWorker errors
            return DirectUploadError(
                lastStatus: lastSeenUploadStatus,
                kind: .unknown,
                message: "Unknown Internal Error",
                reason: realError
            )
        } else if let realError = error.asChunkedFileError() {
            switch realError {
            case .fileHandle(_): return DirectUploadError(
                lastStatus: lastSeenUploadStatus,
                kind: .file,
                message: "Couldn't read file for upload",
                reason: error
            )
            case .invalidState(let msg): return DirectUploadError(
                lastStatus: lastSeenUploadStatus,
                kind: .unknown,
                message: "Internal error: \(msg)",
                reason: nil
            )
            }
        } else {
            return DirectUploadError(
                lastStatus: lastSeenUploadStatus
            )
        }
    }
}

/// An unrecoverable error occurring while the upload was
/// executing The last-known state of the upload is available,
/// as well as the Error that stopped the upload
public struct DirectUploadError : Error {
    /// Represents the possible error cases from a ``DirectUpload``
    public enum Kind : Int {
        /// The cause of the error is not known
        case unknown = -1
        /// The direct upload was cancelled
        case cancelled = 0
        /// The input file could not be read or processed
        case file = 1
        /// The direct upload could not be completed due to an HTTP error
        case http = 2
        /// The direct upload could not be completed due to a connection error
        case connection = 3
    }

    public let lastStatus: DirectUpload.TransportStatus?
    public let kind: Kind
    public let message: String
    public let reason: Error?

    var localizedDescription: String {
        get {
            return "Error \(kind): \(message). Caused by:\n\t\(String(describing: reason))"
        }
    }

}
