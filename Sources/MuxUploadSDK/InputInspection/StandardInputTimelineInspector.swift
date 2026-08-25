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
        track: AVAssetTrack,
        operation: UploadInputInspectionOperation
    ) async -> TimeInterval? {
        guard !(await operation.isCancelled) else { return nil }
        guard let timeRange = try? await track.load(.timeRange),
              !(await operation.isCancelled) else { return nil }
        return presentationStart(in: timeRange)
    }

    static func presentationStart(in timeRange: CMTimeRange) -> TimeInterval? {
        let seconds = timeRange.start.seconds
        return seconds.isFinite ? seconds : nil
    }
}
