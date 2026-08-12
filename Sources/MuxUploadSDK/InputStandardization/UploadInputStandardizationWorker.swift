//
//  UploadInputStandardizationWorker.swift
//

import AVFoundation
import AudioToolbox
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

protocol UploadInputStandardizationWorking: AnyObject {
    func standardize(
        sourceAsset: AVURLAsset,
        rescalingDetails: UploadInputFormatInspectionResult.RescalingDetails,
        outputURL: URL,
        completion: @escaping (AVURLAsset, AVAsset?, Error?) -> ()
    )

    func cancel()
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

final class UploadInputStandardizationWorker {
    typealias Completion = (AVURLAsset, AVAsset?, Error?) -> Void

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

    private final class UncheckedSendableBox<Value>: @unchecked Sendable {
        let value: Value

        init(_ value: Value) {
            self.value = value
        }
    }

    private let stateLock = NSLock()
    private var state: State = .active
    private var reader: AVAssetReader?
    private var writer: AVAssetWriter?
    private var outputURL: URL?
    private var ownsOutputFile = false

    func standardize(
        sourceAsset: AVURLAsset,
        rescalingDetails: UploadInputFormatInspectionResult.RescalingDetails,
        outputURL: URL,
        completion: @escaping Completion
    ) {
        stateLock.lock()
        guard state == .active else {
            stateLock.unlock()
            return
        }
        self.outputURL = outputURL
        stateLock.unlock()

        sourceAsset.loadTracks(withMediaType: .video) { [weak self] videoTracks, error in
            guard let self, self.isActive else { return }
            guard error == nil, let videoTracks else {
                self.complete(
                    sourceAsset: sourceAsset,
                    error: error ?? StandardizationError.missingVideoTrack,
                    completion: completion
                )
                return
            }
            guard videoTracks.count == 1, let videoTrack = videoTracks.first else {
                self.complete(
                    sourceAsset: sourceAsset,
                    error: videoTracks.isEmpty
                        ? StandardizationError.missingVideoTrack
                        : StandardizationError.multipleVideoTracks,
                    completion: completion
                )
                return
            }

            sourceAsset.loadTracks(withMediaType: .audio) { audioTracks, error in
                guard self.isActive else { return }
                guard error == nil, let audioTracks else {
                    self.complete(
                        sourceAsset: sourceAsset,
                        error: error ?? StandardizationError.missingAudioFormat,
                        completion: completion
                    )
                    return
                }
                let audioTrack = audioTracks.first
                self.loadAudioProperties(for: audioTrack) { audioResult in
                    guard self.isActive else { return }
                    guard case .success(let audioProperties) = audioResult else {
                        if case .failure(let error) = audioResult {
                            self.complete(
                                sourceAsset: sourceAsset,
                                error: error,
                                completion: completion
                            )
                        }
                        return
                    }
                    self.loadProperties(
                        sourceAsset: sourceAsset,
                        videoTrack: videoTrack
                    ) { result in
                        guard self.isActive else { return }
                        switch result {
                        case .success(let properties):
                            self.convert(
                                sourceAsset: sourceAsset,
                                videoTrack: videoTrack,
                                audioTrack: audioTrack,
                                audioProperties: audioProperties,
                                properties: properties,
                                rescalingDetails: rescalingDetails,
                                outputURL: outputURL,
                                completion: completion
                            )
                        case .failure(let error):
                            self.complete(
                                sourceAsset: sourceAsset,
                                error: error,
                                completion: completion
                            )
                        }
                    }
                }
            }
        }
    }

    private func loadAudioProperties(
        for track: AVAssetTrack?,
        completion: @escaping (Result<AudioProperties?, Error>) -> Void
    ) {
        guard let track else {
            completion(.success(nil))
            return
        }
        track.loadValuesAsynchronously(forKeys: ["formatDescriptions"]) {
            guard self.isActive else { return }
            do {
                completion(
                    .success(
                        try Self.audioProperties(
                            formatDescriptions: track.formatDescriptions
                                as? [CMAudioFormatDescription] ?? []
                        )
                    )
                )
            } catch {
                completion(.failure(error))
            }
        }
    }

