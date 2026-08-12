//
//  UploadInputStandardizerTests.swift
//

import AVFoundation
import XCTest

@testable import MuxUploadSDK

final class UploadInputStandardizerTests: XCTestCase {
    private final class ControllableWorker: UploadInputStandardizationWorking {
        private(set) var cancellationCount = 0

        func standardize(
            sourceAsset: AVURLAsset,
            rescalingDetails: UploadInputFormatInspectionResult.RescalingDetails,
            outputURL: URL,
            completion: @escaping (AVURLAsset, AVAsset?, Error?) -> ()
        ) {}

        func cancel() {
            cancellationCount += 1
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

    func testTransferFailureStopsAndDrainsEveryTrackExactlyOnce() {
        let group = UploadInputStandardizationWorker.TransferGroup(trackCount: 2)
        let completionExpectation = expectation(
            description: "All failed transfers drain"
        )
        group.notify(queue: .main) {
            completionExpectation.fulfill()
        }

        XCTAssertEqual(Set(group.stop(failed: true)), Set([0, 1]))
        XCTAssertFalse(group.shouldContinue)
        XCTAssertTrue(group.didFail)

        for trackID in [0, 1] {
            XCTAssertTrue(group.claimFinish(trackID: trackID))
            XCTAssertFalse(group.claimFinish(trackID: trackID))
            group.leave()
        }

        wait(for: [completionExpectation], timeout: 1)
    }

    func testTransferCancellationDrainsWithoutReportingFailure() {
        let group = UploadInputStandardizationWorker.TransferGroup(trackCount: 2)

        XCTAssertEqual(Set(group.stop()), Set([0, 1]))
        XCTAssertFalse(group.shouldContinue)
        XCTAssertFalse(group.didFail)

        for trackID in [0, 1] where group.claimFinish(trackID: trackID) {
            group.leave()
        }
    }

    func testCancelReleasesWorkerAndSuppressesCompletion() {
        let worker = ControllableWorker()
        let standardizer = UploadInputStandardizer { worker }
        let id = UUID().uuidString
        let completionExpectation = expectation(
            description: "Cancelled conversion does not complete"
        )
        completionExpectation.isInverted = true

        standardizer.standardize(
            id: id,
            sourceAsset: AVURLAsset(
                url: URL(fileURLWithPath: "/tmp/missing-nat487-input.mp4")
            ),
            rescalingDetails: .init(),
            outputURL: URL(fileURLWithPath: "/tmp/missing-nat487-output.mp4")
        ) { _, _, _ in
            completionExpectation.fulfill()
        }
        standardizer.cancel(id: id)

        wait(for: [completionExpectation], timeout: 0.25)
        XCTAssertEqual(worker.cancellationCount, 1)
        XCTAssertNil(standardizer.workers[id])
    }

    func testCancelledWorkerSuppressesCompletion() {
        let worker = UploadInputStandardizationWorker()
        let completionExpectation = expectation(
            description: "Cancelled worker does not complete"
        )
        completionExpectation.isInverted = true

        worker.cancel()
        worker.standardize(
            sourceAsset: AVURLAsset(
                url: URL(fileURLWithPath: "/tmp/missing-nat487-input.mp4")
            ),
            rescalingDetails: .init(),
            outputURL: URL(fileURLWithPath: "/tmp/missing-nat487-output.mp4")
        ) { _, _, _ in
            completionExpectation.fulfill()
        }

        wait(for: [completionExpectation], timeout: 0.25)
    }

    func testCancelDoesNotDeleteAnOutputFileTheWorkerDoesNotOwn() throws {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nat487-existing-\(UUID().uuidString).mp4")
        let existingData = Data("existing".utf8)
        try existingData.write(to: outputURL)
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let worker = UploadInputStandardizationWorker()
        worker.standardize(
            sourceAsset: AVURLAsset(
                url: URL(fileURLWithPath: "/tmp/missing-nat487-input.mp4")
            ),
            rescalingDetails: .init(),
            outputURL: outputURL
        ) { _, _, _ in }
        worker.cancel()

        XCTAssertEqual(try Data(contentsOf: outputURL), existingData)
    }

    func testCatalogBackedCodecPreservingMP4AACConversion() throws {
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
            try assertConversion(
                inputURL: URL(fileURLWithPath: fixtureDirectory)
                    .appendingPathComponent(fixture.canonicalFilename),
                expectedCodec: testCase.codec,
                expectedBitDepth: testCase.bitDepth,
                expectedDimensions: testCase.dimensions,
                expectedAudioChannels: testCase.audioChannels
            )
        }
    }

