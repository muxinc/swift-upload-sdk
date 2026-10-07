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
        private var bodies: [Data] = []
        private var connections: [NWConnection] = []
        private var heldRequest: NWConnection?
        private let secondRequest: XCTestExpectation

        init(listening: XCTestExpectation, secondRequest: XCTestExpectation) throws {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            listener = try NWListener(using: parameters)
            self.listening = listening
            self.secondRequest = secondRequest
        }

        var port: UInt16? { listener.port?.rawValue }

        var ranges: [String] { lock.withLock { capturedRanges } }
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
                        self.handle(connection, range: fields["content-range"] ?? "missing",
                                    body: request.subdata(in: separator.upperBound..<(separator.upperBound + length)))
                        return
                    }
                }
                if error == nil && !complete { self.receive(on: connection, accumulated: request) }
                else { XCTFail("Incomplete loopback upload request") }
            }
        }

        private func handle(_ request: NWConnection, range: String, body: Data) {
            let index = lock.withLock {
                capturedRanges.append(range)
                bodies.append(body)
                let index = capturedRanges.count - 1
                if index == 1 { heldRequest = request }
                return index
            }
            if index == 1 { secondRequest.fulfill() }
            else { respond(to: request, statusCode: index == 0 ? 308 : 200) }
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
