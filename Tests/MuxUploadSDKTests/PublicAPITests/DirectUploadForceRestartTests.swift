import AVFoundation
import XCTest
@testable import MuxUploadSDK

final class DirectUploadForceRestartTests: XCTestCase {
    func testForceRestartOfBorrowedTransportKeepsTheSamePayloadAndWorker() async throws {
        let manager = makeTestUploadManager()
        let firstStarted = expectation(description: "Original transport starts")
        let borrowed = expectation(description: "Second handle borrows transport")
        let resumed = expectation(description: "Forced restart resumes the existing transport")
        var starts = 0
        let first = makeUpload(input: try UploadInput.mockReadyInput(), inspector: RestartInspector(), manager: manager) {
            starts += 1
            if starts == 1 { firstStarted.fulfill() }
            else if starts == 2 { borrowed.fulfill() }
            else if starts == 3 { resumed.fulfill() }
        }
        let second = makeUpload(input: try UploadInput.mockReadyInput(), inspector: RestartInspector(), manager: manager)
        first.start()
        await fulfillment(of: [firstStarted], timeout: 2)
        let original = try XCTUnwrap(first.fileWorker as? RestartFileWorker)
        second.start()
        await fulfillment(of: [borrowed], timeout: 2)
        second.start(forceRestart: true)
        await fulfillment(of: [resumed], timeout: 2)
        XCTAssertTrue(second.fileWorker === original)
        XCTAssertTrue(first.fileWorker === original)
        XCTAssertFalse(original.wasCancelled)
        let completed = expectation(description: "Both handles observe the same completion")
        completed.expectedFulfillmentCount = 2
        first.resultHandler = { if case .success = $0 { completed.fulfill() } }
        second.resultHandler = { if case .success = $0 { completed.fulfill() } }
        original.emit(.success(.init(finalProgress: Progress(totalUnitCount: 100), startTime: 1, finishTime: 2)))
        await fulfillment(of: [completed], timeout: 2)
    }

    func testForceRestartDuringInspectionSuppressesOldCompletion() async throws {
        for paused in [false, true] {
            let firstInspection = expectation(description: "First inspection")
            let secondInspection = expectation(description: "Replacement inspection")
            let inspector = RestartInspector { index in
                (index == 0 ? firstInspection : secondInspection).fulfill()
            }
            let transport = expectation(description: "Only replacement starts transport")
            let upload = try makeUpload(inspector: inspector)
            upload.inputStatusHandler = { status in
                if case .transportInProgress = status { transport.fulfill() }
            }
            upload.resultHandler = { _ in XCTFail("Restart must not report cancellation") }
            upload.progressHandler = { _ in }

            upload.start()
            await fulfillment(of: [firstInspection], timeout: 2)
            if paused { upload.pause() }
            upload.start(forceRestart: true)
            await fulfillment(of: [secondInspection], timeout: 2)

            let operations = await inspector.operations
            XCTAssertEqual(operations.count, 2)
            let oldWasCancelled = await operations[0].isCancelled
            XCTAssertTrue(oldWasCancelled)
            XCTAssertNotNil(upload.resultHandler)
            XCTAssertNotNil(upload.progressHandler)
            // Release both inspections, including a late result from the old attempt.
            await inspector.completeAll()
            await fulfillment(of: [transport], timeout: 2)
            await cancelAndWait(upload)
        }
    }

    func testForceRestartDuringTransportPreservesWorkerAndCallbacks() async throws {
        for paused in [false, true] {
            let started = expectation(description: "Transport starts")
            let resumed = expectation(description: "The same transport resumes")
            let finished = expectation(description: "Result handler survives")
            let upload = try makeUpload(inspector: RestartInspector())
            upload.inputStatusHandler = { if case .transportInProgress = $0 { started.fulfill() } }
            upload.start()
            await fulfillment(of: [started], timeout: 2)
            upload.inputStatusHandler = nil
            let worker = try XCTUnwrap(upload.fileWorker as? RestartFileWorker)
            worker.emit(.uploading(.init(progress: Progress(totalUnitCount: 100).withCompleted(50), startTime: 1, updateTime: 2)))
            if paused {
                let didPause = expectation(description: "Paused")
                worker.onPause = { didPause.fulfill() }
                upload.pause()
                await fulfillment(of: [didPause], timeout: 2)
            }
            worker.onStart = { resumed.fulfill() }
            upload.resultHandler = { if case .success = $0 { finished.fulfill() } }
            upload.start(forceRestart: true)
            await fulfillment(of: [resumed], timeout: 2)
            XCTAssertTrue(upload.fileWorker === worker)
            XCTAssertFalse(worker.wasCancelled)
            worker.emit(.success(.init(finalProgress: Progress(totalUnitCount: 100).withCompleted(100), startTime: 1, finishTime: 3)))
            await fulfillment(of: [finished], timeout: 2)
        }
    }