    func testCatalogBackedCancellationDrainsActiveTransfers() throws {
        let inputURL = try catalogFixtureURL(
            id: "synthetic-standard-hevc-main10-sdr-2160p30-5-1"
        )
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nat487-cancel-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let transferStarted = expectation(description: "Transfer starts")
        let completionExpectation = expectation(
            description: "Cancelled transfer does not complete"
        )
        completionExpectation.isInverted = true

        weak var cancellableWorker: UploadInputStandardizationWorker?
        let worker = UploadInputStandardizationWorker {
            transferStarted.fulfill()
            cancellableWorker?.cancel()
        }
        cancellableWorker = worker
        worker.standardize(
            sourceAsset: AVURLAsset(url: inputURL),
            rescalingDetails: .init(),
            outputURL: outputURL
        ) { _, _, _ in
            completionExpectation.fulfill()
        }

        wait(for: [transferStarted], timeout: 2)
        wait(for: [completionExpectation], timeout: 0.5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
    }

    private func assertConversion(
        inputURL: URL,
        expectedCodec: AVVideoCodecType,
        expectedBitDepth: Int,
        expectedDimensions: CGSize,
        expectedAudioChannels: UInt32
    ) throws {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nat487-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let completionExpectation = expectation(
            description: "Conversion completes for \(inputURL.lastPathComponent)"
        )
        var conversionError: Error?
        let worker = UploadInputStandardizationWorker()
        worker.standardize(
            sourceAsset: AVURLAsset(url: inputURL),
            rescalingDetails: .init(
                maximumDesiredResolutionPreset: .default,
                recordedResolution: .init(width: 0, height: 0)
            ),
            outputURL: outputURL
        ) { _, standardizedAsset, error in
            conversionError = error
            XCTAssertNotNil(standardizedAsset)
            completionExpectation.fulfill()
        }
        wait(for: [completionExpectation], timeout: 60)
        XCTAssertNil(conversionError)

        let outputAsset = AVURLAsset(url: outputURL)
        let inspectionExpectation = expectation(
            description: "Converted tracks can be read"
        )
        outputAsset.loadTracks(withMediaType: .video) { videoTracks, videoError in
            XCTAssertNil(videoError)
            guard let videoTrack = videoTracks?.first else {
                XCTFail("Missing converted video track")
                inspectionExpectation.fulfill()
                return
            }
            videoTrack.loadValuesAsynchronously(
                forKeys: ["formatDescriptions", "naturalSize"]
            ) {
                let formatDescription = (videoTrack.formatDescriptions
                    as? [CMFormatDescription])?.first
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
                XCTAssertEqual(videoTrack.naturalSize, expectedDimensions)
                outputAsset.loadTracks(withMediaType: .audio) { audioTracks, audioError in
                    XCTAssertNil(audioError)
                    guard let audioTrack = audioTracks?.first else {
                        XCTFail("Missing converted audio track")
                        inspectionExpectation.fulfill()
                        return
                    }
                    audioTrack.loadValuesAsynchronously(
                        forKeys: ["formatDescriptions"]
                    ) {
                        let audioFormat = (audioTrack.formatDescriptions
                            as? [CMAudioFormatDescription])?.first
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
                        inspectionExpectation.fulfill()
                    }
                }
            }
        }
        wait(for: [inspectionExpectation], timeout: 10)
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
