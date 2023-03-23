//
//  Reporter.swift
//  
//
//  Created by Liam Lindner on 3/16/23.
//

import Foundation

class Reporter: NSObject {
    var session: URLSession?
    var pendingUploadEvent: UploadEvent?

    // MARK: - Constructor -
    static let sharedInstance = Reporter()

    fileprivate override init() {
        super.init()

        let sessionConfig: URLSessionConfiguration = URLSessionConfiguration.default
        session = URLSession(configuration: sessionConfig, delegate: self, delegateQueue: nil)
    }

    func report(startTime: TimeInterval, endTime: TimeInterval, fileSize: UInt64, videoDuration: Double) -> Void {
        self.pendingUploadEvent = UploadEvent(startTime: startTime, endTime: endTime, fileSize: fileSize, videoDuration: videoDuration)

        let request = self.generateRequest(url: URL(string: "https://mobile.muxanalytics.com")!)

        let dataTask = session?.dataTask(with: request as URLRequest, completionHandler: { (data, response, error) -> Void in
            self.pendingUploadEvent = nil
        })
        dataTask?.resume()
    }

    private func generateRequest(url: URL) -> URLRequest {
        let request = NSMutableURLRequest(url: url,
                                          cachePolicy: .useProtocolCachePolicy,
                                          timeoutInterval: 10.0)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = JSONEncoder.KeyEncodingStrategy.convertToSnakeCase
            let jsonData = try encoder.encode(self.pendingUploadEvent)
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
