//
//  UploadInputStandardizerTests.swift
//

import AVFoundation
import VideoToolbox
import XCTest

@testable import MuxUploadSDK

final class UploadInputStandardizerTests: XCTestCase {
    private actor ImmediateWorker: UploadInputStandardizationWorking {
        private(set) var receivedConversion: StandardInputConversion?

        func standardize(
            sourceAsset: AVURLAsset,
            rescalingDetails: UploadInputFormatInspectionResult.RescalingDetails,
            conversion: StandardInputConversion,
            outputURL: URL
        ) async throws -> AVURLAsset {
            receivedConversion = conversion
            return AVURLAsset(url: outputURL)
        }

        func cancel() { }
    }

    private actor ControllableWorker: UploadInputStandardizationWorking {
        private(set) var cancellationCount = 0
        private var isCancelled = false
        private var continuation: CheckedContinuation<AVURLAsset, Error>?
        private var didStart = false
        private var startWaiters: [CheckedContinuation<Void, Never>] = []

        func standardize(
            sourceAsset: AVURLAsset,
            rescalingDetails: UploadInputFormatInspectionResult.RescalingDetails,
            conversion: StandardInputConversion,
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

    func testToneMappingUsesPlannedCodecAndRec709EightBitOutput() throws {
        let conversion = toneMappingConversion(dynamicRange: .hlg)
        XCTAssertEqual(
            UploadInputStandardizationWorker.outputCodec(for: conversion),
            .hevc
        )

        let decoderPixelFormat = UploadInputStandardizationWorker.decoderPixelFormat(
            for: try makeHEVCFormatDescription(bitDepth: 10),
            toneMapsToSDR: true
        )
        XCTAssertEqual(
            decoderPixelFormat,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )

        let readerSettings = UploadInputStandardizationWorker.readerVideoSettings(
            decoderPixelFormat: decoderPixelFormat,
            toneMapsToSDR: true
        )
        assertRec709ColorProperties(
            readerSettings[AVVideoColorPropertiesKey]
        )

        let configuration = UploadInputStandardizationWorker.encoderConfiguration(
            codec: .hevc,
            renderSize: CGSize(width: 1920, height: 1080),
            sourceFrameRate: 30,
            decoderPixelFormat: decoderPixelFormat
        )
        XCTAssertEqual(
            configuration.profileLevel,
            kVTProfileLevel_HEVC_Main_AutoLevel as String
        )
        let writerSettings = UploadInputStandardizationWorker.videoWriterSettings(
            codec: .hevc,
            renderSize: CGSize(width: 1920, height: 1080),
            encoderConfiguration: configuration,
            toneMapsToSDR: true
        )
        assertRec709ColorProperties(
            writerSettings[AVVideoColorPropertiesKey]
        )
    }

    func testNonToneMappedConversionDoesNotOverrideColorProperties() throws {
        let decoderPixelFormat = UploadInputStandardizationWorker.decoderPixelFormat(
            for: try makeHEVCFormatDescription(bitDepth: 10)
        )
        let readerSettings = UploadInputStandardizationWorker.readerVideoSettings(
            decoderPixelFormat: decoderPixelFormat,
            toneMapsToSDR: false
        )
        XCTAssertNil(readerSettings[AVVideoColorPropertiesKey])

        let configuration = UploadInputStandardizationWorker.encoderConfiguration(
            codec: .hevc,
            renderSize: CGSize(width: 1920, height: 1080),
            sourceFrameRate: 30,
            decoderPixelFormat: decoderPixelFormat
        )
        let writerSettings = UploadInputStandardizationWorker.videoWriterSettings(
            codec: .hevc,
            renderSize: CGSize(width: 1920, height: 1080),
            encoderConfiguration: configuration,
            toneMapsToSDR: false
        )
        XCTAssertNil(writerSettings[AVVideoColorPropertiesKey])
    }

    func testStandardizerForwardsPlannedConversionToWorker() async throws {
        let worker = ImmediateWorker()
        let standardizer = UploadInputStandardizer { _ in worker }
        let conversion = toneMappingConversion(dynamicRange: .pq)
        let outputURL = URL(fileURLWithPath: "/tmp/planned-tone-map.mp4")

        _ = try await standardizer.standardize(
            id: UUID().uuidString,
            token: UploadInputStandardizationToken(),
            sourceAsset: AVURLAsset(
                url: URL(fileURLWithPath: "/tmp/planned-tone-map-source.mp4")
            ),
            rescalingDetails: .init(),
            conversion: conversion,
            outputURL: outputURL
        )

        let receivedConversion = await worker.receivedConversion
        XCTAssertEqual(receivedConversion, conversion)
    }

    func testEncoderConfigurationNormalizesOnlyUnsupportedFrameRates() {
        let lowResolution = CGSize(width: 1920, height: 1080)
        let highResolution = CGSize(width: 2560, height: 1440)

        XCTAssertEqual(
            UploadInputStandardizationWorker.encoderConfiguration(
                codec: .h264,
                renderSize: lowResolution,
                sourceFrameRate: 5,
                decoderPixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            ).outputFrameRate,
            5
        )
        XCTAssertEqual(
            UploadInputStandardizationWorker.encoderConfiguration(
                codec: .h264,
                renderSize: lowResolution,
                sourceFrameRate: 4.999,
                decoderPixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            ).outputFrameRate,
            30
        )
        XCTAssertEqual(
            UploadInputStandardizationWorker.encoderConfiguration(
                codec: .h264,
                renderSize: lowResolution,
                sourceFrameRate: 120,
                decoderPixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            ).outputFrameRate,
            120
        )
        XCTAssertEqual(
            UploadInputStandardizationWorker.encoderConfiguration(
                codec: .h264,
                renderSize: lowResolution,
                sourceFrameRate: 121,
                decoderPixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            ).outputFrameRate,
            30
        )
        XCTAssertEqual(
            UploadInputStandardizationWorker.encoderConfiguration(
                codec: .hevc,
                renderSize: highResolution,
                sourceFrameRate: 60,
                decoderPixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            ).outputFrameRate,
            60
        )
        XCTAssertEqual(
            UploadInputStandardizationWorker.encoderConfiguration(
                codec: .hevc,
                renderSize: highResolution,
                sourceFrameRate: 60.001,
                decoderPixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            ).outputFrameRate,
            30
        )
        XCTAssertEqual(
            UploadInputStandardizationWorker.encoderConfiguration(
                codec: .hevc,
                renderSize: highResolution,
                sourceFrameRate: .nan,
                decoderPixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            ).outputFrameRate,
            30
        )
    }

    func testEncoderConfigurationKeepsTargetsBelowPublishedLimits() {
        let cases: [(
            codec: AVVideoCodecType,
            renderSize: CGSize,
            pixelFormat: OSType,
            averageBitRate: Int,
            maximumBitRate: Int,
            keyFrameInterval: TimeInterval,
            profileLevel: String
        )] = [
            (
                .h264,
                CGSize(width: 1280, height: 720),
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                5_000_000,
                8_000_000,
                18,
                AVVideoProfileLevelH264HighAutoLevel
            ),
            (
                .h264,
                CGSize(width: 1920, height: 1080),
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                7_000_000,
                8_000_000,
                18,
                AVVideoProfileLevelH264HighAutoLevel
            ),
            (
                .hevc,
                CGSize(width: 2560, height: 1440),
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                16_000_000,
                20_000_000,
                5.4,
                kVTProfileLevel_HEVC_Main_AutoLevel as String
            ),
            (
                .hevc,
                CGSize(width: 3840, height: 2160),
                kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                18_000_000,
                20_000_000,
                5.4,
                kVTProfileLevel_HEVC_Main10_AutoLevel as String
            )
        ]

        for testCase in cases {
            let configuration = UploadInputStandardizationWorker
                .encoderConfiguration(
                    codec: testCase.codec,
                    renderSize: testCase.renderSize,
                    sourceFrameRate: 30,
                    decoderPixelFormat: testCase.pixelFormat
                )
            XCTAssertEqual(
                configuration.averageBitRate,
                testCase.averageBitRate
            )
            XCTAssertEqual(
                configuration.maximumBitRate,
                testCase.maximumBitRate
            )
            XCTAssertLessThan(
                configuration.averageBitRate,
                configuration.maximumBitRate
            )
            XCTAssertEqual(
                configuration.maximumKeyFrameInterval,
                testCase.keyFrameInterval
            )
            XCTAssertEqual(
                configuration.profileLevel,
                testCase.profileLevel
            )
        }
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
                conversion: basicConversion(),
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
                conversion: basicConversion(),
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
                conversion: basicConversion(),
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
                conversion: basicConversion(),
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
                conversion: basicConversion(),
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
            conversion: basicConversion(),
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

    func testPlanningCapabilitiesRequireARealDecodableVideoSample() async throws {
        let inputURL = try await makeGeneratedH264Asset()
        defer { try? FileManager.default.removeItem(at: inputURL) }
        let provider = AVFoundationStandardInputPlanningCapabilityProvider()
        var inspection = UploadInputFormatInspectionResult()
        inspection.metadata.videoTrackCount = 1

        let decodable = await provider.capabilities(
            for: inspection,
            sourceAsset: AVURLAsset(url: inputURL)
        )
        let missing = await provider.capabilities(
            for: inspection,
            sourceAsset: AVURLAsset(
                url: URL(fileURLWithPath: "/tmp/missing-decode-probe-source.mp4")
            )
        )

        XCTAssertTrue(decodable.sourceIsDecodable)
        XCTAssertFalse(missing.sourceIsDecodable)
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

    private func toneMappingConversion(
        dynamicRange: StandardInputDynamicRange,
        sourceDimensions: StandardInputDisplayDimensions =
            StandardInputDisplayDimensions(width: 1920, height: 1080)
    ) -> StandardInputConversion {
        StandardInputConversion(
            sourceCodec: .hevc,
            outputCodec: .hevc,
            sourceDynamicRange: dynamicRange,
            sourceDisplayDimensions: .known(sourceDimensions),
            toneMapsToSDR: true,
            selection: StandardInputPolicySelection(
                maximumResolution: .preset1920x1080
            ),
            requirementsToRemediate: []
        )
    }

    private func basicConversion(
        sourceCodec: StandardInputVideoCodec = .h264,
        outputCodec: StandardInputVideoCodec = .h264,
        maximumResolution: DirectUploadOptions.InputStandardization.MaximumResolution = .preset1920x1080
    ) -> StandardInputConversion {
        StandardInputConversion(
            sourceCodec: sourceCodec,
            outputCodec: outputCodec,
            sourceDynamicRange: .sdr,
            sourceDisplayDimensions: .known(
                StandardInputDisplayDimensions(width: 64, height: 64)
            ),
            toneMapsToSDR: false,
            selection: StandardInputPolicySelection(
                maximumResolution: maximumResolution
            ),
            requirementsToRemediate: []
        )
    }

    private func assertRec709ColorProperties(
        _ value: Any?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let properties = value as? [String: Any] else {
            XCTFail("Missing color properties", file: file, line: line)
            return
        }
        XCTAssertEqual(
            properties[AVVideoColorPrimariesKey] as? String,
            AVVideoColorPrimaries_ITU_R_709_2,
            file: file,
            line: line
        )
        XCTAssertEqual(
            properties[AVVideoTransferFunctionKey] as? String,
            AVVideoTransferFunction_ITU_R_709_2,
            file: file,
            line: line
        )
        XCTAssertEqual(
            properties[AVVideoYCbCrMatrixKey] as? String,
            AVVideoYCbCrMatrix_ITU_R_709_2,
            file: file,
            line: line
        )
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
