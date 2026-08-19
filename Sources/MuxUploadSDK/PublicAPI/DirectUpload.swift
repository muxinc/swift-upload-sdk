//
//  DirectUpload.swift
//  Mux Upload SDK
//
//  Created by Emily Dixon on 2/7/23.
//

import AVFoundation
import Foundation

private actor DirectUploadPreparationLifecycle {
    struct Attempt: Equatable {
        let id = UUID()
        let inspectionToken = UploadInputInspectionOperationRegistry.Token()
        let standardizationToken = UploadInputStandardizationToken()
    }

    private var activeAttempt: Attempt?

    func begin() -> Attempt? {
        guard activeAttempt == nil else { return nil }
        let attempt = Attempt()
        activeAttempt = attempt
        return attempt
    }

    func isActive(_ attempt: Attempt) -> Bool {
        activeAttempt == attempt
    }

    func performIfActive(
        for attempt: Attempt,
        _ operation: () -> Void
    ) -> Bool {
        guard activeAttempt == attempt else { return false }
        operation()
        return true
    }

    func cancel() -> Attempt? {
        defer { activeAttempt = nil }
        return activeAttempt
    }

    func commitTransport(
        for attempt: Attempt,
        _ commit: () -> Void
    ) -> Bool {
        guard activeAttempt == attempt else { return false }
        activeAttempt = nil
        commit()
        return true
    }
}

