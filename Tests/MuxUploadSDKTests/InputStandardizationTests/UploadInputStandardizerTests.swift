//
//  UploadInputStandardizerTests.swift
//

import AVFoundation
import XCTest

@testable import MuxUploadSDK

final class UploadInputStandardizerTests: XCTestCase {

    func testSynchronousFailureAcknowledgementDoesNotRetainWorker() {
        let standardizer = UploadInputStandardizer()
        let id = UUID().uuidString
        let sourceAsset = AVURLAsset(
            url: URL(fileURLWithPath: "/tmp/input.mp4")
        )
        let completionExpectation = expectation(
            description: "Expected unsupported tier to fail synchronously"
        )

        standardizer.standardize(
            id: id,
            sourceAsset: sourceAsset,
            rescalingDetails: .init(
                maximumDesiredResolutionPreset: .preset2560x1440,
                recordedResolution: .init(width: 3840, height: 2160)
            ),
            outputURL: URL(fileURLWithPath: "/tmp/output.mp4")
        ) { _, standardizedAsset, error in
            XCTAssertNil(standardizedAsset)
            XCTAssertEqual(
                error?.localizedDescription,
                StandardizationError.unsupportedResolutionTier.localizedDescription
            )
            standardizer.acknowledgeCompletion(id: id)
            completionExpectation.fulfill()
        }

        wait(for: [completionExpectation], timeout: 1.0)
        XCTAssertNil(standardizer.workers[id])
    }
}
