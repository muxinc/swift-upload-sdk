import AVFoundation
import Foundation
import XCTest

@testable import MuxUploadSDK

final class BulkUploadRestorationTests: XCTestCase {

    private final class Delegate: DirectUploadManagerDelegate {
        var onUpdate: ([DirectUpload]) -> Void

        init(onUpdate: @escaping ([DirectUpload]) -> Void) {
            self.onUpdate = onUpdate
        }

        func didUpdate(managedDirectUploads: [DirectUpload]) {
            XCTAssertTrue(Thread.isMainThread)
            onUpdate(managedDirectUploads)
        }
    }

    private func makePersistence(entries: [PersistenceEntry]) throws -> UploadPersistence {
        let persistence = UploadPersistence(
            innerFile: FakeUploadsFile.simiulatedStorage(),
            atURL: URL(fileURLWithPath: "/unused/uploads.json")
        )
        for entry in entries {
            try persistence.write(entry: entry, for: entry.uploadInfo.id)
        }
        return persistence
    }

    private func makeEntries() -> [PersistenceEntry] {
        [PersistenceEntry.PreviousStateCode.wasPaused, .wasInProgress].enumerated().map { index, state in
            PersistenceEntry(
                savedAt: Date().timeIntervalSince1970,
                stateCode: state,
                lastSuccessfulByte: UInt64(1234 + index),
                uploadInfo: UploadInfo(
                    id: UUID().uuidString,
                    uploadURL: URL(string: "https://example.invalid/upload/\(index)")!,
                    sourceFileURL: URL(fileURLWithPath: "/unused/source-\(index).mov"),
                    options: .inputStandardizationSkipped
                ),
                inputFileURL: URL(fileURLWithPath: "/unused/transport-\(index).mov")
            )
        }
    }

    @MainActor
    func testRestoresEveryPersistedUploadAndNotifiesWithCompleteList() async throws {
        let entries = makeEntries()
        let persistence = try makePersistence(entries: entries)
        let manager = DirectUploadManager(uploadActor: UploadCacheActor(persistence: persistence))
        let updated = expectation(description: "All persisted uploads are registered")
        let delegate = Delegate { uploads in
            XCTAssertEqual(Set(uploads.map(\.id)), Set(entries.map { $0.uploadInfo.id }))
            // Delegates can read manager state during delivery without deadlocking.
            XCTAssertEqual(Set(manager.allManagedDirectUploads().map(\.id)), Set(uploads.map(\.id)))
            updated.fulfill()
        }
        manager.addDelegate(delegate)
        defer { manager.removeDelegate(delegate) }

        manager.resumeAllDirectUploads()
        await fulfillment(of: [updated], timeout: 2)

        XCTAssertEqual(manager.allManagedDirectUploads().count, entries.count)
        for entry in entries {
            let upload = try XCTUnwrap(manager.startedDirectUpload(ofFile: entry.inputFileURL))
            XCTAssertEqual(upload.id, entry.uploadInfo.id)
            XCTAssertEqual(upload.uploadURL, entry.uploadInfo.uploadURL)
            XCTAssertEqual((upload.inputAsset as? AVURLAsset)?.url, entry.uploadInfo.sourceFileURL)
            let worker = try XCTUnwrap(upload.fileWorker)
            guard case .paused = worker.currentState, case .paused = upload.inputStatus else {
                return XCTFail("Restored uploads should remain paused until explicitly started")
            }
            XCTAssertFalse(upload.inProgress)
            XCTAssertEqual(upload.uploadStatus?.isPaused, true)
            XCTAssertNil(upload.uploadStatus?.startTime)
            XCTAssertEqual(upload.uploadStatus?.progress?.completedUnitCount, Int64(entry.lastSuccessfulByte))
            XCTAssertEqual(upload.uploadStatus?.progress?.totalUnitCount, -1)
            let saved = try XCTUnwrap(persistence.readEntry(uploadID: upload.id))
            XCTAssertEqual(saved.lastSuccessfulByte, entry.lastSuccessfulByte)
            XCTAssertEqual(saved.stateCode, entry.stateCode)
        }
    }

    @MainActor
    func testBulkRestorationPreservesAnAlreadyManagedUpload() async throws {
        let entries = makeEntries()
        let persistence = try makePersistence(entries: entries)
        let manager = DirectUploadManager(uploadActor: UploadCacheActor(persistence: persistence))
        let singleUpdated = expectation(description: "Single upload registered")
        let delegate = Delegate { _ in singleUpdated.fulfill() }
        manager.addDelegate(delegate)
        defer { manager.removeDelegate(delegate) }
        let resumed = await manager.resumeDirectUpload(ofFile: entries[0].inputFileURL)
        let existing = try XCTUnwrap(resumed)
        await fulfillment(of: [singleUpdated], timeout: 2)
        let existingWorker = try XCTUnwrap(existing.fileWorker)

        let bulkUpdated = expectation(description: "Remaining upload restored")
        delegate.onUpdate = { uploads in
            XCTAssertEqual(uploads.count, entries.count)
            bulkUpdated.fulfill()
        }
        manager.resumeAllDirectUploads()
        await fulfillment(of: [bulkUpdated], timeout: 2)

        XCTAssertTrue(manager.startedDirectUpload(ofFile: entries[0].inputFileURL) === existing)
        XCTAssertTrue(existing.fileWorker === existingWorker)
        XCTAssertNotNil(manager.startedDirectUpload(ofFile: entries[1].inputFileURL))
    }