    func testForceRestartFromReadyStartsUpload() async throws {
        let transport = expectation(description: "Forced initial start")
        let upload = try makeUpload(inspector: RestartInspector())
        upload.inputStatusHandler = { status in
            if case .transportInProgress = status { transport.fulfill() }
        }
        upload.start(forceRestart: true)
        await fulfillment(of: [transport], timeout: 2)
        await cancelAndWait(upload)
    }

    private func makeUpload(inspector: RestartInspector) throws -> DirectUpload {
        makeUpload(input: try UploadInput.mockReadyInput(), inspector: inspector, manager: makeTestUploadManager())
    }

    private func makeUpload(
        input: UploadInput,
        inspector: RestartInspector,
        manager: DirectUploadManager,
        onStart: (() -> Void)? = nil
    ) -> DirectUpload {
        DirectUpload(
            input: input,
            uploadManager: manager,
            inputInspector: inspector,
            fileWorkerFactory: { info, url, file, byte in
                let worker = RestartFileWorker(uploadInfo: info, inputFileURL: url, file: file, startingByte: byte)
                worker.onStart = onStart
                return worker
            }
        )
    }

    private func cancelAndWait(_ upload: DirectUpload) async {
        let ready = expectation(description: "Explicit cancellation completes")
        upload.resultHandler = nil
        upload.inputStatusHandler = { status in
            if case .ready = status { ready.fulfill() }
        }
        upload.cancel()
        await fulfillment(of: [ready], timeout: 2)
        XCTAssertNil(upload.progressHandler)
        XCTAssertNil(upload.resultHandler)
    }
}

private actor RestartInspector: UploadInputInspector {
    private let onStart: (@Sendable (Int) -> Void)?
    private var continuations: [CheckedContinuation<UploadInputInspectionOutcome, Never>] = []
    private(set) var operations: [UploadInputInspectionOperation] = []

    init(onStart: (@Sendable (Int) -> Void)? = nil) { self.onStart = onStart }

    func inspect(
        sourceInput: AVAsset,
        maximumResolution: DirectUploadOptions.InputStandardization.MaximumResolution,
        operation: UploadInputInspectionOperation
    ) async -> UploadInputInspectionOutcome {
        operations.append(operation)
        guard let onStart else { return outcome }
        return await withCheckedContinuation { continuation in
            continuations.append(continuation)
            onStart(operations.count - 1)
        }
    }

    func completeAll() {
        let pending = continuations
        continuations = []
        pending.forEach { $0.resume(returning: outcome) }
    }

    private var outcome: UploadInputInspectionOutcome {
        .init(result: nil, duration: .zero, error: UploadInputInspectionError.inspectionFailure)
    }
}

private final class RestartFileWorker: ChunkedFileUploader {
    let startingByte: UInt64
    private(set) var wasCancelled = false
    var onPause: (() -> Void)?
    var onStart: (() -> Void)?
    private var delegates: [String: ChunkedFileUploaderDelegate] = [:]

    override init(uploadInfo: UploadInfo, inputFileURL: URL, file: ChunkedFile, startingByte: UInt64 = 0) {
        self.startingByte = startingByte
        super.init(uploadInfo: uploadInfo, inputFileURL: inputFileURL, file: file, startingByte: startingByte)
    }

    override func addDelegate(withToken token: String, _ delegate: ChunkedFileUploaderDelegate) {
        delegates[token] = delegate
    }
    override func removeDelegate(withToken token: String) { delegates.removeValue(forKey: token) }
    override func start() { onStart?() }
    override func start(duration: CMTime) { }
    override func pause() {
        emit(.paused(.init(
            progress: Progress(totalUnitCount: 100).withCompleted(50),
            startTime: 1, updateTime: 2
        )))
        onPause?()
    }
    override func cancel() {
        wasCancelled = true
        emit(.failure(CancellationError()))
    }
    func emit(_ state: InternalUploadState) {
        for delegate in Array(delegates.values) {
            delegate.chunkedFileUploader(self, stateUpdated: state)
        }
    }
}

private extension Progress {
    func withCompleted(_ count: Int64) -> Progress {
        completedUnitCount = count
        return self
    }
}
