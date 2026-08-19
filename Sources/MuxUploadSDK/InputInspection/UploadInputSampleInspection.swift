//
//  UploadInputSampleInspection.swift
//

@preconcurrency import AVFoundation
import CoreMedia
import Foundation

struct UploadInputCompressedSampleObservation: Equatable {
    enum SyncState: Equatable {
        case sync
        case notSync
        case unknown
    }

    enum RandomAccessKind: Equatable {
        case idr
        case openGOP
        case unknown
    }

    let presentationTime: TimeInterval
    let duration: TimeInterval
    let byteCount: Int64
    let syncState: SyncState
    let randomAccessKind: RandomAccessKind
    let dependsOnOthers: Bool?
}

enum UploadInputCompressedSampleAggregator {
    static func inspect(
        _ samples: [UploadInputCompressedSampleObservation]
    ) -> StandardInputMediaFacts {
        var accumulator = Accumulator()
        for sample in samples {
            accumulator.append(sample)
        }
        return accumulator.finish()
    }

    struct Accumulator {
        private var isUsable = true
        private var hasSamples = false
        private var currentStart: TimeInterval = 0
        private var currentEnd: TimeInterval = 0
        private var currentBytes: Int64 = 0
        private var maximumBytes: Int64 = 0
        private var maximumDuration: TimeInterval = 0
        private var maximumBitrate: Double = 0
        private var hasUnknownRandomAccessKind = false
        private var hasOpenRandomAccessPoint = false

        mutating func append(_ sample: UploadInputCompressedSampleObservation) {
            guard isUsable,
                  UploadInputCompressedSampleAggregator.isValid(sample),
                  hasSamples || sample.syncState == .sync else {
                isUsable = false
                return
            }

            if sample.syncState == .sync {
                // Compressed samples arrive in decode order. A full sync sample closes
                // the preceding byte window, while presentation times define its duration.
                if currentBytes > 0,
                   !UploadInputCompressedSampleAggregator.finalizeGOP(
                    byteCount: currentBytes,
                    duration: sample.presentationTime - currentStart,
                    maximumBytes: &maximumBytes,
                    maximumDuration: &maximumDuration,
                    maximumBitrate: &maximumBitrate
                   ) {
                    isUsable = false
                    return
                }
                currentStart = sample.presentationTime
                currentEnd = sample.presentationTime + sample.duration
                currentBytes = 0
                switch sample.dependsOnOthers == true ? .unknown : sample.randomAccessKind {
                case .idr:
                    break
                case .openGOP:
                    hasOpenRandomAccessPoint = true
                case .unknown:
                    hasUnknownRandomAccessKind = true
                }
            } else if sample.syncState == .unknown {
                isUsable = false
                return
            }

            let (nextBytes, overflow) = currentBytes.addingReportingOverflow(
                sample.byteCount
            )
            guard !overflow else {
                isUsable = false
                return
            }
            currentBytes = nextBytes
            currentEnd = max(currentEnd, sample.presentationTime + sample.duration)
            hasSamples = true
        }

        mutating func finish() -> StandardInputMediaFacts {
            var facts = StandardInputMediaFacts()
            guard isUsable,
                  hasSamples,
                  UploadInputCompressedSampleAggregator.finalizeGOP(
                    byteCount: currentBytes,
                    duration: currentEnd - currentStart,
                    maximumBytes: &maximumBytes,
                    maximumDuration: &maximumDuration,
                    maximumBitrate: &maximumBitrate
                  ),
                  maximumBitrate <= Double(Int64.max) else {
                return facts
            }

            facts.maximumKeyframeInterval = .known(maximumDuration)
            // Open GOPs can contain leading pictures that follow a random-access
            // sample in decode order while preceding it in presentation order.
            // Their bytes cannot be assigned reliably to either adjacent GOP.
            if !hasOpenRandomAccessPoint {
                facts.maximumGOPByteSize = .known(maximumBytes)
                facts.maximumGOPBitrate = .known(Int64(maximumBitrate.rounded()))
            }
            if !hasUnknownRandomAccessKind {
                facts.gopStructure = hasOpenRandomAccessPoint
                    ? .known(.open) : .known(.closedWithIDR)
            }
            return facts
        }
    }

    private static func isValid(
        _ sample: UploadInputCompressedSampleObservation
    ) -> Bool {
        // Edit-list preroll may have negative presentation timestamps. The
        // interval remains measurable when a preceding sync boundary is present.
        sample.presentationTime.isFinite
            && sample.duration.isFinite
            && sample.duration > 0
            && sample.byteCount > 0
    }

