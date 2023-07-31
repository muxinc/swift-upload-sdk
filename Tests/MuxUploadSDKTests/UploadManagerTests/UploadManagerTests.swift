//
//  UploadManagerTests.swift
//

import AVFoundation
import Foundation
import XCTest

@testable import MuxUploadSDK

extension UploadOptions {

    static var inputStandardizationSkipped: UploadOptions {
        UploadOptions(
            inputStandardization: .skipped
        )
    }

}

class UploadManagerTests: XCTestCase {

    func testUploadManagerURLDeduplication() throws {

        let uploadManager = DirectUploadManager()

        let uploadURL = try XCTUnwrap(
            URL(string: "https://www.example.com/upload")
        )

        let videoInputURL = try XCTUnwrap(
            URL(string: "file://path/to/dummy/file/")
        )

        let upload = DirectUpload(
            input: UploadInput(
                asset: AVAsset(url: videoInputURL),
                info: UploadInfo(
                    uploadURL: uploadURL,
                    options: .inputStandardizationSkipped
                )
            ),
            uploadManager: uploadManager
        )

        let duplicateUpload = DirectUpload(
            input: UploadInput(
                asset: AVAsset(url: videoInputURL),
                info: UploadInfo(
                    uploadURL: uploadURL,
                    options: .inputStandardizationSkipped
                )
            ),
            uploadManager: uploadManager
        )

        upload.start(forceRestart: false)
        duplicateUpload.start(forceRestart: false)

        XCTAssertEqual(
            uploadManager.allManagedUploads().count,
            1,
            "There should only be one active upload for a given URL"
        )

    }

}
