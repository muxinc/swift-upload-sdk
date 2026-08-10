//
//  StandardInputPlannerTests.swift
//

import XCTest
@testable import MuxUploadSDK

final class StandardInputPlannerTests: XCTestCase {
    private let planner = StandardInputPlanner()

    func testCompliantH264UploadsOriginal() {
        let plan = planner.plan(
            facts: compliantFacts(),
            options: .default,
            capabilities: fullCapabilities()
        )

        XCTAssertEqual(plan.action, .uploadOriginal(.standardInput))
    }

    func testUnknownFactAloneDoesNotTriggerConversion() {
        var facts = compliantFacts()
        facts.maximumGOPBitrate = .unknown

        let plan = planner.plan(
            facts: facts,
            options: .default,
            capabilities: fullCapabilities()
        )

        XCTAssertEqual(
            plan.action,
            .uploadOriginal(.noKnownStandardInputViolation)
        )
        XCTAssertEqual(plan.evaluation.outcome, .unknown)
    }

    func testKnownH264ViolationSelectsH264Conversion() throws {
        var facts = compliantFacts()
        facts.frameRate = .known(121)

        let conversion = try XCTUnwrap(conversion(for: facts))

        XCTAssertEqual(conversion.sourceCodec, .h264)
        XCTAssertEqual(conversion.outputCodec, .h264)
        XCTAssertEqual(conversion.requirementsToRemediate, [.frameRate])
        XCTAssertFalse(conversion.toneMapsToSDR)
    }

    func testSelectedMaximumResolutionTriggersConversionBelowPublishedSourceLimit() throws {
        let facts = compliantFacts(
            dimensions: .init(width: 2048, height: 1152)
        )

        let conversion = try XCTUnwrap(conversion(for: facts))

        XCTAssertEqual(conversion.requirementsToRemediate, [.videoResolution])
        XCTAssertEqual(
            conversion.selection.generatedOutputDimensions,
            .init(width: 1920, height: 1080)
        )
        XCTAssertEqual(conversion.outputCodec, .h264)
    }

    func testKnownHEVCViolationSelectsHEVCConversion() throws {
        var facts = compliantFacts(codec: .hevc)
        facts.maximumKeyframeInterval = .known(11)

        let conversion = try XCTUnwrap(conversion(for: facts))

        XCTAssertEqual(conversion.sourceCodec, .hevc)
        XCTAssertEqual(conversion.outputCodec, .hevc)
        XCTAssertEqual(conversion.requirementsToRemediate, [.keyframeInterval])
    }

    func testLocallyDecodableOtherCodecSelectsH264Conversion() throws {
        var facts = compliantFacts(codec: .other)
        facts.pixelFormat = .known(
            .init(bitDepth: 10, chromaSubsampling: .other)
        )

        let conversion = try XCTUnwrap(conversion(for: facts))

        XCTAssertEqual(conversion.sourceCodec, .other)
        XCTAssertEqual(conversion.outputCodec, .h264)
        XCTAssertTrue(conversion.requirementsToRemediate.contains(.videoCodec))
    }

    func testUnsupportedConversionSelectsFallback() {
        var facts = compliantFacts(codec: .hevc)
        facts.maximumKeyframeInterval = .known(11)
        var capabilities = fullCapabilities()
        capabilities.encodableVideoCodecs.remove(.hevc)

        let plan = planner.plan(
            facts: facts,
            options: .default,
            capabilities: capabilities
        )

        guard case .fallback(.unsupportedConversion(let conversion)) = plan.action else {
            return XCTFail("Expected unsupported-conversion fallback")
        }
        XCTAssertEqual(conversion.outputCodec, .hevc)
    }

    func testUndecodableSourceSelectsFallback() {
        var facts = compliantFacts(codec: .other)
        facts.pixelFormat = .known(
            .init(bitDepth: 10, chromaSubsampling: .other)
        )
        var capabilities = fullCapabilities()
        capabilities.sourceIsDecodable = false

        let plan = planner.plan(
            facts: facts,
            options: .default,
            capabilities: capabilities
        )

        guard case .fallback(.unsupportedConversion(let conversion)) = plan.action else {
            return XCTFail("Expected unsupported-conversion fallback")
        }
        XCTAssertEqual(conversion.sourceCodec, .other)
    }

