//
//  StandardizationDiagnostics.swift
//

import Foundation

protocol StandardizationDiagnosticLogging: Sendable {
    func log(_ diagnostic: StandardizationDiagnostic) async
}

struct SDKStandardizationDiagnosticLogger: StandardizationDiagnosticLogging {
    func log(_ diagnostic: StandardizationDiagnostic) async {
        SDKLogger.logStandardizationDiagnostic(diagnostic)
    }
}

/// A closed diagnostic payload whose rendered form is safe for public OSLog output.
/// Keep associated values typed and controlled: never add caller-supplied strings,
/// URLs, errors, paths, credentials, headers, or tokens.
enum StandardizationDiagnostic: Equatable, Sendable {
    enum InspectionRole: String, Sendable {
        case source
        case generatedOutput = "generated_output"
    }

    enum FailureCategory: String, Sendable {
        case inspection
        case capability
        case planning
        case storage
        case conversion
        case outputInspection = "output_inspection"
        case outputValidation = "output_validation"
    }

    enum FailureReason: String, Sendable {
        case inspectionFailed = "inspection_failed"
        case insufficientEvidence = "insufficient_evidence"
        case unsupportedConversion = "unsupported_conversion"
        case unsupportedHDR = "unsupported_hdr"
        case hdrPreservationUnavailable = "hdr_preservation_unavailable"
        case nonStandardHDR = "non_standard_hdr"
        case storagePreflightFailed = "storage_preflight_failed"
        case conversionFailed = "conversion_failed"
        case outputInspectionFailed = "output_inspection_failed"
        case outputNonCompliant = "output_non_compliant"
        case insufficientOutputPolicyEvidence = "insufficient_output_policy_evidence"
        case insufficientOutputPlanEvidence = "insufficient_output_plan_evidence"
        case outputDoesNotMatchPlan = "output_does_not_match_plan"
    }

    case inspection(
        role: InspectionRole,
        facts: StandardInputMediaFacts,
        legacyReasons: [UploadInputFormatInspectionResult.NonstandardInputReason]
    )
    case plan(
        StandardInputPlan,
        facts: StandardInputMediaFacts,
        options: DirectUploadOptions.InputStandardization
    )
    case conversionCompleted(
        StandardInputConversion,
        durationMilliseconds: Int
    )
    case outputValidation(StandardInputOutputValidation)
    case failure(
        category: FailureCategory,
        reason: FailureReason,
        conversion: StandardInputConversion?,
        durationMilliseconds: Int?
    )

    var message: String {
        // Every rendered value must come from a closed vocabulary or sanitized
        // numeric media fact. This message is logged with `privacy: .public`.
        // Never interpolate caller-supplied strings or error descriptions here.
        switch self {
        case .inspection(let role, let facts, let legacyReasons):
            let codecKey = role == .source ? "source_codec" : "output_codec"
            return fields([
                "event=inspection_completed",
                "role=\(role.rawValue)",
                "\(codecKey)=\(codec(facts.videoCodec))",
                "dimensions=\(dimensions(facts.displayDimensions))",
                "frame_rate=\(finite(facts.frameRate))",
                "average_bitrate=\(integer(facts.averageBitrate))",
                "maximum_gop_bitrate=\(integer(facts.maximumGOPBitrate))",
                "maximum_gop_byte_size=\(integer(facts.maximumGOPByteSize))",
                "maximum_keyframe_interval=\(finite(facts.maximumKeyframeInterval))",
                "gop_structure=\(gopStructure(facts.gopStructure))",
                "pixel_format=\(pixelFormat(facts.pixelFormat))",
                "dynamic_range=\(dynamicRange(facts.dynamicRange))",
                "audio=\(audio(facts.audio))",
                "edit_list=\(editList(facts.editList))",
                "legacy_nonstandard_reasons=\(list(legacyReasons.map(\.description)))"
            ])
        case .plan(let plan, let facts, let options):
            let action = planAction(
                plan.action,
                sourceCodec: facts.videoCodec.value
            )
            return fields([
                "event=plan_selected",
                "plan=\(action.name)",
                "plan_reason=\(action.reason)",
                "source_codec=\(action.sourceCodec)",
                "output_codec=\(action.outputCodec)",
                "resolution_tier=\(resolutionTier(options.maximumResolution))",
                "hdr_handling=\(hdrHandling(options.hdrHandling))",
                "hdr_decision=\(hdrDecision(plan.action))",
                "policy_outcome=\(policyOutcome(plan.evaluation.outcome))",
                "noncompliant_requirements=\(requirements(plan.evaluation.nonCompliantRequirements))",
                "unknown_requirements=\(requirements(plan.evaluation.unknownRequirements))"
            ])
        case .conversionCompleted(let conversion, let durationMilliseconds):
            return fields([
                "event=conversion_completed",
                "source_codec=\(codec(conversion.sourceCodec))",
                "output_codec=\(codec(conversion.outputCodec))",
                "resolution_tier=\(resolutionTier(conversion.selection))",
                "hdr_action=\(conversion.toneMapsToSDR ? "tone_map_to_sdr" : "preserve")",
                "conversion_duration_ms=\(max(0, durationMilliseconds))"
            ])
        case .outputValidation(let validation):
            return fields([
                "event=output_validation_completed",
                "result=\(validationResult(validation.disposition))",
                "policy_outcome=\(policyOutcome(validation.evaluation.outcome))"
            ])
        case .failure(let category, let reason, let conversion, let durationMilliseconds):
            var values = [
                "event=standardization_failure",
                "failure_category=\(category.rawValue)",
                "failure_reason=\(reason.rawValue)"
            ]
            if let conversion {
                values.append("source_codec=\(codec(conversion.sourceCodec))")
                values.append("output_codec=\(codec(conversion.outputCodec))")
                values.append("resolution_tier=\(resolutionTier(conversion.selection))")
                values.append(
                    "hdr_action=\(conversion.toneMapsToSDR ? "tone_map_to_sdr" : "preserve")"
                )
            }
            if let durationMilliseconds {
                values.append("conversion_duration_ms=\(max(0, durationMilliseconds))")
            }
            return fields(values)
        }
    }

