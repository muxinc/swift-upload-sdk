import AVFoundation
import Foundation
import Network
import XCTest

@testable import MuxUploadSDK

final class RestoredUploadTransportTests: XCTestCase {
    private final class Delegate: DirectUploadManagerDelegate {
        let onUpdate: ([DirectUpload]) -> Void
        init(_ onUpdate: @escaping ([DirectUpload]) -> Void) { self.onUpdate = onUpdate }
        func didUpdate(managedDirectUploads: [DirectUpload]) { onUpdate(managedDirectUploads) }
    }

    @MainActor
    func testSingleResumeAfterFailureContinuesFromCheckpoint() async throws {
        try await resumeAfterFailure(usingBulkRestoration: false)
    }

    @MainActor
    func testBulkResumeOfStandardizedPayloadInNewSessionContinuesFromCheckpoint() async throws {
        try await resumeAfterFailure(usingBulkRestoration: true)
    }

    @MainActor
    private func resumeAfterFailure(usingBulkRestoration: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("source.bin")
        try Data([9, 8, 7]).write(to: sourceURL)
        let fileURL = try FileSystemTemporaryStoragePreflighter().outputURL(
            for: sourceURL, duration: .zero,
            conversion: StandardInputConversion(
                sourceCodec: .h264, outputCodec: .h264, sourceDynamicRange: .sdr,
                sourceDisplayDimensions: .known(.init(width: 64, height: 64)),
                toneMapsToSDR: false, selection: .init(maximumResolution: .preset1920x1080),
                requirementsToRemediate: []
            )
        )
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let bytes = Data((0..<4095).map { UInt8($0 % 251) })
        try bytes.write(to: fileURL)
        let listening = expectation(description: "Failure server listening")
        let server = try UploadServer(listening: listening, failFirstRequest: true, initialOffset: 1024)
        server.start()
        defer { server.stop() }
        await fulfillment(of: [listening], timeout: 5)
        let port = try XCTUnwrap(server.port)
        let entry = makeEntry(fileURL: fileURL, port: port, checkpoint: 1024, sourceURL: sourceURL)
        let persistenceURL = directory.appendingPathComponent("uploads.json")
        let persistence = UploadPersistence(innerFile: try UploadsFileImpl(fromFile: persistenceURL), atURL: persistenceURL)
        try persistence.write(entry: entry, for: entry.uploadInfo.id)
        let cache = UploadCacheActor(persistence: persistence)
        let manager = DirectUploadManager(uploadActor: cache)
        let first = await manager.resumeDirectUpload(ofFile: fileURL)
        let failed = try XCTUnwrap(first)
        let failure = expectation(description: "First transfer fails")
        failed.resultHandler = { result in
            guard case .failure = result else { return XCTFail("First request must fail") }
            failure.fulfill()
        }
        failed.start()
        await fulfillment(of: [failure], timeout: 5)

        // Drain the first manager's ordered persistence before simulating process exit.
        let inSessionReplacement = await manager.resumeDirectUpload(ofFile: sourceURL)
        // Read only on-disk state using fresh session objects, as on the next app launch.
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        let nextPersistence = UploadPersistence(innerFile: try UploadsFileImpl(fromFile: persistenceURL), atURL: persistenceURL)
        let nextCache = UploadCacheActor(persistence: nextPersistence)
        let nextManager = DirectUploadManager(uploadActor: nextCache)
        let resumed: DirectUpload
        if usingBulkRestoration {
            let restored = expectation(description: "Failed handle replaced")
            var didRestore = false
            let delegate = Delegate { uploads in
                if let replacement = uploads.first, replacement !== failed, !didRestore {
                    didRestore = true
                    restored.fulfill()
                }
            }
            nextManager.addDelegate(delegate)
            nextManager.resumeAllDirectUploads()
            await fulfillment(of: [restored], timeout: 5)
            nextManager.removeDelegate(delegate)
            resumed = try XCTUnwrap(nextManager.startedDirectUpload(ofFile: fileURL))
        } else {
            resumed = try XCTUnwrap(inSessionReplacement)
        }
        XCTAssertFalse(resumed === failed)
        XCTAssertNotNil(resumed.fileWorker)
        XCTAssertFalse(resumed.inProgress)
        XCTAssertEqual(resumed.uploadStatus?.progress?.completedUnitCount, 1024)
        XCTAssertEqual((usingBulkRestoration ? nextManager : manager).allManagedDirectUploads().count, 1)
        let saved = await (usingBulkRestoration ? nextCache : cache).getUpload(uploadID: entry.uploadInfo.id)
        XCTAssertEqual(saved?.currentState.progress?.completedUnitCount, 1024)

        let success = expectation(description: "Checkpoint transfer succeeds")
        resumed.resultHandler = { result in
            guard case .success = result else { return XCTFail("Resumed transfer must succeed") }
            success.fulfill()
        }
        resumed.start()
        await fulfillment(of: [success], timeout: 5)
        XCTAssertEqual(server.ranges, [
            "bytes 1024-2047/4095", // Failed request.
            "bytes 1024-2047/4095", "bytes 2048-3071/4095", "bytes 3072-4094/4095"
        ])
        XCTAssertEqual(server.receivedBytes, bytes.subdata(in: 1024..<2048) + bytes.subdata(in: 1024..<4095))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(try Data(contentsOf: sourceURL), Data([9, 8, 7]))
    }