/// Serializes the short check-and-register portion of transport startup. The
/// manager's existing URL de-duplication contract depends on those two actions
/// being atomic across independently-created `DirectUpload` instances.
private actor DirectUploadTransportCommitCoordinator {
    static let shared = DirectUploadTransportCommitCoordinator()

    private var isOccupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func coordinate(_ operation: () async -> Bool) async -> Bool {
        await acquire()
        defer { release() }
        return await operation()
    }

    private func acquire() async {
        if !isOccupied {
            isOccupied = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        if waiters.isEmpty {
            isOccupied = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// Preserves the call order of the synchronous public lifecycle API while its
/// implementation crosses actor boundaries. Preparation work is launched
/// separately so cancellation can be processed while inspection or conversion
/// is in flight; the final transport commit returns through this same queue.
private final class DirectUploadLifecycleCommandQueue: Sendable {
    private enum Command {
        case start(forceRestart: Bool)
        case cancel(notifyCaller: Bool)
        case commit(
            videoFile: URL,
            duration: CMTime?,
            attempt: DirectUploadPreparationLifecycle.Attempt,
            continuation: CheckedContinuation<Bool, Never>
        )
    }

    private let continuation: AsyncStream<Command>.Continuation
    private let processor: Task<Void, Never>

    init(owner: DirectUpload) {
        var continuation: AsyncStream<Command>.Continuation!
        let stream = AsyncStream<Command> {
            continuation = $0
        }
        self.continuation = continuation
        self.processor = Task { [weak owner] in
            for await command in stream {
                guard let owner else { return }
                switch command {
                case .start(let forceRestart):
                    await owner.processStartCommand(forceRestart: forceRestart)
                case .cancel(let notifyCaller):
                    await owner.cancelAsync(notifyCaller: notifyCaller)
                case .commit(let videoFile, let duration, let attempt, let continuation):
                    // Worker creation can invoke injected or legacy synchronous
                    // code. Keep consuming cancellation commands while the
                    // lifecycle actor arbitrates this commit independently.
                    Task { [weak owner] in
                        let didCommit = await owner?.processTransportCommit(
                            videoFile: videoFile,
                            duration: duration,
                            attempt: attempt
                        ) ?? false
                        continuation.resume(returning: didCommit)
                    }
                }
            }
        }
    }

    deinit {
        continuation.finish()
        processor.cancel()
    }

    func start(forceRestart: Bool) {
        continuation.yield(.start(forceRestart: forceRestart))
    }

    func cancel(notifyCaller: Bool) {
        continuation.yield(.cancel(notifyCaller: notifyCaller))
    }

    func commit(
        videoFile: URL,
        duration: CMTime?,
        attempt: DirectUploadPreparationLifecycle.Attempt
    ) async -> Bool {
        await withCheckedContinuation { resultContinuation in
            let result = continuation.yield(
                .commit(
                    videoFile: videoFile,
                    duration: duration,
                    attempt: attempt,
                    continuation: resultContinuation
                )
            )
            if case .terminated = result {
                resultContinuation.resume(returning: false)
            }
        }
    }
}

private enum DirectUploadPreparationError: LocalizedError {
    case plannerFallback(StandardInputPlan.FallbackReason)
    case outputRejected(StandardInputOutputValidation)

    var errorDescription: String? {
        switch self {
        case .plannerFallback(let reason):
            return "Standard Input planner selected original-upload fallback: \(reason)"
        case .outputRejected(let validation):
            return "Generated Standard Input output was rejected: \(validation.disposition)"
        }
    }
}

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

    /// Determines whether to cancel the upload when input
    /// standardization does not succeed
    public typealias NonStandardInputHandler = () -> Bool

    /// Sets a handler that will be executed by the SDK
    /// when input standardization doesn't succeed. Return
    /// `true` to cancel the upload, or `false` to
    /// upload the original input. Intentionally preserving
    /// eligible HLG or PQ input does not invoke this handler.
    public var nonStandardInputHandler: NonStandardInputHandler?

    private let manageBySDK: Bool
    var id: String {
        uploadInfo.id
    }
    private let uploadManager: DirectUploadManager
    private let inputInspector: UploadInputInspector
    private let inputInspectionOperations = UploadInputInspectionOperationRegistry()
    private let inputStandardizer: UploadInputStandardizing
    private let preparationLifecycle = DirectUploadPreparationLifecycle()
    private let planner: StandardInputPlanner
    private let outputValidator: StandardInputOutputValidator
    private let capabilityProvider: StandardInputPlanningCapabilityProviding
    private let storagePreflighter: TemporaryStoragePreflighting
    private let fileWorkerFactory: FileWorkerFactory
    private var lifecycleCommands: DirectUploadLifecycleCommandQueue!

    typealias FileWorkerFactory = (
        UploadInfo,
        URL,
        ChunkedFile,
        UInt64
    ) -> ChunkedFileUploader
    
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
        inputInspector: AVFoundationUploadInputInspector = .shared,
        inputStandardizer: UploadInputStandardizing = UploadInputStandardizer(),
        planner: StandardInputPlanner = StandardInputPlanner(),
        outputValidator: StandardInputOutputValidator = StandardInputOutputValidator(),
        capabilityProvider: StandardInputPlanningCapabilityProviding = AVFoundationStandardInputPlanningCapabilityProvider(),
        storagePreflighter: TemporaryStoragePreflighting = FileSystemTemporaryStoragePreflighter(),
        fileWorkerFactory: @escaping FileWorkerFactory = DirectUpload.makeFileWorker
    ) {
        self.input = input
        self.manageBySDK = manage
        self.uploadManager = uploadManager
        self.inputInspector = inputInspector
        self.inputStandardizer = inputStandardizer
        self.planner = planner
        self.outputValidator = outputValidator
        self.capabilityProvider = capabilityProvider
        self.storagePreflighter = storagePreflighter
        self.fileWorkerFactory = fileWorkerFactory
        self.lifecycleCommands = DirectUploadLifecycleCommandQueue(owner: self)
    }

    init(
        input: UploadInput,
        manage: Bool = true,
        uploadManager: DirectUploadManager,
        inputInspector: UploadInputInspector,
        inputStandardizer: UploadInputStandardizing = UploadInputStandardizer(),
        planner: StandardInputPlanner = StandardInputPlanner(),
        outputValidator: StandardInputOutputValidator = StandardInputOutputValidator(),
        capabilityProvider: StandardInputPlanningCapabilityProviding = AVFoundationStandardInputPlanningCapabilityProvider(),
        storagePreflighter: TemporaryStoragePreflighting = FileSystemTemporaryStoragePreflighter(),
        fileWorkerFactory: @escaping FileWorkerFactory = DirectUpload.makeFileWorker
    ) {
        self.input = input
        self.manageBySDK = manage
        self.uploadManager = uploadManager
        self.inputInspector = inputInspector
        self.inputStandardizer = inputStandardizer
        self.planner = planner
        self.outputValidator = outputValidator
        self.capabilityProvider = capabilityProvider
        self.storagePreflighter = storagePreflighter
        self.fileWorkerFactory = fileWorkerFactory
        self.lifecycleCommands = DirectUploadLifecycleCommandQueue(owner: self)
    }

    private static func makeFileWorker(
        uploadInfo: UploadInfo,
        inputFileURL: URL,
        file: ChunkedFile,
        startingByte: UInt64
    ) -> ChunkedFileUploader {
        ChunkedFileUploader(
            uploadInfo: uploadInfo,
            inputFileURL: inputFileURL,
            file: file,
            startingByte: startingByte
        )
    }

    internal convenience init(
        wrapping uploader: ChunkedFileUploader,
        uploadManager: DirectUploadManager
    ) {
        self.init(
            input: UploadInput(
                status: .uploadInProgress(
                    AVURLAsset(url: uploader.uploadInfo.sourceFileURL ?? uploader.inputFileURL),
                    uploader.uploadInfo,
                    TransportStatus(
                        progress: uploader.currentState.progress ?? Progress(),
                        updatedTime: 0,
                        startTime: 0,
                        isPaused: false
                    )
                )
            ),
            uploadManager: uploadManager,
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
        lifecycleCommands.start(forceRestart: forceRestart)
    }

    fileprivate func processStartCommand(forceRestart: Bool) async {
        if self.manageBySDK && fileWorker == nil {
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
        guard case UploadInput.Status.ready = input.status,
              let attempt = await preparationLifecycle.begin() else {
            if forceRestart {
                await cancelAsync(notifyCaller: false)
            }
            return
        }
        guard await preparationLifecycle.isActive(attempt) else { return }
        input.status = .started(input.sourceAsset, input.uploadInfo)
        let sourceAsset = input.sourceAsset
        Task { [weak self] in
            await self?.startInspection(
                sourceAsset: sourceAsset,
                attempt: attempt
            )
        }
    }

    private func startInspection(
        sourceAsset: AVURLAsset,
        attempt: DirectUploadPreparationLifecycle.Attempt
    ) async {
        if !uploadInfo.options.inputStandardization.isRequested {
            await startNetworkTransport(
                videoFile: sourceAsset.url,
                attempt: attempt
            )
            return
        }

        let startedAt = Date()
        let inputSize = (try? FileManager.default.fileSizeOfItem(
            atPath: sourceAsset.url.path
        )) ?? 0
        guard await preparationLifecycle.performIfActive(for: attempt, {
            input.status = .underInspection(sourceAsset, input.uploadInfo)
        }) else { return }

        let operation = UploadInputInspectionOperation()
        await inputInspectionOperations.register(
            operation,
            for: attempt.inspectionToken
        )
        guard await preparationLifecycle.isActive(attempt) else {
            await operation.cancel()
            return
        }
        let outcome = await inputInspector.inspect(
            sourceInput: sourceAsset,
            maximumResolution: uploadInfo.options.inputStandardization.maximumResolution,
            operation: operation
        )
        guard await inputInspectionOperations.claimCompletion(
            for: attempt.inspectionToken
        ), await preparationLifecycle.isActive(attempt) else { return }
        guard let inspection = outcome.result, outcome.error == nil else {
            await handlePreparationFailure(
                error: outcome.error ?? UploadInputInspectionError.inspectionFailure,
                result: outcome.result,
                duration: outcome.duration,
                inputSize: inputSize,
                startedAt: startedAt,
                sourceAsset: sourceAsset,
                attempt: attempt
            )
            return
        }
        inspectionResult = inspection

        let capabilities = await capabilityProvider.capabilities(
            for: inspection,
            sourceAsset: sourceAsset
        )
        guard await preparationLifecycle.isActive(attempt) else { return }
        let plan = planner.plan(
            facts: inspection.mediaFacts,
            options: uploadInfo.options.inputStandardization,
            capabilities: capabilities
        )
        SDKLogger.logger?.debug("Selected Standard Input plan: \(String(describing: plan.action))")
        switch plan.action {
        case .uploadOriginal:
            await startNetworkTransport(
                videoFile: sourceAsset.url,
                attempt: attempt
            )
        case .fallback(let reason):
            await handlePreparationFailure(
                error: DirectUploadPreparationError.plannerFallback(reason),
                result: inspection,
                duration: outcome.duration,
                inputSize: inputSize,
                startedAt: startedAt,
                sourceAsset: sourceAsset,
                attempt: attempt
            )
        case .convert(let conversion):
            await standardize(
                sourceAsset: sourceAsset,
                inspection: inspection,
                conversion: conversion,
                duration: outcome.duration,
                inputSize: inputSize,
                startedAt: startedAt,
                attempt: attempt
            )
        }
    }

    private func standardize(
        sourceAsset: AVURLAsset,
        inspection: UploadInputFormatInspectionResult,
        conversion: StandardInputConversion,
        duration: CMTime,
        inputSize: UInt64,
        startedAt: Date,
        attempt: DirectUploadPreparationLifecycle.Attempt
    ) async {
        let outputURL: URL
        do {
            outputURL = try storagePreflighter.outputURL(
                for: sourceAsset.url,
                duration: duration,
                conversion: conversion
            )
        } catch {
            await handlePreparationFailure(
                error: error,
                result: inspection,
                duration: duration,
                inputSize: inputSize,
                startedAt: startedAt,
                sourceAsset: sourceAsset,
                attempt: attempt
            )
            return
        }
        var transferredOutputOwnership = false
        defer {
            if !transferredOutputOwnership {
                removeOwnedTemporaryFile(outputURL)
            }
        }

        guard await preparationLifecycle.performIfActive(for: attempt, {
            input.status = .standardizing(sourceAsset, input.uploadInfo)
        }) else { return }
        do {
            let generatedAsset = try await inputStandardizer.standardize(
                id: id,
                token: attempt.standardizationToken,
                sourceAsset: sourceAsset,
                rescalingDetails: inspection.rescalingDetails,
                conversion: conversion,
                outputURL: outputURL
            )
            guard await preparationLifecycle.isActive(attempt) else { return }

            let validationOperation = UploadInputInspectionOperation()
            await inputInspectionOperations.register(
                validationOperation,
                for: attempt.inspectionToken
            )
            let generatedOutcome = await inputInspector.inspect(
                sourceInput: generatedAsset,
                maximumResolution: uploadInfo.options.inputStandardization.maximumResolution,
                operation: validationOperation
            )
            guard await inputInspectionOperations.claimCompletion(
                for: attempt.inspectionToken
            ), await preparationLifecycle.isActive(attempt) else { return }
            guard let generatedInspection = generatedOutcome.result,
                  generatedOutcome.error == nil else {
                throw generatedOutcome.error
                    ?? UploadInputInspectionError.inspectionFailure
            }
            let validation = outputValidator.validateGeneratedOutput(
                facts: generatedInspection.mediaFacts,
                sourceTimeline: inspection.timelineFacts,
                outputTimeline: generatedInspection.timelineFacts,
                for: conversion
            )
            guard validation.isAccepted else {
                throw DirectUploadPreparationError.outputRejected(validation)
            }

            Reporter.shared.reportUploadInputStandardizationSuccess(
                inputDuration: duration.seconds,
                inputSize: inputSize,
                options: uploadInfo.options,
                nonStandardInputReasons: inspection.nonStandardInputReasons,
                standardizationEndTime: Date(),
                standardizationStartTime: startedAt,
                uploadURL: uploadURL
            )
            guard await preparationLifecycle.performIfActive(for: attempt, {
                input.status = .standardizationSucceeded(
                    source: sourceAsset,
                    standardized: generatedAsset,
                    uploadInfo: input.uploadInfo
                )
            }) else { return }
            await startNetworkTransport(
                videoFile: generatedAsset.url,
                duration: duration,
                attempt: attempt
            )
            transferredOutputOwnership = fileWorker?.inputFileURL == generatedAsset.url
        } catch is CancellationError {
            return
        } catch {
            guard await preparationLifecycle.isActive(attempt) else { return }
            await handlePreparationFailure(
                error: error,
                result: inspection,
                duration: duration,
                inputSize: inputSize,
                startedAt: startedAt,
                sourceAsset: sourceAsset,
                attempt: attempt
            )
        }
    }

    private func handlePreparationFailure(
        error: Error,
        result: UploadInputFormatInspectionResult?,
        duration: CMTime,
        inputSize: UInt64,
        startedAt: Date,
        sourceAsset: AVURLAsset,
        attempt: DirectUploadPreparationLifecycle.Attempt
    ) async {
        guard await preparationLifecycle.performIfActive(for: attempt, {
            input.status = .standardizationFailed(sourceAsset, input.uploadInfo)
        }) else { return }
        let shouldCancelUpload = nonStandardInputHandler?() ?? false
        Reporter.shared.reportUploadInputStandardizationFailure(
            errorDescription: error.localizedDescription,
            inputDuration: duration.seconds,
            inputSize: inputSize,
            nonStandardInputReasons: result?.nonStandardInputReasons ?? [],
            options: uploadInfo.options,
            standardizationEndTime: Date(),
            standardizationStartTime: startedAt,
            uploadCanceled: shouldCancelUpload,
            uploadURL: uploadURL
        )
        if !shouldCancelUpload {
            await startNetworkTransport(
                videoFile: sourceAsset.url,
                attempt: attempt
            )
        } else {
            await cancelPreparation(for: attempt)
        }
    }

    private func cancelPreparation(
        for attempt: DirectUploadPreparationLifecycle.Attempt
    ) async {
        guard await preparationLifecycle.cancel() == attempt else { return }
        await inputInspectionOperations.cancel(for: attempt.inspectionToken)
        await inputStandardizer.cancel(id: id, token: attempt.standardizationToken)
        let fileWorker = self.fileWorker
        self.fileWorker = nil
        uploadManager.acknowledgeUpload(id: id)
        fileWorker?.cancel()
        input.processUploadCancellation()
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

    private func startNetworkTransport(
        videoFile: URL,
        attempt: DirectUploadPreparationLifecycle.Attempt
    ) async {
        await startNetworkTransport(
            videoFile: videoFile,
            duration: nil,
            attempt: attempt
        )
    }

    private func startNetworkTransport(
        videoFile: URL,
        duration: CMTime?,
        attempt: DirectUploadPreparationLifecycle.Attempt
    ) async {
        guard await preparationLifecycle.isActive(attempt), readyForTransport() else {
            SDKLogger.logger?.info("Tried to start network transport before being ready")
            return
        }
        _ = await lifecycleCommands.commit(
            videoFile: videoFile,
            duration: duration,
            attempt: attempt
        )
    }

    fileprivate func processTransportCommit(
        videoFile: URL,
        duration: CMTime?,
        attempt: DirectUploadPreparationLifecycle.Attempt
    ) async -> Bool {
        await DirectUploadTransportCommitCoordinator.shared.coordinate {
            if self.manageBySDK,
               let existingWorker = self.uploadManager.findChunkedFileUploader(
                   inputFileURL: self.input.sourceAsset.url
               ) {
                return await self.preparationLifecycle.commitTransport(for: attempt) {
                    SDKLogger.logger?.warning(
                        "Reusing the active upload for this input file"
                    )
                    self.fileWorker = existingWorker
                    existingWorker.addDelegate(
                        withToken: self.id,
                        InternalUploaderDelegate { [self] state in handleStateUpdate(state) }
                    )
                    self.handleStateUpdate(existingWorker.currentState)
                    existingWorker.start()
                }
            }

            let completedUnitCount = UInt64(
                self.uploadStatus?.progress?.completedUnitCount ?? 0
            )
            let fileWorker = self.fileWorkerFactory(
                self.input.uploadInfo,
                videoFile,
                ChunkedFile(
                    chunkSize: self.input.uploadInfo.options.transport.chunkSizeInBytes
                ),
                completedUnitCount
            )
            let didCommit = await self.preparationLifecycle.commitTransport(for: attempt) {
                guard self.readyForTransport() else { return }
                SDKLogger.logger?.info("Starting network transport")
                fileWorker.addDelegate(
                    withToken: self.id,
                    InternalUploaderDelegate { [self] state in handleStateUpdate(state) }
                )
                self.fileWorker = fileWorker
                self.uploadManager.registerUpload(self)
                let now = Date().timeIntervalSince1970
                let transportStatus = TransportStatus(
                    progress: fileWorker.currentState.progress ?? Progress(),
                    updatedTime: now,
                    startTime: now,
                    isPaused: false
                )
                self.input.processStartNetworkTransport(
                    startingTransportStatus: transportStatus
                )
                if let duration {
                    fileWorker.start(duration: duration)
                } else {
                    fileWorker.start()
                }
            }
            if !didCommit {
                fileWorker.cancel()
            }
            return didCommit
        }
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
    /// receive no further updates after the resultHandler is called
    public func cancel() {
        lifecycleCommands.cancel(notifyCaller: true)
    }

    fileprivate func cancelAsync(notifyCaller: Bool) async {
        let cancellationHandler = notifyCaller && !isUploadComplete() && isUploadStarted()
            ? resultHandler
            : nil
        let cancellationError = DirectUploadError(
            lastStatus: uploadStatus,
            kind: .cancelled,
            message: "Upload was cancelled by caller",
            reason: nil
        )

        progressHandler = nil
        resultHandler = nil

        let cancelledAttempt = await preparationLifecycle.cancel()
        if let cancelledAttempt {
            await inputInspectionOperations.cancel(
                for: cancelledAttempt.inspectionToken
            )
            await inputStandardizer.cancel(
                id: id,
                token: cancelledAttempt.standardizationToken
            )
        }
        let fileWorker = self.fileWorker
        self.fileWorker = nil
        uploadManager.acknowledgeUpload(id: id)
        fileWorker?.cancel()
        removeOwnedTemporaryFile(fileWorker?.inputFileURL)
        input.processUploadCancellation()

        cancellationHandler?(.failure(cancellationError))
    }
    
    private func isUploadStarted() -> Bool {
        switch internalStatus {
        case .ready(_, _): return false
        default: return true
        }
    }
    
    private func isUploadComplete() -> Bool {
        switch internalStatus {
        case .uploadSucceeded: return true
        case .uploadFailed: return true
        default: return false
        }
    }

    private func removeOwnedTemporaryFile(_ url: URL?) {
        guard let url,
              storagePreflighter.ownsTemporaryOutput(url) else { return }
        try? FileManager.default.removeItem(at: url)
    }
    
    private func handleStateUpdate(_ state: ChunkedFileUploader.InternalUploadState) {
        switch state {
        case .success(let result): do {
            let completedFileURL = fileWorker?.inputFileURL
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
            removeOwnedTemporaryFile(completedFileURL)
        }
        case .failure(let error): do {
            let failedFileURL = fileWorker?.inputFileURL
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
                resultHandler?(DirectUploadResult.failure(DirectUploadError(
                    lastStatus: canceledStatus,
                    kind: .cancelled,
                    message: "user cancelled",
                    reason: nil
                )))
            } else {
                resultHandler?(Result.failure(parsedError))
            }
            fileWorker?.removeDelegate(withToken: id)
            fileWorker = nil
            removeOwnedTemporaryFile(failedFileURL)
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
