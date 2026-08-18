//
//  UploadInputStandardizerTests.swift
//

import AVFoundation
import XCTest

@testable import MuxUploadSDK

final class UploadInputStandardizerTests: XCTestCase {
    private actor ControllableWorker: UploadInputStandardizationWorking {
        private(set) var cancellationCount = 0
        private var isCancelled = false
        private var continuation: CheckedContinuation<AVURLAsset, Error>?
        private var didStart = false
        private var startWaiters: [CheckedContinuation<Void, Never>] = []

        func standardize(
            sourceAsset: AVURLAsset,
            rescalingDetails: UploadInputFormatInspectionResult.RescalingDetails,
            outputURL: URL
        ) async throws -> AVURLAsset {
            if isCancelled {
                throw CancellationError()
            }
            didStart = true
            startWaiters.forEach { $0.resume() }
            startWaiters = []
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
            }
        }

        func waitUntilStarted() async {
            guard !didStart else { return }
            await withCheckedContinuation { continuation in
                startWaiters.append(continuation)
            }
        }

        func cancel() {
            cancellationCount += 1
            isCancelled = true
            continuation?.resume(throwing: CancellationError())
            continuation = nil
        }
    }

    private struct FixtureCatalog: Decodable {
        struct Fixture: Decodable {
            let id: String
            let canonicalFilename: String
        }

        let fixtures: [Fixture]
    }

    func testOutputCodecPreservesH264AndHEVC() {
        XCTAssertEqual(
            UploadInputStandardizationWorker.outputCodec(for: .h264),
            .h264
        )
        XCTAssertEqual(
            UploadInputStandardizationWorker.outputCodec(for: .hevc),
            .hevc
        )
        XCTAssertEqual(
            UploadInputStandardizationWorker.outputCodec(
                for: .init(rawValue: 0x61766333)
            ),
            .h264
        )
        XCTAssertEqual(
            UploadInputStandardizationWorker.outputCodec(
                for: .init(rawValue: 0x68657631)
            ),
            .hevc
        )
    }

    func testOutputCodecUsesH264ForOtherDecodableFormats() {
        XCTAssertEqual(
            UploadInputStandardizationWorker.outputCodec(for: .proRes422),
            .h264
        )
    }

    func testDecoderPixelFormatPreservesSupportedHEVCBitDepth() throws {
        XCTAssertEqual(
            UploadInputStandardizationWorker.decoderPixelFormat(
                for: try makeHEVCFormatDescription(bitDepth: 8)
            ),
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )
        XCTAssertEqual(
            UploadInputStandardizationWorker.decoderPixelFormat(
                for: try makeHEVCFormatDescription(bitDepth: 10)
            ),
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        )
    }

    func testRenderSizeDoesNotUpscale() throws {
        XCTAssertEqual(
            try UploadInputStandardizationWorker.renderSize(
                naturalSize: CGSize(width: 1280, height: 720),
                preferredTransform: .identity,
                boundingSize: CGSize(width: 1920, height: 1080)
            ),
            CGSize(width: 1280, height: 720)
        )
    }

    func testRenderSizeScalesAndAppliesOrientation() throws {
        let portraitTransform = CGAffineTransform(
            a: 0,
            b: 1,
            c: -1,
            d: 0,
            tx: 2160,
            ty: 0
        )
        XCTAssertEqual(
            try UploadInputStandardizationWorker.renderSize(
                naturalSize: CGSize(width: 3840, height: 2160),
                preferredTransform: portraitTransform,
                boundingSize: CGSize(width: 1920, height: 1080)
            ),
            CGSize(width: 1080, height: 1920)
        )
    }

    func testRenderSizeFitsBothOutputAxes() throws {
        XCTAssertEqual(
            try UploadInputStandardizationWorker.renderSize(
                naturalSize: CGSize(width: 4000, height: 3000),
                preferredTransform: .identity,
                boundingSize: CGSize(width: 1920, height: 1080)
            ),
            CGSize(width: 1440, height: 1080)
        )
    }

    func testRenderSizeRoundsToNearestEvenDimensions() throws {
        XCTAssertEqual(
            try UploadInputStandardizationWorker.renderSize(
                naturalSize: CGSize(width: 1920, height: 818),
                preferredTransform: .identity,
                boundingSize: CGSize(width: 1280, height: 720)
            ),
            CGSize(width: 1280, height: 546)
        )
    }

    func testUnreadableAudioFormatFailsInsteadOfGuessing() {
        XCTAssertThrowsError(
            try UploadInputStandardizationWorker.audioProperties(
                formatDescriptions: []
            )
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                StandardizationError.missingAudioFormat.localizedDescription
            )
        }
    }

    func testCancelReleasesWorkerAndSuppressesCompletion() async {
        let worker = ControllableWorker()
        let standardizer = UploadInputStandardizer { _ in worker }
        let id = UUID().uuidString
        let token = UploadInputStandardizationToken()
        let task = Task {
            try await standardizer.standardize(
                id: id,
                token: token,
                sourceAsset: AVURLAsset(
                    url: URL(fileURLWithPath: "/tmp/missing-standardization-input.mp4")
                ),
                rescalingDetails: .init(),
                outputURL: URL(fileURLWithPath: "/tmp/missing-standardization-output.mp4")
            )
        }
        await worker.waitUntilStarted()
        await standardizer.cancel(id: id, token: token)

        do {
            _ = try await task.value
            XCTFail("Cancelled standardization should throw")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let cancellationCount = await worker.cancellationCount
        let hasActiveWorker = await standardizer.hasWorker(id: id)
        XCTAssertEqual(cancellationCount, 1)
        XCTAssertFalse(hasActiveWorker)
    }

    func testStaleCancelDoesNotCancelReplacementWorker() async {
        let firstToken = UploadInputStandardizationToken()
        let replacementToken = UploadInputStandardizationToken()
        let firstWorker = ControllableWorker()
        let replacementWorker = ControllableWorker()
        let standardizer = UploadInputStandardizer { token in
            token == firstToken ? firstWorker : replacementWorker
        }
        let id = UUID().uuidString
        let sourceAsset = AVURLAsset(
            url: URL(fileURLWithPath: "/tmp/missing-standardization-input.mp4")
        )

        let firstTask = Task {
            try await standardizer.standardize(
                id: id,
                token: firstToken,
                sourceAsset: sourceAsset,
                rescalingDetails: .init(),
                outputURL: URL(fileURLWithPath: "/tmp/missing-first-output.mp4")
            )
        }
        await firstWorker.waitUntilStarted()

        let replacementTask = Task {
            try await standardizer.standardize(
                id: id,
                token: replacementToken,
                sourceAsset: sourceAsset,
                rescalingDetails: .init(),
                outputURL: URL(fileURLWithPath: "/tmp/missing-replacement-output.mp4")
            )
        }
        await replacementWorker.waitUntilStarted()

        await standardizer.cancel(id: id, token: firstToken)

        let replacementCancellationCount = await replacementWorker.cancellationCount
        let hasReplacementWorker = await standardizer.hasWorker(id: id)
        XCTAssertEqual(replacementCancellationCount, 0)
        XCTAssertTrue(hasReplacementWorker)

        await standardizer.cancel(id: id, token: replacementToken)
        _ = await firstTask.result
        _ = await replacementTask.result
    }

    func testCancelledWorkerSuppressesCompletion() async {
        let worker = UploadInputStandardizationWorker()
        await worker.cancel()
        do {
            _ = try await worker.standardize(
                sourceAsset: AVURLAsset(
                    url: URL(fileURLWithPath: "/tmp/missing-standardization-input.mp4")
                ),
                rescalingDetails: .init(),
                outputURL: URL(fileURLWithPath: "/tmp/missing-standardization-output.mp4")
            )
            XCTFail("Cancelled worker should throw")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCancelDoesNotDeleteAnOutputFileTheWorkerDoesNotOwn() async throws {
        let inputURL = try await makeGeneratedH264Asset()
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("standardization-existing-\(UUID().uuidString).mp4")
        let existingData = Data("existing".utf8)
        try existingData.write(to: outputURL)
        defer {
            try? FileManager.default.removeItem(at: inputURL)
            try? FileManager.default.removeItem(at: outputURL)
        }

        let worker = UploadInputStandardizationWorker()
        do {
            _ = try await worker.standardize(
                sourceAsset: AVURLAsset(url: inputURL),
                rescalingDetails: .init(),
                outputURL: outputURL
            )
            XCTFail("Standardization should reject an existing output file")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                StandardizationError.outputFileAlreadyExists.localizedDescription
            )
        }

        XCTAssertEqual(try Data(contentsOf: outputURL), existingData)
    }

    func testGeneratedH264ConversionRunsWithoutExternalFixtures() async throws {
        let inputURL = try await makeGeneratedH264Asset()
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("standardized-generated-\(UUID().uuidString).mp4")
        defer {
            try? FileManager.default.removeItem(at: inputURL)
            try? FileManager.default.removeItem(at: outputURL)
        }

        let worker = UploadInputStandardizationWorker()
        let standardizedAsset = try await worker.standardize(
            sourceAsset: AVURLAsset(url: inputURL),
            rescalingDetails: .init(),
            outputURL: outputURL
        )

        XCTAssertEqual(standardizedAsset.url, outputURL)
        let videoTracks = try await standardizedAsset.loadTracks(withMediaType: .video)
        let videoTrack = try XCTUnwrap(videoTracks.first)
        let (formatDescriptions, naturalSize) = try await videoTrack.load(
            .formatDescriptions,
            .naturalSize
        )
        XCTAssertEqual(formatDescriptions.first?.mediaSubType, .h264)
        XCTAssertEqual(naturalSize, CGSize(width: 64, height: 64))
        let audioTracks = try await standardizedAsset.loadTracks(withMediaType: .audio)
        XCTAssertTrue(audioTracks.isEmpty)
    }

    func testCatalogBackedCodecPreservingMP4AACConversion() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let fixtureDirectory = environment["MUX_UPLOAD_MEDIA_FIXTURE_DIRECTORY"],
              let catalogPath = environment["MUX_UPLOAD_MEDIA_FIXTURE_CATALOG"] else {
            throw XCTSkip("External media fixture environment is not configured")
        }

        let catalog = try JSONDecoder().decode(
            FixtureCatalog.self,
            from: Data(contentsOf: URL(fileURLWithPath: catalogPath))
        )
        let cases: [(
            id: String,
            codec: AVVideoCodecType,
            bitDepth: Int,
            dimensions: CGSize,
            audioChannels: UInt32
        )] = [
            (
                "synthetic-standard-h264-sdr-2160p30-stereo",
                .h264,
                8,
                CGSize(width: 1920, height: 1080),
                2
            ),
            (
                "synthetic-standard-hevc-main-sdr-1440p30-stereo",
                .hevc,
                8,
                CGSize(width: 1920, height: 1080),
                2
            ),
            (
                "synthetic-standard-hevc-main10-sdr-2160p30-5-1",
                .hevc,
                10,
                CGSize(width: 1920, height: 1080),
                6
            ),
            (
                "synthetic-unsupported-prores-sdr-720p30-stereo",
                .h264,
                8,
                CGSize(width: 1280, height: 720),
                2
            )
        ]

        for testCase in cases {
            let fixture = try XCTUnwrap(
                catalog.fixtures.first { $0.id == testCase.id }
            )
            try await assertConversion(
                inputURL: URL(fileURLWithPath: fixtureDirectory)
                    .appendingPathComponent(fixture.canonicalFilename),
                expectedCodec: testCase.codec,
                expectedBitDepth: testCase.bitDepth,
                expectedDimensions: testCase.dimensions,
                expectedAudioChannels: testCase.audioChannels
            )
        }
    }

    func testCatalogBackedCancellationDrainsActiveTransfers() async throws {
        let inputURL = try catalogFixtureURL(
            id: "synthetic-standard-hevc-main10-sdr-2160p30-5-1"
        )
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("standardization-cancel-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let transferStarted = expectation(description: "Transfer starts")
        let worker = UploadInputStandardizationWorker { worker in
            transferStarted.fulfill()
            await worker.cancel()
        }
        do {
            _ = try await worker.standardize(
                sourceAsset: AVURLAsset(url: inputURL),
                rescalingDetails: .init(),
                outputURL: outputURL
            )
            XCTFail("Cancelled transfer should throw")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        await fulfillment(of: [transferStarted], timeout: 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
    }

    private func assertConversion(
        inputURL: URL,
        expectedCodec: AVVideoCodecType,
        expectedBitDepth: Int,
        expectedDimensions: CGSize,
        expectedAudioChannels: UInt32
    ) async throws {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("standardized-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let worker = UploadInputStandardizationWorker()
        let standardizedAsset = try await worker.standardize(
            sourceAsset: AVURLAsset(url: inputURL),
            rescalingDetails: .init(
                maximumDesiredResolutionPreset: .default,
                recordedResolution: .init(width: 0, height: 0)
            ),
            outputURL: outputURL
        )
        XCTAssertEqual(standardizedAsset.url, outputURL)

        let outputAsset = AVURLAsset(url: outputURL)
        let videoTracks = try await outputAsset.loadTracks(withMediaType: .video)
        let videoTrack = try XCTUnwrap(videoTracks.first)
        let (videoFormats, naturalSize) = try await videoTrack.load(
            .formatDescriptions,
            .naturalSize
        )
        let formatDescription = videoFormats.first
        XCTAssertEqual(
            formatDescription?.mediaSubType,
            expectedCodec == .hevc ? .hevc : .h264
        )
        if let formatDescription,
           let extensions = CMFormatDescriptionGetExtensions(formatDescription)
            as NSDictionary? {
            XCTAssertEqual(
                AVFoundationUploadInputMetadataReader.codecConfiguration(
                    codec: expectedCodec == .hevc ? .hevc : .h264,
                    extensions: extensions
                )?.bitDepth,
                expectedBitDepth
            )
        } else {
            XCTFail("Missing converted video format description")
        }
        XCTAssertEqual(naturalSize, expectedDimensions)

        let audioTracks = try await outputAsset.loadTracks(withMediaType: .audio)
        let audioTrack = try XCTUnwrap(audioTracks.first)
        let audioFormat = try await audioTrack.load(.formatDescriptions).first
        XCTAssertEqual(
            audioFormat?.mediaSubType,
            CMFormatDescription.MediaSubType(
                rawValue: kAudioFormatMPEG4AAC
            )
        )
        XCTAssertEqual(
            audioFormat.flatMap {
                CMAudioFormatDescriptionGetStreamBasicDescription($0)?
                    .pointee.mChannelsPerFrame
            },
            expectedAudioChannels
        )
    }

    private func catalogFixtureURL(id: String) throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        guard let fixtureDirectory = environment["MUX_UPLOAD_MEDIA_FIXTURE_DIRECTORY"],
              let catalogPath = environment["MUX_UPLOAD_MEDIA_FIXTURE_CATALOG"] else {
            throw XCTSkip("External media fixture environment is not configured")
        }
        let catalog = try JSONDecoder().decode(
            FixtureCatalog.self,
            from: Data(contentsOf: URL(fileURLWithPath: catalogPath))
        )
        let fixture = try XCTUnwrap(catalog.fixtures.first { $0.id == id })
        return URL(fileURLWithPath: fixtureDirectory)
            .appendingPathComponent(fixture.canonicalFilename)
    }

    private func makeGeneratedH264Asset() async throws -> URL {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("generated-h264-\(UUID().uuidString).mp4")
        var didFinish = false
        defer {
            if !didFinish {
                try? FileManager.default.removeItem(at: outputURL)
            }
        }

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 64,
                AVVideoHeightKey: 64
            ]
        )
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else {
            throw StandardizationError.cannotAddWriterInput
        }
        writer.add(input)

        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64,
            kCVPixelBufferHeightKey as String: 64,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: pixelBufferAttributes
        )

        guard writer.startWriting() else {
            throw writer.error ?? StandardizationError.writerStartFailure
        }
        writer.startSession(atSourceTime: .zero)

        for frameIndex in 0..<3 {
            for _ in 0..<1_000 {
                if input.isReadyForMoreMediaData { break }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            guard input.isReadyForMoreMediaData else {
                throw StandardizationError.conversionFailure
            }

            var pixelBuffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(
                kCFAllocatorDefault,
                64,
                64,
                kCVPixelFormatType_32BGRA,
                pixelBufferAttributes as CFDictionary,
                &pixelBuffer
            )
            guard status == kCVReturnSuccess, let pixelBuffer else {
                throw StandardizationError.conversionFailure
            }
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            if let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) {
                baseAddress.assumingMemoryBound(to: UInt8.self).initialize(
                    repeating: UInt8(48 + frameIndex * 24),
                    count: CVPixelBufferGetBytesPerRow(pixelBuffer)
                        * CVPixelBufferGetHeight(pixelBuffer)
                )
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

            guard adaptor.append(
                pixelBuffer,
                withPresentationTime: CMTime(value: CMTimeValue(frameIndex), timescale: 30)
            ) else {
                throw writer.error ?? StandardizationError.conversionFailure
            }
        }

        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? StandardizationError.conversionFailure
        }
        didFinish = true
        return outputURL
    }

    private func makeHEVCFormatDescription(
        bitDepth: Int
    ) throws -> CMVideoFormatDescription {
        var configuration = Data(repeating: 0, count: 19)
        configuration[0] = 1
        configuration[16] = 1
        configuration[17] = UInt8(bitDepth - 8)
        configuration[18] = UInt8(bitDepth - 8)

        var formatDescription: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_HEVC,
            width: 1920,
            height: 1080,
            extensions: [
                kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms:
                    ["hvcC": configuration]
            ] as CFDictionary,
            formatDescriptionOut: &formatDescription
        )
        XCTAssertEqual(status, noErr)
        return try XCTUnwrap(formatDescription)
    }
}