    func testUnremediableViolationSelectsFallback() {
        var facts = compliantFacts()
        facts.editList = .known(.complex)
        var capabilities = fullCapabilities()
        capabilities.remediableRequirements.remove(.editList)

        let plan = planner.plan(
            facts: facts,
            options: .default,
            capabilities: capabilities
        )

        guard case .fallback(.unsupportedConversion(let conversion)) = plan.action else {
            return XCTFail("Expected unsupported-conversion fallback")
        }
        XCTAssertEqual(conversion.requirementsToRemediate, [.editList])
    }

    func testSkippedStandardizationUploadsOriginalWithoutPlanningConversion() {
        var facts = compliantFacts()
        facts.frameRate = .known(121)

        let plan = planner.plan(
            facts: facts,
            options: .skipped,
            capabilities: fullCapabilities()
        )

        XCTAssertEqual(
            plan.action,
            .uploadOriginal(.standardizationNotRequested)
        )
        XCTAssertEqual(plan.evaluation.outcome, .nonCompliant)
    }

    func testMissingCodecOrDynamicRangeUsesFallbackWhenConversionIsNeeded() {
        var missingCodec = compliantFacts()
        missingCodec.videoCodec = .unknown
        missingCodec.frameRate = .known(121)

        var missingDynamicRange = compliantFacts()
        missingDynamicRange.dynamicRange = .unknown
        missingDynamicRange.frameRate = .known(121)

        for facts in [missingCodec, missingDynamicRange] {
            let plan = planner.plan(
                facts: facts,
                options: .default,
                capabilities: fullCapabilities()
            )
            XCTAssertEqual(
                plan.action,
                .fallback(.insufficientEvidenceForConversion)
            )
        }
    }

    func testEligiblePreservedHDRUploadsOriginalIntentionally() {
        for dynamicRange in [StandardInputDynamicRange.hlg, .pq] {
            let plan = planner.plan(
                facts: compliantHDRFacts(dynamicRange: dynamicRange),
                options: .default,
                capabilities: fullCapabilities()
            )

            XCTAssertEqual(
                plan.action,
                .uploadOriginal(.preserveHDR(dynamicRange))
            )
        }
    }

    func testPreservedHDRWithNonColorViolationUsesFallback() {
        var facts = compliantHDRFacts(dynamicRange: .hlg)
        facts.averageBitrate = .known(8_000_001)

        let plan = planner.plan(
            facts: facts,
            options: .default,
            capabilities: fullCapabilities()
        )

        XCTAssertEqual(
            plan.action,
            .fallback(.nonStandardHDR(.hlg, [.averageBitrate]))
        )
    }

    func testUnavailableHDRPreservationUsesFallback() {
        let plan = planner.plan(
            facts: compliantHDRFacts(dynamicRange: .pq),
            options: .default,
            capabilities: fullCapabilities(preservableHDR: [.hlg])
        )

        XCTAssertEqual(
            plan.action,
            .fallback(.hdrPreservationUnavailable(.pq))
        )
    }

    func testHDRWithUnknownEligibilityUsesFallback() {
        var facts = compliantHDRFacts(dynamicRange: .hlg)
        facts.pixelFormat = .unknown

        let plan = planner.plan(
            facts: facts,
            options: .default,
            capabilities: fullCapabilities()
        )

        XCTAssertEqual(plan.action, .fallback(.unsupportedHDR(.hlg)))
    }

    func testToneMappingPreservesHEVCCodecFamily() throws {
        let options = DirectUploadOptions.InputStandardization(
            maximumResolution: .default,
            hdrHandling: .toneMapToSDR
        )
        let plan = planner.plan(
            facts: compliantHDRFacts(dynamicRange: .hlg),
            options: options,
            capabilities: fullCapabilities()
        )

        guard case .convert(let conversion) = plan.action else {
            return XCTFail("Expected tone-map conversion")
        }
        XCTAssertEqual(conversion.sourceCodec, .hevc)
        XCTAssertEqual(conversion.outputCodec, .hevc)
        XCTAssertEqual(conversion.sourceDynamicRange, .hlg)
        XCTAssertTrue(conversion.toneMapsToSDR)
    }

