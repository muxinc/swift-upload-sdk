import Foundation
import XCTest

@testable import MuxUploadSDK

final class UploadPersistenceOrderingTests: XCTestCase {
    @MainActor
    func testAcknowledgementRejectsLateSavesAcrossManagerLifetimes() async throws {
        let (manager, disk, worker, upload) = makeUpload()
        manager.registerUpload(upload)
        for byte in 1...100 { worker.emit(progress(Int64(byte))) }
        manager.acknowledgeUpload(id: upload.id)
        worker.emit(progress(101))

        let restored = await manager.resumeDirectUpload(ofFile: worker.inputFileURL)
        XCTAssertNil(restored)
        try await assertNotRestoredAfterRelaunch(disk: disk, worker: worker)
    }

    @MainActor
    func testSuccessRejectsLateSavesAcrossManagerLifetimes() async throws {
        let (manager, disk, worker, upload) = makeUpload()
        manager.registerUpload(upload)
        for byte in 1...100 { worker.emit(progress(Int64(byte))) }
        worker.emit(.success(.init(finalProgress: Progress(totalUnitCount: 100), startTime: 1, finishTime: 2)))
        worker.emit(progress(101))

        let restored = await manager.resumeDirectUpload(ofFile: worker.inputFileURL)
        XCTAssertNil(restored)
        XCTAssertTrue(upload.complete)
        XCTAssertEqual(manager.allManagedDirectUploads().count, 1)
        try await assertNotRestoredAfterRelaunch(disk: disk, worker: worker)
    }

    @MainActor
    func testReplacementIgnoresOldWorkerCallbacksAndPersistsNewCheckpoint() async throws {
        let (manager, disk, oldWorker, oldUpload) = makeUpload()
        manager.registerUpload(oldUpload)
        oldWorker.emit(progress(512))
        manager.acknowledgeUpload(id: oldUpload.id)
        let replacement = RecordingWorker(
            uploadInfo: oldWorker.uploadInfo,
            inputFileURL: oldWorker.inputFileURL,
            file: ChunkedFile(chunkSize: 1024)
        )
        let fresh = DirectUpload(wrapping: replacement, uploadManager: manager)
        manager.registerUpload(fresh)
        replacement.emit(progress(256))
        oldWorker.emit(progress(900))
        oldWorker.emit(.canceled)
        oldWorker.emit(.failure(InternalUploaderError(reason: DummyError(), lastByte: 1024)))

        let restored = await manager.resumeDirectUpload(ofFile: oldWorker.inputFileURL)
        XCTAssertTrue(restored === fresh)
        let persistence = UploadPersistence(innerFile: disk, atURL: oldWorker.inputFileURL)
        let saved = try XCTUnwrap(persistence.readEntry(uploadID: fresh.id))
        XCTAssertEqual(saved.lastSuccessfulByte, 256)
        XCTAssertTrue(manager.findChunkedFileUploader(
            inputFileURL: replacement.inputFileURL, uploadURL: replacement.uploadInfo.uploadURL
        ) === replacement)
    }

    @MainActor
    private func assertNotRestoredAfterRelaunch(disk: UploadsFile, worker: RecordingWorker) async throws {
        // Reopen the backing file through fresh persistence/cache objects, as a new process would.
        let persistence = UploadPersistence(innerFile: disk, atURL: worker.inputFileURL)
        XCTAssertNil(try persistence.readEntry(uploadID: worker.uploadInfo.id))
        let manager = DirectUploadManager(uploadActor: UploadCacheActor(persistence: persistence))
        let restored = await manager.resumeDirectUpload(ofFile: worker.inputFileURL)
        XCTAssertNil(restored)
    }

    private func makeUpload() -> (DirectUploadManager, UploadsFile, RecordingWorker, DirectUpload) {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let disk = FakeUploadsFile.simiulatedStorage()
        let persistence = UploadPersistence(innerFile: disk, atURL: fileURL)
        let manager = DirectUploadManager(uploadActor: UploadCacheActor(persistence: persistence))
        let worker = RecordingWorker(
            uploadInfo: UploadInfo(uploadURL: URL(string: "https://example.com/upload")!, options: .inputStandardizationSkipped),
            inputFileURL: fileURL,
            file: ChunkedFile(chunkSize: 1024)
        )
        return (manager, disk, worker, DirectUpload(wrapping: worker, uploadManager: manager))
    }

    private func progress(_ byte: Int64) -> ChunkedFileUploader.InternalUploadState {
        let progress = Progress(totalUnitCount: 4096)
        progress.completedUnitCount = byte
        return .uploading(.init(progress: progress, startTime: 1, updateTime: 2))
    }

    private final class RecordingWorker: ChunkedFileUploader {
        private var delegates: [String: ChunkedFileUploaderDelegate] = [:]

        override func addDelegate(withToken token: String, _ delegate: ChunkedFileUploaderDelegate) {
            delegates[token] = delegate
        }
        override func removeDelegate(withToken token: String) { delegates.removeValue(forKey: token) }
        override func cancel() { }
        override func persistenceState(for state: InternalUploadState) -> InternalUploadState { state }

        func emit(_ state: InternalUploadState) {
            for delegate in Array(delegates.values) {
                delegate.chunkedFileUploader(self, stateUpdated: state)
            }
        }
    }
}
