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

        let chunkFileUploader = ChunkedFileUploader(
            uploadInfo: UploadInfo(
                id: UUID().uuidString,
                uploadURL: uploadURL,
                videoFile: videoInputURL,
                chunkSize: 8,
                retriesPerChunk: 2,
                optOutOfEventTracking: true
            )
        )

        let upload = MuxUpload(
            wrapping: chunkFileUploader,
            uploadManager: uploadManager
        )

        let duplicateChunkFileUploader = ChunkedFileUploader(
            uploadInfo: UploadInfo(
                id: UUID().uuidString,
                uploadURL: uploadURL,
                videoFile: videoInputURL,
                chunkSize: 8,
                retriesPerChunk: 2,
                optOutOfEventTracking: true
            )
        )

        let duplicateUpload = MuxUpload(
            wrapping: duplicateChunkFileUploader,
            uploadManager: uploadManager
        )

        upload.start(forceRestart: true)
        duplicateUpload.start(forceRestart: true)

        XCTAssertEqual(
            uploadManager.allManagedUploads().count,
            1,
            "There should only be one active upload for a given URL"
        )

    }

}