    func testUnsupportedToneMappingUsesFallback() {
        let options = DirectUploadOptions.InputStandardization(
            maximumResolution: .default,
            hdrHandling: .toneMapToSDR
        )
        let plan = planner.plan(
            facts: compliantHDRFacts(dynamicRange: .pq),
            options: options,
            capabilities: fullCapabilities(toneMappableHDR: [.hlg])
        )

        guard case .fallback(.unsupportedConversion(let conversion)) = plan.action else {
            return XCTFail("Expected unsupported-conversion fallback")
        }
        XCTAssertTrue(conversion.toneMapsToSDR)
    }

    func testUnknownOrUnsupportedHDRUsesFallback() {
        var otherHDRFacts = compliantFacts()
        otherHDRFacts.dynamicRange = .known(.otherHDR)

        let plan = planner.plan(
            facts: otherHDRFacts,
            options: .default,
            capabilities: fullCapabilities()
        )

        XCTAssertEqual(plan.action, .fallback(.unsupportedHDR(.otherHDR)))
    }

    private func conversion(
        for facts: StandardInputMediaFacts
    ) -> StandardInputConversion? {
        let plan = planner.plan(
            facts: facts,
            options: .default,
            capabilities: fullCapabilities()
        )
        guard case .convert(let conversion) = plan.action else {
            return nil
        }
        return conversion
    }

    private func fullCapabilities(
        toneMappableHDR: Set<StandardInputDynamicRange> = [.hlg, .pq],
        preservableHDR: Set<StandardInputDynamicRange> = [.hlg, .pq]
    ) -> StandardInputPlanningCapabilities {
        StandardInputPlanningCapabilities(
            sourceIsDecodable: true,
            encodableVideoCodecs: [.h264, .hevc],
            remediableRequirements: Set(
                StandardInputPolicyEvaluation.Requirement.allCases
            ),
            toneMappableDynamicRanges: toneMappableHDR,
            preservableHDRDynamicRanges: preservableHDR
        )
    }
}

final class StandardInputOutputValidatorTests: XCTestCase {
    private let validator = StandardInputOutputValidator()

    func testFullyCompliantPolicyOutputIsAccepted() {
        let validation = validator.validatePolicyCompliance(
            facts: compliantFacts(),
            maximumResolution: .default
        )

        XCTAssertTrue(validation.isAccepted)
        XCTAssertEqual(validation.disposition, .accepted)
    }

    func testKnownGeneratedOutputViolationIsRejected() {
        var facts = compliantFacts()
        facts.displayDimensions = .known(.init(width: 2048, height: 1152))

        let validation = validator.validatePolicyCompliance(
            facts: facts,
            maximumResolution: .default
        )

        XCTAssertEqual(
            validation.disposition,
            .rejected(.nonCompliant([.videoResolution]))
        )
    }

    func testInsufficientGeneratedOutputEvidenceIsRejected() {
        var facts = compliantFacts()
        facts.maximumGOPBitrate = .unknown

        let validation = validator.validatePolicyCompliance(
            facts: facts,
            maximumResolution: .default
        )

        XCTAssertEqual(
            validation.disposition,
            .rejected(.insufficientPolicyEvidence([.maximumGOPBitrate]))
        )
    }

    func testHighResolutionOutputDoesNotRequireUnpublishedGOPBitrateLimit() {
        var facts = compliantFacts(
            codec: .hevc,
            dimensions: .init(width: 3840, height: 2160),
            frameRate: 60,
            averageBitrate: 20_000_000,
            maximumKeyframeInterval: 6
        )
        facts.maximumGOPBitrate = .unknown

        let validation = validator.validatePolicyCompliance(
            facts: facts,
            maximumResolution: .preset3840x2160
        )

        XCTAssertEqual(validation.disposition, .accepted)
    }

