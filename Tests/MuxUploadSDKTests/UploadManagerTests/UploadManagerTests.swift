//
//  UploadManagerTests.swift
//

import Foundation
import XCTest

@testable import MuxUploadSDK

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
            uploadInfo: UploadInfo(
                id: UUID().uuidString,
                uploadURL: uploadURL,
                videoFile: videoInputURL,
                chunkSize: 8,
                retriesPerChunk: 2,
                optOutOfEventTracking: true
            ),
            uploadManager: uploadManager
        )

        let duplicateUpload = MuxUpload(
            uploadInfo: UploadInfo(
                id: UUID().uuidString,
                uploadURL: uploadURL,
                videoFile: videoInputURL,
                chunkSize: 8,
                retriesPerChunk: 2,
                optOutOfEventTracking: true
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
