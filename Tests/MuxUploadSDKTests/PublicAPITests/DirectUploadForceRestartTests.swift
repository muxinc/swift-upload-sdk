import AVFoundation
import XCTest
@testable import MuxUploadSDK

final class DirectUploadForceRestartTests: XCTestCase {
    func testForceRestartDoesNotCancelAnotherUploadsWorker() async throws {
        for alreadySharing in [false, true] {
            let manager = DirectUploadManager()
            let input = try UploadInput.mockReadyInput()
            let firstStarted = expectation(description: "First upload transport")
            let shared = alreadySharing ? expectation(description: "Normal start reuses the first worker") : nil
            var startCount = 0
            let first = makeUpload(input: input, inspector: RestartInspector(), manager: manager) {
                startCount += 1
                if startCount == 1 { firstStarted.fulfill() }
                else { shared?.fulfill() }
            }
            let second = makeUpload(input: try UploadInput.mockReadyInput(), inspector: RestartInspector(), manager: manager)
            XCTAssertNotEqual(first.id, second.id)
            first.start()
            await fulfillment(of: [firstStarted], timeout: 2)
            let originalWorker = try XCTUnwrap(first.fileWorker as? RestartFileWorker)
            first.inputStatusHandler = nil
            first.resultHandler = { _ in XCTFail("Restarting another upload must not terminate the first") }

            if let shared {
                second.start()
                await fulfillment(of: [shared], timeout: 2)
                XCTAssertTrue(second.fileWorker === originalWorker)
            }

            let replacementStarted = expectation(description: "Forced start creates independent transport")
            second.inputStatusHandler = { status in
                if case .transportInProgress = status { replacementStarted.fulfill() }
            }
            second.start(forceRestart: true)
            await fulfillment(of: [replacementStarted], timeout: 2)
            XCTAssertFalse(originalWorker.wasCancelled)
            XCTAssertTrue(first.fileWorker === originalWorker)
            XCTAssertFalse(second.fileWorker === originalWorker)
            let replacement = try XCTUnwrap(second.fileWorker as? RestartFileWorker)
            XCTAssertEqual(replacement.startingByte, 0)

            // Both independent uploads must still deliver their own completion.
            let firstFinished = expectation(description: "First upload completes")
            let secondFinished = expectation(description: "Second upload completes")
            first.resultHandler = { result in
                if case .success = result { firstFinished.fulfill() }
            }
            second.resultHandler = { result in
                if case .success = result { secondFinished.fulfill() }
            }
            originalWorker.emit(.success(.init(
                finalProgress: Progress(totalUnitCount: 100), startTime: 1, finishTime: 2
            )))
            XCTAssertTrue(second.fileWorker === replacement)
            replacement.emit(.success(.init(
                finalProgress: Progress(totalUnitCount: 100), startTime: 1, finishTime: 2
            )))
            await fulfillment(of: [firstFinished, secondFinished], timeout: 2)
        }
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
        makeUpload(input: try UploadInput.mockReadyInput(), inspector: inspector, manager: DirectUploadManager())
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