    @MainActor
    func testMissingPayloadRequiresANewURLAndDiscardsCheckpoint() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([9, 8, 7]).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("MuxUploadSDK/Standardized/mux-upload-\(UUID().uuidString).mp4")
        let entry = makeEntry(fileURL: missing, port: 1, checkpoint: 1024, sourceURL: source)
        let disk = FakeUploadsFile.simiulatedStorage()
        try disk.writeContents(of: UploadsFileContents(entries: [entry]))
        let cache = UploadCacheActor(persistence: UploadPersistence(innerFile: disk, atURL: missing))
        let manager = DirectUploadManager(uploadActor: cache)
        let restored = await manager.resumeDirectUpload(ofFile: source)
        let upload = try XCTUnwrap(restored)
        let failure = expectation(description: "Missing payload is reported")
        upload.resultHandler = { result in
            guard case .failure(let error) = result else { return XCTFail("Must report missing bytes") }
            XCTAssertEqual(error.kind, .file)
            XCTAssertTrue(error.message.contains("new upload URL"))
            failure.fulfill()
        }
        upload.start()
        await fulfillment(of: [failure], timeout: 5)
        // Observe the ordered removal before reading the next session's disk state.
        for _ in 0..<100 {
            if await cache.getUpload(uploadID: entry.uploadInfo.id) == nil { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let nextManager = DirectUploadManager(uploadActor: UploadCacheActor(
            persistence: UploadPersistence(innerFile: disk, atURL: missing)))
        let retry = await nextManager.resumeDirectUpload(ofFile: source)
        XCTAssertNil(retry)
        XCTAssertTrue(try disk.readContents().entriesAbsFileUrlToUploadInfo.isEmpty)
        XCTAssertEqual(try Data(contentsOf: source), Data([9, 8, 7]))
    }

    @MainActor
    func testNewDestinationForSameFileDoesNotBorrowRestoredWorker() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("input.bin")
        let bytes = Data((0..<4095).map { UInt8($0 % 251) })
        try bytes.write(to: fileURL)
        let listening = expectation(description: "Destination server listening")
        let transferring = expectation(description: "New session is transferring")
        let server = try UploadServer(listening: listening, secondRequest: transferring, initialOffset: 1024)
        server.start()
        defer { server.stop() }
        await fulfillment(of: [listening], timeout: 5)
        let port = try XCTUnwrap(server.port)
        let entry = makeEntry(fileURL: fileURL, port: port, checkpoint: 1024)
        let persistence = UploadPersistence(innerFile: FakeUploadsFile.simiulatedStorage(), atURL: fileURL)
        try persistence.write(entry: entry, for: entry.uploadInfo.id)
        let manager = DirectUploadManager(uploadActor: UploadCacheActor(persistence: persistence))
        let restored = expectation(description: "Old destination restored")
        let delegate = Delegate { _ in restored.fulfill() }
        manager.addDelegate(delegate)
        manager.resumeAllDirectUploads()
        await fulfillment(of: [restored], timeout: 5)
        manager.removeDelegate(delegate)
        let old = try XCTUnwrap(manager.startedDirectUpload(ofFile: fileURL))
        let oldWorker = try XCTUnwrap(old.fileWorker)
        let newURL = URL(string: "http://127.0.0.1:\(port)/new-session")!
        let fresh = DirectUpload(
            input: UploadInput(asset: AVURLAsset(url: fileURL), info: UploadInfo(
                uploadURL: newURL, options: entry.uploadInfo.options
            )),
            uploadManager: manager
        )
        let succeeded = expectation(description: "New destination succeeds")
        fresh.resultHandler = { result in
            guard case .success = result else { return XCTFail("Fresh transfer must succeed") }
            succeeded.fulfill()
        }
        fresh.start()
        await fulfillment(of: [transferring], timeout: 5)
        XCTAssertTrue(manager.startedDirectUpload(ofFile: fileURL) === fresh)
        let selected = await manager.resumeDirectUpload(ofFile: fileURL)
        XCTAssertTrue(selected === fresh)
        server.releaseSecondRequest()
        await fulfillment(of: [succeeded], timeout: 5)

        XCTAssertEqual(server.paths, Array(repeating: "/new-session", count: 4))
        XCTAssertEqual(server.receivedBytes, bytes)
        XCTAssertEqual(server.ranges.first, "bytes 0-1023/4095")
        XCTAssertTrue(old.fileWorker === oldWorker)
        XCTAssertFalse(old.inProgress)
        XCTAssertEqual(old.uploadStatus?.progress?.completedUnitCount, 1024)
        XCTAssertEqual(manager.allManagedDirectUploads().count, 2)
        XCTAssertTrue(manager.findChunkedFileUploader(inputFileURL: fileURL, uploadURL: entry.uploadInfo.uploadURL) === oldWorker)
        XCTAssertNil(manager.findChunkedFileUploader(inputFileURL: fileURL, uploadURL: newURL))
    }

