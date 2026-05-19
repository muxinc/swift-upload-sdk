//
//  ChunkedFileUploaderTests.swift
//  
//
//  Created by Emily Dixon on 3/3/23.
//

import XCTest
@testable import MuxUploadSDK

final class ChunkedFileUploaderTests: XCTestCase {

    func testPersistenceStateUsesLastSuccessfulByteForUploadingProgress() throws {
        let uploadInfo = UploadInfo(
            uploadURL: try XCTUnwrap(URL(string: "https://www.example.com/upload")),
            options: .default
        )
        let inputFileURL = try XCTUnwrap(URL(string: "file://path/to/dummy/file/resume"))
        let uploader = ChunkedFileUploader(
            uploadInfo: uploadInfo,
            inputFileURL: inputFileURL,
            file: ChunkedFile(chunkSize: 1000),
            startingByte: 1000
        )
        let streamingProgress = Progress(totalUnitCount: 10_000)
        streamingProgress.completedUnitCount = 1_500
        let streamingUpdate = ChunkedFileUploader.Update(
            progress: streamingProgress,
            startTime: 0,
            updateTime: 0
        )

        let state = uploader.persistenceState(for: .uploading(streamingUpdate))

        guard case .uploading(let persistedUpdate) = state else {
            XCTFail("Expected uploading state")
            return
        }
        XCTAssertEqual(persistedUpdate.progress.completedUnitCount, 1000)
    }

}
