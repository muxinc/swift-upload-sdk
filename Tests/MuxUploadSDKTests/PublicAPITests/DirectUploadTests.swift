//
//  DirectUploadTests.swift
//

import AVFoundation
import Foundation
import XCTest
@testable import MuxUploadSDK

class DirectUploadTests: XCTestCase {

    func testInitializationInputStatus() throws {
        let upload = DirectUpload(
            uploadURL: URL(string: "https://www.example.com/upload")!,
            inputFileURL: URL(string: "file://var/mobile/Containers/Data/Application/Documents/myvideo.mp4")!
        )

        guard case DirectUpload.InputStatus.ready(_) = upload.inputStatus else {
            XCTFail("Expected initial input status to be ready")
            return
        }
    }

    func testStartStatusUpdate() async throws {
        let upload = DirectUpload(
            uploadURL: URL(string: "https://www.example.com/upload")!,
            inputFileURL: URL(string: "file://var/mobile/Containers/Data/Application/Documents/myvideo.mp4")!
        )

        let ex = XCTestExpectation(
            description: "Expected input status handler to fire when the upload starts"
        )

        upload.inputStatusHandler = { inputStatus in
            if case DirectUpload.InputStatus.started = inputStatus {
                ex.fulfill()
            }
        }

        upload.start()

        await fulfillment(of: [ex], timeout: 2.0)
        await cancelAndWait(upload)
    }

    func testImmediateStartThenCancelAlwaysProcessesCancellationLast() async throws {
        for iteration in 0..<100 {
            let upload = DirectUpload(
                input: try UploadInput.mockReadyInput(),
                uploadManager: DirectUploadManager(),
                inputInspector: MockUploadInputInspector(shouldDeferCompletion: true)
            )
            let cancellation = expectation(
                description: "Cancellation \(iteration)"
            )
            upload.resultHandler = { result in
                if case .failure(let error) = result,
                   error.kind == .cancelled {
                    cancellation.fulfill()
                }
            }

            upload.start()
            upload.cancel()
            await fulfillment(of: [cancellation], timeout: 1)

            XCTAssertNil(upload.fileWorker)
            guard case .ready = upload.inputStatus else {
                return XCTFail("A queued cancel must leave the upload ready")
            }
        }
    }

