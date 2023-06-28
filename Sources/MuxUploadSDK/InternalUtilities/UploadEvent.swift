//
//  UploadEvent.swift
//  
//
//  Created by Liam Lindner on 3/22/23.
//

import Foundation

struct UploadEvent: Codable {
    var type = "upload"
    var startTime: TimeInterval
    var endTime: TimeInterval
    var fileSize: UInt64
    var videoDuration: Double
    var uploadURL: URL

    var sdkVersion: String

    var osName: String
    var osVersion: String

    var deviceModel: String

    var appName: String?
    var appVersion: String?

    var regionCode: String?
}

extension Bundle {
    var appName: String? {
        return object(forInfoDictionaryKey: "CFBundleName") as? String
    }

    var appVersion: String? {
        return object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }
}