    private func makeEntry(fileURL: URL, port: UInt16, checkpoint: UInt64, sourceURL: URL? = nil, retryLimit: Int = 1) -> PersistenceEntry {
        PersistenceEntry(
            savedAt: Date().timeIntervalSince1970,
            stateCode: .wasPaused,
            lastSuccessfulByte: checkpoint,
            uploadInfo: UploadInfo(
                uploadURL: URL(string: "http://127.0.0.1:\(port)/old-session")!,
                sourceFileURL: sourceURL,
                options: DirectUploadOptions(
                    eventTracking: .init(optedOut: true),
                    inputStandardization: .skipped,
                    chunkSizeInBytes: 1024,
                    retryLimitPerChunk: retryLimit
                )
            ),
            inputFileURL: fileURL
        )
    }

    @MainActor
    func testRestoredTransferStartsAtSavedOffsetAndPersistsAcknowledgedChunks() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("input.bin")
        let originalBytes = Data((0..<4096).map { UInt8($0 % 251) })
        try originalBytes.write(to: fileURL)
        let listening = expectation(description: "Loopback server listening")
        let secondRequest = expectation(description: "Second chunk held while checkpoint is checked")
        let server = try UploadServer(listening: listening, secondRequest: secondRequest, initialOffset: 1234)
        server.start()
        defer { server.stop() }
        await fulfillment(of: [listening], timeout: 5)
        let port = try XCTUnwrap(server.port)
        let entry = PersistenceEntry(
            savedAt: Date().timeIntervalSince1970,
            stateCode: .wasPaused,
            lastSuccessfulByte: 1234,
            uploadInfo: UploadInfo(
                id: UUID().uuidString,
                uploadURL: URL(string: "http://127.0.0.1:\(port)/upload")!,
                options: DirectUploadOptions(
                    eventTracking: .init(optedOut: true),
                    inputStandardization: .skipped,
                    chunkSizeInBytes: 1024,
                    retryLimitPerChunk: 1
                )
            ),
            inputFileURL: fileURL
        )
        let persistence = UploadPersistence(innerFile: FakeUploadsFile.simiulatedStorage(), atURL: fileURL)
        try persistence.write(entry: entry, for: entry.uploadInfo.id)
        let cache = UploadCacheActor(persistence: persistence)
        let manager = DirectUploadManager(uploadActor: cache)
        let restored = expectation(description: "Restored handle is available")
        let checkpointSaved = expectation(description: "First resumed chunk is persisted")
        let persistenceCleared = expectation(description: "Successful transfer is removed from persistence")
        var didRestore = false
        var didSaveCheckpoint = false
        var didClearPersistence = false
        let delegate = Delegate { uploads in
            XCTAssertTrue(Thread.isMainThread)
            if !didRestore {
                didRestore = true
                restored.fulfill()
                return
            }
            Task { @MainActor in
                let cached = await cache.getUpload(uploadID: entry.uploadInfo.id)
                if cached?.currentState.progress?.completedUnitCount == 2258, !didSaveCheckpoint {
                    didSaveCheckpoint = true
                    checkpointSaved.fulfill()
                }
                if cached == nil, uploads.first?.complete == true, !didClearPersistence {
                    didClearPersistence = true
                    persistenceCleared.fulfill()
                }
            }
        }
        manager.addDelegate(delegate)
        defer { manager.removeDelegate(delegate) }
        manager.resumeAllDirectUploads()
        await fulfillment(of: [restored], timeout: 2)
        let upload = try XCTUnwrap(manager.startedDirectUpload(ofFile: fileURL))
        let worker = try XCTUnwrap(upload.fileWorker)
        XCTAssertEqual(upload.uploadStatus?.progress?.totalUnitCount, 4096)
        XCTAssertEqual(upload.uploadStatus?.progress?.completedUnitCount, 1234)
        XCTAssertFalse(upload.inProgress)