    private static func finalizeGOP(
        byteCount: Int64,
        duration: TimeInterval,
        maximumBytes: inout Int64,
        maximumDuration: inout TimeInterval,
        maximumBitrate: inout Double
    ) -> Bool {
        guard byteCount > 0, duration.isFinite, duration > 0 else {
            return false
        }

        maximumBytes = max(maximumBytes, byteCount)
        maximumDuration = max(maximumDuration, duration)
        maximumBitrate = max(
            maximumBitrate,
            Double(byteCount) * 8 / duration
        )
        return maximumBitrate.isFinite
    }

}

enum AVFoundationUploadInputSampleReader {
    static func inspect(
        asset: AVAsset,
        videoTrack: AVAssetTrack,
        codec: StandardInputFact<StandardInputVideoCodec>,
        operation: UploadInputInspectionOperation? = nil
    ) async -> StandardInputMediaFacts {
        guard (await operation?.isCancelled) != true else { return StandardInputMediaFacts() }
        guard let codec = codec.value,
              codec == .h264 || codec == .hevc else {
            return StandardInputMediaFacts()
        }
        guard let reader = try? AVAssetReader(asset: asset) else {
            return StandardInputMediaFacts()
        }

        let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        // Nil output settings preserve the stored compressed representation and avoid
        // decoding. NAL data is copied only for the relatively infrequent sync samples.
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            return StandardInputMediaFacts()
        }
        reader.add(output)
        guard reader.startReading() else {
            return StandardInputMediaFacts()
        }
        guard await operation?.register(assetReader: reader) ?? true else {
            return StandardInputMediaFacts()
        }

        var accumulator = UploadInputCompressedSampleAggregator.Accumulator()
        while (await operation?.isCancelled) != true,
              let sampleBuffer = output.copyNextSampleBuffer() {
            // Readers may vend zero-sample marker buffers before media samples.
            if CMSampleBufferGetNumSamples(sampleBuffer) == 0 {
                continue
            }
            autoreleasepool {
                if let observation = makeObservation(
                    sampleBuffer,
                    codec: codec
                ) {
                    accumulator.append(observation)
                } else {
                    reader.cancelReading()
                }
            }
            if reader.status == .cancelled {
                return StandardInputMediaFacts()
            }
        }

