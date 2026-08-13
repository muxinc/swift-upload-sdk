//
//  UploadInputMetadataInspectionTests.swift
//

import AudioToolbox
import AVFoundation
import CoreMedia
import XCTest
@testable import MuxUploadSDK

final class UploadInputMetadataInspectionTests: XCTestCase {

    func testClassifiesIdentityTrimAndComplexEditMappings() {
        let identity = AVFoundationVideoTrackSegmentMetadata(
            timeMapping: CMTimeMapping(
                source: CMTimeRange(
                    start: .zero,
                    duration: CMTime(seconds: 3, preferredTimescale: 600)
                ),
                target: CMTimeRange(
                    start: .zero,
                    duration: CMTime(seconds: 3, preferredTimescale: 600)
                )
            ),
            isEmpty: false
        )
        XCTAssertEqual(
            AVFoundationUploadInputMetadataReader.inspectEditList([identity]),
            .known(.none)
        )

        let trim = AVFoundationVideoTrackSegmentMetadata(
            timeMapping: CMTimeMapping(
                source: CMTimeRange(
                    start: CMTime(seconds: 0.5, preferredTimescale: 600),
                    duration: CMTime(seconds: 3, preferredTimescale: 600)
                ),
                target: CMTimeRange(
                    start: .zero,
                    duration: CMTime(seconds: 3, preferredTimescale: 600)
                )
            ),
            isEmpty: false
        )
        XCTAssertEqual(
            AVFoundationUploadInputMetadataReader.inspectEditList([trim]),
            .known(.simple)
        )

        let scaled = AVFoundationVideoTrackSegmentMetadata(
            timeMapping: CMTimeMapping(
                source: CMTimeRange(
                    start: .zero,
                    duration: CMTime(seconds: 3, preferredTimescale: 600)
                ),
                target: CMTimeRange(
                    start: .zero,
                    duration: CMTime(seconds: 4, preferredTimescale: 600)
                )
            ),
            isEmpty: false
        )
        XCTAssertEqual(
            AVFoundationUploadInputMetadataReader.inspectEditList([scaled]),
            .known(.complex)
        )
        XCTAssertEqual(
            AVFoundationUploadInputMetadataReader.inspectEditList([identity, trim]),
            .known(.complex)
        )
        XCTAssertEqual(
            AVFoundationUploadInputMetadataReader.inspectEditList(nil),
            .unknown
        )
    }

