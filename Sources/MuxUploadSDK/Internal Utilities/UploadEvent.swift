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
    var start_time: TimeInterval
    var end_time: TimeInterval
    var file_size: UInt64
    var video_duration: Double

    var sdk_version: String

    var os_name: String
    var os_version: String

    var device_model: String

    var app_name: String?
    var app_version: String?

    var regionCode: String?

    init(start_time: TimeInterval, end_time: TimeInterval, file_size: UInt64, video_duration: Double) {
        let locale = Locale.current
        let device = UIDevice.current

        self.start_time = start_time
        self.end_time = end_time
        self.file_size = file_size
        self.video_duration = video_duration

        self.sdk_version = "0.2.0" // TODO Read from properties

        self.os_name = device.systemName
        self.os_version = device.systemVersion

        self.device_model = device.model

        self.app_name = Bundle.main.appName
        self.app_version = Bundle.main.appVersion

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
