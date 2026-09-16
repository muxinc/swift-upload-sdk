//
//  StandardInputPolicyTests.swift
//

import XCTest
@testable import MuxUploadSDK

final class StandardInputPolicyTests: XCTestCase {

    private let evaluator = StandardInputPolicyEvaluator()

    func testSDKMaximumResolutionSelectsAcceptanceTierAndOutputTarget() {
        let p720 = selection(.preset1280x720)
        let defaultResolution = selection(.default)
        let p1440 = selection(.preset2560x1440)
        let p2160 = selection(.preset3840x2160)

        XCTAssertEqual(p720.acceptanceTier, .upTo1080p)
        XCTAssertEqual(
            p720.generatedOutputDimensions,
            .init(width: 1280, height: 720)
        )
        XCTAssertEqual(defaultResolution.acceptanceTier, .upTo1080p)
        XCTAssertEqual(
            defaultResolution.generatedOutputDimensions,
            .init(width: 1920, height: 1080)
        )
        XCTAssertEqual(defaultResolution, selection(.preset1920x1080))
        XCTAssertEqual(p1440.acceptanceTier, .highResolution)
        XCTAssertEqual(
            p1440.generatedOutputDimensions,
            .init(width: 2560, height: 1440)
        )
        XCTAssertEqual(p2160.acceptanceTier, .highResolution)
        XCTAssertEqual(
            p2160.generatedOutputDimensions,
            .init(width: 3840, height: 2160)
        )
    }

    func testPublished1080pBoundaryValuesAreCompliant() {
        let evaluation = evaluator.evaluate(
            compliantFacts(
                dimensions: .init(width: 1920, height: 1080),
                frameRate: 120.0,
                averageBitrate: 8_000_000,
                maximumGOPBitrate: 16_000_000,
                maximumKeyframeInterval: 20.0
            ),
            selection: selection()
        )

        XCTAssertEqual(evaluation.outcome, .compliant)
        XCTAssertTrue(evaluation.nonCompliantRequirements.isEmpty)
        XCTAssertTrue(evaluation.unknownRequirements.isEmpty)
    }

    func testHEVCUsesPublishedKeyframeIntervalForEachTier() {
        var facts = compliantFacts(
            codec: .hevc,
            dimensions: .init(width: 1920, height: 1080),
            maximumKeyframeInterval: 10.0
        )

        XCTAssertEqual(
            evaluator.evaluate(
                facts,
                selection: selection()
            ).status(for: .keyframeInterval),
            .compliant
        )

        facts.maximumKeyframeInterval = .known(10.001)

        XCTAssertEqual(
            evaluator.evaluate(
                facts,
                selection: selection()
            ).status(for: .keyframeInterval),
            .nonCompliant
        )

        facts.displayDimensions = .known(.init(width: 3840, height: 2160))
        facts.frameRate = .known(60.0)
        facts.averageBitrate = .known(20_000_000)
        facts.maximumKeyframeInterval = .known(6.0)

        XCTAssertEqual(
            evaluator.evaluate(
                facts,
                selection: selection(.preset3840x2160)
            ).status(for: .keyframeInterval),
            .compliant
        )
    }

    func testMissingPerGOPBitrateIsUnknownAt1080p() {
        var facts = compliantFacts()
        facts.maximumGOPBitrate = .unknown

        let evaluation = evaluator.evaluate(facts, selection: selection())

        XCTAssertEqual(evaluation.outcome, .unknown)
        XCTAssertEqual(evaluation.nonCompliantRequirements, [])
        XCTAssertEqual(evaluation.unknownRequirements, [.maximumGOPBitrate])
    }

    func testKnownViolationWinsOverUnknownFact() {
        var facts = compliantFacts()
        facts.averageBitrate = .known(8_000_001)
        facts.maximumGOPBitrate = .unknown

        let evaluation = evaluator.evaluate(facts, selection: selection())

        XCTAssertEqual(evaluation.outcome, .nonCompliant)
        XCTAssertEqual(evaluation.nonCompliantRequirements, [.averageBitrate])
        XCTAssertEqual(evaluation.unknownRequirements, [.maximumGOPBitrate])
    }

    func testHighResolutionPolicyHasNoPerGOPBitrateCeiling() {
        var facts = compliantFacts(
            dimensions: .init(width: 2560, height: 1440),
            frameRate: 60.0,
            averageBitrate: 20_000_000,
            maximumGOPBitrate: nil,
            maximumKeyframeInterval: 10.0
        )

        var evaluation = evaluator.evaluate(
            facts,
            selection: selection(.preset2560x1440)
        )

        XCTAssertEqual(evaluation.status(for: .maximumGOPBitrate), .compliant)
        XCTAssertEqual(evaluation.outcome, .compliant)

        facts.averageBitrate = .known(20_000_001)
        evaluation = evaluator.evaluate(
            facts,
            selection: selection(.preset2560x1440)
        )

        XCTAssertEqual(evaluation.status(for: .averageBitrate), .nonCompliant)
        XCTAssertEqual(evaluation.outcome, .nonCompliant)
    }

