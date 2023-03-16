//
//  Reporter.swift
//  
//
//  Created by Liam Lindner on 3/16/23.
//

import Foundation
import UIKit

struct UploadEvent: Codable {
    var type = "upload"
    var duration: String

    var os_name: String
    var os_version: String

    var device_model: String

    var app_name: String
    var app_version: String

    init(duration: String) {
        self.duration = duration

        let device = UIDevice.current

        self.os_name = device.systemName
        self.os_version = device.systemVersion

        self.device_model = device.model

        self.app_name = Bundle.main.appName ?? ""
        self.app_version = Bundle.main.appVersion ?? ""
    }
}

public final class Reporter {
    let url = URL(string: "https://mobile-analytics.mux.dev/api/events")
    var request: URLRequest

    init() {
        guard let requestUrl = url else { fatalError() }
        request = URLRequest(url: requestUrl)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }

    func report(duration: String) -> Void {
        let newUploadEvent = UploadEvent(duration: duration)
        do {
            let jsonData = try JSONEncoder().encode(newUploadEvent)
            request.httpBody = jsonData
            let task = URLSession.shared.dataTask(with: request) { (data, response, error) in
                if let error = error {
                    print("Error took place \(error)")
                    return
                }
            }
            task.resume()
        } catch _ as NSError {}
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
