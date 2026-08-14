//
//  StandardInputPlanner.swift
//

import Foundation

struct StandardInputPlanningCapabilities: Equatable {
    /// Capabilities are supplied for the current source and device. This keeps
    /// hardware probing and asset-specific decode checks outside the pure planner.
    var sourceIsDecodable: Bool
    var encodableVideoCodecs: Set<StandardInputVideoCodec>
    var remediableRequirements: Set<StandardInputPolicyEvaluation.Requirement>
    var toneMappableDynamicRanges: Set<StandardInputDynamicRange>

    /// HDR ranges eligible for intentional unchanged upload. The caller owns
    /// server/configuration eligibility, especially for PQ input.
    var preservableHDRDynamicRanges: Set<StandardInputDynamicRange>

    func supports(_ conversion: StandardInputConversion) -> Bool {
        sourceIsDecodable
            && encodableVideoCodecs.contains(conversion.outputCodec)
            && remediableRequirements.isSuperset(
                of: conversion.requirementsToRemediate
            )
            && (!conversion.toneMapsToSDR
                || toneMappableDynamicRanges.contains(conversion.sourceDynamicRange))
    }
}

struct StandardInputConversion: Equatable, Sendable {
    let sourceCodec: StandardInputVideoCodec
    let outputCodec: StandardInputVideoCodec
    let sourceDynamicRange: StandardInputDynamicRange
    let sourceDisplayDimensions: StandardInputFact<StandardInputDisplayDimensions>
    let toneMapsToSDR: Bool
    let selection: StandardInputPolicySelection
    let requirementsToRemediate: Set<StandardInputPolicyEvaluation.Requirement>
}

struct StandardInputPlan: Equatable {
    enum UploadOriginalReason: Equatable {
        case standardizationNotRequested
        case standardInput
        case noKnownStandardInputViolation
        case preserveHDR(StandardInputDynamicRange)
    }

    enum FallbackReason: Equatable {
        case insufficientEvidenceForConversion
        case unsupportedConversion(StandardInputConversion)
        case unsupportedHDR(StandardInputDynamicRange)
        case hdrPreservationUnavailable(StandardInputDynamicRange)
        case nonStandardHDR(
            StandardInputDynamicRange,
            Set<StandardInputPolicyEvaluation.Requirement>
        )
    }

    enum Action: Equatable {
        case uploadOriginal(UploadOriginalReason)
        case convert(StandardInputConversion)
        case fallback(FallbackReason)
    }

    let action: Action
    let evaluation: StandardInputPolicyEvaluation
}

struct StandardInputPlanner {
    let evaluator: StandardInputPolicyEvaluator

    init(evaluator: StandardInputPolicyEvaluator = StandardInputPolicyEvaluator()) {
        self.evaluator = evaluator
    }

    func plan(
        facts: StandardInputMediaFacts,
        options: DirectUploadOptions.InputStandardization,
        capabilities: StandardInputPlanningCapabilities
    ) -> StandardInputPlan {
        let selection = StandardInputPolicySelection(
            maximumResolution: options.maximumResolution
        )
        let evaluation = evaluator.evaluate(
            facts,
            selection: selection,
            role: .sourceInput
        )

        guard options.isRequested else {
            return StandardInputPlan(
                action: .uploadOriginal(.standardizationNotRequested),
                evaluation: evaluation
            )
        }

        var requirementsToRemediate = Set(
            evaluation.nonCompliantRequirements
        )
        if let dimensions = facts.displayDimensions.value,
           dimensions.width > 0,
           dimensions.height > 0,
           !dimensions.fitsWithin(selection.generatedOutputDimensions) {
            requirementsToRemediate.insert(.videoResolution)
        }

        switch facts.dynamicRange.value {
        case .hlg?:
            return planHDR(
                dynamicRange: .hlg,
                facts: facts,
                options: options,
                capabilities: capabilities,
                selection: selection,
                evaluation: evaluation,
                requirementsToRemediate: requirementsToRemediate
            )
        case .pq?:
            return planHDR(
                dynamicRange: .pq,
                facts: facts,
                options: options,
                capabilities: capabilities,
                selection: selection,
                evaluation: evaluation,
                requirementsToRemediate: requirementsToRemediate
            )
        case .otherHDR?:
            return StandardInputPlan(
                action: .fallback(.unsupportedHDR(.otherHDR)),
                evaluation: evaluation
            )
        case .sdr?:
            break
        case nil:
            guard requirementsToRemediate.isEmpty else {
                return StandardInputPlan(
                    action: .fallback(.insufficientEvidenceForConversion),
                    evaluation: evaluation
                )
            }
        }

        guard !requirementsToRemediate.isEmpty else {
            let reason: StandardInputPlan.UploadOriginalReason =
                evaluation.outcome == .compliant
                    ? .standardInput
                    : .noKnownStandardInputViolation
            return StandardInputPlan(
                action: .uploadOriginal(reason),
                evaluation: evaluation
            )
        }

        return planConversion(
            facts: facts,
            capabilities: capabilities,
            selection: selection,
            evaluation: evaluation,
            requirementsToRemediate: requirementsToRemediate,
            toneMapsToSDR: false
        )
    }

