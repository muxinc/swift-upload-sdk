//
//  UploadInputStandardizationWorker.swift
//

import AVFoundation
import AudioToolbox
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

protocol UploadInputStandardizationWorking: AnyObject, Sendable {
    func standardize(
        sourceAsset: AVURLAsset,
        rescalingDetails: UploadInputFormatInspectionResult.RescalingDetails,
        outputURL: URL
    ) async throws -> AVURLAsset

    func cancel() async
}

struct StandardizationError: LocalizedError {
    var localizedDescription: String

    var errorDescription: String? {
        localizedDescription
    }

    static let missingVideoTrack = StandardizationError(
        localizedDescription: "The input does not contain a video track"
    )

    static let multipleVideoTracks = StandardizationError(
        localizedDescription: "Inputs with multiple video tracks cannot be standardized"
    )

    static let missingVideoFormat = StandardizationError(
        localizedDescription: "The input video format could not be read"
    )

    static let missingAudioFormat = StandardizationError(
        localizedDescription: "The input audio format could not be read"
    )

    static let invalidVideoDimensions = StandardizationError(
        localizedDescription: "The input video dimensions are invalid"
    )

    static let cannotAddReaderOutput = StandardizationError(
        localizedDescription: "The asset reader rejected an output"
    )

    static let cannotAddWriterInput = StandardizationError(
        localizedDescription: "The asset writer rejected an input"
    )

    static let writerRejectedSettings = StandardizationError(
        localizedDescription: "The asset writer rejected the output settings"
    )

    static let readerStartFailure = StandardizationError(
        localizedDescription: "The asset reader failed to start"
    )

    static let writerStartFailure = StandardizationError(
        localizedDescription: "The asset writer failed to start"
    )

    static let conversionFailure = StandardizationError(
        localizedDescription: "Failed to convert the input"
    )

    static let outputFileAlreadyExists = StandardizationError(
        localizedDescription: "The standardization output file already exists"
    )
}

