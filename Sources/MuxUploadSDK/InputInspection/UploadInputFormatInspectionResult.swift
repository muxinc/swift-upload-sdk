//
//  UploadInputFormatInspectionResult.swift
//

import AVFoundation
import Foundation

enum UploadInputFormatInspectionResult {

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

    case inspectionFailure(duration: CMTime)
    case standard(duration: CMTime)
    case nonstandard(
        reasons: [NonstandardInputReason],
        duration: CMTime
    )

    var isStandard: Bool {
        if case Self.standard = self {
            return true
        } else {
            return false
        }
    }

    var sourceInputDuration: CMTime {
        switch self {
        case .inspectionFailure(duration: let duration):
            return duration
        case .standard(duration: let duration):
            return duration
        case .nonstandard(_, duration: let duration):
            return duration
        }
    }

    var nonstandardInputReasons: [NonstandardInputReason]? {
        if case Self.nonstandard(let nonstandardInputReasons, _) = self {
            return nonstandardInputReasons
        } else {
            return nil
        }
    }

}
