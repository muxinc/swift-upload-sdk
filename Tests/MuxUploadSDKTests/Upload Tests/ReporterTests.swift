//
//  ReporterTests.swift
//

import Foundation
import XCTest

@testable import MuxUploadSDK

class ReporterTests: XCTestCase {

    enum ExpectedJSONStrings {
        static let inputStandardizationFailed = #"{"data":{"app_name":"AcmeApp","app_version":"3.2.1","device_model":"iPad","error_description":"foo","input_duration":3.1400000000000001,"input_size":1500000,"maximum_resolution":"default","non_standard_input_reasons":[],"platform_name":"iPadOS","platform_version":"15.0.0","sdk_version":"0.4.1","standardization_end_time":"2023-07-07T03:43:58Z","standardization_start_time":"2023-07-07T03:38:58Z","upload_canceled":false,"upload_url":"https:\/\/www.example.com"},"session_id":"xyz789","type":"upload_input_standardization_failed","version":"1"}"#

        static let inputStandardizationSucceeded = #"{"data":{"app_name":"AcmeApp","app_version":"3.2.1","device_model":"iPad","input_duration":3.1400000000000001,"input_size":1500000,"maximum_resolution":"default","non_standard_input_reasons":[],"platform_name":"iPadOS","platform_version":"15.0.0","sdk_version":"0.4.1","standardization_end_time":"2023-07-07T03:43:58Z","standardization_start_time":"2023-07-07T03:38:58Z","upload_url":"https:\/\/www.example.com"},"session_id":"jkl567","type":"upload_input_standardization_succeeded","version":"1"}"#

        static let uploadFailed = #"{"data":{"app_name":"AcmeApp","app_version":"3.2.1","device_model":"iPad","error_description":"foo","input_duration":3.1400000000000001,"input_size":1500000,"input_standardization_enabled":false,"platform_name":"iPadOS","platform_version":"16.2.0","region_code":"US","sdk_version":"0.3.0","upload_end_time":"2023-07-07T04:12:48Z","upload_start_time":"2023-07-07T04:12:18Z","upload_url":"https:\/\/www.example.com"},"session_id":"abc123","type":"upload_failed","version":"1"}"#

        static let uploadSucceeded = #"{"data":{"app_name":"AcmeApp","app_version":"3.2.1","device_model":"iPad","input_duration":3.1400000000000001,"input_size":1500000,"input_standardization_enabled":true,"platform_name":"iPadOS","platform_version":"16.2.0","region_code":"US","sdk_version":"0.3.0","upload_end_time":"2023-07-07T04:12:48Z","upload_start_time":"2023-07-07T04:12:18Z","upload_url":"https:\/\/www.example.com"},"session_id":"abc123","type":"upload_succeeded","version":"1"}"#
    }

    var jsonEncoder = Reporter().jsonEncoder

    func testInputStandardizationFailedEventSerialization() throws {
        let data = InputStandardizationFailedEvent.Data(
            appName: "AcmeApp",
            appVersion: "3.2.1",
            deviceModel: "iPad",
            errorDescription: "foo",
            inputDuration: 3.14,
            inputSize: 1_500_000,
            maximumResolution: "default",
            nonStandardInputReasons: [],
            platformName: "iPadOS",
            platformVersion: "15.0.0",
            sdkVersion: "0.4.1",
            standardizationStartTime: Date(timeIntervalSince1970: 1688701138.45),
            standardizationEndTime: Date(timeIntervalSince1970: 1688701438.45),
            uploadCanceled: false,
            uploadURL: URL(string: "https://www.example.com")!
        )

        let event = InputStandardizationFailedEvent(
            sessionID: "xyz789",
            data: data
        )

        let json = try XCTUnwrap(
            String(
                data: jsonEncoder.encode(event),
                encoding: .utf8
            )
        )

        XCTAssertEqual(
            json,
            ExpectedJSONStrings.inputStandardizationFailed
        )
    }

    func testInputStandardizationSucceededEventSerialization() throws {
        let data = InputStandardizationSucceededEvent.Data(
            appName: "AcmeApp",
            appVersion: "3.2.1",
            deviceModel: "iPad",
            inputDuration: 3.14,
            inputSize: 1_500_000,
            maximumResolution: "default",
            nonStandardInputReasons: [],
            platformName: "iPadOS",
            platformVersion: "15.0.0",
            sdkVersion: "0.4.1",
            standardizationStartTime: Date(timeIntervalSince1970: 1688701138.45),
            standardizationEndTime: Date(timeIntervalSince1970: 1688701438.45),
            uploadURL: URL(string: "https://www.example.com")!
        )

        let event = InputStandardizationSucceededEvent(
            sessionID: "jkl567",
            data: data
        )

        let json = try XCTUnwrap(
            String(
                data: jsonEncoder.encode(event),
                encoding: .utf8
            )
        )

        XCTAssertEqual(
            json,
            ExpectedJSONStrings.inputStandardizationSucceeded
        )
    }

    func testUploadFailedEventSerialization() throws {
        let data = UploadFailedEvent.Data(
            appName: "AcmeApp",
            appVersion: "3.2.1",
            deviceModel: "iPad",
            errorDescription: "foo",
            inputDuration: 3.14,
            inputSize: 1_500_000,
            inputStandardizationEnabled: false,
            platformName: "iPadOS",
            platformVersion: "16.2.0",
            regionCode: "US",
            sdkVersion: "0.3.0",
            uploadStartTime: Date(timeIntervalSince1970: 1688703138.45),
            uploadEndTime: Date(timeIntervalSince1970: 1688703168.45),
            uploadURL: URL(string: "https://www.example.com")!
        )

        let event = UploadFailedEvent(
            sessionID: "abc123",
            data: data
        )

        let json = try XCTUnwrap(
            String(
                data: jsonEncoder.encode(event),
                encoding: .utf8
            )
        )

        XCTAssertEqual(
            json,
            ExpectedJSONStrings.uploadFailed
        )
    }

    func testUploadSucceededEventSerialization() throws {
        let data = UploadSucceededEvent.Data(
            appName: "AcmeApp",
            appVersion: "3.2.1",
            deviceModel: "iPad",
            inputDuration: 3.14,
            inputSize: 1_500_000,
            inputStandardizationEnabled: true,
            platformName: "iPadOS",
            platformVersion: "16.2.0",
            regionCode: "US",
            sdkVersion: "0.3.0",
            uploadStartTime: Date(timeIntervalSince1970: 1688703138.45),
            uploadEndTime: Date(timeIntervalSince1970: 1688703168.45),
            uploadURL: URL(string: "https://www.example.com")!
        )

        let event = UploadSucceededEvent(
            sessionID: "abc123",
            version: "1",
            data: data
        )

        let json = try XCTUnwrap(
            String(
                data: jsonEncoder.encode(event),
                encoding: .utf8
            )
        )

        XCTAssertEqual(
            json,
            ExpectedJSONStrings.uploadSucceeded
        )
    }

}