    func testTemporaryStorageOwnershipUsesInjectedBaseDirectory() throws {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("direct-upload-storage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: baseDirectory) }
        let preflighter = FileSystemTemporaryStoragePreflighter(
            baseDirectory: baseDirectory
        )
        let output = try preflighter.outputURL(
            for: baseDirectory.appendingPathComponent("source.mp4"),
            duration: .zero,
            conversion: StandardInputConversion(
                sourceCodec: .h264,
                outputCodec: .h264,
                sourceDynamicRange: .sdr,
                sourceDisplayDimensions: .known(
                    .init(width: 64, height: 64)
                ),
                toneMapsToSDR: false,
                selection: .init(maximumResolution: .preset1920x1080),
                requirementsToRemediate: []
            )
        )

        XCTAssertTrue(preflighter.ownsTemporaryOutput(output))
        XCTAssertFalse(
            FileSystemTemporaryStoragePreflighter()
                .ownsTemporaryOutput(output)
        )
    }

    func testInputInspectionSuccess() async throws {
        let input = try UploadInput.mockReadyInput()

        let upload = DirectUpload(
            input: input,
            uploadManager: DirectUploadManager(),
            inputInspector: MockUploadInputInspector.alwaysStandard
        )

        let preparingStatusExpectation = XCTestExpectation(
            description: "Expected input status handler to fire when the upload is preparing"
        )

        let uploadInProgressExpecation = XCTestExpectation(
            description: "Expected input status handler to fire when the upload is in progress"
        )

        upload.inputStatusHandler = { inputStatus in
            if case DirectUpload.InputStatus.preparing = inputStatus {
                preparingStatusExpectation.fulfill()
            }

            if case DirectUpload.InputStatus.transportInProgress = inputStatus {
                uploadInProgressExpecation.fulfill()
            }
        }

        upload.start()

        await fulfillment(
            of: [preparingStatusExpectation, uploadInProgressExpecation],
            timeout: 2.0,
            enforceOrder: true
        )
        await cancelAndWait(upload)
    }

    func testCancelDuringInspectionCancelsOperationAndSuppressesCompletion() async throws {
        let input = try UploadInput.mockReadyInput()
        let inspector = MockUploadInputInspector(shouldDeferCompletion: true)
        let standardizer = MockUploadInputStandardizer()
        let upload = DirectUpload(
            input: input,
            uploadManager: DirectUploadManager(),
            inputInspector: inspector,
            inputStandardizer: standardizer
        )
        let cancellationExpectation = expectation(
            description: "Expected cancellation result during inspection"
        )
        let transportExpectation = expectation(
            description: "Cancelled inspection must not start transport"
        )
        transportExpectation.isInverted = true
        upload.resultHandler = { result in
            guard case .failure = result else {
                return XCTFail("Expected cancellation failure")
            }
            cancellationExpectation.fulfill()
        }
        upload.inputStatusHandler = { status in
            if case .transportInProgress = status {
                transportExpectation.fulfill()
            }
        }

        upload.start()

        let operation = await inspector.waitForDeferredInspectionStart()

        upload.cancel()
        for _ in 0..<100 where !(await operation.isCancelled) {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        await inspector.completeDeferredInspection()

        let standardizerSnapshot = await waitForStandardizer(
            standardizer,
            cancelCallCount: 1
        )
        let operationWasCancelled = await operation.isCancelled
        XCTAssertTrue(operationWasCancelled)
        XCTAssertEqual(standardizerSnapshot.cancelCallCount, 1)
        XCTAssertNil(upload.fileWorker)
        guard case .ready = upload.inputStatus else {
            return XCTFail("Expected cancellation to reset the upload to ready")
        }
        await fulfillment(
            of: [cancellationExpectation, transportExpectation],
            timeout: 0.1
        )
    }

    func testConcurrentInspectionCancellationAndCompletionAreMutuallyExclusive() async {
        for _ in 0..<250 {
            let registry = UploadInputInspectionOperationRegistry()
            let token = UploadInputInspectionOperationRegistry.Token()
            let operation = UploadInputInspectionOperation()
            await registry.register(operation, for: token)

            let completionTask = Task.detached {
                await registry.claimCompletion(for: token)
            }
            let cancellationTask = Task.detached {
                await registry.cancel(for: token)
            }
            let completionClaimed = await completionTask.value
            let cancellationClaimed = await cancellationTask.value

            XCTAssertNotEqual(
                completionClaimed,
                cancellationClaimed,
                "Exactly one concurrent caller must claim the active inspection"
            )
            let operationWasCancelled = await operation.isCancelled
            XCTAssertEqual(
                operationWasCancelled,
                cancellationClaimed,
                "Cancellation must reach the operation only when it wins the claim"
            )
        }
    }

    func testCancellingPreviousInspectionDoesNotCancelReplacement() async {
        let registry = UploadInputInspectionOperationRegistry()
        let previousToken = UploadInputInspectionOperationRegistry.Token()
        let replacementToken = UploadInputInspectionOperationRegistry.Token()
        let previousOperation = UploadInputInspectionOperation()
        let replacementOperation = UploadInputInspectionOperation()

        await registry.register(previousOperation, for: previousToken)
        await registry.register(replacementOperation, for: replacementToken)

        let staleCancellationClaimed = await registry.cancel(for: previousToken)
        let previousWasCancelled = await previousOperation.isCancelled
        let replacementWasInitiallyCancelled = await replacementOperation.isCancelled
        let replacementCancellationClaimed = await registry.cancel(for: replacementToken)
        let replacementWasCancelled = await replacementOperation.isCancelled
        XCTAssertFalse(staleCancellationClaimed)
        XCTAssertTrue(previousWasCancelled)
        XCTAssertFalse(replacementWasInitiallyCancelled)
        XCTAssertTrue(replacementCancellationClaimed)
        XCTAssertTrue(replacementWasCancelled)
    }

    func testCancelAndRestartInvalidateClaimedInspectionTransportTransition() async throws {
        let input = try UploadInput.mockReadyInput()
        let inspector = MockUploadInputInspector(shouldDeferCompletion: true)
        let factoryEntered = expectation(
            description: "Old attempt began worker creation"
        )
        let completionFinished = expectation(
            description: "Inspection completion finished"
        )
        let cancellationReported = expectation(
            description: "Cancellation was reported after cleanup"
        )
        let allowWorkerCreation = DispatchSemaphore(value: 0)
        let uploadManager = DirectUploadManager()
        let upload = DirectUpload(
            input: input,
            uploadManager: uploadManager,
            inputInspector: inspector,
            fileWorkerFactory: { uploadInfo, inputFileURL, file, startingByte in
                factoryEntered.fulfill()
                allowWorkerCreation.wait()
                return ChunkedFileUploader(
                    uploadInfo: uploadInfo,
                    inputFileURL: inputFileURL,
                    file: file,
                    startingByte: startingByte
                )
            }
        )
        upload.resultHandler = { result in
            guard case .failure(let error) = result,
                  error.kind == .cancelled else {
                return XCTFail("Expected cancellation failure")
            }
            XCTAssertNil(upload.fileWorker)
            guard case .ready = upload.inputStatus else {
                return XCTFail("Expected cleanup before cancellation reporting")
            }
            cancellationReported.fulfill()
        }

        upload.start()
        _ = await inspector.waitForDeferredInspectionStart()

        Task {
            await inspector.completeDeferredInspection()
            completionFinished.fulfill()
        }
        await fulfillment(of: [factoryEntered], timeout: 1.0)

        upload.cancel()
        await fulfillment(of: [cancellationReported], timeout: 1.0)

        upload.start()
        _ = await inspector.waitForDeferredInspectionStart()

        allowWorkerCreation.signal()
        await fulfillment(of: [completionFinished], timeout: 1.0)

        XCTAssertNil(upload.fileWorker)
        XCTAssertTrue(uploadManager.allManagedDirectUploads().isEmpty)
        guard case .preparing = upload.inputStatus else {
            return XCTFail("Expected the old attempt not to advance the new attempt")
        }
        await cancelAndWait(upload)
    }

    func testInputInspectionFailure() async throws {
        let input = try UploadInput.mockReadyInput()
        let diagnostics = RecordingStandardizationDiagnosticLogger()

        let upload = DirectUpload(
            input: input,
            uploadManager: DirectUploadManager(),
            inputInspector: MockUploadInputInspector.alwaysFailing,
            standardizationDiagnosticLogger: diagnostics
        )

        let preparingStatusExpectation = XCTestExpectation(
            description: "Expected input status handler to fire when the upload is preparing"
        )

        let uploadInProgressExpecation = XCTestExpectation(
            description: "Expected input status handler to fire when the upload is in progress"
        )

        upload.inputStatusHandler = { inputStatus in
            if case DirectUpload.InputStatus.preparing = inputStatus {
                preparingStatusExpectation.fulfill()
            }

            if case DirectUpload.InputStatus.transportInProgress = inputStatus {
                uploadInProgressExpecation.fulfill()
            }
        }

        upload.start()

        await fulfillment(
            of: [preparingStatusExpectation, uploadInProgressExpecation],
            timeout: 2.0,
            enforceOrder: true
        )
        let messages = await diagnostics.messages()
        XCTAssertTrue(messages.contains(where: {
            $0.contains("failure_category=inspection")
                && $0.contains("failure_reason=inspection_failed")
        }))
        await cancelAndWait(upload)
    }

    func testNonStandardInputHandlerReturningTrueCancelsUpload() async throws {
        let input = try UploadInput.mockReadyInput()
        let upload = DirectUpload(
            input: input,
            uploadManager: DirectUploadManager(),
            inputInspector: MockUploadInputInspector.alwaysFailing
        )
        var handlerCallCount = 0
        let handlerExpectation = expectation(description: "Failure handler runs")
        let readyExpectation = expectation(description: "Upload resets to ready")

        upload.nonStandardInputHandler = {
            handlerCallCount += 1
            handlerExpectation.fulfill()
            return true
        }
        upload.inputStatusHandler = { status in
            if case .ready = status { readyExpectation.fulfill() }
        }

        upload.start()

        await fulfillment(of: [handlerExpectation, readyExpectation], timeout: 1.0)
        XCTAssertEqual(handlerCallCount, 1)
        guard case .ready = upload.inputStatus else {
            return XCTFail("Expected true to cancel and reset the upload to ready")
        }
    }

    func testNonStandardInputHandlerReturningFalseUploadsOriginal() async throws {
        let input = try UploadInput.mockReadyInput()
        let upload = DirectUpload(
            input: input,
            uploadManager: DirectUploadManager(),
            inputInspector: MockUploadInputInspector.alwaysFailing
        )
        var handlerCallCount = 0
        let handlerExpectation = expectation(description: "Failure handler runs")
        let transportExpectation = expectation(description: "Original transport starts")
        var transportedFileURL: URL?

        upload.nonStandardInputHandler = {
            handlerCallCount += 1
            handlerExpectation.fulfill()
            return false
        }
        upload.inputStatusHandler = { status in
            if case .transportInProgress = status {
                transportedFileURL = upload.videoFile
                transportExpectation.fulfill()
            }
        }

        upload.start()

        await fulfillment(of: [handlerExpectation, transportExpectation], timeout: 1.0)
        XCTAssertEqual(handlerCallCount, 1)
        XCTAssertEqual(transportedFileURL, input.sourceAsset.url)
        await cancelAndWait(upload)
    }

    func testHandlerReturningTrueCancelsAfterRescalingFailure() async throws {
        try await assertStandardizationFailureBehavior(
            inspectionResult: UploadInputFormatInspectionResult(
                nonStandardInputReasons: [],
                mediaFacts: conversionFacts(
                    codec: .h264,
                    dimensions: .init(width: 3840, height: 2160)
                ),
                metadata: UploadInputMetadataInspection(videoTrackCount: 1),
                rescalingDetails: .init(
                    maximumDesiredResolutionPreset: .default,
                    recordedResolution: .init(width: 3840, height: 2160)
                )
            ),
            shouldCancel: true
        )
    }

    func testHandlerReturningFalseUploadsOriginalAfterRescalingFailure() async throws {
        try await assertStandardizationFailureBehavior(
            inspectionResult: UploadInputFormatInspectionResult(
                nonStandardInputReasons: [],
                mediaFacts: conversionFacts(
                    codec: .h264,
                    dimensions: .init(width: 3840, height: 2160)
                ),
                metadata: UploadInputMetadataInspection(videoTrackCount: 1),
                rescalingDetails: .init(
                    maximumDesiredResolutionPreset: .default,
                    recordedResolution: .init(width: 3840, height: 2160)
                )
            ),
            shouldCancel: false
        )
    }

    func testHandlerReturningTrueCancelsAfterNonstandardInputFailure() async throws {
        try await assertStandardizationFailureBehavior(
            inspectionResult: UploadInputFormatInspectionResult(
                nonStandardInputReasons: [.videoCodec],
                mediaFacts: conversionFacts(codec: .other),
                metadata: UploadInputMetadataInspection(videoTrackCount: 1),
                rescalingDetails: .init()
            ),
            shouldCancel: true
        )
    }

    func testHandlerReturningFalseUploadsOriginalAfterNonstandardInputFailure() async throws {
        try await assertStandardizationFailureBehavior(
            inspectionResult: UploadInputFormatInspectionResult(
                nonStandardInputReasons: [.videoCodec],
                mediaFacts: conversionFacts(codec: .other),
                metadata: UploadInputMetadataInspection(videoTrackCount: 1),
                rescalingDetails: .init()
            ),
            shouldCancel: false
        )
    }

    func testPlannerPreservesEligibleHLGWithoutStandardizationOrFailureCallback() async throws {
        let input = try makeInput(
            options: DirectUploadOptions(
                inputStandardization: .init(
                    maximumResolution: .preset3840x2160,
                    hdrHandling: .preserve
                )
            )
        )
        let standardizer = MockUploadInputStandardizer()
        let diagnostics = RecordingStandardizationDiagnosticLogger()
        let inspection = inspectionResult(
            facts: compliantFacts(codec: .hevc, dynamicRange: .hlg, bitDepth: 10)
        )
        let upload = DirectUpload(
            input: input,
            uploadManager: DirectUploadManager(),
            inputInspector: MockUploadInputInspector(mockInspectionResult: inspection),
            inputStandardizer: standardizer,
            capabilityProvider: FullyCapablePlanningProvider(),
            standardizationDiagnosticLogger: diagnostics
        )
        let transportExpectation = expectation(description: "Original transport starts")
        var failureHandlerCallCount = 0
        var transportedFileURL: URL?
        upload.nonStandardInputHandler = {
            failureHandlerCallCount += 1
            return false
        }
        upload.inputStatusHandler = { status in
            if case .transportInProgress = status {
                transportedFileURL = upload.videoFile
                transportExpectation.fulfill()
            }
        }

        upload.start()
        await fulfillment(of: [transportExpectation], timeout: 1.0)
        await cancelAndWait(upload)

        XCTAssertEqual(failureHandlerCallCount, 0)
        let standardizerSnapshot = await standardizer.snapshot()
        XCTAssertEqual(standardizerSnapshot.standardizeCallCount, 0)
        XCTAssertEqual(transportedFileURL, input.sourceAsset.url)
        let messages = await diagnostics.messages()
        XCTAssertTrue(messages.contains(where: {
            $0.contains("event=plan_selected")
                && $0.contains("source_codec=hevc")
                && $0.contains("output_codec=hevc")
                && $0.contains("resolution_tier=2160p")
                && $0.contains("hdr_handling=preserve")
                && $0.contains("hdr_decision=preserve_hlg_for_mux_processing")
        }))
        XCTAssertFalse(messages.contains(where: {
            $0.contains("event=standardization_failure")
        }))
    }

    func testPlannerPreservesEligiblePQWithDistinctServerProcessingDiagnostic() async throws {
        let input = try makeInput(
            options: DirectUploadOptions(
                inputStandardization: .init(
                    maximumResolution: .preset3840x2160,
                    hdrHandling: .preserve
                )
            )
        )
        let diagnostics = RecordingStandardizationDiagnosticLogger()
        let upload = DirectUpload(
            input: input,
            uploadManager: DirectUploadManager(),
            inputInspector: MockUploadInputInspector(
                mockInspectionResult: inspectionResult(
                    facts: compliantFacts(
                        codec: .hevc,
                        dynamicRange: .pq,
                        bitDepth: 10
                    )
                )
            ),
            capabilityProvider: FullyCapablePlanningProvider(),
            standardizationDiagnosticLogger: diagnostics
        )
        let transportExpectation = expectation(description: "Original transport starts")
        upload.inputStatusHandler = { status in
            if case .transportInProgress = status {
                transportExpectation.fulfill()
            }
        }

        upload.start()
        await fulfillment(of: [transportExpectation], timeout: 1.0)
        await cancelAndWait(upload)

        let messages = await diagnostics.messages()
        XCTAssertTrue(messages.contains(where: {
            $0.contains("dynamic_range=pq")
        }))
        XCTAssertTrue(messages.contains(where: {
            $0.contains("hdr_decision=preserve_pq_for_compatible_server_processing")
        }))
        XCTAssertFalse(messages.contains(where: {
            $0.contains("event=standardization_failure")
        }))
    }

    func testToneMapPlanUsesOnlyValidatedGeneratedOutput() async throws {
        let outputURL = temporaryOutputURL()
        FileManager.default.createFile(atPath: outputURL.path, contents: Data([0]))
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let input = try makeInput(
            options: DirectUploadOptions(
                inputStandardization: .init(
                    maximumResolution: .default,
                    hdrHandling: .toneMapToSDR
                )
            )
        )
        let source = inspectionResult(
            facts: compliantFacts(codec: .hevc, dynamicRange: .hlg, bitDepth: 10)
        )
        let generated = inspectionResult(
            facts: compliantFacts(codec: .hevc, dynamicRange: .sdr, bitDepth: 8)
        )
        let standardizer = MockUploadInputStandardizer(error: nil, resultURL: outputURL)
        let diagnostics = RecordingStandardizationDiagnosticLogger()
        let upload = DirectUpload(
            input: input,
            uploadManager: DirectUploadManager(),
            inputInspector: MockUploadInputInspector(
                mockInspectionResult: source,
                duration: CMTime(seconds: 10, preferredTimescale: 600),
                subsequentResults: [generated]
            ),
            inputStandardizer: standardizer,
            capabilityProvider: FullyCapablePlanningProvider(),
            storagePreflighter: FixedTemporaryStoragePreflighter(outputURL: outputURL),
            standardizationDiagnosticLogger: diagnostics
        )
        let transportExpectation = expectation(description: "Generated transport starts")
        var transportedFileURL: URL?
        upload.inputStatusHandler = { status in
            if case .transportInProgress = status {
                transportedFileURL = upload.videoFile
                transportExpectation.fulfill()
            }
        }

        upload.start()
        await fulfillment(of: [transportExpectation], timeout: 1.0)

        let snapshot = await standardizer.snapshot()
        XCTAssertEqual(snapshot.standardizeCallCount, 1)
        XCTAssertEqual(snapshot.conversion?.toneMapsToSDR, true)
        XCTAssertEqual(transportedFileURL, outputURL)
        let messages = await diagnostics.messages()
        XCTAssertTrue(messages.contains(where: {
            $0.contains("event=inspection_completed role=source")
                && $0.contains("source_codec=hevc")
                && $0.contains("dynamic_range=hlg")
        }))
        XCTAssertTrue(messages.contains(where: {
            $0.contains("event=plan_selected plan=convert")
                && $0.contains("source_codec=hevc")
                && $0.contains("output_codec=hevc")
                && $0.contains("resolution_tier=1080p")
                && $0.contains("hdr_handling=tone_map_to_sdr")
        }))
        XCTAssertTrue(messages.contains(where: {
            $0.contains("event=conversion_completed")
                && $0.contains("conversion_duration_ms=")
        }))
        XCTAssertTrue(messages.contains(where: {
            $0.contains("event=inspection_completed role=generated_output")
                && $0.contains("output_codec=hevc")
                && $0.contains("dynamic_range=sdr")
        }))
        XCTAssertTrue(messages.contains(where: {
            $0.contains("event=output_validation_completed result=accepted")
        }))
        await cancelAndWait(upload)
    }

    func testRejectedGeneratedOutputFallsBackAndDeletesOwnedOutput() async throws {
        let outputURL = temporaryOutputURL()
        FileManager.default.createFile(atPath: outputURL.path, contents: Data([0]))
        let input = try makeInput(options: .default)
        let source = inspectionResult(
            facts: conversionFacts(codec: .other)
        )
        var rejectedFacts = compliantFacts(codec: .h264, dynamicRange: .sdr, bitDepth: 8)
        rejectedFacts.averageBitrate = .known(50_000_000)
        let standardizer = MockUploadInputStandardizer(error: nil, resultURL: outputURL)
        let diagnostics = RecordingStandardizationDiagnosticLogger()
        let upload = DirectUpload(
            input: input,
            uploadManager: DirectUploadManager(),
            inputInspector: MockUploadInputInspector(
                mockInspectionResult: source,
                duration: CMTime(seconds: 10, preferredTimescale: 600),
                subsequentResults: [inspectionResult(facts: rejectedFacts)]
            ),
            inputStandardizer: standardizer,
            capabilityProvider: FullyCapablePlanningProvider(),
            storagePreflighter: FixedTemporaryStoragePreflighter(outputURL: outputURL),
            standardizationDiagnosticLogger: diagnostics
        )
        let handlerExpectation = expectation(description: "Validation failure handler runs")
        let transportExpectation = expectation(description: "Original transport starts")
        var transportedFileURL: URL?
        upload.nonStandardInputHandler = {
            handlerExpectation.fulfill()
            return false
        }
        upload.inputStatusHandler = { status in
            if case .transportInProgress = status {
                transportedFileURL = upload.videoFile
                transportExpectation.fulfill()
            }
        }

        upload.start()
        await fulfillment(of: [handlerExpectation, transportExpectation], timeout: 1.0)

        for _ in 0..<100 where FileManager.default.fileExists(atPath: outputURL.path) {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertEqual(transportedFileURL, input.sourceAsset.url)
        let messages = await diagnostics.messages()
        XCTAssertTrue(messages.contains(where: {
            $0.contains("failure_category=output_validation")
                && $0.contains("failure_reason=output_non_compliant")
        }))
        await cancelAndWait(upload)
    }

    func testStoragePreflightFailureFallsBackBeforeStandardization() async throws {
        let input = try makeInput(options: .default)
        let standardizer = MockUploadInputStandardizer()
        let diagnostics = RecordingStandardizationDiagnosticLogger()
        let upload = DirectUpload(
            input: input,
            uploadManager: DirectUploadManager(),
            inputInspector: MockUploadInputInspector(
                mockInspectionResult: inspectionResult(
                    facts: conversionFacts(codec: .other)
                )
            ),
            inputStandardizer: standardizer,
            capabilityProvider: FullyCapablePlanningProvider(),
            storagePreflighter: FixedTemporaryStoragePreflighter(outputURL: nil),
            standardizationDiagnosticLogger: diagnostics
        )
        let handlerExpectation = expectation(description: "Preflight failure handler runs")
        let transportExpectation = expectation(description: "Original transport starts")
        var transportedFileURL: URL?
        upload.nonStandardInputHandler = {
            handlerExpectation.fulfill()
            return false
        }
        upload.inputStatusHandler = { status in
            if case .transportInProgress = status {
                transportedFileURL = upload.videoFile
                transportExpectation.fulfill()
            }
        }

        upload.start()
        await fulfillment(of: [handlerExpectation, transportExpectation], timeout: 1.0)

        let standardizerSnapshot = await standardizer.snapshot()
        XCTAssertEqual(standardizerSnapshot.standardizeCallCount, 0)
        XCTAssertEqual(transportedFileURL, input.sourceAsset.url)
        let messages = await diagnostics.messages()
        XCTAssertTrue(messages.contains(where: {
            $0.contains("failure_category=storage")
                && $0.contains("failure_reason=storage_preflight_failed")
        }))
        await cancelAndWait(upload)
    }

    func testUnsupportedConversionLogsCapabilityFailureAndFallsBack() async throws {
        let input = try makeInput(options: .default)
        let standardizer = MockUploadInputStandardizer()
        let diagnostics = RecordingStandardizationDiagnosticLogger()
        let upload = DirectUpload(
            input: input,
            uploadManager: DirectUploadManager(),
            inputInspector: MockUploadInputInspector(
                mockInspectionResult: inspectionResult(
                    facts: conversionFacts(codec: .other)
                )
            ),
            inputStandardizer: standardizer,
            capabilityProvider: NoConversionPlanningProvider(),
            standardizationDiagnosticLogger: diagnostics
        )
        let handlerExpectation = expectation(description: "Failure handler runs")
        let transportExpectation = expectation(description: "Original transport starts")
        upload.nonStandardInputHandler = {
            handlerExpectation.fulfill()
            return false
        }
        upload.inputStatusHandler = { status in
            if case .transportInProgress = status {
                transportExpectation.fulfill()
            }
        }

        upload.start()
        await fulfillment(of: [handlerExpectation, transportExpectation], timeout: 1.0)

        let standardizerSnapshot = await standardizer.snapshot()
        XCTAssertEqual(standardizerSnapshot.standardizeCallCount, 0)
        let messages = await diagnostics.messages()
        XCTAssertTrue(messages.contains(where: {
            $0.contains("event=plan_selected plan=fallback")
                && $0.contains("plan_reason=unsupported_conversion")
        }))
        XCTAssertTrue(messages.contains(where: {
            $0.contains("failure_category=capability")
                && $0.contains("failure_reason=unsupported_conversion")
        }))
        await cancelAndWait(upload)
    }

    func testConversionFailureDiagnosticDoesNotExposeUncontrolledErrorOrCredentials() async throws {
        let uploadURL = try XCTUnwrap(URL(
            string: "https://upload.example.com/private?token=UPLOAD_SECRET"
        ))
        let input = UploadInput(
            asset: AVURLAsset(
                url: URL(fileURLWithPath: "/private/customer/SECRET_SOURCE.mov")
            ),
            info: UploadInfo(uploadURL: uploadURL, options: .default)
        )
        let diagnostics = RecordingStandardizationDiagnosticLogger()
        let rawError = SensitiveDiagnosticError(
            description: "Authorization: Bearer HEADER_SECRET at \(uploadURL.absoluteString) from /private/customer/SECRET_SOURCE.mov"
        )
        let upload = DirectUpload(
            input: input,
            uploadManager: DirectUploadManager(),
            inputInspector: MockUploadInputInspector(
                mockInspectionResult: inspectionResult(
                    facts: conversionFacts(codec: .other)
                )
            ),
            inputStandardizer: MockUploadInputStandardizer(error: rawError),
            capabilityProvider: FullyCapablePlanningProvider(),
            standardizationDiagnosticLogger: diagnostics
        )
        let handlerExpectation = expectation(description: "Failure handler runs")
        let transportExpectation = expectation(description: "Original transport starts")
        upload.nonStandardInputHandler = {
            handlerExpectation.fulfill()
            return false
        }
        upload.inputStatusHandler = { status in
            if case .transportInProgress = status {
                transportExpectation.fulfill()
            }
        }

        upload.start()
        await fulfillment(of: [handlerExpectation, transportExpectation], timeout: 1.0)

        let message = (await diagnostics.messages()).joined(separator: "\n")
        XCTAssertTrue(message.contains("failure_category=conversion"))
        XCTAssertTrue(message.contains("failure_reason=conversion_failed"))
        XCTAssertTrue(message.contains("conversion_duration_ms="))
        XCTAssertFalse(message.contains("UPLOAD_SECRET"))
        XCTAssertFalse(message.contains("HEADER_SECRET"))
        XCTAssertFalse(message.contains("upload.example.com"))
        XCTAssertFalse(message.contains("/private/customer"))
        XCTAssertFalse(message.contains("Authorization"))
        await cancelAndWait(upload)
    }

    func testTransportFailureDeletesOwnedStandardizedOutput() async throws {
        let outputURL = temporaryOutputURL()
        FileManager.default.createFile(atPath: outputURL.path, contents: Data([0]))
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let input = try makeInput(
            options: DirectUploadOptions(
                inputStandardization: .init(
                    maximumResolution: .default,
                    hdrHandling: .toneMapToSDR
                )
            )
        )
        let source = inspectionResult(
            facts: compliantFacts(codec: .hevc, dynamicRange: .hlg, bitDepth: 10)
        )
        let generated = inspectionResult(
            facts: compliantFacts(codec: .hevc, dynamicRange: .sdr, bitDepth: 8)
        )
        let upload = DirectUpload(
            input: input,
            uploadManager: DirectUploadManager(),
            inputInspector: MockUploadInputInspector(
                mockInspectionResult: source,
                duration: CMTime(seconds: 10, preferredTimescale: 600),
                subsequentResults: [generated]
            ),
            inputStandardizer: MockUploadInputStandardizer(
                error: nil,
                resultURL: outputURL
            ),
            capabilityProvider: FullyCapablePlanningProvider(),
            storagePreflighter: FixedTemporaryStoragePreflighter(outputURL: outputURL),
            fileWorkerFactory: makeFailingFileWorker
        )
        let failureExpectation = expectation(description: "Transport fails")
        upload.resultHandler = { result in
            guard case .failure = result else {
                return XCTFail("Expected transport failure")
            }
            failureExpectation.fulfill()
        }

        upload.start()
        await fulfillment(of: [failureExpectation], timeout: 1.0)

        for _ in 0..<100 where FileManager.default.fileExists(atPath: outputURL.path) {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
    }

    func testTransportFailurePreservesOriginalInput() async throws {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("direct-upload-source-\(UUID().uuidString).mp4")
        FileManager.default.createFile(atPath: sourceURL.path, contents: Data([0]))
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let input = UploadInput(
            asset: AVURLAsset(url: sourceURL),
            info: UploadInfo(
                uploadURL: try XCTUnwrap(URL(string: "https://example.com/upload")),
                options: .default
            )
        )
        let upload = DirectUpload(
            input: input,
            uploadManager: DirectUploadManager(),
            inputInspector: MockUploadInputInspector.alwaysFailing,
            storagePreflighter: FixedTemporaryStoragePreflighter(outputURL: nil),
            fileWorkerFactory: makeFailingFileWorker
        )
        let failureExpectation = expectation(description: "Transport fails")
        upload.nonStandardInputHandler = { false }
        upload.resultHandler = { result in
            guard case .failure = result else {
                return XCTFail("Expected transport failure")
            }
            failureExpectation.fulfill()
        }

        upload.start()
        await fulfillment(of: [failureExpectation], timeout: 1.0)

        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
    }

    private func makeFailingFileWorker(
        uploadInfo: UploadInfo,
        inputFileURL: URL,
        file: ChunkedFile,
        startingByte: UInt64
    ) -> ChunkedFileUploader {
        FailingChunkedFileUploader(
            uploadInfo: uploadInfo,
            inputFileURL: inputFileURL,
            file: file,
            startingByte: startingByte
        )
    }

    private func assertStandardizationFailureBehavior(
        inspectionResult: UploadInputFormatInspectionResult,
        shouldCancel: Bool
    ) async throws {
        let input = try UploadInput.mockReadyInput()
        let standardizer = MockUploadInputStandardizer()
        let upload = DirectUpload(
            input: input,
            uploadManager: DirectUploadManager(),
            inputInspector: MockUploadInputInspector(
                mockInspectionResult: inspectionResult
            ),
            inputStandardizer: standardizer,
            capabilityProvider: FullyCapablePlanningProvider()
        )
        var handlerCallCount = 0
        let handlerExpectation = expectation(
            description: "Standardization failure handler runs"
        )
        let finalStatusExpectation = expectation(
            description: "Standardization failure reaches its final status"
        )
        var transportedFileURL: URL?

        upload.nonStandardInputHandler = {
            handlerCallCount += 1
            handlerExpectation.fulfill()
            return shouldCancel
        }
        upload.inputStatusHandler = { status in
            if shouldCancel, case .ready = status {
                finalStatusExpectation.fulfill()
            } else if !shouldCancel, case .transportInProgress = status {
                transportedFileURL = upload.videoFile
                finalStatusExpectation.fulfill()
            }
        }

        upload.start()
        await fulfillment(
            of: [handlerExpectation, finalStatusExpectation],
            timeout: 2,
            enforceOrder: true
        )

        XCTAssertEqual(handlerCallCount, 1)
        let standardizerSnapshot = await standardizer.snapshot()
        XCTAssertEqual(standardizerSnapshot.standardizeCallCount, 1)

        if shouldCancel {
            guard case .ready = upload.inputStatus else {
                return XCTFail("Expected true to cancel and reset the upload to ready")
            }
        } else {
            XCTAssertEqual(transportedFileURL, input.sourceAsset.url)
            await cancelAndWait(upload)
        }
    }

    private func cancelAndWait(_ upload: DirectUpload) async {
        if case .ready = upload.inputStatus, upload.fileWorker == nil {
            return
        }
        let cancellationExpectation = expectation(
            description: "Upload cancellation finishes"
        )
        upload.inputStatusHandler = { status in
            if case .ready = status {
                cancellationExpectation.fulfill()
            }
        }
        upload.cancel()
        await fulfillment(of: [cancellationExpectation], timeout: 2.0)
    }

    private func waitForStandardizer(
        _ standardizer: MockUploadInputStandardizer,
        cancelCallCount: Int
    ) async -> MockUploadInputStandardizer.Snapshot {
        for _ in 0..<100 {
            let snapshot = await standardizer.snapshot()
            if snapshot.cancelCallCount == cancelCallCount {
                return snapshot
            }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return await standardizer.snapshot()
    }

    private func conversionFacts(
        codec: StandardInputVideoCodec,
        dimensions: StandardInputDisplayDimensions = .init(width: 1920, height: 1080)
    ) -> StandardInputMediaFacts {
        StandardInputMediaFacts(
            videoCodec: .known(codec),
            displayDimensions: .known(dimensions),
            dynamicRange: .known(.sdr)
        )
    }

    private func compliantFacts(
        codec: StandardInputVideoCodec,
        dynamicRange: StandardInputDynamicRange,
        bitDepth: Int
    ) -> StandardInputMediaFacts {
        StandardInputMediaFacts(
            videoCodec: .known(codec),
            displayDimensions: .known(.init(width: 1920, height: 1080)),
            frameRate: .known(30),
            averageBitrate: .known(7_000_000),
            maximumGOPBitrate: .known(8_000_000),
            maximumGOPByteSize: .known(1_000_000),
            maximumKeyframeInterval: .known(5),
            gopStructure: .known(.closedWithIDR),
            pixelFormat: .known(.init(bitDepth: bitDepth, chromaSubsampling: .yuv420)),
            dynamicRange: .known(dynamicRange),
            audio: .known(.none),
            editList: .known(.none)
        )
    }

    private func inspectionResult(
        facts: StandardInputMediaFacts
    ) -> UploadInputFormatInspectionResult {
        UploadInputFormatInspectionResult(
            mediaFacts: facts,
            metadata: UploadInputMetadataInspection(videoTrackCount: 1),
            timelineFacts: StandardInputTimelineFacts(
                duration: .known(10),
                audioVideoStartOffset: .known(.notApplicable)
            ),
            rescalingDetails: .init()
        )
    }

    private func makeInput(options: DirectUploadOptions) throws -> UploadInput {
        UploadInput(
            asset: AVURLAsset(url: URL(fileURLWithPath: "/tmp/direct-upload-source.mp4")),
            info: UploadInfo(
                uploadURL: try XCTUnwrap(URL(string: "https://example.com/upload")),
                options: options
            )
        )
    }

    private func temporaryOutputURL() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(FileSystemTemporaryStoragePreflighter.directoryName)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory.appendingPathComponent(
            "\(FileSystemTemporaryStoragePreflighter.filePrefix)\(UUID().uuidString).mp4"
        )
    }

}

private final class FailingChunkedFileUploader: ChunkedFileUploader {
    private var delegates: [String: ChunkedFileUploaderDelegate] = [:]

    override func addDelegate(
        withToken token: String,
        _ delegate: ChunkedFileUploaderDelegate
    ) {
        delegates[token] = delegate
    }

    override func removeDelegate(withToken token: String) {
        delegates.removeValue(forKey: token)
    }

    override func start() {
        fail()
    }

    override func start(duration: CMTime) {
        fail()
    }

    private func fail() {
        let delegates = Array(delegates.values)
        for delegate in delegates {
            delegate.chunkedFileUploader(self, stateUpdated: .failure(DummyError()))
        }
    }
}

private struct SensitiveDiagnosticError: LocalizedError {
    let description: String

    var errorDescription: String? {
        description
    }
}

private struct FullyCapablePlanningProvider: StandardInputPlanningCapabilityProviding {
    func capabilities(
        for inspection: UploadInputFormatInspectionResult,
        sourceAsset: AVAsset
    ) async -> StandardInputPlanningCapabilities {
        StandardInputPlanningCapabilities(
            sourceIsDecodable: true,
            encodableVideoCodecs: [.h264, .hevc],
            remediableRequirements: Set(StandardInputPolicyEvaluation.Requirement.allCases),
            toneMappableDynamicRanges: [.hlg, .pq],
            preservableHDRDynamicRanges: [.hlg, .pq]
        )
    }
}

private struct NoConversionPlanningProvider: StandardInputPlanningCapabilityProviding {
    func capabilities(
        for inspection: UploadInputFormatInspectionResult,
        sourceAsset: AVAsset
    ) async -> StandardInputPlanningCapabilities {
        StandardInputPlanningCapabilities(
            sourceIsDecodable: false,
            encodableVideoCodecs: [],
            remediableRequirements: [],
            toneMappableDynamicRanges: [],
            preservableHDRDynamicRanges: [.hlg, .pq]
        )
    }
}

private struct FixedTemporaryStoragePreflighter: TemporaryStoragePreflighting {
    let outputURL: URL?

    func outputURL(
        for sourceURL: URL,
        duration: CMTime,
        conversion: StandardInputConversion
    ) throws -> URL {
        guard let outputURL else { throw DummyError() }
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        return outputURL
    }

    func ownsTemporaryOutput(_ url: URL) -> Bool {
        url == outputURL
    }
}
