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

        // FIXME: If this fails, an event without a payload
        // is sent which probably isn't what we want
        do {
            let httpBody = try serializePendingEvent()
            let request = self.generateRequest(
                url: URL(string: "https://mobile.muxanalytics.com")!,
                httpBody: httpBody
            )
            let dataTask = session?.dataTask(with: request as URLRequest, completionHandler: { (data, response, error) -> Void in
                self.pendingUploadEvent = nil
            })
            dataTask?.resume()
        } catch _ as NSError {}
    }

    func serializePendingEvent() throws -> Data {
        return try jsonEncoder.encode(pendingUploadEvent)
    }

    private func generateRequest(
        url: URL,
        httpBody: Data
    ) -> URLRequest {
        let request = NSMutableURLRequest(url: url,
                                          cachePolicy: .useProtocolCachePolicy,
                                          timeoutInterval: 10.0)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = httpBody

        return request as URLRequest
    }
}

// TODO: Implement as a separate object so the URLSession
// can become non-optional, which removes a bunch of edge cases
extension Reporter: URLSessionDelegate, URLSessionTaskDelegate {
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Swift.Void) {
        if(self.pendingUploadEvent != nil) {
            if let redirectUrl = request.url, let httpBody = try? serializePendingEvent() {
                let request = self.generateRequest(
                    url: redirectUrl,
                    httpBody: httpBody
                )
                completionHandler(request)
            }
        }
    }
}
