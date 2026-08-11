//
//  StandardInputOutputValidator.swift
//

import Foundation

struct StandardInputTimelineFacts: Equatable {
    enum AudioVideoStartOffset: Equatable {
        case notApplicable
        case seconds(TimeInterval)
    }

    var duration: StandardInputFact<TimeInterval> = .unknown
    var audioVideoStartOffset: StandardInputFact<AudioVideoStartOffset> = .unknown
}

struct StandardInputOutputValidation: Equatable {
    enum PlanExpectation: Hashable {
        case videoCodec
        case dynamicRange
        case displayAspectRatio
        case duration
        case audioVideoStartOffset
    }

    enum RejectionReason: Equatable {
        case nonCompliant(Set<StandardInputPolicyEvaluation.Requirement>)
        case insufficientPolicyEvidence(
            Set<StandardInputPolicyEvaluation.Requirement>
        )
        case insufficientPlanEvidence(Set<PlanExpectation>)
        case doesNotMatchPlan(Set<PlanExpectation>)
    }

    enum Disposition: Equatable {
        case accepted
        case rejected(RejectionReason)
    }

    let disposition: Disposition
    let evaluation: StandardInputPolicyEvaluation

    var isAccepted: Bool {
        disposition == .accepted
    }
}

struct StandardInputOutputValidator {
    /// Duration may change by one output frame or 50ms, whichever is larger.
    /// A/V-start-offset changes remain bounded at 50ms.
    static let minimumDurationDelta: TimeInterval = 0.050
    static let maximumAudioVideoStartOffsetDelta: TimeInterval = 0.050

    /// Video encoders commonly align dimensions to even pixel counts. Permit
    /// that rounding on both output axes without accepting a material
    /// aspect-ratio change.
    static let maximumAspectRatioDimensionError = 2.0

    let evaluator: StandardInputPolicyEvaluator

    init(evaluator: StandardInputPolicyEvaluator = StandardInputPolicyEvaluator()) {
        self.evaluator = evaluator
    }

    func validatePolicyCompliance(
        facts: StandardInputMediaFacts,
        maximumResolution: DirectUploadOptions.InputStandardization.MaximumResolution
    ) -> StandardInputOutputValidation {
        validate(
            facts: facts,
            selection: StandardInputPolicySelection(
                maximumResolution: maximumResolution
            ),
            expectedCodec: nil,
            expectedDynamicRange: nil,
            sourceTimeline: nil,
            outputTimeline: nil,
            sourceDisplayDimensions: nil
        )
    }

    func validateGeneratedOutput(
        facts: StandardInputMediaFacts,
        sourceTimeline: StandardInputTimelineFacts,
        outputTimeline: StandardInputTimelineFacts,
        for conversion: StandardInputConversion
    ) -> StandardInputOutputValidation {
        validate(
            facts: facts,
            selection: conversion.selection,
            expectedCodec: conversion.outputCodec,
            expectedDynamicRange: conversion.toneMapsToSDR
                ? .sdr
                : conversion.sourceDynamicRange,
            sourceTimeline: sourceTimeline,
            outputTimeline: outputTimeline,
            sourceDisplayDimensions: conversion.sourceDisplayDimensions
        )
    }

    private func validate(
        facts: StandardInputMediaFacts,
        selection: StandardInputPolicySelection,
        expectedCodec: StandardInputVideoCodec?,
        expectedDynamicRange: StandardInputDynamicRange?,
        sourceTimeline: StandardInputTimelineFacts?,
        outputTimeline: StandardInputTimelineFacts?,
        sourceDisplayDimensions: StandardInputFact<StandardInputDisplayDimensions>?
    ) -> StandardInputOutputValidation {
        let evaluation = evaluator.evaluate(
            facts,
            selection: selection,
            role: .generatedOutput
        )

        if !evaluation.nonCompliantRequirements.isEmpty {
            return StandardInputOutputValidation(
                disposition: .rejected(
                    .nonCompliant(Set(evaluation.nonCompliantRequirements))
                ),
                evaluation: evaluation
            )
        }
        if !evaluation.unknownRequirements.isEmpty {
            return StandardInputOutputValidation(
                disposition: .rejected(
                    .insufficientPolicyEvidence(
                        Set(evaluation.unknownRequirements)
                    )
                ),
                evaluation: evaluation
            )
        }

        var insufficientEvidence: Set<StandardInputOutputValidation.PlanExpectation> = []
        var mismatches: Set<StandardInputOutputValidation.PlanExpectation> = []

        if let expectedCodec, facts.videoCodec.value != expectedCodec {
            mismatches.insert(.videoCodec)
        }
        if let expectedDynamicRange,
           facts.dynamicRange.value != expectedDynamicRange {
            mismatches.insert(.dynamicRange)
        }

        if let sourceDisplayDimensions {
            if let sourceDimensions = validDimensions(sourceDisplayDimensions),
               let outputDimensions = validDimensions(facts.displayDimensions) {
                if !preservesAspectRatio(
                    source: sourceDimensions,
                    output: outputDimensions
                ) {
                    mismatches.insert(.displayAspectRatio)
                }
            } else {
                insufficientEvidence.insert(.displayAspectRatio)
            }
        }

        if let sourceTimeline, let outputTimeline {
            compareTimeline(
                source: sourceTimeline,
                output: outputTimeline,
                outputFrameRate: facts.frameRate,
                insufficientEvidence: &insufficientEvidence,
                mismatches: &mismatches
            )
        }

        return result(
            evaluation: evaluation,
            insufficientEvidence: insufficientEvidence,
            mismatches: mismatches
        )
    }