    func testHighResolutionSelectionUsesSourceResolutionToChooseEffectiveTier() {
        let facts = compliantFacts(
            dimensions: .init(width: 1920, height: 1080),
            frameRate: 120.0,
            averageBitrate: 15_000_000,
            maximumGOPBitrate: 16_000_000,
            maximumKeyframeInterval: 15.0
        )

        let evaluation = evaluator.evaluate(
            facts,
            selection: selection(.preset3840x2160)
        )

        XCTAssertEqual(evaluation.status(for: .frameRate), .compliant)
        XCTAssertEqual(evaluation.status(for: .averageBitrate), .nonCompliant)
        XCTAssertEqual(evaluation.status(for: .maximumGOPBitrate), .compliant)
        XCTAssertEqual(evaluation.status(for: .keyframeInterval), .compliant)
        XCTAssertEqual(evaluation.outcome, .nonCompliant)
    }

    func testMaximumGOPByteSizeIsNotComparedWithBitrateLimits() {
        var facts = compliantFacts()
        facts.maximumGOPByteSize = .known(Int64.max)

        let evaluation = evaluator.evaluate(facts, selection: selection())

        XCTAssertEqual(evaluation.outcome, .compliant)
        XCTAssertEqual(
            evaluation.status(for: .maximumGOPBitrate),
            .compliant
        )
    }

    func testPublishedFrameRateRangesAreInclusive() {
        var facts = compliantFacts(frameRate: 5.0)

        XCTAssertEqual(
            evaluator.evaluate(
                facts,
                selection: selection()
            ).status(for: .frameRate),
            .compliant
        )

        facts.frameRate = .known(120.001)

        XCTAssertEqual(
            evaluator.evaluate(
                facts,
                selection: selection()
            ).status(for: .frameRate),
            .nonCompliant
        )

        facts = compliantFacts(
            dimensions: .init(width: 2560, height: 1440),
            frameRate: 60.001,
            averageBitrate: 20_000_000,
            maximumGOPBitrate: nil,
            maximumKeyframeInterval: 10.0
        )

        XCTAssertEqual(
            evaluator.evaluate(
                facts,
                selection: selection(.preset2560x1440)
            ).status(for: .frameRate),
            .nonCompliant
        )
    }

    func testPublishedSourceResolutionIsOrientationNeutral() {
        var facts = compliantFacts(
            dimensions: .init(width: 1152, height: 2048)
        )

        XCTAssertEqual(
            evaluator.evaluate(
                facts,
                selection: selection()
            ).status(for: .videoResolution),
            .compliant
        )

        facts.displayDimensions = .known(.init(width: 1152, height: 2049))

        XCTAssertEqual(
            evaluator.evaluate(
                facts,
                selection: selection()
            ).status(for: .videoResolution),
            .nonCompliant
        )
    }

    func testPublishedSourceLimitIsSeparateFromGeneratedOutputTarget() {
        let facts = compliantFacts(
            dimensions: .init(width: 2048, height: 1152)
        )

        XCTAssertEqual(
            evaluator.evaluate(
                facts,
                selection: selection(),
                role: .sourceInput
            ).status(for: .videoResolution),
            .compliant
        )
        XCTAssertEqual(
            evaluator.evaluate(
                facts,
                selection: selection(),
                role: .generatedOutput
            ).status(for: .videoResolution),
            .nonCompliant
        )
    }

    func test2160pSourceAndGeneratedOutputUsePublishedDimensionRules() {
        var facts = compliantFacts(
            dimensions: .init(width: 2160, height: 4096),
            frameRate: 60.0,
            averageBitrate: 20_000_000,
            maximumGOPBitrate: nil,
            maximumKeyframeInterval: 10.0
        )

        XCTAssertEqual(
            evaluator.evaluate(
                facts,
                selection: selection(.preset3840x2160),
                role: .sourceInput
            ).status(for: .videoResolution),
            .compliant
        )

        XCTAssertEqual(
            evaluator.evaluate(
                facts,
                selection: selection(.preset3840x2160),
                role: .generatedOutput
            ).status(for: .videoResolution),
            .nonCompliant
        )

        facts.displayDimensions = .known(.init(width: 2160, height: 3840))

        XCTAssertEqual(
            evaluator.evaluate(
                facts,
                selection: selection(.preset3840x2160),
                role: .generatedOutput
            ).status(for: .videoResolution),
            .compliant
        )
    }