    static func plannerFailure(
        _ reason: StandardInputPlan.FallbackReason
    ) -> (FailureCategory, FailureReason) {
        switch reason {
        case .insufficientEvidenceForConversion:
            return (.planning, .insufficientEvidence)
        case .unsupportedConversion:
            return (.capability, .unsupportedConversion)
        case .unsupportedHDR:
            return (.planning, .unsupportedHDR)
        case .hdrPreservationUnavailable:
            return (.capability, .hdrPreservationUnavailable)
        case .nonStandardHDR:
            return (.planning, .nonStandardHDR)
        }
    }

    static func validationFailure(
        _ validation: StandardInputOutputValidation
    ) -> FailureReason {
        guard case .rejected(let reason) = validation.disposition else {
            return .outputDoesNotMatchPlan
        }
        switch reason {
        case .nonCompliant:
            return .outputNonCompliant
        case .insufficientPolicyEvidence:
            return .insufficientOutputPolicyEvidence
        case .insufficientPlanEvidence:
            return .insufficientOutputPlanEvidence
        case .doesNotMatchPlan:
            return .outputDoesNotMatchPlan
        }
    }

    private func fields(_ values: [String]) -> String {
        (["standard_input"] + values).joined(separator: " ")
    }

    private func planAction(
        _ action: StandardInputPlan.Action,
        sourceCodec: StandardInputVideoCodec?
    ) -> (name: String, reason: String, sourceCodec: String, outputCodec: String) {
        let sourceCodecDescription = sourceCodec.map(codec) ?? "unknown"
        switch action {
        case .uploadOriginal(let reason):
            return (
                "upload_original",
                uploadOriginalReason(reason),
                sourceCodecDescription,
                sourceCodecDescription
            )
        case .convert(let conversion):
            return (
                "convert",
                conversion.toneMapsToSDR ? "tone_map_to_sdr" : "remediate_noncompliance",
                codec(conversion.sourceCodec),
                codec(conversion.outputCodec)
            )
        case .fallback(let reason):
            return (
                "fallback",
                Self.plannerFailure(reason).1.rawValue,
                sourceCodecDescription,
                sourceCodecDescription
            )
        }
    }

    private func uploadOriginalReason(
        _ reason: StandardInputPlan.UploadOriginalReason
    ) -> String {
        switch reason {
        case .standardizationNotRequested:
            return "standardization_not_requested"
        case .standardInput:
            return "standard_input"
        case .noKnownStandardInputViolation:
            return "no_known_violation"
        case .preserveHDR(.hlg):
            return "preserve_hlg"
        case .preserveHDR(.pq):
            return "preserve_pq"
        case .preserveHDR(.sdr):
            return "invalid_preserve_sdr"
        case .preserveHDR(.otherHDR):
            return "invalid_preserve_other_hdr"
        }
    }

    private func hdrDecision(_ action: StandardInputPlan.Action) -> String {
        switch action {
        case .uploadOriginal(.preserveHDR(.hlg)):
            return "preserve_hlg_for_mux_processing"
        case .uploadOriginal(.preserveHDR(.pq)):
            return "preserve_pq_for_compatible_server_processing"
        case .convert(let conversion) where conversion.toneMapsToSDR:
            return "tone_map_to_sdr"
        case .fallback:
            return "fallback_to_original"
        default:
            return "not_applicable"
        }
    }

    private func codec(_ fact: StandardInputFact<StandardInputVideoCodec>) -> String {
        fact.value.map(codec) ?? "unknown"
    }

    private func codec(_ codec: StandardInputVideoCodec) -> String {
        switch codec {
        case .h264: return "h264"
        case .hevc: return "hevc"
        case .other: return "other"
        }
    }