    private func compareTimeline(
        source: StandardInputTimelineFacts,
        output: StandardInputTimelineFacts,
        outputFrameRate: StandardInputFact<Double>,
        insufficientEvidence: inout Set<StandardInputOutputValidation.PlanExpectation>,
        mismatches: inout Set<StandardInputOutputValidation.PlanExpectation>
    ) {
        if let sourceDuration = positiveFinite(source.duration),
           let outputDuration = positiveFinite(output.duration),
           let frameRate = positiveFinite(outputFrameRate) {
            let maximumDurationDelta = max(
                Self.minimumDurationDelta,
                1.0 / frameRate
            )
            if abs(sourceDuration - outputDuration) > maximumDurationDelta {
                mismatches.insert(.duration)
            }
        } else {
            insufficientEvidence.insert(.duration)
        }

        guard let sourceOffset = source.audioVideoStartOffset.value,
              let outputOffset = output.audioVideoStartOffset.value else {
            insufficientEvidence.insert(.audioVideoStartOffset)
            return
        }

        switch (sourceOffset, outputOffset) {
        case (.notApplicable, .notApplicable):
            break
        case (.seconds(let source), .seconds(let output))
            where source.isFinite && output.isFinite:
            if abs(source - output)
                > Self.maximumAudioVideoStartOffsetDelta {
                mismatches.insert(.audioVideoStartOffset)
            }
        default:
            mismatches.insert(.audioVideoStartOffset)
        }
    }

    private func result(
        evaluation: StandardInputPolicyEvaluation,
        insufficientEvidence: Set<StandardInputOutputValidation.PlanExpectation>,
        mismatches: Set<StandardInputOutputValidation.PlanExpectation>
    ) -> StandardInputOutputValidation {
        let disposition: StandardInputOutputValidation.Disposition
        if !mismatches.isEmpty {
            disposition = .rejected(.doesNotMatchPlan(mismatches))
        } else if !insufficientEvidence.isEmpty {
            disposition = .rejected(
                .insufficientPlanEvidence(insufficientEvidence)
            )
        } else {
            disposition = .accepted
        }
        return StandardInputOutputValidation(
            disposition: disposition,
            evaluation: evaluation
        )
    }

    private func validDimensions(
        _ fact: StandardInputFact<StandardInputDisplayDimensions>
    ) -> StandardInputDisplayDimensions? {
        guard let dimensions = fact.value,
              dimensions.width > 0,
              dimensions.height > 0 else {
            return nil
        }
        return dimensions
    }

    private func positiveFinite(
        _ fact: StandardInputFact<TimeInterval>
    ) -> TimeInterval? {
        guard let value = fact.value, value.isFinite, value > 0 else {
            return nil
        }
        return value
    }

    private func preservesAspectRatio(
        source: StandardInputDisplayDimensions,
        output: StandardInputDisplayDimensions
    ) -> Bool {
        let dimensionError = Self.maximumAspectRatioDimensionError
        let widthScaleRange = (
            lower: (Double(output.width) - dimensionError) / Double(source.width),
            upper: (Double(output.width) + dimensionError) / Double(source.width)
        )
        let heightScaleRange = (
            lower: (Double(output.height) - dimensionError) / Double(source.height),
            upper: (Double(output.height) + dimensionError) / Double(source.height)
        )
        let minimumScale = max(
            0,
            max(widthScaleRange.lower, heightScaleRange.lower)
        )
        let maximumScale = min(widthScaleRange.upper, heightScaleRange.upper)
        return minimumScale <= maximumScale
    }
}