    func cancel() {
        stateLock.lock()
        guard state == .active else {
            stateLock.unlock()
            return
        }
        state = .cancelled
        let reader = self.reader
        let writer = self.writer
        let outputURL = self.outputURL
        let ownsOutputFile = self.ownsOutputFile
        self.reader = nil
        self.writer = nil
        self.outputURL = nil
        self.ownsOutputFile = false
        stateLock.unlock()

        reader?.cancelReading()
        writer?.cancelWriting()
        if ownsOutputFile {
            removePartialOutput(at: outputURL)
        }
    }

    private var isActive: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return state == .active
    }

    private func loadProperties(
        sourceAsset: AVAsset,
        videoTrack: AVAssetTrack,
        completion: @escaping (Result<LoadedAssetProperties, Error>) -> Void
    ) {
        sourceAsset.loadValuesAsynchronously(forKeys: ["duration"]) {
            guard self.isActive else { return }
            videoTrack.loadValuesAsynchronously(
                forKeys: [
                    "naturalSize",
                    "preferredTransform",
                    "nominalFrameRate",
                    "formatDescriptions"
                ]
            ) {
                guard self.isActive else { return }
                guard let formatDescriptions = videoTrack.formatDescriptions
                    as? [CMFormatDescription],
                      !formatDescriptions.isEmpty else {
                    completion(.failure(StandardizationError.missingVideoFormat))
                    return
                }
                completion(
                    .success(
                        LoadedAssetProperties(
                            duration: sourceAsset.duration,
                            naturalSize: videoTrack.naturalSize,
                            preferredTransform: videoTrack.preferredTransform,
                            nominalFrameRate: videoTrack.nominalFrameRate,
                            formatDescriptions: formatDescriptions
                        )
                    )
                )
            }
        }
    }

    private func convert(
        sourceAsset: AVURLAsset,
        videoTrack: AVAssetTrack,
        audioTrack: AVAssetTrack?,
        audioProperties: AudioProperties?,
        properties: LoadedAssetProperties,
        rescalingDetails: UploadInputFormatInspectionResult.RescalingDetails,
        outputURL: URL,
        completion: @escaping Completion
    ) {
        do {
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
            guard register(reader: reader, writer: writer) else { return }

            let sourceFormatDescription = properties.formatDescriptions[0]
            let decoderPixelFormat = Self.decoderPixelFormat(
                for: sourceFormatDescription
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
                nominalFrameRate: properties.nominalFrameRate,
                renderSize: renderSize
            )
            guard reader.canAdd(videoOutput) else {
                throw StandardizationError.cannotAddReaderOutput
            }
            reader.add(videoOutput)

            let videoSettings = Self.videoWriterSettings(
                codec: Self.outputCodec(
                    for: sourceFormatDescription.mediaSubType
                ),
                renderSize: renderSize,
                decoderPixelFormat: decoderPixelFormat
            )
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

            pump(
                sourceAsset: sourceAsset,
                reader: reader,
                writer: writer,
                videoOutput: videoOutput,
                videoInput: videoInput,
                audioOutput: audioPair?.output,
                audioInput: audioPair?.input,
                completion: completion
            )
        } catch {
            complete(
                sourceAsset: sourceAsset,
                error: error,
                completion: completion
            )
        }
    }

    private func register(reader: AVAssetReader, writer: AVAssetWriter) -> Bool {
        stateLock.lock()
        let shouldStart = state == .active
        if shouldStart {
            self.reader = reader
            self.writer = writer
            ownsOutputFile = true
        }
        stateLock.unlock()

        if !shouldStart {
            reader.cancelReading()
            writer.cancelWriting()
            removePartialOutput(at: writer.outputURL)
        }
        return shouldStart
    }

