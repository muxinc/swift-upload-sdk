//
//  UploadFailedEvent.swift
//

import Foundation

struct UploadFailedEvent: Codable {
    var type: String = "upload_failed"
    var sessionID: String
    var version: String = "1"
    var data: Data

    struct Data: Codable {
        var appName: String?
        var appVersion: String?
        var deviceModel: String
        var errorDescription: String
        var inputDuration: Double
        var inputSize: UInt64
        var inputStandardizationRequested: Bool
        var platformName: String
        var platformVersion: String
        var regionCode: String?
        var sdkVersion: String
        var uploadStartTime: Date
        var uploadEndTime: Date
        var uploadURL: URL
    }
}
