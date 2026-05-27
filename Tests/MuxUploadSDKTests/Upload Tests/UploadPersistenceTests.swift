//
//  UploadPersistence.swift
//  
//
//  Created by Emily Dixon on 3/6/23.
//

import XCTest
@testable import MuxUploadSDK

/// Tests the write-through logic of the Upload Peristence. Actual interaction with the filesystem can't be tested
final class UploadPersistenceTests: XCTestCase {
    static let oldEntryAgeInSeconds: TimeInterval = 30 * 24 * 60 * 60
    
    // TESTS
    // writesInProgressShouldSave
    // writesWhilePausedShouldSave
    // writesTerminatedShouldRemove
    
    func testWrite() throws {
        let e1 = PersistenceEntry(
            savedAt: Date().timeIntervalSince1970,
            stateCode: .wasPaused,
            lastSuccessfulByte: 0,
            uploadInfo: renameDummyUploadInfo(basename: "e1"),
            inputFileURL: URL(string: "file://path/to/dummy/file/e1")!
        )
        let e2 = PersistenceEntry(
            savedAt: Date().timeIntervalSince1970,
            stateCode: .wasPaused,
            lastSuccessfulByte: 0,
            uploadInfo: renameDummyUploadInfo(basename: "e2"),
            inputFileURL: URL(string: "file://path/to/dummy/file/e2")!
        )
        let persistence = UploadPersistence(innerFile: makeSimulatedUploadsFile(), atURL: makeDummyFileURL(basename: "fake-cache-file"))
        XCTAssertNoThrow(
            try persistence.write(entry: e1, for: e1.uploadInfo.id)
        )
        XCTAssertNoThrow(
            try persistence.write(entry: e2, for: e2.uploadInfo.id)
        )
        
        let readItem = try persistence.readEntry(uploadID: e1.uploadInfo.id)
        XCTAssertEqual(
            try persistence.readAll().count,
            2,
            "two items should have been written"
        )
        XCTAssertEqual(
            readItem!.inputFileURL,
            e1.inputFileURL,
            "Should read the same item as written"
        )
    }
    
    func testReadAndReadAll() throws {
        let e1 = PersistenceEntry(
            basename: "e1"
        )
        let e2 = PersistenceEntry(
            basename: "e2"
        )
        let persistence = UploadPersistence(innerFile: makeSimulatedUploadsFile(), atURL: makeDummyFileURL(basename: "fake-cache-file"))
        XCTAssertNoThrow(
            try persistence.write(entry: e1, for: e1.uploadInfo.id)
        )

        XCTAssertNoThrow(
            try persistence.write(entry: e2, for: e2.uploadInfo.id)
        )
        
        // Read them in a different order to ensure idempotence
        let readItem1 = try XCTUnwrap(
            persistence.readEntry(uploadID: e2.uploadInfo.id)
        )
        let readItem2 = try XCTUnwrap(
            persistence.readEntry(uploadID: e1.uploadInfo.id)
        )
        let allItems = try XCTUnwrap(
            persistence.readAll()
        )
        
        XCTAssertEqual(
            allItems.count,
            2,
            "readAll read 2 items"
        )
        XCTAssertEqual(
            // remember, they're swapped
            readItem2.inputFileURL,
            e1.inputFileURL,
            "read() should return the right item"
        )
        XCTAssertEqual(
            // remember, they're swapped
            readItem1.inputFileURL,
            e2.inputFileURL,
            "read() should return the right item"
        )
    }
    
    func testRemove() throws {
        let e1 = PersistenceEntry(
            basename: "e1"
        )
        let e2 = PersistenceEntry(
            basename: "e2"
        )
        let persistence = UploadPersistence(innerFile: makeSimulatedUploadsFile(), atURL: makeDummyFileURL(basename: "fake-cache-file"))
        // Shouldn't throw (but not specifically part of the test)
        XCTAssertNoThrow(
            try persistence.write(entry: e1, for: e1.uploadInfo.id)
        )
        XCTAssertNoThrow(
            try persistence.write(entry: e2, for: e2.uploadInfo.id)
        )
        XCTAssertNoThrow(
            try persistence.remove(entryAtID: e2.uploadInfo.id)
        )
        
        let readItem = try persistence.readEntry(uploadID: e1.uploadInfo.id)
        XCTAssertEqual(
            try persistence.readAll().count,
            1,
            "one item should remain"
        )
        XCTAssertEqual(
            readItem!.inputFileURL,
            e1.inputFileURL,
            "Should read the same item as written"
        )
    }
    