    private func pump(
        sourceAsset: AVURLAsset,
        reader: AVAssetReader,
        writer: AVAssetWriter,
        videoOutput: AVAssetReaderOutput,
        videoInput: AVAssetWriterInput,
        audioOutput: AVAssetReaderOutput?,
        audioInput: AVAssetWriterInput?,
        completion: @escaping Completion
    ) {
        let group = DispatchGroup()
        let readerBox = UncheckedSendableBox(reader)

        Self.transfer(
            output: videoOutput,
            input: videoInput,
            reader: readerBox,
            queue: DispatchQueue(
                label: "com.mux.upload-sdk.standardization.video",
                qos: .userInitiated
            ),
            group: group
        )

        if let audioOutput, let audioInput {
            Self.transfer(
                output: audioOutput,
                input: audioInput,
                reader: readerBox,
                queue: DispatchQueue(
                    label: "com.mux.upload-sdk.standardization.audio",
                    qos: .userInitiated
                ),
                group: group
            )
        }

        group.notify(queue: .global(qos: .userInitiated)) { [weak self] in
            guard let self, self.isActive else { return }
            guard reader.status == .completed else {
                writer.cancelWriting()
                self.complete(
                    sourceAsset: sourceAsset,
                    error: reader.error ?? StandardizationError.conversionFailure,
                    completion: completion
                )
                return
            }
            writer.finishWriting {
                guard self.isActive else { return }
                guard writer.status == .completed else {
                    self.complete(
                        sourceAsset: sourceAsset,
                        error: writer.error ?? StandardizationError.conversionFailure,
                        completion: completion
                    )
                    return
                }
                self.complete(
                    sourceAsset: sourceAsset,
                    standardizedAsset: AVURLAsset(url: writer.outputURL),
                    completion: completion
                )
            }
        }
    }

    private static func transfer(
        output: AVAssetReaderOutput,
        input: AVAssetWriterInput,
        reader: UncheckedSendableBox<AVAssetReader>,
        queue: DispatchQueue,
        group: DispatchGroup
    ) {
        let outputBox = UncheckedSendableBox(output)
        let inputBox = UncheckedSendableBox(input)
        group.enter()
        input.requestMediaDataWhenReady(on: queue) {
            let output = outputBox.value
            let input = inputBox.value
            while input.isReadyForMoreMediaData {
                guard let sampleBuffer = output.copyNextSampleBuffer() else {
                    input.markAsFinished()
                    group.leave()
                    return
                }
                guard input.append(sampleBuffer) else {
                    reader.value.cancelReading()
                    input.markAsFinished()
                    group.leave()
                    return
                }
            }
        }
    }

    private func complete(
        sourceAsset: AVURLAsset,
        standardizedAsset: AVAsset? = nil,
        error: Error? = nil,
        completion: @escaping Completion
    ) {
        stateLock.lock()
        guard state == .active else {
            stateLock.unlock()
            return
        }
        state = .completed
        reader = nil
        writer = nil
        let outputURL = self.outputURL
        let ownsOutputFile = self.ownsOutputFile
        self.outputURL = nil
        self.ownsOutputFile = false
        stateLock.unlock()

        if error != nil, ownsOutputFile {
            removePartialOutput(at: outputURL)
        }
        completion(sourceAsset, standardizedAsset, error)
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
        nominalFrameRate: Float,
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
        let frameRate = nominalFrameRate.isFinite && nominalFrameRate > 0
            ? nominalFrameRate
            : 30
        composition.frameDuration = CMTime(
            value: 1_000,
            timescale: CMTimeScale((frameRate * 1_000).rounded())
        )
        return composition
    }

    private static func videoWriterSettings(
        codec: AVVideoCodecType,
        renderSize: CGSize,
        decoderPixelFormat: OSType
    ) -> [String: Any] {
        var settings: [String: Any] = [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: Int(renderSize.width),
            AVVideoHeightKey: Int(renderSize.height)
        ]
        if codec == .hevc,
           decoderPixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange {
            settings[AVVideoCompressionPropertiesKey] = [
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel
            ]
        }
        return settings
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