        let succeeded = expectation(description: "Resumed transfer completes")
        upload.resultHandler = { result in
            if case .failure(let error) = result { XCTFail("Unexpected failure: \(error)") }
            succeeded.fulfill()
        }

        upload.start()
        await fulfillment(of: [secondRequest, checkpointSaved], timeout: 5)

        XCTAssertTrue(upload.fileWorker === worker)
        XCTAssertTrue(upload.inProgress)
        XCTAssertEqual(server.ranges, ["bytes 1234-2257/4096", "bytes 2258-3281/4096"])
        server.releaseSecondRequest()
        await fulfillment(of: [succeeded, persistenceCleared], timeout: 5)

        XCTAssertEqual(server.ranges, ["bytes 1234-2257/4096", "bytes 2258-3281/4096", "bytes 3282-4095/4096"])
        XCTAssertEqual(server.receivedBytes, originalBytes.subdata(in: 1234..<4096))
        XCTAssertEqual(upload.uploadStatus?.progress?.completedUnitCount, 4096)
        let remaining = await cache.getUpload(uploadID: entry.uploadInfo.id)
        XCTAssertNil(remaining)
    }

    @MainActor
    func testStartAfterFailureRetriesTheSameHandleAndPayload() async throws {
        try await exerciseRecovery(failFirst: true)
    }

    @MainActor
    func testPartialAcknowledgementAndStaleCheckpointUseServerOffset() async throws {
        try await exerciseRecovery(checkpoint: 1024, remoteOffset: 0, partialAck: true)
    }

    @MainActor
    func testCheckpointAtEOFChecksServerWithoutSendingAnEmptyChunk() async throws {
        try await exerciseRecovery(checkpoint: 4095, remoteOffset: 4095, complete: true)
    }

    @MainActor
    func testLostFinalResponseIsRecognizedOnTheNextStart() async throws {
        try await exerciseRecovery(loseFinal: true)
    }

    @MainActor
    func testRetryExhaustionRetainsPayloadButExpiredURLRemovesIt() async throws {
        for status in [503, 429, 403, 404] { try await exerciseRecovery(status: status) }
    }

    @MainActor
    func testChangedPayloadFailsBeforeContactingTheUploadServer() async throws {
        try await exerciseRecovery(changed: true)
    }

    @MainActor
    func testFailedCompletionWriteRetainsPayloadForServerConfirmedRecovery() async throws {
        try await exerciseRecovery(failedCompletionWrite: true)
    }

    @MainActor
    func testRetryLimitAndCancellationAfterFailureAreHonored() async throws {
        try await exerciseRecovery(status: 503, attempts: 3)
        try await exerciseRecovery(status: 503, cancelAndRestart: true)
    }

    @MainActor
    private func exerciseRecovery(checkpoint: UInt64 = 0, remoteOffset: Int = 0,
                                  failFirst: Bool = false, partialAck: Bool = false,
                                  complete: Bool = false, loseFinal: Bool = false,
                                  status: Int? = nil, changed: Bool = false, attempts: Int = 1,
                                  failedCompletionWrite: Bool = false, cancelAndRestart: Bool = false) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("original.bin")
        try Data([9, 8, 7]).write(to: source)
        let payloadDirectory = FileSystemTemporaryStoragePreflighter.durableBaseDirectory
            .appendingPathComponent(FileSystemTemporaryStoragePreflighter.directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: payloadDirectory, withIntermediateDirectories: true)
        let payload = payloadDirectory.appendingPathComponent("mux-upload-\(UUID().uuidString).mp4")
        let bytes = Data((0..<4095).map { UInt8($0 % 251) })
        try bytes.write(to: payload)
        defer { try? FileManager.default.removeItem(at: payload) }
        let listening = expectation(description: "Strict server listening")
        let server = try UploadServer(listening: listening, failFirstRequest: failFirst,
            initialOffset: remoteOffset, partialFirstAck: partialAck, forcedStatus: status,
            initiallyComplete: complete, loseFinalResponse: loseFinal)
        server.start()
        defer { server.stop() }
        await fulfillment(of: [listening], timeout: 5)
        var entry = makeEntry(fileURL: payload, port: try XCTUnwrap(server.port), checkpoint: checkpoint, sourceURL: source,
                              retryLimit: attempts)
        entry.payloadDigest = try uploadPayloadDigest(at: payload)
        if changed { try Data(repeating: 7, count: bytes.count).write(to: payload) }
        let manifest = directory.appendingPathComponent("uploads.json")
        let disk = CompletionWriteFailureFile(inner: try UploadsFileImpl(fromFile: manifest), failRemoval: failedCompletionWrite)
        let persistence = UploadPersistence(innerFile: disk, atURL: manifest)
        try persistence.write(entry: entry, for: entry.uploadInfo.id)
        let manager = DirectUploadManager(uploadActor: UploadCacheActor(persistence: persistence))
        let restored = await manager.resumeDirectUpload(ofFile: source)
        let upload = try XCTUnwrap(restored)
        let result = expectation(description: "First result")
        var first: DirectUploadResult?
        upload.resultHandler = { first = $0; result.fulfill() }
        upload.start()
        upload.start() // Repeated calls must not create concurrent transports.
        await fulfillment(of: [result], timeout: 5)
        if failFirst || loseFinal {
            guard case .failure = first else { return XCTFail("Expected an interrupted first attempt") }
            XCTAssertTrue(FileManager.default.fileExists(atPath: payload.path))
            let success = expectation(description: "Same handle recovers")
            upload.resultHandler = {
                if case .failure(let error) = $0 { XCTFail("Retry failed: \(error)") }
                success.fulfill()
            }
            upload.start(forceRestart: loseFinal)
            await fulfillment(of: [success], timeout: 5)
            XCTAssertEqual(server.queries.count, 2)
        } else if let status {
            guard case .failure(let error) = first else { return XCTFail("Expected HTTP failure") }
            XCTAssertEqual(error.kind, .http)
            XCTAssertEqual(error.httpStatusCode, status)
            XCTAssertEqual(error.requiresNewUpload, status < 500 && status != 429)
            XCTAssertEqual(server.ranges.count, attempts, "Retry limit must bound the first failed chunk")
            XCTAssertEqual(FileManager.default.fileExists(atPath: payload.path), !error.requiresNewUpload)
            XCTAssertEqual(try persistence.readEntry(uploadID: entry.uploadInfo.id) != nil, !error.requiresNewUpload)
            let cancelled = expectation(description: "Cancellation is durably complete")
            upload.inputStatusHandler = { if case .ready = $0 { cancelled.fulfill() } }
            upload.cancel()
            await fulfillment(of: [cancelled], timeout: 2)
            if cancelAndRestart {
                let rejected = expectation(description: "Cancelled session requires a new URL")
                upload.resultHandler = {
                    guard case .failure(let failure) = $0 else { return XCTFail("Cancellation must be terminal") }
                    XCTAssertTrue(failure.requiresNewUpload)
                    rejected.fulfill()
                }
                upload.start()
                await fulfillment(of: [rejected], timeout: 2)
                XCTAssertEqual(server.queries.count, 1)
                XCTAssertFalse(FileManager.default.fileExists(atPath: payload.path))
                XCTAssertNil(try persistence.readEntry(uploadID: entry.uploadInfo.id))
            }
            return
        } else if changed {
            guard case .failure(let error) = first else { return XCTFail("Changed payload must fail") }
            XCTAssertTrue(error.requiresNewUpload)
            XCTAssertTrue(server.queries.isEmpty)
        } else {
            guard case .success = first else { return XCTFail("Expected server-confirmed completion") }
        }
        if failedCompletionWrite {
            XCTAssertTrue(FileManager.default.fileExists(atPath: payload.path))
            XCTAssertNotNil(try persistence.readEntry(uploadID: entry.uploadInfo.id))
            disk.allowRemoval()
            let reloaded = DirectUploadManager(uploadActor: UploadCacheActor(persistence:
                UploadPersistence(innerFile: disk, atURL: manifest)))
            let candidate = await reloaded.resumeDirectUpload(ofFile: source)
            let recovered = try XCTUnwrap(candidate)
            let done = expectation(description: "Remote success survives a failed local completion write")
            recovered.resultHandler = { if case .failure(let error) = $0 { XCTFail("Unexpected failure: \(error)") }; done.fulfill() }
            recovered.start()
            await fulfillment(of: [done], timeout: 5)
            XCTAssertEqual(server.queries.count, 2)
            XCTAssertEqual(server.ranges.count, 4, "Already-completed bytes must not be sent again")
        }
        if complete { XCTAssertTrue(server.ranges.isEmpty) }
        if partialAck { XCTAssertEqual(server.ranges.prefix(2), ["bytes 0-1023/4095", "bytes 512-1535/4095"]) }
        if !changed { XCTAssertTrue(upload.complete) }
        let finalPersistence = UploadPersistence(innerFile: disk, atURL: manifest)
        XCTAssertNil(try finalPersistence.readEntry(uploadID: entry.uploadInfo.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: payload.path))
        XCTAssertEqual(try Data(contentsOf: source), Data([9, 8, 7]))
    }

    @MainActor
    func testPreparationIntentIsPersistedAndRestoredBeforeTransport() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.bin")
        try Data(repeating: 1, count: 100).write(to: source)
        let manifest = directory.appendingPathComponent("uploads.json")
        let persistence = UploadPersistence(innerFile: try UploadsFileImpl(fromFile: manifest), atURL: manifest)
        let manager = DirectUploadManager(uploadActor: UploadCacheActor(persistence: persistence))
        let inspector = MockUploadInputInspector(shouldDeferCompletion: true)
        let upload = DirectUpload(input: UploadInput(asset: AVURLAsset(url: source), info:
            UploadInfo(uploadURL: URL(string: "https://example.com/new-session")!, options: .default)),
            uploadManager: manager, inputInspector: inspector)
        upload.start()
        _ = await inspector.waitForDeferredInspectionStart()
        let entry = try XCTUnwrap(persistence.readEntry(uploadID: upload.id))
        XCTAssertEqual(entry.stateCode, .preparing)
        XCTAssertNil(upload.videoFile)
        let reopened = DirectUploadManager(uploadActor: UploadCacheActor(persistence:
            UploadPersistence(innerFile: try UploadsFileImpl(fromFile: manifest), atURL: manifest)))
        let restored = expectation(description: "Authoritative startup restoration completes")
        reopened.resumeAllDirectUploads { result in
            do {
                let handles = try result.get()
                XCTAssertEqual(handles.map(\.id), [upload.id])
                XCTAssertEqual(handles.first?.sourceFileURL, source)
                XCTAssertNil(handles.first?.videoFile)
                XCTAssertFalse(handles.first?.inProgress ?? true)
            } catch { XCTFail("Restoration failed: \(error)") }
            restored.fulfill()
        }
        await fulfillment(of: [restored], timeout: 2)
        upload.cancel()
        await inspector.completeDeferredInspection()
        await upload.waitForPreparation()
        await manager.waitForPersistence()
    }

    @MainActor
    func testFailedPayloadCommitPreventsNetworkAndSameHandleCanRetry() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data((0..<4095).map { UInt8($0 % 251) }).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let listening = expectation(description: "Server listening")
        let server = try UploadServer(listening: listening)
        server.start()
        defer { server.stop() }
        await fulfillment(of: [listening], timeout: 5)
        let disk = PayloadCommitFailureFile()
        let persistence = UploadPersistence(innerFile: disk, atURL: source)
        let manager = DirectUploadManager(uploadActor: UploadCacheActor(persistence: persistence))
        let info = makeEntry(fileURL: source, port: try XCTUnwrap(server.port), checkpoint: 0).uploadInfo
        let upload = DirectUpload(input: UploadInput(asset: AVURLAsset(url: source), info: info), uploadManager: manager)
        let failed = expectation(description: "Persistence failure surfaced")
        upload.resultHandler = {
            guard case .failure(let error) = $0 else { return XCTFail("Must not upload uncommitted bytes") }
            XCTAssertFalse(error.requiresNewUpload)
            failed.fulfill()
        }
        upload.start()
        await fulfillment(of: [failed], timeout: 5)
        XCTAssertTrue(server.queries.isEmpty)
        XCTAssertTrue(server.ranges.isEmpty)
        XCTAssertEqual(try persistence.readEntry(uploadID: upload.id)?.stateCode, .preparing)
        disk.allowPayloadCommit()
        let succeeded = expectation(description: "Same handle retries after storage recovers")
        upload.resultHandler = {
            if case .failure(let error) = $0 { XCTFail("Retry failed: \(error)") }
            succeeded.fulfill()
        }
        upload.start()
        await fulfillment(of: [succeeded], timeout: 5)
        XCTAssertEqual(server.queries.count, 1)
        XCTAssertEqual(server.receivedBytes, try Data(contentsOf: source))
        XCTAssertTrue(try persistence.readAll().isEmpty)
    }

    @MainActor
    func testBulkRestorationReportsUnreadableManifest() async throws {
        let manager = DirectUploadManager(uploadActor: UploadCacheActor(persistence:
            UploadPersistence(innerFile: FakeUploadsFile.failsReadAndWrite(),
                              atURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))))
        let reported = expectation(description: "Restoration reports storage failure")
        manager.resumeAllDirectUploads { result in
            XCTAssertTrue(Thread.isMainThread)
            if case .success = result { XCTFail("An unreadable manifest must not look like an empty queue") }
            reported.fulfill()
        }
        await fulfillment(of: [reported], timeout: 2)
    }

    private final class UploadServer {
        private let lock = NSLock()
        private let queue = DispatchQueue(label: "restored-upload-loopback-server")
        private let listener: NWListener
        private let listening: XCTestExpectation
        private var capturedRanges: [String] = []
        private var capturedQueries: [String] = []
        private var capturedPaths: [String] = []
        private var bodies: [Data] = []
        private var connections: [NWConnection] = []
        private var held: (NWConnection, String, Int, Int)?
        private var offsets: [String: Int] = [:]
        private var completed: Set<String> = []
        private let secondRequest: XCTestExpectation?
        private let failFirstRequest: Bool
        private let initialOffset: Int
        private let partialFirstAck: Bool
        private let forcedStatus: Int?
        private let initiallyComplete: Bool
        private let loseFinalResponse: Bool

        init(listening: XCTestExpectation, secondRequest: XCTestExpectation? = nil,
             failFirstRequest: Bool = false, initialOffset: Int = 0, partialFirstAck: Bool = false,
             forcedStatus: Int? = nil, initiallyComplete: Bool = false, loseFinalResponse: Bool = false) throws {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            listener = try NWListener(using: parameters)
            self.listening = listening; self.secondRequest = secondRequest
            self.failFirstRequest = failFirstRequest; self.initialOffset = initialOffset
            self.partialFirstAck = partialFirstAck; self.forcedStatus = forcedStatus
            self.initiallyComplete = initiallyComplete; self.loseFinalResponse = loseFinalResponse
        }

        var port: UInt16? { listener.port?.rawValue }
        var ranges: [String] { lock.withLock { capturedRanges } }
        var queries: [String] { lock.withLock { capturedQueries } }
        var paths: [String] { lock.withLock { capturedPaths } }
        var receivedBytes: Data { lock.withLock { bodies.reduce(into: Data()) { $0.append($1) } } }

        func start() {
            listener.stateUpdateHandler = { [weak self] state in
                if case .ready = state { self?.listening.fulfill() }
                if case .failed(let error) = state { XCTFail("Loopback listener failed: \(error)") }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                self.lock.withLock { self.connections.append(connection) }
                connection.start(queue: self.queue)
                self.receive(on: connection, accumulated: Data())
            }
            listener.start(queue: queue)
        }

        func stop() {
            listener.cancel()
            lock.withLock { connections }.forEach { $0.cancel() }
        }

        private func receive(on connection: NWConnection, accumulated: Data) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
                guard let self else { return }
                var request = accumulated
                if let data { request.append(data) }
                if let separator = request.range(of: Data("\r\n\r\n".utf8)),
                   let headers = String(data: request[..<separator.lowerBound], encoding: .utf8) {
                    let fields = headers.components(separatedBy: "\r\n").dropFirst().reduce(into: [String: String]()) { result, line in
                        let parts = line.split(separator: ":", maxSplits: 1)
                        if parts.count == 2 { result[parts[0].lowercased()] = parts[1].trimmingCharacters(in: .whitespaces) }
                    }
                    if let length = fields["content-length"].flatMap(Int.init), request.count - separator.upperBound >= length {
                        let path = headers.components(separatedBy: "\r\n").first?.split(separator: " ").dropFirst().first.map(String.init) ?? "missing"
                        self.handle(connection, path: path, range: fields["content-range"] ?? "missing",
                                    body: request.subdata(in: separator.upperBound..<(separator.upperBound + length)))
                        return
                    }
                }
                if error == nil && !complete { self.receive(on: connection, accumulated: request) }
            }
        }

        private func handle(_ request: NWConnection, path: String, range: String, body: Data) {
            let offset = lock.withLock { offsets[path] ?? (path == "/new-session" ? 0 : initialOffset) }
            if range.hasPrefix("bytes */") {
                lock.withLock { capturedQueries.append(range) }
                let done = lock.withLock { completed.contains(path) } || initiallyComplete
                respond(to: request, statusCode: done ? 200 : 308, offset: offset)
                return
            }
            let index = lock.withLock {
                capturedRanges.append(range); capturedPaths.append(path); bodies.append(body)
                return capturedRanges.count - 1
            }
            let pieces = range.replacingOccurrences(of: "bytes ", with: "").split(separator: "/")
            let bounds = pieces.first?.split(separator: "-") ?? []
            guard pieces.count == 2, bounds.count == 2, let start = Int(bounds[0]),
                  let end = Int(bounds[1]), let total = Int(pieces[1]), start <= end,
                  start == offset, body.count == end - start + 1, end < total else {
                respond(to: request, statusCode: 416, offset: offset); return
            }
            if let forcedStatus { respond(to: request, statusCode: forcedStatus, offset: offset); return }
            if index == 0 && failFirstRequest { respond(to: request, statusCode: 500, offset: offset); return }
            if index == 1, let secondRequest {
                lock.withLock { held = (request, path, end, total) }
                secondRequest.fulfill(); return
            }
            let accepted = index == 0 && partialFirstAck ? min(body.count, 512) : body.count
            let next = start + accepted
            lock.withLock {
                offsets[path] = next
                if next == total { completed.insert(path) }
            }
            if next == total && loseFinalResponse { request.cancel(); return }
            respond(to: request, statusCode: next == total ? 200 : 308, offset: next)
        }

        func releaseSecondRequest() {
            guard let (request, path, end, total) = lock.withLock({ let current = held; held = nil; return current }) else {
                return XCTFail("Expected a held second chunk")
            }
            lock.withLock { offsets[path] = end + 1; if end + 1 == total { completed.insert(path) } }
            respond(to: request, statusCode: end + 1 == total ? 200 : 308, offset: end + 1)
        }

        private func respond(to connection: NWConnection, statusCode: Int, offset: Int) {
            let acknowledged = statusCode == 308 && offset > 0 ? "Range: bytes=0-\(offset - 1)\r\n" : ""
            let response = Data("HTTP/1.1 \(statusCode) OK\r\n\(acknowledged)Content-Length: 0\r\nConnection: close\r\n\r\n".utf8)
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}