    func testReadsH264SDRMetadataIntoPolicyFacts() throws {
        let formatDescription = try makeVideoFormatDescription(
            codecType: fourCharacterCode("avc1"),
            width: 1920,
            height: 1080,
            extensions: [
                swiftString(kCMFormatDescriptionExtension_ColorPrimaries):
                    kCMFormatDescriptionColorPrimaries_ITU_R_709_2,
                swiftString(kCMFormatDescriptionExtension_TransferFunction):
                    kCMFormatDescriptionTransferFunction_ITU_R_709_2,
                swiftString(kCMFormatDescriptionExtension_YCbCrMatrix):
                    kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2,
                swiftString(kCMFormatDescriptionExtension_FullRangeVideo): false,
                swiftString(
                    kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms
                ): ["avcC": Data([1, 77, 0, 40, 0xff, 0xe0, 0])]
            ]
        )

        let result = AVFoundationUploadInputMetadataReader.inspect(
            videoTracks: [
                AVFoundationVideoTrackMetadata(
                    formatDescriptions: [formatDescription],
                    preferredTransform: .identity,
                    nominalFrameRate: 30,
                    estimatedDataRate: 7_500_000
                )
            ],
            audioTracks: []
        )

        XCTAssertEqual(result.mediaFacts.videoCodec, .known(.h264))
        XCTAssertEqual(
            result.mediaFacts.displayDimensions,
            .known(.init(width: 1920, height: 1080))
        )
        XCTAssertEqual(result.mediaFacts.frameRate, .known(30))
        XCTAssertEqual(result.mediaFacts.averageBitrate, .known(7_500_000))
        XCTAssertEqual(
            result.mediaFacts.pixelFormat,
            .known(.init(bitDepth: 8, chromaSubsampling: .yuv420))
        )
        XCTAssertEqual(result.mediaFacts.dynamicRange, .known(.sdr))
        XCTAssertEqual(result.mediaFacts.audio, .known(.none))
        XCTAssertEqual(result.mediaFacts.maximumGOPBitrate, .unknown)
        XCTAssertEqual(result.mediaFacts.maximumGOPByteSize, .unknown)
        XCTAssertEqual(result.mediaFacts.maximumKeyframeInterval, .unknown)
        XCTAssertEqual(result.mediaFacts.gopStructure, .unknown)
        XCTAssertEqual(
            result.metadata.encodedDimensions,
            .known(.init(width: 1920, height: 1080))
        )
        XCTAssertEqual(
            result.metadata.videoTransform,
            .known(.init(rotation: .degrees0, isMirrored: false))
        )
        XCTAssertEqual(result.metadata.videoTrackCount, 1)
        XCTAssertEqual(result.metadata.audioTrackCount, .known(0))
        XCTAssertEqual(
            result.metadata.colorProperties.transferFunction,
            .known(swiftString(kCMFormatDescriptionTransferFunction_ITU_R_709_2))
        )
        XCTAssertEqual(result.metadata.colorProperties.isFullRangeVideo, .known(false))

        let evaluation = StandardInputPolicyEvaluator().evaluate(
            result.mediaFacts,
            selection: StandardInputPolicySelection(maximumResolution: .default)
        )
        XCTAssertEqual(evaluation.status(for: .videoCodec), .compliant)
        XCTAssertEqual(evaluation.status(for: .videoResolution), .compliant)
        XCTAssertEqual(evaluation.status(for: .frameRate), .compliant)
        XCTAssertEqual(evaluation.status(for: .averageBitrate), .compliant)
        XCTAssertEqual(evaluation.status(for: .pixelFormat), .compliant)
        XCTAssertEqual(evaluation.status(for: .dynamicRange), .compliant)
        XCTAssertEqual(evaluation.status(for: .audio), .compliant)
        XCTAssertEqual(evaluation.status(for: .gopStructure), .unknown)
        XCTAssertEqual(evaluation.outcome, .unknown)
        XCTAssertTrue(evaluation.nonCompliantRequirements.isEmpty)
    }

    func testReadsPortraitHEVCMain10HLGMetadataWithNormalizedRotation() throws {
        var hevcConfiguration = Data(repeating: 0, count: 19)
        hevcConfiguration[0] = 1
        hevcConfiguration[16] = 1
        hevcConfiguration[17] = 2
        hevcConfiguration[18] = 2
        let formatDescription = try makeVideoFormatDescription(
            codecType: fourCharacterCode("hvc1"),
            width: 3840,
            height: 2160,
            extensions: [
                swiftString(kCMFormatDescriptionExtension_ColorPrimaries):
                    kCMFormatDescriptionColorPrimaries_ITU_R_2020,
                swiftString(kCMFormatDescriptionExtension_TransferFunction):
                    kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG,
                swiftString(kCMFormatDescriptionExtension_YCbCrMatrix):
                    kCMFormatDescriptionYCbCrMatrix_ITU_R_2020,
                swiftString(
                    kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms
                ): ["hvcC": hevcConfiguration]
            ]
        )

        let result = AVFoundationUploadInputMetadataReader.inspect(
            videoTracks: [
                AVFoundationVideoTrackMetadata(
                    formatDescriptions: [formatDescription],
                    preferredTransform: CGAffineTransform(
                        a: 0,
                        b: 1,
                        c: -1,
                        d: 0,
                        tx: 2160,
                        ty: 0
                    ),
                    nominalFrameRate: 59.94,
                    estimatedDataRate: 19_500_000
                )
            ],
            audioTracks: []
        )

        XCTAssertEqual(result.mediaFacts.videoCodec, .known(.hevc))
        XCTAssertEqual(
            result.mediaFacts.displayDimensions,
            .known(.init(width: 2160, height: 3840))
        )
        XCTAssertEqual(
            result.mediaFacts.pixelFormat,
            .known(.init(bitDepth: 10, chromaSubsampling: .yuv420))
        )
        XCTAssertEqual(result.mediaFacts.dynamicRange, .known(.hlg))
        XCTAssertEqual(
            result.metadata.encodedDimensions,
            .known(.init(width: 3840, height: 2160))
        )
        XCTAssertEqual(
            result.metadata.videoTransform,
            .known(.init(rotation: .degrees270, isMirrored: false))
        )
    }