    @MainActor
    func testSingleResumePreservesABulkRestoredHandle() async throws {
        let entries = makeEntries()
        let persistence = try makePersistence(entries: entries)
        let manager = DirectUploadManager(uploadActor: UploadCacheActor(persistence: persistence))
        let bulkUpdated = expectation(description: "Bulk restoration finished")
        let delegate = Delegate { _ in bulkUpdated.fulfill() }
        manager.addDelegate(delegate)
        defer { manager.removeDelegate(delegate) }
        manager.resumeAllDirectUploads()
        await fulfillment(of: [bulkUpdated], timeout: 2)
        let existing = try XCTUnwrap(manager.startedDirectUpload(ofFile: entries[0].inputFileURL))
        let worker = try XCTUnwrap(existing.fileWorker)

        let singleUpdated = expectation(description: "Single restoration finished")
        delegate.onUpdate = { _ in singleUpdated.fulfill() }
        let resumed = await manager.resumeDirectUpload(ofFile: entries[0].uploadInfo.sourceFileURL!)
        await fulfillment(of: [singleUpdated], timeout: 2)

        XCTAssertTrue(resumed === existing)
        XCTAssertTrue(resumed?.fileWorker === worker)
    }

    @MainActor
    func testConcurrentSingleResumesReturnTheSameHandle() async throws {
        let entry = makeEntries()[0]
        let persistence = try makePersistence(entries: [entry])
        let manager = DirectUploadManager(uploadActor: UploadCacheActor(persistence: persistence))
        let uploads = await withTaskGroup(of: DirectUpload?.self, returning: [DirectUpload].self) { group in
            for _ in 0..<2 {
                group.addTask { await manager.resumeDirectUpload(ofFile: entry.inputFileURL) }
            }
            var restored: [DirectUpload] = []
            for await upload in group {
                if let upload { restored.append(upload) }
            }
            return restored
        }
        XCTAssertEqual(uploads.count, 2)
        let first = try XCTUnwrap(uploads.first)
        XCTAssertTrue(uploads.last === first)
        XCTAssertTrue(manager.startedDirectUpload(ofFile: entry.inputFileURL) === first)
    }

    @MainActor
    func testSnapshotCapturedBeforeAcknowledgementCannotRestoreCancelledUpload() async throws {
        let entry = makeEntries()[0]
        let persistence = try makePersistence(entries: [entry])
        let cache = UploadCacheActor(persistence: persistence)
        let manager = DirectUploadManager(uploadActor: cache)
        let initial = expectation(description: "Initial single restoration finished")
        let delegate = Delegate { _ in initial.fulfill() }
        manager.addDelegate(delegate)
        defer { manager.removeDelegate(delegate) }
        let original = await manager.resumeDirectUpload(ofFile: entry.inputFileURL)
        await fulfillment(of: [initial], timeout: 2)
        XCTAssertNotNil(original)
        let snapshot = await cache.getAllUploads()
        let staleWorker = try XCTUnwrap(snapshot.first)

        let removed = expectation(description: "Acknowledgement deleted persistence")
        delegate.onUpdate = { uploads in
            if uploads.isEmpty { removed.fulfill() }
        }
        manager.acknowledgeUpload(id: entry.uploadInfo.id)
        XCTAssertNil(manager.restorePersistedUpload(staleWorker))
        await fulfillment(of: [removed], timeout: 2)

        XCTAssertNil(try persistence.readEntry(uploadID: entry.uploadInfo.id))
        XCTAssertNil(manager.restorePersistedUpload(staleWorker))
        XCTAssertTrue(manager.allManagedDirectUploads().isEmpty)
    }

    @MainActor
    func testRegisteringRestoredWorkerWithUnknownTotalPreservesCheckpoint() async throws {
        let entry = makeEntries()[0]
        let persistence = try makePersistence(entries: [entry])
        let cache = UploadCacheActor(persistence: persistence)
        let manager = DirectUploadManager(uploadActor: cache)
        let worker = ChunkedFileUploader(persistenceEntry: entry)
        let upload = DirectUpload(wrapping: worker, uploadManager: manager)

        manager.registerUpload(upload)
        let restored = await manager.resumeDirectUpload(ofFile: entry.inputFileURL)
        let saved = await cache.getUpload(uploadID: entry.uploadInfo.id)

        XCTAssertTrue(restored === upload)
        XCTAssertEqual(saved?.currentState.progress?.completedUnitCount, Int64(entry.lastSuccessfulByte))
        XCTAssertEqual(saved?.currentState.progress?.totalUnitCount, -1)
    }

