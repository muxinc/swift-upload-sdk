//
//  UploadInputFormatInspectionResult.swift
//

import AVFoundation
import Foundation

struct UploadInputFormatInspectionResult {
    enum NonstandardInputReason {
        case videoCodec
        case audioCodec
        case videoGOPSize
        case videoFrameRate
        case videoResolution
        case videoBitrate
        case pixelAspectRatio
        case videoEditList
        case audioEditList
        case unexpectedMediaFileParameters
        case unsupportedPixelFormat
    }

    var nonStandardInputReasons: [NonstandardInputReason] = []

    var isStandardInput: Bool {
        nonStandardInputReasons.isEmpty
    }

    struct RescalingDetails {
        var maximumDesiredResolutionPreset: DirectUploadOptions.InputStandardization.MaximumResolution = .default

        var recordedResolution: CMVideoDimensions = CMVideoDimensions(width: 0, height: 0)

        var needsRescaling: Bool {
            switch maximumDesiredResolutionPreset {
            case .default, .preset1920x1080:
                if max(recordedResolution.width, recordedResolution.height) > 1920 {
                    return true
                } else {
                    return false
                }
            case .preset1280x720:
                if max(recordedResolution.width, recordedResolution.height) > 1280 {
                    return true
                } else {
                    return false
                }
            case .preset3840x2160:
                if max(recordedResolution.width, recordedResolution.height) > 3840 {
                    return true
                } else {
                    return false
                }
            }
        }
    }

    var rescalingDetails: RescalingDetails = RescalingDetails()
}

extension UploadInputFormatInspectionResult.NonstandardInputReason: CustomStringConvertible {
    var description: String {
        switch self {
        case .audioCodec:
            return "audio_codec"
        case .audioEditList:
            return "audio_edit_list"
        case .pixelAspectRatio:
            return "pixel_aspect_ratio"
        case .videoBitrate:
            return "video_bitrate"
        case .videoCodec:
            return "video_codec"
        case .videoEditList:
            return "video_edit_list"
        case .videoFrameRate:
            return "video_frame_rate"
        case .videoGOPSize:
            return "video_gop_size"
        case .videoResolution:
            return "video_resolution"
        case .unexpectedMediaFileParameters:
            return "unexpected_media_file_parameters"
        case .unsupportedPixelFormat:
            return "unsupported_pixel_format"
        }
    }
}