    func testGeneratedOutputMustPreservePlannedCodec() throws {
        var sourceFacts = compliantFacts(codec: .hevc)
        sourceFacts.maximumKeyframeInterval = .known(11)
        let conversion = try XCTUnwrap(makeConversion(facts: sourceFacts))
        let outputFacts = compliantFacts(codec: .h264)

        let validation = validator.validateGeneratedOutput(
            facts: outputFacts,
            sourceTimeline: validTimeline(),
            outputTimeline: validTimeline(),
            for: conversion
        )

        XCTAssertEqual(
            validation.disposition,
            .rejected(.doesNotMatchPlan([.videoCodec]))
        )
    }

    func testToneMappedOutputMustBeSDR() throws {
        let sourceFacts = compliantHDRFacts(dynamicRange: .hlg)
        let options = DirectUploadOptions.InputStandardization(
            maximumResolution: .default,
            hdrHandling: .toneMapToSDR
        )
        let plan = StandardInputPlanner().plan(
            facts: sourceFacts,
            options: options,
            capabilities: fullTestCapabilities()
        )
        guard case .convert(let conversion) = plan.action else {
            return XCTFail("Expected tone-map conversion")
        }

        let outputFacts = compliantFacts(codec: .hevc)
        var unexpectedHDROutput = outputFacts
        unexpectedHDROutput.pixelFormat = sourceFacts.pixelFormat
        unexpectedHDROutput.dynamicRange = sourceFacts.dynamicRange

        let validation = validator.validateGeneratedOutput(
            facts: unexpectedHDROutput,
            sourceTimeline: validTimeline(),
            outputTimeline: validTimeline(),
            for: conversion
        )

        XCTAssertEqual(
            validation.disposition,
            .rejected(.doesNotMatchPlan([.dynamicRange]))
        )
    }

    func testGeneratedOutputAcceptsDurationAndAVOffsetWithinNAT480Bounds() throws {
        var sourceFacts = compliantFacts(codec: .hevc)
        sourceFacts.maximumKeyframeInterval = .known(11)
        let conversion = try XCTUnwrap(makeConversion(facts: sourceFacts))

        let validation = validator.validateGeneratedOutput(
            facts: compliantFacts(codec: .hevc),
            sourceTimeline: validTimeline(duration: 10, offset: 0.010),
            outputTimeline: validTimeline(duration: 10.049, offset: 0.059),
            for: conversion
        )

        XCTAssertEqual(validation.disposition, .accepted)
    }

    func testGeneratedOutputRejectsDurationOutsideNAT480Bound() throws {
        var sourceFacts = compliantFacts(codec: .hevc)
        sourceFacts.maximumKeyframeInterval = .known(11)
        let conversion = try XCTUnwrap(makeConversion(facts: sourceFacts))

        let validation = validator.validateGeneratedOutput(
            facts: compliantFacts(codec: .hevc),
            sourceTimeline: validTimeline(duration: 8.115),
            outputTimeline: validTimeline(duration: 8.166667),
            for: conversion
        )

        XCTAssertEqual(
            validation.disposition,
            .rejected(.doesNotMatchPlan([.duration]))
        )
    }

    func testGeneratedOutputUsesOneFrameDurationBoundBelow20FPS() throws {
        var sourceFacts = compliantFacts(codec: .hevc)
        sourceFacts.maximumKeyframeInterval = .known(11)
        let conversion = try XCTUnwrap(makeConversion(facts: sourceFacts))

        let validation = validator.validateGeneratedOutput(
            facts: compliantFacts(codec: .hevc, frameRate: 15),
            sourceTimeline: validTimeline(duration: 10),
            outputTimeline: validTimeline(duration: 10.060),
            for: conversion
        )

        XCTAssertEqual(validation.disposition, .accepted)
    }

    func testGeneratedOutputRejectsAVOffsetOutsideNAT480Bound() throws {
        var sourceFacts = compliantFacts(codec: .hevc)
        sourceFacts.maximumKeyframeInterval = .known(11)
        let conversion = try XCTUnwrap(makeConversion(facts: sourceFacts))

        let validation = validator.validateGeneratedOutput(
            facts: compliantFacts(codec: .hevc),
            sourceTimeline: validTimeline(offset: -0.071),
            outputTimeline: validTimeline(offset: -0.020),
            for: conversion
        )

        XCTAssertEqual(
            validation.disposition,
            .rejected(.doesNotMatchPlan([.audioVideoStartOffset]))
        )
    }

