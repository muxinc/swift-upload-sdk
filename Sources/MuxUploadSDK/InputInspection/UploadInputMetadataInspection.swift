//
//  UploadInputMetadataInspection.swift
//

import AudioToolbox
import CoreGraphics
import CoreMedia
import Foundation

struct UploadInputMetadataInspection: Equatable {
    struct VideoTransform: Equatable {
        /// The source metadata orientation normalized to the range 0...270.
        /// For example, a signed -90-degree rotation is represented as 270 degrees.
        enum Rotation: Int, Equatable {
            case degrees0 = 0
            case degrees90 = 90
            case degrees180 = 180
            case degrees270 = 270
        }

        let rotation: Rotation
        let isMirrored: Bool
    }

    struct ColorProperties: Equatable {
        var primaries: StandardInputFact<String> = .unknown
        var transferFunction: StandardInputFact<String> = .unknown
        var yCbCrMatrix: StandardInputFact<String> = .unknown
        var isFullRangeVideo: StandardInputFact<Bool> = .unknown
    }

    var videoTrackCount: Int = 0
    var audioTrackCount: StandardInputFact<Int> = .unknown
    var encodedDimensions: StandardInputFact<StandardInputDisplayDimensions> = .unknown
    var videoTransform: StandardInputFact<VideoTransform> = .unknown
    var colorProperties: ColorProperties = ColorProperties()
}

struct AVFoundationVideoTrackMetadata {
    let formatDescriptions: [CMFormatDescription]
    let preferredTransform: CGAffineTransform
    let nominalFrameRate: Float
    let estimatedDataRate: Float
}

struct AVFoundationAudioTrackMetadata {
    let formatDescriptions: [CMFormatDescription]
}

enum AVFoundationUploadInputMetadataReader {
    struct Result {
        let mediaFacts: StandardInputMediaFacts
        let metadata: UploadInputMetadataInspection
    }

    static func inspect(
        videoTracks: [AVFoundationVideoTrackMetadata],
        audioTracks: [AVFoundationAudioTrackMetadata]?
    ) -> Result {
        var facts = StandardInputMediaFacts()
        var metadata = UploadInputMetadataInspection(
            videoTrackCount: videoTracks.count,
            audioTrackCount: audioTracks.map { .known($0.count) } ?? .unknown
        )

        facts.audio = audioTracks.map(inspectAudio) ?? .unknown

        guard videoTracks.count == 1,
              let videoTrack = videoTracks.first,
              let formatDescription = videoTrack.formatDescriptions.first else {
            return Result(mediaFacts: facts, metadata: metadata)
        }

        facts.videoCodec = inspectVideoCodec(formatDescription.mediaSubType)

        let encodedDimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
        if encodedDimensions.width > 0, encodedDimensions.height > 0 {
            metadata.encodedDimensions = .known(
                StandardInputDisplayDimensions(
                    width: Int(encodedDimensions.width),
                    height: Int(encodedDimensions.height)
                )
            )
        }

        facts.displayDimensions = inspectDisplayDimensions(
            formatDescription: formatDescription,
            preferredTransform: videoTrack.preferredTransform
        )
        metadata.videoTransform = inspectVideoTransform(videoTrack.preferredTransform)
        facts.frameRate = positiveFinite(Double(videoTrack.nominalFrameRate))
        facts.averageBitrate = positiveFiniteInteger(Double(videoTrack.estimatedDataRate))

        let extensions = (CMFormatDescriptionGetExtensions(formatDescription)
            as NSDictionary?) ?? NSDictionary()
        metadata.colorProperties = inspectColorProperties(extensions)
        facts.dynamicRange = inspectDynamicRange(
            transferFunction: metadata.colorProperties.transferFunction,
            extensions: extensions
        )
        facts.pixelFormat = inspectPixelFormat(
            codec: facts.videoCodec,
            extensions: extensions
        )

        return Result(mediaFacts: facts, metadata: metadata)
    }

    private static func inspectVideoCodec(
        _ mediaSubType: CMFormatDescription.MediaSubType
    ) -> StandardInputFact<StandardInputVideoCodec> {
        switch fourCharacterCodeString(mediaSubType.rawValue) {
        case "avc1", "avc3":
            return .known(.h264)
        case "hvc1", "hev1":
            return .known(.hevc)
        default:
            return .known(.other)
        }
    }

    private static func inspectDisplayDimensions(
        formatDescription: CMFormatDescription,
        preferredTransform: CGAffineTransform
    ) -> StandardInputFact<StandardInputDisplayDimensions> {
        let presentationDimensions = CMVideoFormatDescriptionGetPresentationDimensions(
            formatDescription,
            usePixelAspectRatio: true,
            useCleanAperture: true
        )

        guard presentationDimensions.width.isFinite,
              presentationDimensions.height.isFinite,
              presentationDimensions.width > 0,
              presentationDimensions.height > 0,
              inspectVideoTransform(preferredTransform).value != nil else {
            return .unknown
        }

        let transformedBounds = CGRect(
            origin: .zero,
            size: presentationDimensions
        ).applying(preferredTransform)
        let width = Int(abs(transformedBounds.width).rounded())
        let height = Int(abs(transformedBounds.height).rounded())

        guard width > 0, height > 0 else {
            return .unknown
        }

        return .known(StandardInputDisplayDimensions(width: width, height: height))
    }

