//
//  Reporter.swift
//  
//
//  Created by Liam Lindner on 3/16/23.
//

import Foundation
import UIKit

class Reporter: NSObject {
    var session: URLSession?
    var pendingUploadEvent: UploadEvent?

    var jsonEncoder: JSONEncoder

    override init() {
        let jsonEncoder = JSONEncoder()
        jsonEncoder.keyEncodingStrategy = JSONEncoder.KeyEncodingStrategy.convertToSnakeCase
        jsonEncoder.outputFormatting = .sortedKeys
        self.jsonEncoder = jsonEncoder

        super.init()

        let sessionConfig: URLSessionConfiguration = URLSessionConfiguration.default
        session = URLSession(configuration: sessionConfig, delegate: self, delegateQueue: nil)
    }

    func report(
        startTime: TimeInterval,
        endTime: TimeInterval,
        fileSize: UInt64,
        videoDuration: Double,
        uploadURL: URL
    ) -> Void {

        // TODO: Set these using dependency Injection
        let locale = Locale.current
        let device = UIDevice.current

        let regionCode: String?
        if #available(iOS 16, *) {
            regionCode = locale.language.region?.identifier
        } else {
            regionCode = locale.regionCode
        }

        self.pendingUploadEvent = UploadEvent(
            startTime: startTime,
            endTime: endTime,
            fileSize: fileSize,
            videoDuration: videoDuration,
            uploadURL: uploadURL,
            sdkVersion: Version.versionString,
            osName: device.systemName,
            osVersion: device.systemVersion,
            deviceModel: device.model,
            appName: Bundle.main.bundleIdentifier,
            appVersion: Bundle.main.appVersion,
            regionCode: regionCode
        )

        let request = self.generateRequest(url: URL(string: "https://mobile.muxanalytics.com")!)

        let dataTask = session?.dataTask(with: request as URLRequest, completionHandler: { (data, response, error) -> Void in
            self.pendingUploadEvent = nil
        })
        dataTask?.resume()
    }

    func serializePendingEvent() throws -> Data {
        return try jsonEncoder.encode(pendingUploadEvent)
    }

    private func generateRequest(url: URL) -> URLRequest {
        let request = NSMutableURLRequest(url: url,
                                          cachePolicy: .useProtocolCachePolicy,
                                          timeoutInterval: 10.0)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            let jsonData = try serializePendingEvent()
            request.httpBody = jsonData
        } catch _ as NSError {}

        return request as URLRequest
    }
}

extension Reporter: URLSessionDelegate, URLSessionTaskDelegate {
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Swift.Void) {
        if(self.pendingUploadEvent != nil) {
            if let redirectUrl = request.url {
                let request = self.generateRequest(url: redirectUrl)
                completionHandler(request)
            }
        }
    }
}
