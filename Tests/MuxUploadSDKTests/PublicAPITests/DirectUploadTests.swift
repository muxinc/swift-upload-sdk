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

    func testStartStatusUpdate() throws {
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

        wait(
            for: [ex],
            timeout: 2.0
        )
    }

    func testInputInspectionSuccess() throws {
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

        wait(
            for: [preparingStatusExpectation, uploadInProgressExpecation],
            timeout: 2.0,
            enforceOrder: true
        )
    }

    func testCancelDuringInspectionCancelsOperationAndSuppressesCompletion() throws {
        let input = try UploadInput.mockReadyInput()
        let inspector = MockUploadInputInspector()
        let standardizer = MockUploadInputStandardizer()
        inspector.shouldDeferCompletion = true
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

        guard case .preparing = upload.inputStatus else {
            return XCTFail("Expected inspection to remain in progress")
        }
        let operation = try XCTUnwrap(inspector.operation)

        upload.cancel()
        inspector.completeDeferredInspection()

        XCTAssertTrue(operation.isCancelled)
        XCTAssertEqual(standardizer.cancelCallCount, 1)
        XCTAssertNil(upload.fileWorker)
        guard case .ready = upload.inputStatus else {
            return XCTFail("Expected cancellation to reset the upload to ready")
        }
        wait(
            for: [cancellationExpectation, transportExpectation],
            timeout: 0.1
        )
    }

    func testConcurrentInspectionCancellationAndCompletionAreMutuallyExclusive() async {
        for _ in 0..<250 {
            let registry = UploadInputInspectionOperationRegistry()
            let token = UploadInputInspectionOperationRegistry.Token()
            let operation = UploadInputInspectionOperation { _, _, _ in }
            registry.register(operation, for: token)

            let completionTask = Task.detached {
                registry.claimCompletion(for: token)
            }
            let cancellationTask = Task.detached {
                registry.cancel(for: token)
            }
            let completionClaimed = await completionTask.value
            let cancellationClaimed = await cancellationTask.value

            XCTAssertNotEqual(
                completionClaimed,
                cancellationClaimed,
                "Exactly one concurrent caller must claim the active inspection"
            )
            XCTAssertEqual(
                operation.isCancelled,
                cancellationClaimed,
                "Cancellation must reach the operation only when it wins the claim"
            )
        }
    }

    func testCancellingPreviousInspectionDoesNotCancelReplacement() {
        let registry = UploadInputInspectionOperationRegistry()
        let previousToken = UploadInputInspectionOperationRegistry.Token()
        let replacementToken = UploadInputInspectionOperationRegistry.Token()
        let previousOperation = UploadInputInspectionOperation { _, _, _ in }
        let replacementOperation = UploadInputInspectionOperation { _, _, _ in }

        registry.register(previousOperation, for: previousToken)
        registry.register(replacementOperation, for: replacementToken)

        XCTAssertFalse(registry.cancel(for: previousToken))
        XCTAssertTrue(previousOperation.isCancelled)
        XCTAssertFalse(replacementOperation.isCancelled)
        XCTAssertTrue(registry.cancel(for: replacementToken))
        XCTAssertTrue(replacementOperation.isCancelled)
    }

    func testCancelAndRestartInvalidateClaimedInspectionTransportTransition() throws {
        let input = try UploadInput.mockReadyInput()
        let inspector = MockUploadInputInspector()
        inspector.shouldDeferCompletion = true
        let factoryEntered = expectation(
            description: "Old attempt began worker creation"
        )
        let completionFinished = expectation(
            description: "Inspection completion finished"
        )
        let cancellationAttempted = expectation(
            description: "Cancellation was invoked"
        )
        let cancellationFinished = expectation(
            description: "Cancellation finished"
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

        DispatchQueue.global().async {
            inspector.completeDeferredInspection()
            completionFinished.fulfill()
        }
        wait(for: [factoryEntered], timeout: 1.0)

        DispatchQueue.global().async {
            cancellationAttempted.fulfill()
            upload.cancel()
            cancellationFinished.fulfill()
        }
        wait(for: [cancellationAttempted], timeout: 1.0)
        wait(
            for: [cancellationFinished, cancellationReported],
            timeout: 1.0
        )

        upload.start()
        guard case .preparing = upload.inputStatus else {
            return XCTFail("Expected the new attempt to remain under inspection")
        }

        allowWorkerCreation.signal()
        wait(for: [completionFinished], timeout: 1.0)

        XCTAssertNil(upload.fileWorker)
        XCTAssertTrue(uploadManager.allManagedDirectUploads().isEmpty)
        guard case .preparing = upload.inputStatus else {
            return XCTFail("Expected the old attempt not to advance the new attempt")
        }
        upload.cancel()
    }

    func testInputInspectionFailure() throws {
        let input = try UploadInput.mockReadyInput()

        let upload = DirectUpload(
            input: input,
            uploadManager: DirectUploadManager(),
            inputInspector: MockUploadInputInspector.alwaysFailing
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

        wait(
            for: [preparingStatusExpectation, uploadInProgressExpecation],
            timeout: 2.0,
            enforceOrder: true
        )
    }

    func testNonStandardInputHandlerReturningTrueCancelsUpload() throws {
        let input = try UploadInput.mockReadyInput()
        let upload = DirectUpload(
            input: input,
            uploadManager: DirectUploadManager(),
            inputInspector: MockUploadInputInspector.alwaysFailing
        )
        var handlerCallCount = 0

        upload.nonStandardInputHandler = {
            handlerCallCount += 1
            return true
        }

        upload.start()

        XCTAssertEqual(handlerCallCount, 1)
        guard case .ready = upload.inputStatus else {
            return XCTFail("Expected true to cancel and reset the upload to ready")
        }
    }

    func testNonStandardInputHandlerReturningFalseUploadsOriginal() throws {
        let input = try UploadInput.mockReadyInput()
        let upload = DirectUpload(
            input: input,
            uploadManager: DirectUploadManager(),
            inputInspector: MockUploadInputInspector.alwaysFailing
        )
        var handlerCallCount = 0

        upload.nonStandardInputHandler = {
            handlerCallCount += 1
            return false
        }

        upload.start()

        XCTAssertEqual(handlerCallCount, 1)
        guard case .transportInProgress = upload.inputStatus else {
            return XCTFail("Expected false to upload the original input")
        }
        XCTAssertEqual(upload.fileWorker?.inputFileURL, input.sourceAsset.url)
        upload.cancel()
    }

    func testHandlerReturningTrueCancelsAfterRescalingFailure() throws {
        try assertStandardizationFailureBehavior(
            inspectionResult: UploadInputFormatInspectionResult(
                nonStandardInputReasons: [],
                rescalingDetails: .init(
                    maximumDesiredResolutionPreset: .default,
                    recordedResolution: .init(width: 3840, height: 2160)
                )
            ),
            shouldCancel: true
        )
    }

    func testHandlerReturningFalseUploadsOriginalAfterRescalingFailure() throws {
        try assertStandardizationFailureBehavior(
            inspectionResult: UploadInputFormatInspectionResult(
                nonStandardInputReasons: [],
                rescalingDetails: .init(
                    maximumDesiredResolutionPreset: .default,
                    recordedResolution: .init(width: 3840, height: 2160)
                )
            ),
            shouldCancel: false
        )
    }

    func testHandlerReturningTrueCancelsAfterNonstandardInputFailure() throws {
        try assertStandardizationFailureBehavior(
            inspectionResult: UploadInputFormatInspectionResult(
                nonStandardInputReasons: [.videoCodec],
                rescalingDetails: .init()
            ),
            shouldCancel: true
        )
    }

    func testHandlerReturningFalseUploadsOriginalAfterNonstandardInputFailure() throws {
        try assertStandardizationFailureBehavior(
            inspectionResult: UploadInputFormatInspectionResult(
                nonStandardInputReasons: [.videoCodec],
                rescalingDetails: .init()
            ),
            shouldCancel: false
        )
    }

    private func assertStandardizationFailureBehavior(
        inspectionResult: UploadInputFormatInspectionResult,
        shouldCancel: Bool
    ) throws {
        let input = try UploadInput.mockReadyInput()
        let standardizer = MockUploadInputStandardizer()
        let upload = DirectUpload(
            input: input,
            uploadManager: DirectUploadManager(),
            inputInspector: MockUploadInputInspector(
                mockInspectionResult: inspectionResult
            ),
            inputStandardizer: standardizer
        )
        var handlerCallCount = 0

        upload.nonStandardInputHandler = {
            handlerCallCount += 1
            return shouldCancel
        }

        upload.start()

        XCTAssertEqual(handlerCallCount, 1)
        XCTAssertEqual(standardizer.standardizeCallCount, 1)
        XCTAssertEqual(standardizer.acknowledgeCompletionCallCount, 1)

        if shouldCancel {
            guard case .ready = upload.inputStatus else {
                return XCTFail("Expected true to cancel and reset the upload to ready")
            }
        } else {
            guard case .transportInProgress = upload.inputStatus else {
                return XCTFail("Expected false to upload the original input")
            }
            XCTAssertEqual(upload.fileWorker?.inputFileURL, input.sourceAsset.url)
            upload.cancel()
        }
    }

}
