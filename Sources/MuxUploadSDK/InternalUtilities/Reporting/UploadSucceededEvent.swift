//
//  UploadSucceededEvent.swift
//  
//
//  Created by Liam Lindner on 3/22/23.
//

import Foundation

struct UploadSucceededEvent: Codable {
    var type: String = "upload_succeeded"
    var sessionID: String
    var version: String = "1"
    var data: Data

    struct Data: Codable {
        var appName: String?
        var appVersion: String?
        var deviceModel: String
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
