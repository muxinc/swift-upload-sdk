//
//  DirectUploadOptionsTests.swift
//

import XCTest
@testable import MuxUploadSDK

final class DirectUploadOptionsTests: XCTestCase {

    func testInputStandardizationDefaultsRemain1080pAndPreserveHDR() {
        XCTAssertEqual(
            DirectUploadOptions.InputStandardization.default.maximumResolution,
            .default
        )
        XCTAssertEqual(
            DirectUploadOptions.InputStandardization.default.hdrHandling,
            .preserve
        )
    }

    func testExistingMaximumResolutionInitializerDefaultsToPreserveHDR() {
        let options = DirectUploadOptions.InputStandardization(
            maximumResolution: .preset3840x2160
        )

        XCTAssertEqual(options.maximumResolution, .preset3840x2160)
        XCTAssertEqual(options.hdrHandling, .preserve)
    }

    func testInputStandardizationSupports1440pAndOptInToneMapping() {
        let options = DirectUploadOptions.InputStandardization(
            maximumResolution: .preset2560x1440,
            hdrHandling: .toneMapToSDR
        )

        XCTAssertEqual(options.maximumResolution, .preset2560x1440)
        XCTAssertEqual(options.maximumResolution.description, "preset2560x1440")
        XCTAssertEqual(options.hdrHandling, .toneMapToSDR)
    }

    func test1440pResolutionThresholdDoesNotUpscale() {
        var details = UploadInputFormatInspectionResult.RescalingDetails(
            maximumDesiredResolutionPreset: .preset2560x1440,
            recordedResolution: .init(width: 2560, height: 1440)
        )

        XCTAssertFalse(details.needsRescaling)

        details.recordedResolution = .init(width: 2561, height: 1440)

        XCTAssertTrue(details.needsRescaling)
    }

    func testPersistedOptionsWithoutHDRHandlingDecodeAsPreserve() throws {
        let persistedOptions = """
        {
          "isRequested": true,
          "maximumResolution": {
            "preset3840x2160": {}
          }
        }
        """

        let decoded = try JSONDecoder().decode(
            DirectUploadOptions.InputStandardization.self,
            from: Data(persistedOptions.utf8)
        )

        XCTAssertEqual(decoded.maximumResolution, .preset3840x2160)
        XCTAssertEqual(decoded.hdrHandling, .preserve)
    }

    func testExistingMaximumResolutionSerializedValuesRemainStable() throws {
        let resolutions: [
            DirectUploadOptions.InputStandardization.MaximumResolution
        ] = [
            .default,
            .preset1280x720,
            .preset1920x1080,
            .preset3840x2160
        ]

        let encoded = try resolutions.map {
            try XCTUnwrap(
                String(data: JSONEncoder().encode($0), encoding: .utf8)
            )
        }

        XCTAssertEqual(
            encoded,
            [
                #"{"default":{}}"#,
                #"{"preset1280x720":{}}"#,
                #"{"preset1920x1080":{}}"#,
                #"{"preset3840x2160":{}}"#
            ]
        )
    }

    func testHDRHandlingRoundTripsThroughPersistence() throws {
        let options = DirectUploadOptions.InputStandardization(
            maximumResolution: .preset2560x1440,
            hdrHandling: .toneMapToSDR
        )

        let encoded = try JSONEncoder().encode(options)
        let decoded = try JSONDecoder().decode(
            DirectUploadOptions.InputStandardization.self,
            from: encoded
        )

        XCTAssertEqual(decoded, options)
    }
}
