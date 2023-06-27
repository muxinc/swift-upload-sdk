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

    case inspectionFailure
    case standard
    case nonstandard([NonstandardInputReason])

    var isStandard: Bool {
        if case Self.standard = self {
            return true
        } else {
            return false
        }
    }

    var nonstandardInputReasons: [NonstandardInputReason]? {
        if case Self.nonstandard(let nonstandardInputReasons) = self {
            return nonstandardInputReasons
        } else {
            return nil
        }
    }

}