    func testGeneratedOutputRejectsMissingIntegrityEvidence() throws {
        var sourceFacts = compliantFacts(codec: .hevc)
        sourceFacts.maximumKeyframeInterval = .known(11)
        let conversion = try XCTUnwrap(makeConversion(facts: sourceFacts))

        let validation = validator.validateGeneratedOutput(
            facts: compliantFacts(codec: .hevc),
            sourceTimeline: StandardInputTimelineFacts(),
            outputTimeline: StandardInputTimelineFacts(),
            for: conversion
        )

        XCTAssertEqual(
            validation.disposition,
            .rejected(
                .insufficientPlanEvidence([
                    .duration,
                    .audioVideoStartOffset
                ])
            )
        )
    }

    func testGeneratedOutputReportsKnownMismatchBeforeMissingEvidence() throws {
        var sourceFacts = compliantFacts(codec: .hevc)
        sourceFacts.maximumKeyframeInterval = .known(11)
        let conversion = try XCTUnwrap(makeConversion(facts: sourceFacts))

        let validation = validator.validateGeneratedOutput(
            facts: compliantFacts(codec: .h264),
            sourceTimeline: StandardInputTimelineFacts(),
            outputTimeline: StandardInputTimelineFacts(),
            for: conversion
        )

        XCTAssertEqual(
            validation.disposition,
            .rejected(.doesNotMatchPlan([.videoCodec]))
        )
    }

    func testGeneratedOutputRejectsChangedDisplayAspectRatio() throws {
        var sourceFacts = compliantFacts()
        sourceFacts.maximumKeyframeInterval = .known(21)
        let conversion = try XCTUnwrap(makeConversion(facts: sourceFacts))
        let outputFacts = compliantFacts(
            dimensions: .init(width: 1440, height: 1080)
        )

        let validation = validator.validateGeneratedOutput(
            facts: outputFacts,
            sourceTimeline: validTimeline(),
            outputTimeline: validTimeline(),
            for: conversion
        )

        XCTAssertEqual(
            validation.disposition,
            .rejected(.doesNotMatchPlan([.displayAspectRatio]))
        )
    }

    func testGeneratedOutputAcceptsPreservedPortraitAspectRatio() throws {
        var sourceFacts = compliantFacts(
            dimensions: .init(width: 1080, height: 1920)
        )
        sourceFacts.maximumKeyframeInterval = .known(21)
        let conversion = try XCTUnwrap(makeConversion(facts: sourceFacts))
        let outputFacts = compliantFacts(
            dimensions: .init(width: 720, height: 1280)
        )

        let validation = validator.validateGeneratedOutput(
            facts: outputFacts,
            sourceTimeline: validTimeline(),
            outputTimeline: validTimeline(),
            for: conversion
        )

        XCTAssertEqual(validation.disposition, .accepted)
    }

    func testGeneratedOutputAcceptsEvenAlignedAspectRatioRounding() throws {
        var sourceFacts = compliantFacts(
            dimensions: .init(width: 1918, height: 1080)
        )
        sourceFacts.maximumKeyframeInterval = .known(21)
        let conversion = try XCTUnwrap(makeConversion(facts: sourceFacts))
        let outputFacts = compliantFacts(
            dimensions: .init(width: 1280, height: 720)
        )

        let validation = validator.validateGeneratedOutput(
            facts: outputFacts,
            sourceTimeline: validTimeline(),
            outputTimeline: validTimeline(),
            for: conversion
        )

        XCTAssertEqual(validation.disposition, .accepted)
    }