    private func dimensions(
        _ fact: StandardInputFact<StandardInputDisplayDimensions>
    ) -> String {
        guard let value = fact.value else { return "unknown" }
        return "\(value.width)x\(value.height)"
    }

    private func integer(_ fact: StandardInputFact<Int64>) -> String {
        fact.value.map(String.init) ?? "unknown"
    }

    private func finite(_ fact: StandardInputFact<Double>) -> String {
        guard let value = fact.value, value.isFinite else { return "unknown" }
        return String(format: "%.3f", value)
    }

    private func gopStructure(
        _ fact: StandardInputFact<StandardInputGOPStructure>
    ) -> String {
        switch fact.value {
        case .closedWithIDR?: return "closed_with_idr"
        case .closedWithoutIDR?: return "closed_without_idr"
        case .open?: return "open"
        case nil: return "unknown"
        }
    }

    private func pixelFormat(
        _ fact: StandardInputFact<StandardInputPixelFormat>
    ) -> String {
        guard let value = fact.value else { return "unknown" }
        let chroma = value.chromaSubsampling == .yuv420 ? "yuv420" : "other"
        return "\(value.bitDepth)bit_\(chroma)"
    }

    private func dynamicRange(
        _ fact: StandardInputFact<StandardInputDynamicRange>
    ) -> String {
        fact.value.map(dynamicRange) ?? "unknown"
    }

    private func dynamicRange(_ value: StandardInputDynamicRange) -> String {
        switch value {
        case .sdr: return "sdr"
        case .hlg: return "hlg"
        case .pq: return "pq"
        case .otherHDR: return "other_hdr"
        }
    }

    private func audio(_ fact: StandardInputFact<StandardInputAudio>) -> String {
        switch fact.value {
        case .none?: return "none"
        case .aac(.mono)?: return "aac_mono"
        case .aac(.stereo)?: return "aac_stereo"
        case .aac(.fivePointOne)?: return "aac_5_1"
        case .aac(.other)?: return "aac_other"
        case .otherCodec?: return "other_codec"
        case nil: return "unknown"
        }
    }

    private func editList(_ fact: StandardInputFact<StandardInputEditList>) -> String {
        switch fact.value {
        case .none?: return "none"
        case .simple?: return "simple"
        case .complex?: return "complex"
        case nil: return "unknown"
        }
    }

    private func resolutionTier(
        _ maximumResolution: DirectUploadOptions.InputStandardization.MaximumResolution
    ) -> String {
        switch maximumResolution {
        case .preset1280x720: return "720p"
        case .default, .preset1920x1080: return "1080p"
        case .preset2560x1440: return "1440p"
        case .preset3840x2160: return "2160p"
        }
    }

    private func resolutionTier(_ selection: StandardInputPolicySelection) -> String {
        switch (
            selection.generatedOutputDimensions.width,
            selection.generatedOutputDimensions.height
        ) {
        case (1280, 720): return "720p"
        case (1920, 1080): return "1080p"
        case (2560, 1440): return "1440p"
        case (3840, 2160): return "2160p"
        default: return "unknown"
        }
    }

    private func hdrHandling(
        _ value: DirectUploadOptions.InputStandardization.HDRHandling
    ) -> String {
        switch value {
        case .preserve: return "preserve"
        case .toneMapToSDR: return "tone_map_to_sdr"
        }
    }

    private func policyOutcome(_ outcome: StandardInputPolicyEvaluation.Outcome) -> String {
        switch outcome {
        case .compliant: return "compliant"
        case .nonCompliant: return "non_compliant"
        case .unknown: return "unknown"
        }
    }

    private func requirements(
        _ values: [StandardInputPolicyEvaluation.Requirement]
    ) -> String {
        list(values.map(requirement).sorted())
    }

    private func requirement(
        _ value: StandardInputPolicyEvaluation.Requirement
    ) -> String {
        switch value {
        case .videoCodec: return "video_codec"
        case .videoResolution: return "video_resolution"
        case .frameRate: return "frame_rate"
        case .averageBitrate: return "average_bitrate"
        case .maximumGOPBitrate: return "maximum_gop_bitrate"
        case .keyframeInterval: return "keyframe_interval"
        case .gopStructure: return "gop_structure"
        case .pixelFormat: return "pixel_format"
        case .dynamicRange: return "dynamic_range"
        case .audio: return "audio"
        case .editList: return "edit_list"
        }
    }

    private func validationResult(
        _ disposition: StandardInputOutputValidation.Disposition
    ) -> String {
        switch disposition {
        case .accepted: return "accepted"
        case .rejected(.nonCompliant): return "rejected_non_compliant"
        case .rejected(.insufficientPolicyEvidence):
            return "rejected_insufficient_policy_evidence"
        case .rejected(.insufficientPlanEvidence):
            return "rejected_insufficient_plan_evidence"
        case .rejected(.doesNotMatchPlan): return "rejected_plan_mismatch"
        }
    }

    private func list(_ values: [String]) -> String {
        values.isEmpty ? "none" : values.sorted().joined(separator: ",")
    }
}
