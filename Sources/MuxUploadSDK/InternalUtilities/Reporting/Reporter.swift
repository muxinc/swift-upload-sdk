//
//  Reporter.swift
//  
//
//  Created by Liam Lindner on 3/16/23.
//

import Foundation

fileprivate func processInfoOperationSystemVersion() -> String {
    let version = ProcessInfo().operatingSystemVersion
    return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
}

fileprivate func posixModelName() -> String {
    var systemName = utsname()
    uname(&systemName)
    return withUnsafePointer(to: &systemName.machine) {
        $0.withMemoryRebound(to: CChar.self, capacity: 1) {
            ptr in String.init(validatingUTF8: ptr)
        }
    } ?? "Unknown"
}

fileprivate func inferredPlatformName() -> String {
    let modelName = posixModelName().lowercased()
    if modelName.contains("ipad") {
        return "iPadOS"
    } else if modelName.contains("iphone") {
        return "iOS"
    } else {
        #if targetEnvironment(simulator)
        return "Simulator"
        #else
        return "Unknown"
        #endif
    }
}

class Reporter: NSObject {

    static let shared: Reporter = Reporter()

    var session: URLSession?

    var pendingEvents: [ObjectIdentifier: Codable] = [:]

    var jsonEncoder: JSONEncoder

    var sessionID: String = UUID().uuidString
    var url: URL
    var additionalHTTPHeaders: [String: String] {
        ["x-litix-sdk": "swift-upload-sdk"]
    }

    // TODO: Set these using dependency Injection
    var locale: Locale {
        Locale.current
    }

    let model: String
    let platformName: String
    let platformVersion: String

    var regionCode: String? {
        if #available(iOS 16, *) {
            return locale.language.region?.identifier
        } else {
            return locale.regionCode
        }
    }

    override init() {
        let jsonEncoder = JSONEncoder()
        jsonEncoder.keyEncodingStrategy = JSONEncoder.KeyEncodingStrategy.convertToSnakeCase
        jsonEncoder.outputFormatting = .sortedKeys
        jsonEncoder.dateEncodingStrategy = .iso8601
        self.jsonEncoder = jsonEncoder

        // TODO: throwable initializer after NSObject super
        // is removed
        self.url = URL(
            string: "https://mobile.muxanalytics.com"
        )!

        self.model = posixModelName()
        self.platformName = inferredPlatformName()
        self.platformVersion = processInfoOperationSystemVersion()

        super.init()

        let sessionConfig: URLSessionConfiguration = URLSessionConfiguration.default
        session = URLSession(configuration: sessionConfig, delegate: self, delegateQueue: nil)
    }

    func send<Event: Codable>(
        event: Event,
        url: URL
    ) {
        guard let httpBody = try? jsonEncoder.encode(event) else {
            return
        }

        let request = NSMutableURLRequest.makeJSONPost(
            url: url,
            httpBody: httpBody,
            additionalHTTPHeaders: additionalHTTPHeaders
        )

        guard let dataTask = session?.dataTask(
            with: request as URLRequest
        ) else {
            return
        }

        let taskID = ObjectIdentifier(dataTask)

        pendingEvents[
            taskID
        ] = event

        dataTask.resume()
    }
}

extension Reporter {
    func reportUploadSuccess(
        inputDuration: Double,
        inputSize: UInt64,
        options: DirectUploadOptions,
        uploadEndTime: Date,
        uploadStartTime: Date,
        uploadURL: URL
    ) -> Void {

        guard !options.eventTracking.optedOut else {
            return
        }

        let data = UploadSucceededEvent.Data(
            appName: Bundle.main.appName,
            appVersion: Bundle.main.appVersion,
            deviceModel: model,
            inputDuration: inputDuration,
            inputSize: inputSize,
            inputStandardizationRequested: options.inputStandardization.isRequested,
            platformName: platformName,
            platformVersion: platformVersion,
            regionCode: regionCode,
            sdkVersion: SemanticVersion.versionString,
            uploadStartTime: uploadStartTime,
            uploadEndTime: uploadEndTime,
            uploadURL: uploadURL
        )

        let event = UploadSucceededEvent(
            sessionID: sessionID,
            data: data
        )

        send(
            event: event,
            url: url
        )
    }

