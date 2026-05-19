//
//  UploadManagerTests.swift
//

import AVFoundation
import Foundation
import XCTest

@testable import MuxUploadSDK

extension DirectUploadOptions {

    static var inputStandardizationSkipped: DirectUploadOptions {
        DirectUploadOptions(
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
                asset: AVURLAsset(url: videoInputURL),
                info: UploadInfo(
                    uploadURL: uploadURL,
                    options: .inputStandardizationSkipped
                )
            ),
            uploadManager: uploadManager
        )

        let duplicateUpload = DirectUpload(
            input: UploadInput(
                asset: AVURLAsset(url: videoInputURL),
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
            uploadManager.allManagedDirectUploads().count,
            1,
            "There should only be one active upload for a given URL"
        )

    }

    func testResumeDirectUploadFindsPersistedUploadByInputFileURL() async throws {
        let inputFileURL = try XCTUnwrap(
            URL(string: "file://path/to/dummy/file/resume")
        )
        let uploadURL = try XCTUnwrap(
            URL(string: "https://www.example.com/upload/resume")
        )
        let uploadInfo = UploadInfo(
            id: UUID().uuidString,
            uploadURL: uploadURL,
            options: .inputStandardizationSkipped
        )
        let persistence = UploadPersistence(
            innerFile: FakeUploadsFile.simiulatedStorage(),
            atURL: inputFileURL
        )
        try persistence.write(
            entry: PersistenceEntry(
                savedAt: Date().timeIntervalSince1970,
                stateCode: .wasInProgress,
                lastSuccessfulByte: 1234,
                uploadInfo: uploadInfo,
                inputFileURL: inputFileURL
            ),
            for: uploadInfo.id
        )
        let uploadManager = DirectUploadManager(
            uploadActor: UploadCacheActor(persistence: persistence)
        )

        let restoredUpload = await uploadManager.resumeDirectUpload(ofFile: inputFileURL)

        XCTAssertNotNil(restoredUpload)
        XCTAssertEqual(restoredUpload?.videoFile, inputFileURL)
        XCTAssertEqual(restoredUpload?.uploadURL, uploadURL)
        XCTAssertEqual(uploadManager.allManagedDirectUploads().count, 1)
    }

    func testResumeDirectUploadFindsPersistedUploadByOriginalSourceFileURL() async throws {
        let sourceFileURL = try XCTUnwrap(
            URL(string: "file://path/to/dummy/file/source")
        )
        let transportFileURL = try XCTUnwrap(
            URL(string: "file://path/to/dummy/file/standardized")
        )
        let uploadURL = try XCTUnwrap(
            URL(string: "https://www.example.com/upload/resume")
        )
        let uploadInfo = UploadInfo(
            id: UUID().uuidString,
            uploadURL: uploadURL,
            sourceFileURL: sourceFileURL,
            options: .inputStandardizationSkipped
        )
        let persistence = UploadPersistence(
            innerFile: FakeUploadsFile.simiulatedStorage(),
            atURL: transportFileURL
        )
        try persistence.write(
            entry: PersistenceEntry(
                savedAt: Date().timeIntervalSince1970,
                stateCode: .wasInProgress,
                lastSuccessfulByte: 1234,
                uploadInfo: uploadInfo,
                inputFileURL: transportFileURL
            ),
            for: uploadInfo.id
        )
        let uploadManager = DirectUploadManager(
            uploadActor: UploadCacheActor(persistence: persistence)
        )

        let restoredUpload = await uploadManager.resumeDirectUpload(ofFile: sourceFileURL)

        XCTAssertNotNil(restoredUpload)
        XCTAssertEqual(restoredUpload?.videoFile, transportFileURL)
        let inputAsset = try XCTUnwrap(restoredUpload?.inputAsset as? AVURLAsset)
        XCTAssertEqual(inputAsset.url, sourceFileURL)
        XCTAssertEqual(restoredUpload?.uploadURL, uploadURL)
    }

}
