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
        let server = try UploadServer(listening: listening, failFirstRequest: true)
        server.start()
        defer { server.stop() }
        await fulfillment(of: [listening], timeout: 5)
        let port = try XCTUnwrap(server.port)
        let entry = makeEntry(fileURL: fileURL, port: port, checkpoint: 1024, sourceURL: sourceURL)
        let persistenceURL = directory.appendingPathComponent("uploads.json")
        let persistence = UploadPersistence(innerFile: DiskUploadsFile(url: persistenceURL), atURL: persistenceURL)
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
        let nextPersistence = UploadPersistence(innerFile: DiskUploadsFile(url: persistenceURL), atURL: persistenceURL)
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

    func testLegacyStandardizedPayloadMovesToCurrentContainerAndExpires() throws {
        let name = "mux-upload-\(UUID().uuidString).mp4"
        let legacy = FileManager.default.temporaryDirectory
            .appendingPathComponent(FileSystemTemporaryStoragePreflighter.directoryName)
            .appendingPathComponent(name)
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: legacy)
        let durable = FileSystemTemporaryStoragePreflighter.durableBaseDirectory
            .appendingPathComponent(FileSystemTemporaryStoragePreflighter.directoryName).appendingPathComponent(name)
        defer {
            try? FileManager.default.removeItem(at: legacy)
            try? FileManager.default.removeItem(at: durable)
        }
        // An older install's absolute container path, with bytes still present in today's tmp.
        let oldURL = URL(fileURLWithPath: "/previous-container/tmp/MuxUploadSDK/Standardized/" + name)
        let entry = makeEntry(fileURL: oldURL, port: 1, checkpoint: 2)
        let disk = FakeUploadsFile.simiulatedStorage()
        try disk.writeContents(of: UploadsFileContents(entries: [entry]))
        let persistence = UploadPersistence(innerFile: disk, atURL: legacy)
        let restored = try XCTUnwrap(persistence.readEntry(uploadID: entry.uploadInfo.id))
        XCTAssertEqual(restored.inputFileURL, durable)
        XCTAssertEqual(restored.lastSuccessfulByte, 2)
        XCTAssertEqual(try Data(contentsOf: durable), Data([1, 2, 3]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertEqual(try durable.deletingLastPathComponent().resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)

        // A subsequent container-path change also resolves the same durable bytes.
        let moved = entry.with(inputFileURL: URL(fileURLWithPath:
            "/previous-container/Library/Application Support/MuxUploadSDK/Standardized/" + name),
                               uploadURL: entry.uploadInfo.uploadURL)
        try disk.writeContents(of: UploadsFileContents(entries: [moved]))
        let reloaded = UploadPersistence(innerFile: disk, atURL: legacy)
        XCTAssertEqual(try reloaded.readEntry(uploadID: entry.uploadInfo.id)?.inputFileURL, durable)
        try reloaded.write(entry: restored.with(savedAt: Date().timeIntervalSince1970 - 4 * 24 * 60 * 60,
                                               inputFileURL: durable, uploadURL: entry.uploadInfo.uploadURL),
                           for: entry.uploadInfo.id)
        XCTAssertTrue(try UploadPersistence(innerFile: disk, atURL: legacy).readAll().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: durable.path))
    }

    @MainActor
    func testMissingLegacyPayloadReportsFileErrorAndDiscardsCheckpoint() async throws {
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
            XCTAssertTrue(error.message.contains("Start a new upload"))
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
        let server = try UploadServer(listening: listening, secondRequest: transferring)
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

    private func makeEntry(fileURL: URL, port: UInt16, checkpoint: UInt64, sourceURL: URL? = nil) -> PersistenceEntry {
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
                    retryLimitPerChunk: 1
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
        let server = try UploadServer(listening: listening, secondRequest: secondRequest)
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

    private final class UploadServer {
        private let lock = NSLock()
        private let queue = DispatchQueue(label: "restored-upload-loopback-server")
        private let listener: NWListener
        private let listening: XCTestExpectation
        private var capturedRanges: [String] = []
        private var capturedPaths: [String] = []
        private var bodies: [Data] = []
        private var connections: [NWConnection] = []
        private var heldRequest: NWConnection?
        private let secondRequest: XCTestExpectation?
        private let failFirstRequest: Bool

        init(listening: XCTestExpectation, secondRequest: XCTestExpectation? = nil, failFirstRequest: Bool = false) throws {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            listener = try NWListener(using: parameters)
            self.listening = listening
            self.secondRequest = secondRequest
            self.failFirstRequest = failFirstRequest
        }

        var port: UInt16? { listener.port?.rawValue }

        var ranges: [String] { lock.withLock { capturedRanges } }
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
            let active = lock.withLock { connections }
            active.forEach { $0.cancel() }
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
                        if parts.count == 2 {
                            result[parts[0].lowercased()] = parts[1].trimmingCharacters(in: .whitespaces)
                        }
                    }
                    if let length = fields["content-length"].flatMap(Int.init),
                       request.count - separator.upperBound >= length {
                        let path = headers.components(separatedBy: "\r\n").first?.split(separator: " ").dropFirst().first.map(String.init) ?? "missing"
                        self.handle(connection, path: path, range: fields["content-range"] ?? "missing",
                                    body: request.subdata(in: separator.upperBound..<(separator.upperBound + length)))
                        return
                    }
                }
                if error == nil && !complete { self.receive(on: connection, accumulated: request) }
                else { XCTFail("Incomplete loopback upload request") }
            }
        }

        private func handle(_ request: NWConnection, path: String, range: String, body: Data) {
            let index = lock.withLock {
                capturedRanges.append(range)
                capturedPaths.append(path)
                bodies.append(body)
                let index = capturedRanges.count - 1
                if index == 1, secondRequest != nil { heldRequest = request }
                return index
            }
            if index == 0, failFirstRequest {
                respond(to: request, statusCode: 500)
            } else if index == 1, let secondRequest {
                secondRequest.fulfill()
            } else {
                let bounds = range.split(separator: "/")
                let end = bounds.first?.split(separator: "-").last.flatMap { Int($0) }
                let total = bounds.last.flatMap { Int($0) }
                respond(to: request, statusCode: end == total.map({ $0 - 1 }) ? 200 : 308)
            }
        }

        func releaseSecondRequest() {
            let request = takeHeldRequest()
            XCTAssertNotNil(request)
            if let request { respond(to: request, statusCode: 308) }
        }

        private func takeHeldRequest() -> NWConnection? {
            lock.withLock {
                let request = heldRequest
                heldRequest = nil
                return request
            }
        }
        private func respond(to connection: NWConnection, statusCode: Int) {
            let response = Data("HTTP/1.1 \(statusCode) OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
            connection.send(content: response, completion: .contentProcessed { error in
                XCTAssertNil(error)
                connection.cancel()
            })
        }
    }
}

private struct DiskUploadsFile: UploadsFile {
    let url: URL
    func maybeOpenCache() throws {}
    func readContents() throws -> UploadsFileContents {
        guard FileManager.default.fileExists(atPath: url.path) else { return UploadsFileContents(entries: []) }
        return try JSONDecoder().decode(UploadsFileContents.self, from: Data(contentsOf: url))
    }
    func writeContents(of contents: UploadsFileContents) throws {
        try JSONEncoder().encode(contents).write(to: url, options: .atomic)
    }
}