private final class CompletionWriteFailureFile: UploadsFile {
    private let inner: UploadsFile
    private let lock = NSLock()
    private var failRemoval: Bool
    init(inner: UploadsFile, failRemoval: Bool) { self.inner = inner; self.failRemoval = failRemoval }
    func allowRemoval() { lock.withLock { failRemoval = false } }
    func maybeOpenCache() throws { try inner.maybeOpenCache() }
    func readContents() throws -> UploadsFileContents { try inner.readContents() }
    func writeContents(of contents: UploadsFileContents) throws {
        if contents.entriesAbsFileUrlToUploadInfo.isEmpty && lock.withLock({ failRemoval }) {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
        }
        try inner.writeContents(of: contents)
    }
}

private final class PayloadCommitFailureFile: UploadsFile {
    private let inner = FakeUploadsFile.simiulatedStorage()
    private let lock = NSLock()
    private var failCommit = true
    func allowPayloadCommit() { lock.withLock { failCommit = false } }
    func maybeOpenCache() throws { try inner.maybeOpenCache() }
    func readContents() throws -> UploadsFileContents { try inner.readContents() }
    func writeContents(of contents: UploadsFileContents) throws {
        if lock.withLock({ failCommit }), contents.entriesAbsFileUrlToUploadInfo.contains(where: { $0.stateCode != .preparing }) {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
        }
        try inner.writeContents(of: contents)
    }
}