    private static func inspectVideoTransform(
        _ transform: CGAffineTransform
    ) -> StandardInputFact<UploadInputMetadataInspection.VideoTransform> {
        let values = [transform.a, transform.b, transform.c, transform.d]
        guard values.allSatisfy(\.isFinite) else {
            return .unknown
        }

        let firstAxisLength = hypot(transform.a, transform.b)
        let secondAxisLength = hypot(transform.c, transform.d)
        guard firstAxisLength > 0,
              secondAxisLength > 0,
              abs((transform.a * transform.c + transform.b * transform.d)
                  / (firstAxisLength * secondAxisLength)) < 0.001 else {
            return .unknown
        }

        let angle = atan2(transform.b / firstAxisLength, transform.a / firstAxisLength)
        let counterclockwiseQuarterTurns = Int((angle / (.pi / 2)).rounded())
        let clockwiseQuarterTurns = -counterclockwiseQuarterTurns
        let normalizedQuarterTurns = (clockwiseQuarterTurns % 4 + 4) % 4
        let expectedAngle = Double(counterclockwiseQuarterTurns) * (.pi / 2)
        guard abs(angle - expectedAngle) < 0.001 else {
            return .unknown
        }

        let rotation: UploadInputMetadataInspection.VideoTransform.Rotation
        switch normalizedQuarterTurns {
        case 0:
            rotation = .degrees0
        case 1:
            rotation = .degrees90
        case 2:
            rotation = .degrees180
        default:
            rotation = .degrees270
        }

        return .known(
            UploadInputMetadataInspection.VideoTransform(
                rotation: rotation,
                isMirrored: transform.a * transform.d - transform.b * transform.c < 0
            )
        )
    }

    private static func inspectColorProperties(
        _ extensions: NSDictionary
    ) -> UploadInputMetadataInspection.ColorProperties {
        UploadInputMetadataInspection.ColorProperties(
            primaries: stringFact(
                extensions[kCMFormatDescriptionExtension_ColorPrimaries]
            ),
            transferFunction: stringFact(
                extensions[kCMFormatDescriptionExtension_TransferFunction]
            ),
            yCbCrMatrix: stringFact(
                extensions[kCMFormatDescriptionExtension_YCbCrMatrix]
            ),
            isFullRangeVideo: boolFact(
                extensions[kCMFormatDescriptionExtension_FullRangeVideo]
            )
        )
    }

    private static func inspectDynamicRange(
        transferFunction: StandardInputFact<String>,
        extensions: NSDictionary
    ) -> StandardInputFact<StandardInputDynamicRange> {
        guard let transferFunction = transferFunction.value else {
            return hasHDRMetadata(extensions) ? .known(.otherHDR) : .unknown
        }

        if transferFunction == swiftString(
            kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG
        ) {
            return .known(.hlg)
        }
        if transferFunction == swiftString(
            kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
        ) {
            return .known(.pq)
        }

        let sdrTransferFunctions = [
            kCMFormatDescriptionTransferFunction_ITU_R_709_2,
            kCMFormatDescriptionTransferFunction_SMPTE_240M_1995,
            kCMFormatDescriptionTransferFunction_sRGB,
            kCMFormatDescriptionTransferFunction_UseGamma
        ].map(swiftString)
        if sdrTransferFunctions.contains(transferFunction) {
            return .known(.sdr)
        }

        if hasHDRMetadata(extensions) {
            return .known(.otherHDR)
        }
        return .unknown
    }

    private static func inspectPixelFormat(
        codec: StandardInputFact<StandardInputVideoCodec>,
        extensions: NSDictionary
    ) -> StandardInputFact<StandardInputPixelFormat> {
        guard let codec = codec.value,
              codec == .h264 || codec == .hevc else {
            return .unknown
        }

        if let codecConfiguration = codecConfiguration(
            codec: codec,
            extensions: extensions
        ) {
            return .known(codecConfiguration)
        }

        return .unknown
    }

    static func codecConfiguration(
        codec: StandardInputVideoCodec,
        extensions: NSDictionary
    ) -> StandardInputPixelFormat? {
        guard let atoms = extensions[
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms
        ] as? NSDictionary else {
            return nil
        }

        switch codec {
        case .h264:
            guard let data = atoms["avcC"] as? Data else {
                return nil
            }
            return inspectAVCConfiguration(data)
        case .hevc:
            guard let data = atoms["hvcC"] as? Data else {
                return nil
            }
            return inspectHEVCConfiguration(data)
        case .other:
            return nil
        }
    }