    func testReadsPQTransferFunction() throws {
        let formatDescription = try makeVideoFormatDescription(
            codecType: fourCharacterCode("hev1"),
            width: 1920,
            height: 1080,
            extensions: [
                swiftString(kCMFormatDescriptionExtension_TransferFunction):
                    kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
            ]
        )

        let result = AVFoundationUploadInputMetadataReader.inspect(
            videoTracks: [
                AVFoundationVideoTrackMetadata(
                    formatDescriptions: [formatDescription],
                    preferredTransform: .identity,
                    nominalFrameRate: 30,
                    estimatedDataRate: 8_000_000
                )
            ],
            audioTracks: []
        )

        XCTAssertEqual(result.mediaFacts.videoCodec, .known(.hevc))
        XCTAssertEqual(result.mediaFacts.dynamicRange, .known(.pq))
        XCTAssertEqual(result.mediaFacts.pixelFormat, .unknown)
    }

    func testUnavailableAndInvalidMetadataRemainUnknown() throws {
        let formatDescription = try makeVideoFormatDescription(
            codecType: fourCharacterCode("hvc1"),
            width: 1920,
            height: 1080
        )

        let result = AVFoundationUploadInputMetadataReader.inspect(
            videoTracks: [
                AVFoundationVideoTrackMetadata(
                    formatDescriptions: [formatDescription],
                    preferredTransform: CGAffineTransform(
                        a: 1,
                        b: 0,
                        c: 0.5,
                        d: 1,
                        tx: 0,
                        ty: 0
                    ),
                    nominalFrameRate: 0,
                    estimatedDataRate: .nan
                )
            ],
            audioTracks: [
                AVFoundationAudioTrackMetadata(formatDescriptions: [])
            ]
        )

        XCTAssertEqual(result.mediaFacts.displayDimensions, .unknown)
        XCTAssertEqual(result.mediaFacts.frameRate, .unknown)
        XCTAssertEqual(result.mediaFacts.averageBitrate, .unknown)
        XCTAssertEqual(result.mediaFacts.pixelFormat, .unknown)
        XCTAssertEqual(result.mediaFacts.dynamicRange, .unknown)
        XCTAssertEqual(result.mediaFacts.audio, .unknown)
        XCTAssertEqual(result.metadata.videoTransform, .unknown)
        XCTAssertEqual(result.metadata.colorProperties.primaries, .unknown)
        XCTAssertEqual(result.metadata.colorProperties.transferFunction, .unknown)
        XCTAssertEqual(result.metadata.colorProperties.yCbCrMatrix, .unknown)
        XCTAssertEqual(result.metadata.colorProperties.isFullRangeVideo, .unknown)
    }

    func testReadsAACChannelLayoutAndTrackCounts() throws {
        let audioFormatDescription = try makeAudioFormatDescription(
            formatID: kAudioFormatMPEG4AAC,
            channelCount: 2
        )

        let result = AVFoundationUploadInputMetadataReader.inspect(
            videoTracks: [],
            audioTracks: [
                AVFoundationAudioTrackMetadata(
                    formatDescriptions: [audioFormatDescription]
                )
            ]
        )

        XCTAssertEqual(result.mediaFacts.audio, .known(.aac(.stereo)))
        XCTAssertEqual(result.metadata.videoTrackCount, 0)
        XCTAssertEqual(result.metadata.audioTrackCount, .known(1))
        XCTAssertEqual(result.mediaFacts.videoCodec, .unknown)
    }

    func testReadsNonAACAudioCodec() throws {
        let audioFormatDescription = try makeAudioFormatDescription(
            formatID: kAudioFormatLinearPCM,
            channelCount: 2
        )

        let result = AVFoundationUploadInputMetadataReader.inspect(
            videoTracks: [],
            audioTracks: [
                AVFoundationAudioTrackMetadata(
                    formatDescriptions: [audioFormatDescription]
                )
            ]
        )

        XCTAssertEqual(result.mediaFacts.audio, .known(.otherCodec))
    }