    func testGeneratedOutputRejectsMissingSourceAspectRatioEvidence() throws {
        var sourceFacts = compliantFacts()
        sourceFacts.displayDimensions = .unknown
        sourceFacts.maximumKeyframeInterval = .known(21)
        let conversion = try XCTUnwrap(makeConversion(facts: sourceFacts))

        let validation = validator.validateGeneratedOutput(
            facts: compliantFacts(),
            sourceTimeline: validTimeline(),
            outputTimeline: validTimeline(),
            for: conversion
        )

        XCTAssertEqual(
            validation.disposition,
            .rejected(.insufficientPlanEvidence([.displayAspectRatio]))
        )
    }

    func testGeneratedOutputRejectsChangedAVApplicability() throws {
        var sourceFacts = compliantFacts(codec: .hevc)
        sourceFacts.maximumKeyframeInterval = .known(11)
        let conversion = try XCTUnwrap(makeConversion(facts: sourceFacts))

        let validation = validator.validateGeneratedOutput(
            facts: compliantFacts(codec: .hevc),
            sourceTimeline: validTimeline(offset: nil),
            outputTimeline: validTimeline(offset: 0),
            for: conversion
        )

        XCTAssertEqual(
            validation.disposition,
            .rejected(.doesNotMatchPlan([.audioVideoStartOffset]))
        )
    }

    func testGeneratedVideoOnlyOutputDoesNotRequireAVOffset() throws {
        var sourceFacts = compliantFacts(codec: .hevc)
        sourceFacts.maximumKeyframeInterval = .known(11)
        sourceFacts.audio = .known(.none)
        let conversion = try XCTUnwrap(makeConversion(facts: sourceFacts))
        var outputFacts = compliantFacts(codec: .hevc)
        outputFacts.audio = .known(.none)

        let validation = validator.validateGeneratedOutput(
            facts: outputFacts,
            sourceTimeline: validTimeline(offset: nil),
            outputTimeline: validTimeline(offset: nil),
            for: conversion
        )

        XCTAssertEqual(validation.disposition, .accepted)
    }

    private func makeConversion(
        facts: StandardInputMediaFacts
    ) -> StandardInputConversion? {
        let plan = StandardInputPlanner().plan(
            facts: facts,
            options: .default,
            capabilities: fullTestCapabilities()
        )
        guard case .convert(let conversion) = plan.action else {
            return nil
        }
        return conversion
    }

    private func validTimeline(
        duration: TimeInterval = 10,
        offset: TimeInterval? = 0
    ) -> StandardInputTimelineFacts {
        StandardInputTimelineFacts(
            duration: .known(duration),
            audioVideoStartOffset: .known(
                offset.map(StandardInputTimelineFacts.AudioVideoStartOffset.seconds)
                    ?? .notApplicable
            )
        )
    }
}

private func compliantHDRFacts(
    dynamicRange: StandardInputDynamicRange
) -> StandardInputMediaFacts {
    compliantFacts(
        codec: .hevc,
        maximumKeyframeInterval: 10,
        pixelFormat: .init(bitDepth: 10, chromaSubsampling: .yuv420),
        dynamicRange: dynamicRange
    )
}

private func compliantFacts(
    codec: StandardInputVideoCodec = .h264,
    dimensions: StandardInputDisplayDimensions = .init(width: 1920, height: 1080),
    frameRate: Double = 30,
    averageBitrate: Int64 = 4_000_000,
    maximumKeyframeInterval: TimeInterval = 2,
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
        maximumGOPBitrate: .known(5_000_000),
        maximumGOPByteSize: .unknown,
        maximumKeyframeInterval: .known(maximumKeyframeInterval),
        gopStructure: .known(.closedWithIDR),
        pixelFormat: .known(pixelFormat),
        dynamicRange: .known(dynamicRange),
        audio: .known(.aac(.stereo)),
        editList: .known(.simple)
    )
}

private func fullTestCapabilities() -> StandardInputPlanningCapabilities {
    StandardInputPlanningCapabilities(
        sourceIsDecodable: true,
        encodableVideoCodecs: [.h264, .hevc],
        remediableRequirements: Set(
            StandardInputPolicyEvaluation.Requirement.allCases
        ),
        toneMappableDynamicRanges: [.hlg, .pq],
        preservableHDRDynamicRanges: [.hlg, .pq]
    )
}
