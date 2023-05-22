//
//  UploadManagerTests.swift
//

import AVFoundation
import Foundation
import XCTest

@testable import MuxUploadSDK

extension UploadOptions {

    static var inputStandardizationDisabled: UploadOptions {
        UploadOptions(
            inputStandardization: .disabled
        )
    }

}

class UploadManagerTests: XCTestCase {

    func testUploadManagerURLDeduplication() throws {

        let uploadManager = UploadManager()

        let uploadURL = try XCTUnwrap(
            URL(string: "https://www.example.com/upload")
        )

        let videoInputURL = try XCTUnwrap(
            URL(string: "file://path/to/dummy/file/")
        )

        let upload = MuxUpload(
            input: UploadInput(
                asset: AVAsset(url: videoInputURL),
                info: UploadInfo(
                    uploadURL: uploadURL,
                    options: .inputStandardizationDisabled
                )
            ),
            uploadManager: uploadManager
        )

        let duplicateUpload = MuxUpload(
            input: UploadInput(
                asset: AVAsset(url: videoInputURL),
                info: UploadInfo(
                    uploadURL: uploadURL,
                    options: .inputStandardizationDisabled
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
