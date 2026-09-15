import AVFoundation
import XCTest
@testable import MuxUploadSDK

final class DirectUploadForceRestartTests: XCTestCase {
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

    func testForceRestartDuringTransportResetsProgressAndPreservesCallbacks() async throws {
        for paused in [false, true] {
            let firstTransport = expectation(description: "First transport")
            let secondTransport = expectation(description: "Replacement transport")
            let progress = expectation(description: "Progress handler survives restart")
            let success = expectation(description: "Result handler survives restart")
            let pauseReached = paused ? expectation(description: "Transport paused") : nil
            let upload = try makeUpload(inspector: RestartInspector())
            var transportCount = 0
            var lastWorker: ChunkedFileUploader?
            upload.inputStatusHandler = { status in
                if case .transportInProgress = status, upload.fileWorker !== lastWorker {
                    lastWorker = upload.fileWorker
                    transportCount += 1
                    (transportCount == 1 ? firstTransport : secondTransport).fulfill()
                }
            }
            upload.start()
            await fulfillment(of: [firstTransport], timeout: 2)
            let oldWorker = try XCTUnwrap(upload.fileWorker as? RestartFileWorker)
            oldWorker.emit(.uploading(.init(
                progress: Progress(totalUnitCount: 100).withCompleted(50),
                startTime: 1, updateTime: 2
            )))
            if let pauseReached {
                oldWorker.onPause = { pauseReached.fulfill() }
                upload.pause()
                await fulfillment(of: [pauseReached], timeout: 2)
            }
            upload.progressHandler = { _ in progress.fulfill() }
            upload.resultHandler = { result in
                guard case .success = result else {
                    return XCTFail("Old transport must not report a terminal result")
                }
                success.fulfill()
            }
            upload.start(forceRestart: true)
            await fulfillment(of: [secondTransport], timeout: 2)
            let replacement = try XCTUnwrap(upload.fileWorker as? RestartFileWorker)
            XCTAssertFalse(oldWorker === replacement)
            XCTAssertTrue(oldWorker.wasCancelled)
            XCTAssertEqual(replacement.startingByte, 0)
            oldWorker.emit(.failure(CancellationError()))
            XCTAssertTrue(upload.fileWorker === replacement)
            replacement.emit(.uploading(.init(
                progress: Progress(totalUnitCount: 100), startTime: 3, updateTime: 4
            )))
            replacement.emit(.success(.init(
                finalProgress: Progress(totalUnitCount: 100), startTime: 3, finishTime: 5
            )))
            await fulfillment(of: [progress, success], timeout: 2)
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
        DirectUpload(
            input: try UploadInput.mockReadyInput(),
            uploadManager: DirectUploadManager(),
            inputInspector: inspector,
            fileWorkerFactory: { info, url, file, byte in
                RestartFileWorker(uploadInfo: info, inputFileURL: url, file: file, startingByte: byte)
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
    private var delegates: [String: ChunkedFileUploaderDelegate] = [:]

    override init(uploadInfo: UploadInfo, inputFileURL: URL, file: ChunkedFile, startingByte: UInt64 = 0) {
        self.startingByte = startingByte
        super.init(uploadInfo: uploadInfo, inputFileURL: inputFileURL, file: file, startingByte: startingByte)
    }

    override func addDelegate(withToken token: String, _ delegate: ChunkedFileUploaderDelegate) {
        delegates[token] = delegate
    }
    override func removeDelegate(withToken token: String) { delegates.removeValue(forKey: token) }
    override func start() { }
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