    private func planHDR(
        dynamicRange: StandardInputDynamicRange,
        facts: StandardInputMediaFacts,
        options: DirectUploadOptions.InputStandardization,
        capabilities: StandardInputPlanningCapabilities,
        selection: StandardInputPolicySelection,
        evaluation: StandardInputPolicyEvaluation,
        requirementsToRemediate: Set<StandardInputPolicyEvaluation.Requirement>
    ) -> StandardInputPlan {
        switch options.hdrHandling {
        case .preserve:
            guard evaluation.status(for: .dynamicRange) == .compliant else {
                return StandardInputPlan(
                    action: .fallback(.unsupportedHDR(dynamicRange)),
                    evaluation: evaluation
                )
            }
            guard capabilities.preservableHDRDynamicRanges.contains(dynamicRange) else {
                return StandardInputPlan(
                    action: .fallback(.hdrPreservationUnavailable(dynamicRange)),
                    evaluation: evaluation
                )
            }
            guard requirementsToRemediate.isEmpty else {
                return StandardInputPlan(
                    action: .fallback(
                        .nonStandardHDR(dynamicRange, requirementsToRemediate)
                    ),
                    evaluation: evaluation
                )
            }
            return StandardInputPlan(
                action: .uploadOriginal(.preserveHDR(dynamicRange)),
                evaluation: evaluation
            )
        case .toneMapToSDR:
            guard facts.videoCodec.value == .h264
                    || facts.videoCodec.value == .hevc else {
                return StandardInputPlan(
                    action: .fallback(.unsupportedHDR(dynamicRange)),
                    evaluation: evaluation
                )
            }
            return planConversion(
                facts: facts,
                capabilities: capabilities,
                selection: selection,
                evaluation: evaluation,
                requirementsToRemediate: requirementsToRemediate,
                toneMapsToSDR: true
            )
        }
    }

    private func planConversion(
        facts: StandardInputMediaFacts,
        capabilities: StandardInputPlanningCapabilities,
        selection: StandardInputPolicySelection,
        evaluation: StandardInputPolicyEvaluation,
        requirementsToRemediate: Set<StandardInputPolicyEvaluation.Requirement>,
        toneMapsToSDR: Bool
    ) -> StandardInputPlan {
        guard let sourceCodec = facts.videoCodec.value,
              let sourceDynamicRange = facts.dynamicRange.value else {
            return StandardInputPlan(
                action: .fallback(.insufficientEvidenceForConversion),
                evaluation: evaluation
            )
        }

        let outputCodec: StandardInputVideoCodec
        switch sourceCodec {
        case .h264, .hevc:
            outputCodec = sourceCodec
        case .other:
            outputCodec = .h264
        }

        let conversion = StandardInputConversion(
            sourceCodec: sourceCodec,
            outputCodec: outputCodec,
            sourceDynamicRange: sourceDynamicRange,
            sourceDisplayDimensions: facts.displayDimensions,
            toneMapsToSDR: toneMapsToSDR,
            selection: selection,
            requirementsToRemediate: requirementsToRemediate
        )

        return StandardInputPlan(
            action: capabilities.supports(conversion)
                ? .convert(conversion)
                : .fallback(.unsupportedConversion(conversion)),
            evaluation: evaluation
        )
    }
}