    func testReadsNonLCAACProfilesAsUnsupported() throws {
        let nonLCProfiles: [AudioFormatID] = [
            kAudioFormatMPEG4AAC_HE,
            kAudioFormatMPEG4AAC_HE_V2,
            kAudioFormatMPEG4AAC_LD,
            kAudioFormatMPEG4AAC_ELD
        ]

        for formatID in nonLCProfiles {
            let formatDescription = try makeAudioFormatDescription(
                formatID: formatID,
                channelCount: 2
            )
            let result = AVFoundationUploadInputMetadataReader.inspect(
                videoTracks: [],
                audioTracks: [
                    AVFoundationAudioTrackMetadata(
                        formatDescriptions: [formatDescription]
                    )
                ]
            )

            XCTAssertEqual(
                result.mediaFacts.audio,
                .known(.otherCodec),
                "Expected format ID \(formatID) to remain distinct from AAC-LC"
            )
        }
    }

    func testUnavailableAudioMetadataDoesNotBlockKnownVideoFacts() throws {
        let formatDescription = try makeVideoFormatDescription(
            codecType: fourCharacterCode("avc1"),
            width: 1920,
            height: 1080
        )

        let result = AVFoundationUploadInputMetadataReader.inspect(
            videoTracks: [
                AVFoundationVideoTrackMetadata(
                    formatDescriptions: [formatDescription],
                    preferredTransform: .identity,
                    nominalFrameRate: 30,
                    estimatedDataRate: 7_500_000
                )
            ],
            audioTracks: nil
        )

        XCTAssertEqual(result.mediaFacts.videoCodec, .known(.h264))
        XCTAssertEqual(
            result.mediaFacts.displayDimensions,
            .known(.init(width: 1920, height: 1080))
        )
        XCTAssertEqual(result.mediaFacts.audio, .unknown)
        XCTAssertEqual(result.metadata.audioTrackCount, .unknown)
    }

    func testMultipleTracksAreCountedAndAmbiguousAudioIsUnknown() {
        let emptyVideo = AVFoundationVideoTrackMetadata(
            formatDescriptions: [],
            preferredTransform: .identity,
            nominalFrameRate: 0,
            estimatedDataRate: 0
        )
        let emptyAudio = AVFoundationAudioTrackMetadata(formatDescriptions: [])

        let result = AVFoundationUploadInputMetadataReader.inspect(
            videoTracks: [emptyVideo, emptyVideo],
            audioTracks: [emptyAudio, emptyAudio]
        )

        XCTAssertEqual(result.metadata.videoTrackCount, 2)
        XCTAssertEqual(result.metadata.audioTrackCount, .known(2))
        XCTAssertEqual(result.mediaFacts.videoCodec, .unknown)
        XCTAssertEqual(result.mediaFacts.audio, .unknown)
    }

    func testReadsKnownUnsupportedHEVCPixelFormat() throws {
        var hevcConfiguration = Data(repeating: 0, count: 19)
        hevcConfiguration[0] = 1
        hevcConfiguration[16] = 2
        hevcConfiguration[17] = 4
        hevcConfiguration[18] = 4
        let formatDescription = try makeVideoFormatDescription(
            codecType: fourCharacterCode("hvc1"),
            width: 1920,
            height: 1080,
            extensions: [
                swiftString(
                    kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms
                ): ["hvcC": hevcConfiguration]
            ]
        )

        let result = AVFoundationUploadInputMetadataReader.inspect(
            videoTracks: [
                AVFoundationVideoTrackMetadata(
                    formatDescriptions: [formatDescription],
                    preferredTransform: .identity,
                    nominalFrameRate: 30,
                    estimatedDataRate: 8_000_000
                )
            ],
            audioTracks: []
        )

        XCTAssertEqual(
            result.mediaFacts.pixelFormat,
            .known(.init(bitDepth: 12, chromaSubsampling: .other))
        )
    }

