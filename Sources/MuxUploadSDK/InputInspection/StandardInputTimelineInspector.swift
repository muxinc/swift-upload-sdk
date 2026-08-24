//
//  StandardInputTimelineInspector.swift
//

@preconcurrency import AVFoundation
import CoreMedia
import Foundation

enum StandardInputTimelineInspector {
    static func inspect(
        asset: AVAsset,
        videoTrack: AVAssetTrack,
        audioTrack: AVAssetTrack?,
        duration: CMTime,
        operation: UploadInputInspectionOperation
    ) async -> StandardInputTimelineFacts {
        let durationSeconds = duration.seconds
        let durationFact: StandardInputFact<TimeInterval> = durationSeconds.isFinite
                && durationSeconds > 0
            ? .known(durationSeconds)
            : .unknown

        guard let videoStart = await firstPresentationTime(
            asset: asset,
            track: videoTrack,
            operation: operation
        ) else {
            return StandardInputTimelineFacts(duration: durationFact)
        }

        guard let audioTrack else {
            return StandardInputTimelineFacts(
                duration: durationFact,
                audioVideoStartOffset: .known(.notApplicable)
            )
        }
        guard let audioStart = await firstPresentationTime(
            asset: asset,
            track: audioTrack,
            operation: operation
        ) else {
            return StandardInputTimelineFacts(duration: durationFact)
        }

        return StandardInputTimelineFacts(
            duration: durationFact,
            audioVideoStartOffset: .known(.seconds(audioStart - videoStart))
        )
    }

    private static func firstPresentationTime(
        asset: AVAsset,
        track: AVAssetTrack,
        operation: UploadInputInspectionOperation
    ) async -> TimeInterval? {
        guard !(await operation.isCancelled) else { return nil }
        guard let reader = try? AVAssetReader(asset: asset) else { return nil }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading(),
              await operation.register(assetReader: reader) else {
            return nil
        }
        while let sample = output.copyNextSampleBuffer() {
            guard !(await operation.isCancelled) else {
                reader.cancelReading()
                return nil
            }
            guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
            let seconds = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            reader.cancelReading()
            return seconds.isFinite ? seconds : nil
        }
        return nil
    }
}