    func testPixelFormatAndHDRRulesAreCodecAware() {
        var facts = compliantFacts(
            codec: .hevc,
            maximumKeyframeInterval: 10.0,
            pixelFormat: .init(bitDepth: 10, chromaSubsampling: .yuv420),
            dynamicRange: .hlg
        )

        var evaluation = evaluator.evaluate(facts, selection: selection())

        XCTAssertEqual(evaluation.status(for: .pixelFormat), .compliant)
        XCTAssertEqual(evaluation.status(for: .dynamicRange), .compliant)

        facts.videoCodec = .known(.h264)
        facts.maximumKeyframeInterval = .known(20.0)
        evaluation = evaluator.evaluate(facts, selection: selection())

        XCTAssertEqual(evaluation.status(for: .pixelFormat), .nonCompliant)
        XCTAssertEqual(evaluation.status(for: .dynamicRange), .nonCompliant)
    }

    func testUnsupportedCodecAndGOPStructureAreNonCompliant() {
        var facts = compliantFacts()
        facts.videoCodec = .known(.other)
        facts.gopStructure = .known(.open)

        let evaluation = evaluator.evaluate(facts, selection: selection())

        XCTAssertEqual(evaluation.status(for: .videoCodec), .nonCompliant)
        XCTAssertEqual(evaluation.status(for: .gopStructure), .nonCompliant)
        XCTAssertEqual(evaluation.outcome, .nonCompliant)
    }

    func testAudioAndEditListRulesRejectUnsupportedValues() {
        var facts = compliantFacts()
        facts.audio = .known(.aac(.other))
        facts.editList = .known(.complex)

        let evaluation = evaluator.evaluate(facts, selection: selection())

        XCTAssertEqual(evaluation.status(for: .audio), .nonCompliant)
        XCTAssertEqual(evaluation.status(for: .editList), .nonCompliant)
        XCTAssertEqual(
            evaluation.nonCompliantRequirements,
            [.audio, .editList]
        )
    }

    func testUnavailableFactsRemainUnknown() {
        let evaluation = evaluator.evaluate(
            StandardInputMediaFacts(),
            selection: selection()
        )

        XCTAssertEqual(evaluation.outcome, .unknown)
        XCTAssertEqual(
            evaluation.unknownRequirements,
            StandardInputPolicyEvaluation.Requirement.allCases
        )
    }

    func testInvalidMeasurementSentinelsRemainUnknown() {
        var facts = compliantFacts()
        facts.displayDimensions = .known(.init(width: 0, height: 1080))
        facts.frameRate = .known(0)
        facts.averageBitrate = .known(0)
        facts.maximumGOPBitrate = .known(0)
        facts.maximumKeyframeInterval = .known(0)

        let evaluation = evaluator.evaluate(facts, selection: selection())

        XCTAssertEqual(evaluation.outcome, .unknown)
        XCTAssertEqual(
            evaluation.unknownRequirements,
            [
                .videoResolution,
                .frameRate,
                .averageBitrate,
                .maximumGOPBitrate,
                .keyframeInterval
            ]
        )
        XCTAssertTrue(evaluation.nonCompliantRequirements.isEmpty)
    }

    private func selection(
        _ maximumResolution: DirectUploadOptions.InputStandardization.MaximumResolution = .default
    ) -> StandardInputPolicySelection {
        StandardInputPolicySelection(maximumResolution: maximumResolution)
    }

    private func compliantFacts(
        codec: StandardInputVideoCodec = .h264,
        dimensions: StandardInputDisplayDimensions = .init(
            width: 1920,
            height: 1080
        ),
        frameRate: Double = 120.0,
        averageBitrate: Int64 = 8_000_000,
        maximumGOPBitrate: Int64? = 16_000_000,
        maximumKeyframeInterval: TimeInterval = 20.0,
        pixelFormat: StandardInputPixelFormat = .init(
            bitDepth: 8,
            chromaSubsampling: .yuv420
        ),
        dynamicRange: StandardInputDynamicRange = .sdr
    ) -> StandardInputMediaFacts {
        StandardInputMediaFacts(
            videoCodec: .known(codec),
            displayDimensions: .known(dimensions),
            frameRate: .known(frameRate),
            averageBitrate: .known(averageBitrate),
            maximumGOPBitrate: maximumGOPBitrate.map(StandardInputFact.known)
                ?? .unknown,
            maximumGOPByteSize: .unknown,
            maximumKeyframeInterval: .known(maximumKeyframeInterval),
            gopStructure: .known(.closedWithIDR),
            pixelFormat: .known(pixelFormat),
            dynamicRange: .known(dynamicRange),
            audio: .known(.aac(.fivePointOne)),
            editList: .known(.simple)
        )
    }
}