    func testCleanUpOldEntriesRemovesThreeDayOldEntries() throws {
        let newerEntry = PersistenceEntry(
            basename: "newer"
        )
        let olderEntry = PersistenceEntry(
            basename: "older",
            savedAt: UploadPersistenceTests.oldEntryAgeInSeconds
        )
        let uploadsFile = makeSimulatedUploadsFile()
        let persistence = UploadPersistence(innerFile: uploadsFile, atURL: makeDummyFileURL(basename: "fake-cache-file"))
        
        // Should not throw (not specifically under test)
        XCTAssertNoThrow(
            try persistence.write(
                entry: newerEntry, for: newerEntry.uploadInfo.id
            )
        )
        XCTAssertNoThrow(
            try persistence.write(
                entry: olderEntry, for: olderEntry.uploadInfo.id
            )
        )
        
        let persistenceNextSession = UploadPersistence(innerFile: uploadsFile, atURL: makeDummyFileURL(basename: "fake-cache-file"))
        let entriesAfterCleanup = try XCTUnwrap(
            persistenceNextSession.readAll()
        )
        XCTAssertEqual(
            1,
            entriesAfterCleanup.count,
            "Only one entry should be saved after cleanup"
        )
        XCTAssertEqual(
            entriesAfterCleanup[0].inputFileURL,
            makeDummyFileURL(basename: "newer"),
            "The newer entry should be saved but not the older"
        )
    }

    func testFailureWithLastBytePreservesEntryForResume() throws {
        let persistence = UploadPersistence(innerFile: makeSimulatedUploadsFile(), atURL: makeDummyFileURL(basename: "fake-cache-file"))
        let uploadInfo = renameDummyUploadInfo(basename: "failed-upload")
        let inputFileURL = makeDummyFileURL(basename: "failed-upload")

        persistence.update(
            uploadState: .failure(InternalUploaderError(reason: DummyError(), lastByte: 1234)),
            for: uploadInfo,
            fileInputURL: inputFileURL
        )

        let entry = try XCTUnwrap(persistence.readEntry(uploadID: uploadInfo.id))
        XCTAssertEqual(entry.inputFileURL, inputFileURL)
        XCTAssertEqual(entry.lastSuccessfulByte, 1234)
        XCTAssertEqual(entry.stateCode, .wasInProgress)
    }

    func testPausedStatePersistsSafeCheckpoint() throws {
        let safeProgress = Progress(totalUnitCount: 10_000)
        safeProgress.completedUnitCount = 1_000
        let update = ChunkedFileUploader.Update(
            progress: safeProgress,
            startTime: 0,
            updateTime: 0
        )
        let persistence = UploadPersistence(innerFile: makeSimulatedUploadsFile(), atURL: makeDummyFileURL(basename: "fake-cache-file"))
        let uploadInfo = renameDummyUploadInfo(basename: "paused-upload")
        let inputFileURL = makeDummyFileURL(basename: "paused-upload")

        persistence.update(
            uploadState: .paused(update),
            for: uploadInfo,
            fileInputURL: inputFileURL
        )

        let entry = try XCTUnwrap(persistence.readEntry(uploadID: uploadInfo.id))
        XCTAssertEqual(entry.lastSuccessfulByte, 1_000)
        XCTAssertEqual(entry.stateCode, .wasPaused)
    }

    func testDefaultPersistenceCreatesBackingFileOnFirstWrite() throws {
        let applicationSupportDirectory = try XCTUnwrap(
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        )
        let uploadCacheDirectory = applicationSupportDirectory.appendingPathComponent("mux", isDirectory: true)
        let uploadCacheFile = uploadCacheDirectory.appendingPathComponent("uploads.json")
        defer {
            try? FileManager.default.removeItem(at: uploadCacheFile)
        }

        try? FileManager.default.removeItem(at: uploadCacheFile)

        let uploadInfo = renameDummyUploadInfo(basename: "default-persistence")
        let inputFileURL = makeDummyFileURL(basename: "default-persistence")
        let persistence = try UploadPersistence()

        XCTAssertNoThrow(
            persistence.update(
                uploadState: .failure(InternalUploaderError(reason: DummyError(), lastByte: 1234)),
                for: uploadInfo,
                fileInputURL: inputFileURL
            )
        )

        let entry = try XCTUnwrap(persistence.readEntry(uploadID: uploadInfo.id))
        XCTAssertEqual(entry.lastSuccessfulByte, 1234)
        XCTAssertTrue(FileManager.default.fileExists(atPath: uploadCacheFile.path))
    }
    
    private func makeSimulatedUploadsFile() -> UploadsFile {
        return FakeUploadsFile.simiulatedStorage()
    }
    
    private func makeDummyFileURL(basename: String) -> URL {
        return URL(string: "file://path/to/dummy/file/\(basename)")!
    }
    
    private func makeDummyHttpUrl(basename: String) -> URL {
        return URL(string: "https://dummy.site/page/\(basename)")!
    }
    
    private func renameDummyUploadInfo(basename: String) -> UploadInfo {
        return UploadInfo(
            id: UUID().uuidString,
            uploadURL: URL(string: "https://dummy.site/page/\(basename)")!,
            options: .default
        )
    }
}
