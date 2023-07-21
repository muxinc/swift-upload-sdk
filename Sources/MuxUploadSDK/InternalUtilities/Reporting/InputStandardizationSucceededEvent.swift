//
//  InputStandardizationSucceededEvent.swift
//  

import Foundation

struct InputStandardizationSucceededEvent: Codable {
    var type: String = "upload_input_standardization_succeeded"
    var sessionID: String
    var version: String = "1"
    var data: Data

    struct Data: Codable {
        var appName: String?
        var appVersion: String?
        var deviceModel: String
        var inputDuration: Double
        var inputSize: UInt64
        var maximumResolution: String
        var nonStandardInputReasons: [String]
        var platformName: String
        var platformVersion: String
        var regionCode: String?
        var sdkVersion: String
        var standardizationStartTime: Date
        var standardizationEndTime: Date
        var uploadURL: URL
    }
}
