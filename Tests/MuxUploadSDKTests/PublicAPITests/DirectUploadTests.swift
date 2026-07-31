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