    func reportUploadFailure(
        errorDescription: String,
        inputDuration: Double,
        inputSize: UInt64,
        options: DirectUploadOptions,
        uploadEndTime: Date,
        uploadStartTime: Date,
        uploadURL: URL
    ) {
        guard !options.eventTracking.optedOut else {
            return
        }

        let data = UploadFailedEvent.Data(
            appName: Bundle.main.appName,
            appVersion: Bundle.main.appVersion,
            deviceModel: model,
            errorDescription: errorDescription,
            inputDuration: inputDuration,
            inputSize: inputSize,
            inputStandardizationRequested: options.inputStandardization.isRequested,
            platformName: platformName,
            platformVersion: platformVersion,
            regionCode: regionCode,
            sdkVersion: SemanticVersion.versionString,
            uploadStartTime: uploadStartTime,
            uploadEndTime: uploadEndTime,
            uploadURL: url
        )

        let event = UploadFailedEvent(
            sessionID: sessionID,
            data: data
        )

        send(
            event: event,
            url: url
        )
    }

    func reportUploadInputStandardizationSuccess(
        inputDuration: Double,
        inputSize: UInt64,
        options: DirectUploadOptions,
        nonStandardInputReasons: [UploadInputFormatInspectionResult.NonstandardInputReason],
        standardizationEndTime: Date,
        standardizationStartTime: Date,
        uploadURL: URL
    ) {
        guard !options.eventTracking.optedOut else {
            return
        }

        let data = InputStandardizationSucceededEvent.Data(
            appName: Bundle.main.appName,
            appVersion: Bundle.main.appVersion,
            deviceModel: model,
            inputDuration: inputDuration,
            inputSize: inputSize,
            maximumResolution: options.inputStandardization.maximumResolution.description,
            nonStandardInputReasons: nonStandardInputReasons.map(\.description),
            platformName: platformName,
            platformVersion: platformVersion,
            regionCode: regionCode,
            sdkVersion: SemanticVersion.versionString,
            standardizationStartTime: standardizationStartTime,
            standardizationEndTime: standardizationEndTime,
            uploadURL: uploadURL
        )

        let event = InputStandardizationSucceededEvent(
            sessionID: sessionID,
            data: data
        )

        send(
            event: event,
            url: url
        )
    }

    func reportUploadInputStandardizationFailure(
        errorDescription: String,
        inputDuration: Double,
        inputSize: UInt64,
        nonStandardInputReasons: [UploadInputFormatInspectionResult.NonstandardInputReason],
        options: DirectUploadOptions,
        standardizationEndTime: Date,
        standardizationStartTime: Date,
        uploadCanceled: Bool,
        uploadURL: URL
    ) {
        guard !options.eventTracking.optedOut else {
            return
        }

        let data = InputStandardizationFailedEvent.Data(
            appName: Bundle.main.appName,
            appVersion: Bundle.main.appVersion,
            deviceModel: model,
            errorDescription: errorDescription,
            inputDuration: inputDuration,
            inputSize: inputSize,
            maximumResolution: options.inputStandardization.maximumResolution.description,
            nonStandardInputReasons: nonStandardInputReasons.map(\.description),
            platformName: platformName,
            platformVersion: platformVersion,
            regionCode: regionCode,
            sdkVersion: SemanticVersion.versionString,
            standardizationStartTime: standardizationStartTime,
            standardizationEndTime: standardizationEndTime,
            uploadCanceled: uploadCanceled,
            uploadURL: uploadURL
        )

        let event = InputStandardizationFailedEvent(
            sessionID: sessionID,
            data: data
        )

        send(
            event: event,
            url: url
        )
    }
}

// TODO: Implement as a separate object so the URLSession
// can become non-optional, which removes a bunch of edge cases
extension Reporter: URLSessionDelegate, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Swift.Void) {
        if let pendingEvent = pendingEvents[ObjectIdentifier(task)], let redirectURL = request.url {
            guard let httpBody = try? jsonEncoder.encode(pendingEvent) else {
                completionHandler(nil)
                return
            }

            // TODO: This can be URLRequest instead of NSMutableURLRequest
            // test URLRequest-based construction in case
            // for any weirdness
            let request = NSMutableURLRequest.makeJSONPost(
                url: redirectURL,
                httpBody: httpBody,
                additionalHTTPHeaders: additionalHTTPHeaders
            )

            completionHandler(request as URLRequest)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        pendingEvents[
            ObjectIdentifier(task)
        ] = nil
    }
}
