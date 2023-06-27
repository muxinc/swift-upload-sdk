//
//  UploadEvent.swift
//  
//
//  Created by Liam Lindner on 3/22/23.
//

import Foundation
import UIKit

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

extension UploadEvent {
    init(
        startTime: TimeInterval,
        endTime: TimeInterval,
        fileSize: UInt64,
        videoDuration: Double,
        uploadURL: URL
    ) {
        let locale = Locale.current
        let device = UIDevice.current

        self.startTime = startTime
        self.endTime = endTime
        self.fileSize = fileSize
        self.videoDuration = videoDuration
        self.uploadURL = uploadURL

        self.sdkVersion = Version.versionString

        self.osName = device.systemName
        self.osVersion = device.systemVersion

        self.deviceModel = device.model

        self.appName = Bundle.main.bundleIdentifier
        self.appVersion = Bundle.main.appVersion

        if #available(iOS 16, *) {
            self.regionCode = locale.language.region?.identifier
        } else {
            self.regionCode = locale.regionCode
        }
    }
}

extension Bundle {
    var appName: String? {
        return object(forInfoDictionaryKey: "CFBundleName") as? String
    }

    var appVersion: String? {
        return object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }
}
