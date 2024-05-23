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

    var reasons: [NonstandardInputReason]

    var isStandardInput: Bool {
        reasons.isEmpty
    }
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