    private static func inspectHEVCConfiguration(
        _ data: Data
    ) -> StandardInputPixelFormat? {
        guard data.count > 18, byte(in: data, at: 0) == 1 else {
            return nil
        }

        let chromaFormat = byte(in: data, at: 16) & 0x03
        let lumaBitDepth = Int(byte(in: data, at: 17) & 0x07) + 8
        let chromaBitDepth = Int(byte(in: data, at: 18) & 0x07) + 8

        return StandardInputPixelFormat(
            bitDepth: max(lumaBitDepth, chromaBitDepth),
            chromaSubsampling: chromaFormat == 1 ? .yuv420 : .other
        )
    }

    private static func inspectAVCConfiguration(
        _ data: Data
    ) -> StandardInputPixelFormat? {
        guard data.count > 6, byte(in: data, at: 0) == 1 else {
            return nil
        }

        let profile = byte(in: data, at: 1)
        let eightBit420Profiles: Set<UInt8> = [66, 77, 88]
        if eightBit420Profiles.contains(profile) {
            return StandardInputPixelFormat(
                bitDepth: 8,
                chromaSubsampling: .yuv420
            )
        }

        let profilesWithExtendedConfiguration: Set<UInt8> = [
            100, 110, 122, 144
        ]
        guard profilesWithExtendedConfiguration.contains(profile) else {
            return nil
        }

        var offset = 6
        let sequenceParameterSetCount = Int(byte(in: data, at: 5) & 0x1f)
        guard skipLengthPrefixedEntries(
            count: sequenceParameterSetCount,
            data: data,
            offset: &offset
        ), offset < data.count else {
            return nil
        }

        let pictureParameterSetCount = Int(byte(in: data, at: offset))
        offset += 1
        guard skipLengthPrefixedEntries(
            count: pictureParameterSetCount,
            data: data,
            offset: &offset
        ), offset + 2 < data.count else {
            return nil
        }

        let chromaFormat = byte(in: data, at: offset) & 0x03
        let lumaBitDepth = Int(byte(in: data, at: offset + 1) & 0x07) + 8
        let chromaBitDepth = Int(byte(in: data, at: offset + 2) & 0x07) + 8

        return StandardInputPixelFormat(
            bitDepth: max(lumaBitDepth, chromaBitDepth),
            chromaSubsampling: chromaFormat == 1 ? .yuv420 : .other
        )
    }

    private static func skipLengthPrefixedEntries(
        count: Int,
        data: Data,
        offset: inout Int
    ) -> Bool {
        for _ in 0..<count {
            guard offset + 1 < data.count else {
                return false
            }
            let length = Int(byte(in: data, at: offset)) << 8
                | Int(byte(in: data, at: offset + 1))
            offset += 2
            guard offset + length <= data.count else {
                return false
            }
            offset += length
        }
        return true
    }

    private static func byte(in data: Data, at offset: Int) -> UInt8 {
        data[data.index(data.startIndex, offsetBy: offset)]
    }

    private static func inspectAudio(
        _ tracks: [AVFoundationAudioTrackMetadata]
    ) -> StandardInputFact<StandardInputAudio> {
        guard !tracks.isEmpty else {
            return .known(.none)
        }
        guard tracks.count == 1,
              let formatDescription = tracks[0].formatDescriptions.first else {
            return .unknown
        }

        let mediaSubType = formatDescription.mediaSubType.rawValue
        guard mediaSubType == kAudioFormatMPEG4AAC else {
            return .known(.otherCodec)
        }

        guard let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(
            formatDescription
        ) else {
            return .unknown
        }

        let channelLayout: StandardInputAudio.ChannelLayout
        switch streamDescription.pointee.mChannelsPerFrame {
        case 1:
            channelLayout = .mono
        case 2:
            channelLayout = .stereo
        case 6:
            channelLayout = .fivePointOne
        default:
            channelLayout = .other
        }

        return .known(.aac(channelLayout))
    }

    private static func positiveFinite(_ value: Double) -> StandardInputFact<Double> {
        guard value.isFinite, value > 0 else {
            return .unknown
        }
        return .known(value)
    }

    private static func positiveFiniteInteger(
        _ value: Double
    ) -> StandardInputFact<Int64> {
        guard value.isFinite,
              value > 0,
              value <= Double(Int64.max) else {
            return .unknown
        }
        return .known(Int64(value.rounded()))
    }

    private static func stringFact(_ value: Any?) -> StandardInputFact<String> {
        guard let value = value as? String, !value.isEmpty else {
            return .unknown
        }
        return .known(value)
    }

    private static func swiftString(_ value: CFString) -> String {
        value as String
    }

    private static func boolFact(_ value: Any?) -> StandardInputFact<Bool> {
        guard let value = value as? NSNumber else {
            return .unknown
        }
        return .known(value.boolValue)
    }

    private static func hasHDRMetadata(_ extensions: NSDictionary) -> Bool {
        extensions[kCMFormatDescriptionExtension_MasteringDisplayColorVolume] != nil
            || extensions[kCMFormatDescriptionExtension_ContentLightLevelInfo] != nil
    }

    private static func fourCharacterCodeString(_ value: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }
}