    func testReadsKnownUnsupportedAVCPixelFormat() throws {
        let formatDescription = try makeVideoFormatDescription(
            codecType: fourCharacterCode("avc1"),
            width: 1920,
            height: 1080,
            extensions: [
                swiftString(
                    kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms
                ): [
                    "avcC": Data([
                        1, 100, 0, 40, 0xff, 0xe0, 0,
                        0xfe, 0xfa, 0xfa
                    ])
                ]
            ]
        )

        let result = AVFoundationUploadInputMetadataReader.inspect(
            videoTracks: [
                AVFoundationVideoTrackMetadata(
                    formatDescriptions: [formatDescription],
                    preferredTransform: .identity,
                    nominalFrameRate: 30,
                    estimatedDataRate: 8_000_000
                )
            ],
            audioTracks: []
        )

        XCTAssertEqual(
            result.mediaFacts.pixelFormat,
            .known(.init(bitDepth: 10, chromaSubsampling: .other))
        )
    }

    func testDoesNotReadExtendedAVCFieldsForSVCProfile() throws {
        let formatDescription = try makeVideoFormatDescription(
            codecType: fourCharacterCode("avc1"),
            width: 1920,
            height: 1080,
            extensions: [
                swiftString(
                    kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms
                ): [
                    "avcC": Data([
                        1, 83, 0, 40, 0xff, 0xe0, 0,
                        0xfd, 0xfa, 0xfa
                    ])
                ]
            ]
        )

        let result = AVFoundationUploadInputMetadataReader.inspect(
            videoTracks: [
                AVFoundationVideoTrackMetadata(
                    formatDescriptions: [formatDescription],
                    preferredTransform: .identity,
                    nominalFrameRate: 30,
                    estimatedDataRate: 8_000_000
                )
            ],
            audioTracks: []
        )

        XCTAssertEqual(result.mediaFacts.pixelFormat, .unknown)
    }

    func testVideoInspectionFailurePreservesKnownAudioFacts() throws {
        let audioFormatDescription = try makeAudioFormatDescription(
            formatID: kAudioFormatMPEG4AAC,
            channelCount: 2
        )

        let result = AVFoundationUploadInputInspector()
            .makeVideoInspectionFailureResult(
                videoTrackCount: 1,
                audioMetadata: [
                    AVFoundationAudioTrackMetadata(
                        formatDescriptions: [audioFormatDescription]
                    )
                ]
            )

        XCTAssertEqual(result.mediaFacts.audio, .known(.aac(.stereo)))
        XCTAssertEqual(result.metadata.videoTrackCount, 1)
        XCTAssertEqual(result.metadata.audioTrackCount, .known(1))
        XCTAssertEqual(result.mediaFacts.videoCodec, .unknown)
    }

    func testInspectorReturnsTrackCountsWithMultiVideoFallback() {
        let asset = AVMutableComposition()
        XCTAssertNotNil(
            asset.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )
        )
        XCTAssertNotNil(
            asset.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )
        )
        let completion = expectation(description: "inspection completes")

        AVFoundationUploadInputInspector().performInspection(
            sourceInput: asset,
            maximumResolution: .default
        ) { result, duration, error in
            XCTAssertEqual(result?.metadata.videoTrackCount, 2)
            XCTAssertEqual(result?.metadata.audioTrackCount, .known(0))
            XCTAssertEqual(duration, .zero)
            XCTAssertNotNil(error)
            completion.fulfill()
        }

        wait(for: [completion], timeout: 2)
    }

    private func makeVideoFormatDescription(
        codecType: CMVideoCodecType,
        width: Int32,
        height: Int32,
        extensions: [String: Any] = [:]
    ) throws -> CMVideoFormatDescription {
        var formatDescription: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: codecType,
            width: width,
            height: height,
            extensions: extensions as CFDictionary,
            formatDescriptionOut: &formatDescription
        )
        XCTAssertEqual(status, noErr)
        return try XCTUnwrap(formatDescription)
    }

    private func makeAudioFormatDescription(
        formatID: AudioFormatID,
        channelCount: UInt32
    ) throws -> CMAudioFormatDescription {
        var streamDescription = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: formatID,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 1024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: channelCount,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        var formatDescription: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &streamDescription,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        XCTAssertEqual(status, noErr)
        return try XCTUnwrap(formatDescription)
    }

    private func swiftString(_ value: CFString) -> String {
        value as String
    }

    private func fourCharacterCode(_ value: String) -> FourCharCode {
        value.utf8.reduce(0) { partialResult, byte in
            partialResult << 8 | FourCharCode(byte)
        }
    }
}