actor UploadInputStandardizationWorker {
    private enum State {
        case active
        case cancelled
        case completed
    }

    private struct LoadedAssetProperties {
        let duration: CMTime
        let naturalSize: CGSize
        let preferredTransform: CGAffineTransform
        let nominalFrameRate: Float
        let formatDescriptions: [CMFormatDescription]
    }

    struct AudioProperties {
        let sampleRate: Double
        let channelCount: Int
        let channelLayout: Data?
        let sourceFormatDescription: CMAudioFormatDescription?

        var isAAC: Bool {
            sourceFormatDescription?.mediaSubType.rawValue == kAudioFormatMPEG4AAC
        }
    }

    struct EncoderConfiguration: Equatable {
        let outputFrameRate: Double
        let averageBitRate: Int
        let maximumBitRate: Int
        let maximumKeyFrameInterval: TimeInterval
        let profileLevel: String
    }

    private enum TransferError: Error {
        case appendFailed
        case startedMoreThanOnce
    }

    /// `requestMediaDataWhenReady` is the pull-style writer API available on
    /// the iOS 15 deployment floor. This adapter is the only unchecked
    /// sendability boundary: it owns its AVFoundation objects, and every
    /// access to them and to its mutable terminal state occurs on `queue`.
    private final class LegacySampleTransfer: @unchecked Sendable {
        let output: AVAssetReaderOutput
        let input: AVAssetWriterInput
        private let queue: DispatchQueue
        private var continuation: CheckedContinuation<Void, Error>?
        private var terminalResult: Result<Void, Error>?
        private var didStart = false

        init(
            output: AVAssetReaderOutput,
            input: AVAssetWriterInput,
            queue: DispatchQueue
        ) {
            self.output = output
            self.input = input
            self.queue = queue
        }

        func transfer() async throws {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    queue.async { [self] in
                        start(continuation: continuation)
                    }
                }
            } onCancel: {
                self.cancel()
            }
        }

        func cancel() {
            queue.async { [self] in
                finish(with: .failure(CancellationError()))
            }
        }

        private func start(continuation: CheckedContinuation<Void, Error>) {
            guard !didStart else {
                continuation.resume(throwing: TransferError.startedMoreThanOnce)
                return
            }
            didStart = true

            if let terminalResult {
                continuation.resume(with: terminalResult)
                return
            }

            self.continuation = continuation
            input.requestMediaDataWhenReady(on: queue) { [self] in
                pump()
            }
        }

        private func pump() {
            guard terminalResult == nil,
                  input.isReadyForMoreMediaData else { return }
            guard let sampleBuffer = output.copyNextSampleBuffer() else {
                finish(with: .success(()))
                return
            }
            guard input.append(sampleBuffer) else {
                finish(with: .failure(TransferError.appendFailed))
                return
            }

            // Yield between samples so cancellation queued on this serial
            // adapter can run without racing AVAssetReader access.
            queue.async { [self] in
                pump()
            }
        }

        private func finish(with result: Result<Void, Error>) {
            guard terminalResult == nil else { return }
            terminalResult = result
            input.markAsFinished()
            continuation?.resume(with: result)
            continuation = nil
        }
    }

    private var state: State = .active
    private var reader: AVAssetReader?
    private var writer: AVAssetWriter?
    private var transfers: [LegacySampleTransfer] = []
    private var outputURL: URL?
    private var ownsOutputFile = false
    private let transferDidStart: (
        @Sendable (UploadInputStandardizationWorker) async -> Void
    )?

    init(
        transferDidStart: (
            @Sendable (UploadInputStandardizationWorker) async -> Void
        )? = nil
    ) {
        self.transferDidStart = transferDidStart
    }

    func standardize(
        sourceAsset: AVURLAsset,
        rescalingDetails: UploadInputFormatInspectionResult.RescalingDetails,
        outputURL: URL
    ) async throws -> AVURLAsset {
        try ensureActive()
        self.outputURL = outputURL
        do {
            let videoTracks = try await sourceAsset.loadTracks(withMediaType: .video)
            try ensureActive()
            guard videoTracks.count == 1, let videoTrack = videoTracks.first else {
                throw videoTracks.isEmpty
                    ? StandardizationError.missingVideoTrack
                    : StandardizationError.multipleVideoTracks
            }

            let audioTracks = try await sourceAsset.loadTracks(withMediaType: .audio)
            try ensureActive()
            let audioTrack = audioTracks.first
            let audioProperties = try await loadAudioProperties(for: audioTrack)
            let properties = try await loadProperties(
                sourceAsset: sourceAsset,
                videoTrack: videoTrack
            )
            let standardizedAsset = try await convert(
                sourceAsset: sourceAsset,
                videoTrack: videoTrack,
                audioTrack: audioTrack,
                audioProperties: audioProperties,
                properties: properties,
                rescalingDetails: rescalingDetails,
                outputURL: outputURL
            )
            try ensureActive()
            finishSuccessfully()
            return standardizedAsset
        } catch {
            let finalError: Error = state == .cancelled
                ? CancellationError()
                : error
            cleanupPartialOutput()
            if state == .active {
                state = .completed
            }
            throw finalError
        }
    }

    func cancel() {
        guard state == .active else { return }
        state = .cancelled

        if transfers.isEmpty {
            reader?.cancelReading()
            writer?.cancelWriting()
        } else {
            transfers.forEach { $0.cancel() }
        }
    }

    private func ensureActive() throws {
        guard state == .active, !Task.isCancelled else {
            throw CancellationError()
        }
    }

    private func loadAudioProperties(
        for track: AVAssetTrack?
    ) async throws -> AudioProperties? {
        guard let track else { return nil }
        let formatDescriptions = try await track.load(.formatDescriptions)
        try ensureActive()
        return try Self.audioProperties(
            formatDescriptions: formatDescriptions
        )
    }

    private func loadProperties(
        sourceAsset: AVAsset,
        videoTrack: AVAssetTrack
    ) async throws -> LoadedAssetProperties {
        let duration = try await sourceAsset.load(.duration)
        let (
            naturalSize,
            preferredTransform,
            nominalFrameRate,
            formatDescriptions
        ) = try await videoTrack.load(
            .naturalSize,
            .preferredTransform,
            .nominalFrameRate,
            .formatDescriptions
        )
        try ensureActive()
        guard !formatDescriptions.isEmpty else {
            throw StandardizationError.missingVideoFormat
        }
        return LoadedAssetProperties(
            duration: duration,
            naturalSize: naturalSize,
            preferredTransform: preferredTransform,
            nominalFrameRate: nominalFrameRate,
            formatDescriptions: formatDescriptions
        )
    }

    private func convert(
        sourceAsset: AVURLAsset,
        videoTrack: AVAssetTrack,
        audioTrack: AVAssetTrack?,
        audioProperties: AudioProperties?,
        properties: LoadedAssetProperties,
        rescalingDetails: UploadInputFormatInspectionResult.RescalingDetails,
        outputURL: URL
    ) async throws -> AVURLAsset {
        let renderSize = try Self.renderSize(
            naturalSize: properties.naturalSize,
            preferredTransform: properties.preferredTransform,
            boundingSize: Self.boundingSize(
                for: rescalingDetails.maximumDesiredResolutionPreset
            )
        )
        let reader = try AVAssetReader(asset: sourceAsset)
        guard !FileManager.default.fileExists(atPath: outputURL.path) else {
            throw StandardizationError.outputFileAlreadyExists
        }
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        self.reader = reader
        self.writer = writer
        ownsOutputFile = true

        let sourceFormatDescription = properties.formatDescriptions[0]
        let decoderPixelFormat = Self.decoderPixelFormat(
            for: sourceFormatDescription
        )
        let codec = Self.outputCodec(
            for: sourceFormatDescription.mediaSubType
        )
        let encoderConfiguration = Self.encoderConfiguration(
            codec: codec,
            renderSize: renderSize,
            sourceFrameRate: Double(properties.nominalFrameRate),
            decoderPixelFormat: decoderPixelFormat
        )

        let videoOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: [videoTrack],
            videoSettings: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    decoderPixelFormat,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
        )
        videoOutput.alwaysCopiesSampleData = false
        videoOutput.videoComposition = Self.videoComposition(
            track: videoTrack,
            duration: properties.duration,
            naturalSize: properties.naturalSize,
            preferredTransform: properties.preferredTransform,
            outputFrameRate: encoderConfiguration.outputFrameRate,
            renderSize: renderSize
        )
        guard reader.canAdd(videoOutput) else {
            throw StandardizationError.cannotAddReaderOutput
        }
        reader.add(videoOutput)

        var videoSettings = Self.videoWriterSettings(
            codec: codec,
            renderSize: renderSize,
            encoderConfiguration: encoderConfiguration
        )
        let compressionPropertiesKey = AVVideoCompressionPropertiesKey
        if !writer.canApply(outputSettings: videoSettings, forMediaType: .video),
           var compressionProperties = videoSettings[compressionPropertiesKey]
                as? [String: Any] {
            // Apple documents AllowOpenGOP as applicable only to certain
            // encoders. If unavailable, omit only that hint; output validation
            // remains the final gate for GOP structure compliance.
            compressionProperties.removeValue(
                forKey: kVTCompressionPropertyKey_AllowOpenGOP as String
            )
            videoSettings[compressionPropertiesKey] = compressionProperties
        }
        guard writer.canApply(
            outputSettings: videoSettings,
            forMediaType: .video
        ) else {
            throw StandardizationError.writerRejectedSettings
        }
        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: videoSettings
        )
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else {
            throw StandardizationError.cannotAddWriterInput
        }
        writer.add(videoInput)

        let audioPair = try audioTrack.map {
            guard let audioProperties else {
                throw StandardizationError.missingAudioFormat
            }
            return try Self.addAudioPipeline(
                track: $0,
                properties: audioProperties,
                reader: reader,
                writer: writer
            )
        }

        guard writer.startWriting() else {
            throw writer.error ?? StandardizationError.writerStartFailure
        }
        writer.startSession(atSourceTime: .zero)
        guard reader.startReading() else {
            writer.cancelWriting()
            throw reader.error ?? StandardizationError.readerStartFailure
        }

        var transfers = [
            LegacySampleTransfer(
                output: videoOutput,
                input: videoInput,
                queue: DispatchQueue(
                    label: "com.mux.upload-sdk.standardization.video",
                    qos: .userInitiated
                )
            )
        ]
        if let audioOutput = audioPair?.output,
           let audioInput = audioPair?.input {
            transfers.append(
                LegacySampleTransfer(
                    output: audioOutput,
                    input: audioInput,
                    queue: DispatchQueue(
                        label: "com.mux.upload-sdk.standardization.audio",
                        qos: .userInitiated
                    )
                )
            )
        }
        self.transfers = transfers
        try ensureActive()
        if let transferDidStart {
            await transferDidStart(self)
        }

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for transfer in transfers {
                    group.addTask {
                        try await transfer.transfer()
                    }
                }
                try await group.waitForAll()
            }
        } catch {
            transfers.forEach { $0.cancel() }
            throw writer.error
                ?? reader.error
                ?? error
        }

        self.transfers = []
        try ensureActive()
        guard reader.status == .completed else {
            throw reader.error ?? StandardizationError.conversionFailure
        }

        await writer.finishWriting()
        try ensureActive()
        guard writer.status == .completed else {
            throw writer.error ?? StandardizationError.conversionFailure
        }
        return AVURLAsset(url: writer.outputURL)
    }

    private func finishSuccessfully() {
        state = .completed
        reader = nil
        writer = nil
        transfers = []
        outputURL = nil
        ownsOutputFile = false
    }

    private func cleanupPartialOutput() {
        transfers.forEach { $0.cancel() }
        transfers = []
        reader?.cancelReading()
        if let writer, writer.status != .unknown {
            writer.cancelWriting()
        }
        reader = nil
        writer = nil
        let outputURL = self.outputURL
        let ownsOutputFile = self.ownsOutputFile
        self.outputURL = nil
        self.ownsOutputFile = false
        if ownsOutputFile {
            removePartialOutput(at: outputURL)
        }
    }

    private func removePartialOutput(at url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    static func outputCodec(
        for mediaSubType: CMFormatDescription.MediaSubType
    ) -> AVVideoCodecType {
        switch mediaSubType.rawValue {
        case CMFormatDescription.MediaSubType.hevc.rawValue,
             0x68657631: // hev1
            return .hevc
        case CMFormatDescription.MediaSubType.h264.rawValue,
             0x61766333: // avc3
            return .h264
        default:
            return .h264
        }
    }

    static func decoderPixelFormat(
        for formatDescription: CMFormatDescription
    ) -> OSType {
        guard outputCodec(for: formatDescription.mediaSubType) == .hevc,
              let extensions = CMFormatDescriptionGetExtensions(formatDescription)
                as NSDictionary?,
              AVFoundationUploadInputMetadataReader.codecConfiguration(
                codec: .hevc,
                extensions: extensions
              ) == StandardInputPixelFormat(
                bitDepth: 10,
                chromaSubsampling: .yuv420
              ) else {
            return kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        }
        return kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
    }

    static func boundingSize(
        for preset: DirectUploadOptions.InputStandardization.MaximumResolution
    ) -> CGSize {
        switch preset {
        case .preset1280x720:
            return CGSize(width: 1280, height: 720)
        case .default, .preset1920x1080:
            return CGSize(width: 1920, height: 1080)
        case .preset2560x1440:
            return CGSize(width: 2560, height: 1440)
        case .preset3840x2160:
            return CGSize(width: 3840, height: 2160)
        }
    }

    static func renderSize(
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform,
        boundingSize: CGSize
    ) throws -> CGSize {
        let displayRect = CGRect(origin: .zero, size: naturalSize)
            .applying(preferredTransform)
            .standardized
        guard displayRect.width.isFinite,
              displayRect.height.isFinite,
              displayRect.width > 0,
              displayRect.height > 0 else {
            throw StandardizationError.invalidVideoDimensions
        }
        let scale = min(
            1,
            max(boundingSize.width, boundingSize.height)
                / max(displayRect.width, displayRect.height),
            min(boundingSize.width, boundingSize.height)
                / min(displayRect.width, displayRect.height)
        )
        return CGSize(
            width: even(displayRect.width * scale),
            height: even(displayRect.height * scale)
        )
    }

    private static func even(_ value: CGFloat) -> CGFloat {
        CGFloat(max(2, Int((value / 2).rounded()) * 2))
    }

    private static func videoComposition(
        track: AVAssetTrack,
        duration: CMTime,
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform,
        outputFrameRate: Double,
        renderSize: CGSize
    ) -> AVVideoComposition {
        let transformedRect = CGRect(origin: .zero, size: naturalSize)
            .applying(preferredTransform)
            .standardized
        let scale = min(
            renderSize.width / transformedRect.width,
            renderSize.height / transformedRect.height
        )
        let normalize = CGAffineTransform(
            translationX: -transformedRect.minX,
            y: -transformedRect.minY
        )
        let transform = preferredTransform
            .concatenating(normalize)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))

        let layerInstruction = AVMutableVideoCompositionLayerInstruction(
            assetTrack: track
        )
        layerInstruction.setTransform(transform, at: .zero)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        instruction.layerInstructions = [layerInstruction]

        let composition = AVMutableVideoComposition()
        composition.instructions = [instruction]
        composition.renderSize = renderSize
        composition.frameDuration = CMTime(
            value: 1_000,
            timescale: CMTimeScale((outputFrameRate * 1_000).rounded())
        )
        return composition
    }

    static func encoderConfiguration(
        codec: AVVideoCodecType,
        renderSize: CGSize,
        sourceFrameRate: Double,
        decoderPixelFormat: OSType
    ) -> EncoderConfiguration {
        let maximumDimension = max(renderSize.width, renderSize.height)
        let standardDimension = StandardInputPolicyProfile.publishedMux.limits(
            for: .upTo1080p
        ).maximumSourceDimension
        // The policy's effective tier follows the completed output dimensions.
        // A small output under a high-resolution customer selection must still
        // meet the stricter up-to-1080p limits.
        let acceptanceTier: StandardInputAcceptanceTier = maximumDimension
                <= CGFloat(standardDimension)
            ? .upTo1080p
            : .highResolution
        let limits = StandardInputPolicyProfile.publishedMux.limits(
            for: acceptanceTier
        )
        let outputFrameRate = sourceFrameRate.isFinite
                && limits.frameRateRange.contains(sourceFrameRate)
            ? sourceFrameRate
            : 30

        let averageBitRate: Int
        // Leave deliberate headroom below the published ceiling for each
        // generated size. The data-rate limit below is the hard guardrail;
        // VideoToolbox documents average bitrate as a soft target.
        switch maximumDimension {
        case ...1280:
            averageBitRate = 5_000_000
        case ...2048:
            averageBitRate = 7_000_000
        case ...2560:
            averageBitRate = 16_000_000
        default:
            averageBitRate = 18_000_000
        }

        let profileLevel: String
        switch codec {
        case .hevc:
            profileLevel = decoderPixelFormat
                    == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                ? kVTProfileLevel_HEVC_Main10_AutoLevel as String
                : kVTProfileLevel_HEVC_Main_AutoLevel as String
        default:
            profileLevel = AVVideoProfileLevelH264HighAutoLevel
        }

        return EncoderConfiguration(
            outputFrameRate: outputFrameRate,
            averageBitRate: averageBitRate,
            maximumBitRate: Int(limits.maximumAverageBitrate),
            maximumKeyFrameInterval: 0.9 * (limits.maximumKeyframeIntervals[
                codec == .hevc ? .hevc : .h264
            ] ?? 10),
            profileLevel: profileLevel
        )
    }

    private static func videoWriterSettings(
        codec: AVVideoCodecType,
        renderSize: CGSize,
        encoderConfiguration: EncoderConfiguration
    ) -> [String: Any] {
        [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: Int(renderSize.width),
            AVVideoHeightKey: Int(renderSize.height),
            AVVideoCompressionPropertiesKey: [
                kVTCompressionPropertyKey_AverageBitRate as String:
                    encoderConfiguration.averageBitRate,
                kVTCompressionPropertyKey_DataRateLimits as String: [
                    encoderConfiguration.maximumBitRate / 8,
                    1
                ],
                kVTCompressionPropertyKey_ExpectedFrameRate as String:
                    encoderConfiguration.outputFrameRate,
                kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration as String:
                    encoderConfiguration.maximumKeyFrameInterval,
                kVTCompressionPropertyKey_AllowOpenGOP as String: false,
                AVVideoProfileLevelKey: encoderConfiguration.profileLevel
            ]
        ]
    }

    private static func addAudioPipeline(
        track: AVAssetTrack,
        properties: AudioProperties,
        reader: AVAssetReader,
        writer: AVAssetWriter
    ) throws -> (output: AVAssetReaderOutput, input: AVAssetWriterInput) {
        if properties.isAAC {
            let output = AVAssetReaderTrackOutput(
                track: track,
                outputSettings: nil
            )
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else {
                throw StandardizationError.cannotAddReaderOutput
            }
            reader.add(output)

            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: nil,
                sourceFormatHint: properties.sourceFormatDescription
            )
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else {
                throw StandardizationError.cannotAddWriterInput
            }
            writer.add(input)
            return (output, input)
        }

        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM]
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw StandardizationError.cannotAddReaderOutput
        }
        reader.add(output)

        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: properties.sampleRate,
            AVNumberOfChannelsKey: properties.channelCount,
            AVEncoderBitRateKey: properties.channelCount > 2 ? 384_000 : 160_000
        ]
        if let channelLayout = properties.channelLayout {
            settings[AVChannelLayoutKey] = channelLayout
        }
        guard writer.canApply(
            outputSettings: settings,
            forMediaType: .audio
        ) else {
            throw StandardizationError.writerRejectedSettings
        }
        let input = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: settings
        )
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else {
            throw StandardizationError.cannotAddWriterInput
        }
        writer.add(input)
        return (output, input)
    }

    static func audioProperties(
        formatDescriptions: [CMAudioFormatDescription]
    ) throws -> AudioProperties {
        guard let formatDescription = formatDescriptions.first,
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(
                formatDescription
              )?.pointee,
              streamDescription.mSampleRate.isFinite,
              streamDescription.mSampleRate > 0,
              streamDescription.mChannelsPerFrame > 0 else {
            throw StandardizationError.missingAudioFormat
        }

        var layoutSize = 0
        let layout = CMAudioFormatDescriptionGetChannelLayout(
            formatDescription,
            sizeOut: &layoutSize
        )
        let layoutData = layout.map { Data(bytes: $0, count: layoutSize) }
            ?? defaultChannelLayout(channelCount: Int(streamDescription.mChannelsPerFrame))
        return AudioProperties(
            sampleRate: streamDescription.mSampleRate,
            channelCount: Int(streamDescription.mChannelsPerFrame),
            channelLayout: layoutData,
            sourceFormatDescription: formatDescription
        )
    }

    private static func defaultChannelLayout(channelCount: Int) -> Data? {
        let tag: AudioChannelLayoutTag
        switch channelCount {
        case 1:
            tag = kAudioChannelLayoutTag_Mono
        case 2:
            tag = kAudioChannelLayoutTag_Stereo
        case 6:
            tag = kAudioChannelLayoutTag_MPEG_5_1_D
        default:
            return nil
        }
        var layout = AudioChannelLayout(
            mChannelLayoutTag: tag,
            mChannelBitmap: AudioChannelBitmap(rawValue: 0),
            mNumberChannelDescriptions: 0,
            mChannelDescriptions: AudioChannelDescription()
        )
        return Data(
            bytes: &layout,
            count: MemoryLayout<AudioChannelLayout>.size
        )
    }
}

extension UploadInputStandardizationWorker: UploadInputStandardizationWorking {}