    @MainActor
    func testExplicitRegistrationAfterAcknowledgementAllowsFreshAttempt() async throws {
        let entry = makeEntries()[0]
        let persistence = try makePersistence(entries: [entry])
        let manager = DirectUploadManager(uploadActor: UploadCacheActor(persistence: persistence))
        manager.acknowledgeUpload(id: entry.uploadInfo.id)
        let uploader = ChunkedFileUploader(persistenceEntry: entry)
        let fresh = DirectUpload(wrapping: uploader, uploadManager: manager)

        manager.registerUpload(fresh)

        XCTAssertTrue(manager.startedDirectUpload(ofFile: entry.inputFileURL) === fresh)
        XCTAssertTrue(manager.restorePersistedUpload(ChunkedFileUploader(persistenceEntry: entry)) === fresh)
    }

    @MainActor
    func testRepeatedBulkRestorationPreservesHandles() async throws {
        let entries = makeEntries()
        let persistence = try makePersistence(entries: entries)
        let manager = DirectUploadManager(uploadActor: UploadCacheActor(persistence: persistence))
        let firstUpdated = expectation(description: "First restoration finished")
        let delegate = Delegate { _ in firstUpdated.fulfill() }
        manager.addDelegate(delegate)
        defer { manager.removeDelegate(delegate) }
        manager.resumeAllDirectUploads()
        await fulfillment(of: [firstUpdated], timeout: 2)
        let originals = manager.allManagedDirectUploads()
        XCTAssertEqual(originals.count, entries.count)

        let secondUpdated = expectation(description: "Repeated restoration finished")
        delegate.onUpdate = { uploads in
            XCTAssertEqual(uploads.count, entries.count)
            secondUpdated.fulfill()
        }
        manager.resumeAllDirectUploads()
        await fulfillment(of: [secondUpdated], timeout: 2)

        for original in originals {
            let fileURL = try XCTUnwrap(original.videoFile)
            XCTAssertTrue(manager.startedDirectUpload(ofFile: fileURL) === original)
        }
    }

    @MainActor
    func testConcurrentBulkRestorationRegistersEachUploadOnce() async throws {
        let entries = makeEntries()
        let persistence = try makePersistence(entries: entries)
        let manager = DirectUploadManager(uploadActor: UploadCacheActor(persistence: persistence))
        let updated = expectation(description: "Both restoration requests finished")
        updated.expectedFulfillmentCount = 2
        let delegate = Delegate { uploads in
            XCTAssertEqual(Set(uploads.map(\.id)), Set(entries.map { $0.uploadInfo.id }))
            XCTAssertEqual(uploads.count, entries.count)
            updated.fulfill()
        }
        manager.addDelegate(delegate)
        defer { manager.removeDelegate(delegate) }

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<2 {
                group.addTask { manager.resumeAllDirectUploads() }
            }
        }
        await fulfillment(of: [updated], timeout: 2)

        XCTAssertEqual(manager.allManagedDirectUploads().count, entries.count)
    }

    @MainActor
    func testRestoredUploadCanBeCancelledAndRemovedFromPersistence() async throws {
        let entries = makeEntries()
        let persistence = try makePersistence(entries: entries)
        let manager = DirectUploadManager(uploadActor: UploadCacheActor(persistence: persistence))
        let restored = expectation(description: "Uploads restored")
        let delegate = Delegate { _ in restored.fulfill() }
        manager.addDelegate(delegate)
        defer { manager.removeDelegate(delegate) }
        manager.resumeAllDirectUploads()
        await fulfillment(of: [restored], timeout: 2)
        let upload = try XCTUnwrap(manager.startedDirectUpload(ofFile: entries[0].inputFileURL))

        let cancelled = expectation(description: "Cancelled upload removed")
        delegate.onUpdate = { uploads in
            XCTAssertEqual(uploads.map(\.id), [entries[1].uploadInfo.id])
            cancelled.fulfill()
        }
        upload.cancel()
        await fulfillment(of: [cancelled], timeout: 2)

        XCTAssertNil(manager.startedDirectUpload(ofFile: entries[0].inputFileURL))
        XCTAssertNil(try persistence.readEntry(uploadID: upload.id))
    }

    @MainActor
    func testEmptyPersistenceNotifiesWithEmptyList() async throws {
        let persistence = try makePersistence(entries: [])
        let manager = DirectUploadManager(uploadActor: UploadCacheActor(persistence: persistence))
        let updated = expectation(description: "Empty restoration finished")
        let delegate = Delegate { uploads in
            XCTAssertTrue(uploads.isEmpty)
            updated.fulfill()
        }
        manager.addDelegate(delegate)
        defer { manager.removeDelegate(delegate) }

        manager.resumeAllDirectUploads()
        await fulfillment(of: [updated], timeout: 2)

        XCTAssertTrue(manager.allManagedDirectUploads().isEmpty)
    }
}
