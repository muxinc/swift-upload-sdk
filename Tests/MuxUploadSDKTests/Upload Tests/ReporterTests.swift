//
//  ReporterTests.swift
//

import Foundation
import XCTest

@testable import MuxUploadSDK

class ReporterTests: XCTestCase {

    func testUploadEventSerialization() throws {
        let reporter = Reporter()
        reporter.pendingUploadEvent = UploadEvent(
            startTime: 100,
            endTime: 103,
            fileSize: 1_500_000,
            videoDuration: 3.14,
            uploadURL: URL(string: "https://www.example.com")!,
            sdkVersion: "0.3.1",
            osName: "iPadOS",
            osVersion: "16.2",
            deviceModel: "iPad",
            appName: "foo",
            appVersion: "14.3.1",
            regionCode: "US"
        )

        let serializedUploadEvent = try reporter.serializePendingEvent()

        let json = try XCTUnwrap(
            String(
                data: serializedUploadEvent,
                encoding: .utf8
            )
        )

        XCTAssertEqual(
            json,
            "{\"app_name\":\"foo\",\"app_version\":\"14.3.1\",\"device_model\":\"iPad\",\"end_time\":103,\"file_size\":1500000,\"os_name\":\"iPadOS\",\"os_version\":\"16.2\",\"region_code\":\"US\",\"sdk_version\":\"0.3.1\",\"start_time\":100,\"type\":\"upload\",\"upload_url\":\"https:\\/\\/www.example.com\",\"video_duration\":3.1400000000000001}"
        )

    }

}
