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

            if case DirectUpload.InputStatus.uploadInProgress = inputStatus {
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

            if case DirectUpload.InputStatus.uploadInProgress = inputStatus {
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
    

}