        guard (await operation?.isCancelled) != true else {
            reader.cancelReading()
            return StandardInputMediaFacts()
        }
        guard reader.status == .completed else {
            return StandardInputMediaFacts()
        }
        return accumulator.finish()
    }

    private static func makeObservation(
        _ sampleBuffer: CMSampleBuffer,
        codec: StandardInputVideoCodec
    ) -> UploadInputCompressedSampleObservation? {
        guard CMSampleBufferGetNumSamples(sampleBuffer) == 1,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer,
                createIfNecessary: false
              ),
              let attachment = (attachments as NSArray).firstObject
                as? NSDictionary else {
            return nil
        }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let duration = CMSampleBufferGetDuration(sampleBuffer)
        let isNotSync = boolean(
            attachment[kCMSampleAttachmentKey_NotSync]
        ) ?? false
        let isPartialSync = boolean(
            attachment[kCMSampleAttachmentKey_PartialSync]
        ) ?? false
        let syncState: UploadInputCompressedSampleObservation.SyncState =
            isNotSync || isPartialSync ? .notSync : .sync

        let randomAccessKind: UploadInputCompressedSampleObservation.RandomAccessKind
        if syncState == .sync {
            randomAccessKind = inspectRandomAccessKind(
                sampleBuffer,
                codec: codec,
                attachment: attachment
            )
        } else {
            randomAccessKind = .unknown
        }

        return UploadInputCompressedSampleObservation(
            presentationTime: CMTimeGetSeconds(presentationTime),
            duration: CMTimeGetSeconds(duration),
            byteCount: Int64(CMSampleBufferGetTotalSampleSize(sampleBuffer)),
            syncState: syncState,
            randomAccessKind: randomAccessKind,
            dependsOnOthers: boolean(
                attachment[kCMSampleAttachmentKey_DependsOnOthers]
            )
        )
    }

    private static func inspectRandomAccessKind(
        _ sampleBuffer: CMSampleBuffer,
        codec: StandardInputVideoCodec,
        attachment: NSDictionary
    ) -> UploadInputCompressedSampleObservation.RandomAccessKind {
        let attachmentKind: UploadInputCompressedSampleObservation.RandomAccessKind?
        if codec == .hevc,
           let nalUnitType = (attachment[
            kCMSampleAttachmentKey_HEVCSyncSampleNALUnitType
           ] as? NSNumber)?.intValue {
            attachmentKind = randomAccessKind(codec: codec, nalUnitTypes: [nalUnitType])
        } else {
            attachmentKind = nil
        }

        guard let data = compressedData(sampleBuffer),
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let lengthFieldSize = nalUnitLengthFieldSize(formatDescription, codec: codec),
              let nalUnitTypes = nalUnitTypes(
                in: data,
                lengthFieldSize: lengthFieldSize,
                codec: codec
              ) else {
            return attachmentKind ?? .unknown
        }

        let parsedKind = randomAccessKind(codec: codec, nalUnitTypes: nalUnitTypes)
        guard let attachmentKind else {
            return parsedKind
        }
        return attachmentKind == parsedKind ? parsedKind : .unknown
    }

    static func nalUnitTypes(
        in data: Data,
        lengthFieldSize: Int,
        codec: StandardInputVideoCodec
    ) -> [Int]? {
        guard (1...4).contains(lengthFieldSize) else {
            return nil
        }

        var offset = 0
        var types: [Int] = []
        while offset < data.count {
            guard data.count - offset >= lengthFieldSize else {
                return nil
            }
            var nalUnitLength = 0
            for index in 0..<lengthFieldSize {
                nalUnitLength = (nalUnitLength << 8) | Int(data[offset + index])
            }
            offset += lengthFieldSize
            guard nalUnitLength > 0,
                  nalUnitLength <= data.count - offset else {
                return nil
            }

            let firstByte = data[offset]
            switch codec {
            case .h264:
                types.append(Int(firstByte & 0x1f))
            case .hevc:
                guard nalUnitLength >= 2 else {
                    return nil
                }
                types.append(Int((firstByte >> 1) & 0x3f))
            case .other:
                return nil
            }
            offset += nalUnitLength
        }
        return types
    }

    static func randomAccessKind(
        codec: StandardInputVideoCodec,
        nalUnitTypes: [Int]
    ) -> UploadInputCompressedSampleObservation.RandomAccessKind {
        switch codec {
        case .h264:
            let vclTypes = nalUnitTypes.filter { (1...5).contains($0) }
            guard !vclTypes.isEmpty else {
                return .unknown
            }
            return vclTypes.contains(5) ? .idr : .openGOP
        case .hevc:
            let vclTypes = nalUnitTypes.filter { (0...31).contains($0) }
            guard !vclTypes.isEmpty else {
                return .unknown
            }
            if vclTypes.contains(where: { (19...20).contains($0) }) {
                return vclTypes.contains(where: { (16...18).contains($0) || $0 == 21 })
                    ? .unknown : .idr
            }
            return vclTypes.contains(where: { (16...18).contains($0) || $0 == 21 })
                ? .openGOP : .unknown
        case .other:
            return .unknown
        }
    }

    private static func nalUnitLengthFieldSize(
        _ formatDescription: CMFormatDescription,
        codec: StandardInputVideoCodec
    ) -> Int? {
        let extensions = CMFormatDescriptionGetExtensions(formatDescription)
            as NSDictionary?
        let atoms = extensions?[
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms
        ] as? NSDictionary
        let atomName = codec == .h264 ? "avcC" : "hvcC"
        guard let configuration = atoms?[atomName] as? Data else {
            return nil
        }

        switch codec {
        case .h264 where configuration.count > 4:
            return Int(configuration[4] & 0x03) + 1
        case .hevc where configuration.count > 21:
            return Int(configuration[21] & 0x03) + 1
        default:
            return nil
        }
    }

    private static func compressedData(_ sampleBuffer: CMSampleBuffer) -> Data? {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return nil
        }
        let length = CMBlockBufferGetDataLength(blockBuffer)
        guard length > 0 else {
            return nil
        }
        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                return kCMBlockBufferBadPointerParameterErr
            }
            return CMBlockBufferCopyDataBytes(
                blockBuffer,
                atOffset: 0,
                dataLength: length,
                destination: baseAddress
            )
        }
        return status == kCMBlockBufferNoErr ? data : nil
    }

    private static func boolean(_ value: Any?) -> Bool? {
        (value as? NSNumber)?.boolValue
    }
}

extension StandardInputMediaFacts {
    mutating func mergeGOPFacts(from other: StandardInputMediaFacts) {
        maximumGOPBitrate = other.maximumGOPBitrate
        maximumGOPByteSize = other.maximumGOPByteSize
        maximumKeyframeInterval = other.maximumKeyframeInterval
        gopStructure = other.gopStructure
    }
}
