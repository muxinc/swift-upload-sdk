//
//  StandardInputPolicy.swift
//

import Foundation

enum StandardInputFact<Value> {
    case known(Value)
    case unknown

    var value: Value? {
        guard case .known(let value) = self else {
            return nil
        }

        return value
    }
}

extension StandardInputFact: Equatable where Value: Equatable { }

enum StandardInputVideoCodec: Hashable {
    case h264
    case hevc
    case other
}

struct StandardInputDisplayDimensions: Equatable {
    let width: Int
    let height: Int

    var maximumDimension: Int {
        max(width, height)
    }

    var minimumDimension: Int {
        min(width, height)
    }

    func fitsWithin(_ other: StandardInputDisplayDimensions) -> Bool {
        maximumDimension <= other.maximumDimension
            && minimumDimension <= other.minimumDimension
    }
}

struct StandardInputPixelFormat: Hashable {
    enum ChromaSubsampling: Hashable {
        case yuv420
        case other
    }

    let bitDepth: Int
    let chromaSubsampling: ChromaSubsampling
}

enum StandardInputDynamicRange: Hashable {
    case sdr
    case hlg
    case pq
    case otherHDR
}

enum StandardInputGOPStructure: Hashable {
    case closedWithIDR
    case closedWithoutIDR
    case open
}

enum StandardInputAudio: Hashable {
    enum ChannelLayout: Hashable {
        case mono
        case stereo
        case fivePointOne
        case other
    }

    case none
    case aac(ChannelLayout)
    case otherCodec
}

enum StandardInputEditList: Hashable {
    case none
    case simple
    case complex
}

struct StandardInputMediaFacts: Equatable {
    var videoCodec: StandardInputFact<StandardInputVideoCodec> = .unknown
    var displayDimensions: StandardInputFact<StandardInputDisplayDimensions> = .unknown
    var frameRate: StandardInputFact<Double> = .unknown
    var averageBitrate: StandardInputFact<Int64> = .unknown
    var maximumGOPBitrate: StandardInputFact<Int64> = .unknown
    var maximumGOPByteSize: StandardInputFact<Int64> = .unknown
    var maximumKeyframeInterval: StandardInputFact<TimeInterval> = .unknown
    var gopStructure: StandardInputFact<StandardInputGOPStructure> = .unknown
    var pixelFormat: StandardInputFact<StandardInputPixelFormat> = .unknown
    var dynamicRange: StandardInputFact<StandardInputDynamicRange> = .unknown
    var audio: StandardInputFact<StandardInputAudio> = .unknown
    var editList: StandardInputFact<StandardInputEditList> = .unknown
}

enum StandardInputAcceptanceTier: Hashable {
    case upTo1080p
    case highResolution
}

struct StandardInputPolicySelection: Equatable {
    let acceptanceTier: StandardInputAcceptanceTier
    let generatedOutputDimensions: StandardInputDisplayDimensions

    init(
        maximumResolution: DirectUploadOptions.InputStandardization.MaximumResolution
    ) {
        switch maximumResolution {
        case .preset1280x720:
            self.acceptanceTier = .upTo1080p
            self.generatedOutputDimensions = StandardInputDisplayDimensions(
                width: 1280,
                height: 720
            )
        case .default, .preset1920x1080:
            self.acceptanceTier = .upTo1080p
            self.generatedOutputDimensions = StandardInputDisplayDimensions(
                width: 1920,
                height: 1080
            )
        case .preset2560x1440:
            self.acceptanceTier = .highResolution
            self.generatedOutputDimensions = StandardInputDisplayDimensions(
                width: 2560,
                height: 1440
            )
        case .preset3840x2160:
            self.acceptanceTier = .highResolution
            self.generatedOutputDimensions = StandardInputDisplayDimensions(
                width: 3840,
                height: 2160
            )
        }
    }
}

enum StandardInputMediaRole {
    case sourceInput
    case generatedOutput
}

struct StandardInputPolicyProfile {
    struct TierLimits {
        let maximumSourceDimension: Int
        let frameRateRange: ClosedRange<Double>
        let maximumAverageBitrate: Int64
        let maximumGOPBitrate: Int64?
        let maximumKeyframeIntervals: [StandardInputVideoCodec: TimeInterval]
    }

    let upTo1080pLimits: TierLimits
    let highResolutionLimits: TierLimits
    let supportedVideoCodecs: Set<StandardInputVideoCodec>
    let supportedGOPStructures: Set<StandardInputGOPStructure>
    let supportedPixelFormats: [
        StandardInputVideoCodec: Set<StandardInputPixelFormat>
    ]
    let supportedDynamicRanges: Set<StandardInputDynamicRange>
    let supportedHDRVideoCodecs: Set<StandardInputVideoCodec>
    let supportedHDRPixelFormats: Set<StandardInputPixelFormat>
    let supportedAudio: Set<StandardInputAudio>
    let supportedEditLists: Set<StandardInputEditList>

    func limits(for tier: StandardInputAcceptanceTier) -> TierLimits {
        switch tier {
        case .upTo1080p:
            return upTo1080pLimits
        case .highResolution:
            return highResolutionLimits
        }
    }
}

extension StandardInputPolicyProfile {
    static let publishedMux = StandardInputPolicyProfile(
        upTo1080pLimits: TierLimits(
            maximumSourceDimension: 2048,
            frameRateRange: 5.0...120.0,
            maximumAverageBitrate: 8_000_000,
            maximumGOPBitrate: 16_000_000,
            maximumKeyframeIntervals: [
                .h264: 20.0,
                .hevc: 10.0
            ]
        ),
        highResolutionLimits: TierLimits(
            maximumSourceDimension: 4096,
            frameRateRange: 5.0...60.0,
            maximumAverageBitrate: 20_000_000,
            maximumGOPBitrate: nil,
            maximumKeyframeIntervals: [
                .h264: 10.0,
                .hevc: 6.0
            ]
        ),
        supportedVideoCodecs: [.h264, .hevc],
        supportedGOPStructures: [.closedWithIDR],
        supportedPixelFormats: [
            .h264: [
                StandardInputPixelFormat(
                    bitDepth: 8,
                    chromaSubsampling: .yuv420
                )
            ],
            .hevc: [
                StandardInputPixelFormat(
                    bitDepth: 8,
                    chromaSubsampling: .yuv420
                ),
                StandardInputPixelFormat(
                    bitDepth: 10,
                    chromaSubsampling: .yuv420
                )
            ]
        ],
        supportedDynamicRanges: [.sdr, .hlg, .pq],
        supportedHDRVideoCodecs: [.hevc],
        supportedHDRPixelFormats: [
            StandardInputPixelFormat(
                bitDepth: 10,
                chromaSubsampling: .yuv420
            )
        ],
        supportedAudio: [
            .none,
            .aac(.mono),
            .aac(.stereo),
            .aac(.fivePointOne)
        ],
        supportedEditLists: [.none, .simple]
    )
}

struct StandardInputPolicyEvaluation: Equatable {
    enum Requirement: CaseIterable, Equatable {
        case videoCodec
        case videoResolution
        case frameRate
        case averageBitrate
        case maximumGOPBitrate
        case keyframeInterval
        case gopStructure
        case pixelFormat
        case dynamicRange
        case audio
        case editList
    }

    enum Status: Equatable {
        case compliant
        case nonCompliant
        case unknown
    }

    enum Outcome: Equatable {
        case compliant
        case nonCompliant
        case unknown
    }

    struct Check: Equatable {
        let requirement: Requirement
        let status: Status
    }

    let checks: [Check]

    var outcome: Outcome {
        if checks.contains(where: { $0.status == .nonCompliant }) {
            return .nonCompliant
        }

        if checks.contains(where: { $0.status == .unknown }) {
            return .unknown
        }

        return .compliant
    }

    var nonCompliantRequirements: [Requirement] {
        checks.compactMap { check in
            check.status == .nonCompliant ? check.requirement : nil
        }
    }

    var unknownRequirements: [Requirement] {
        checks.compactMap { check in
            check.status == .unknown ? check.requirement : nil
        }
    }

    func status(for requirement: Requirement) -> Status? {
        checks.first(where: { $0.requirement == requirement })?.status
    }
}

struct StandardInputPolicyEvaluator {
    let profile: StandardInputPolicyProfile

    init(profile: StandardInputPolicyProfile = .publishedMux) {
        self.profile = profile
    }

    func evaluate(
        _ facts: StandardInputMediaFacts,
        selection: StandardInputPolicySelection,
        role: StandardInputMediaRole = .sourceInput
    ) -> StandardInputPolicyEvaluation {
        let acceptanceTier = effectiveAcceptanceTier(
            dimensions: facts.displayDimensions,
            maximumTier: selection.acceptanceTier
        )
        let limits = profile.limits(for: acceptanceTier)

        return StandardInputPolicyEvaluation(
            checks: [
                .init(
                    requirement: .videoCodec,
                    status: evaluate(facts.videoCodec) {
                        profile.supportedVideoCodecs.contains($0)
                    }
                ),
                .init(
                    requirement: .videoResolution,
                    status: evaluateDimensions(
                        facts.displayDimensions,
                        role: role,
                        limits: limits,
                        generatedOutputDimensions: selection.generatedOutputDimensions
                    )
                ),
                .init(
                    requirement: .frameRate,
                    status: evaluatePositiveFinite(facts.frameRate) {
                        limits.frameRateRange.contains($0)
                    }
                ),
                .init(
                    requirement: .averageBitrate,
                    status: evaluatePositive(facts.averageBitrate) {
                        $0 <= limits.maximumAverageBitrate
                    }
                ),
                .init(
                    requirement: .maximumGOPBitrate,
                    status: evaluateMaximumGOPBitrate(
                        facts.maximumGOPBitrate,
                        maximum: limits.maximumGOPBitrate
                    )
                ),
                .init(
                    requirement: .keyframeInterval,
                    status: evaluateKeyframeInterval(
                        facts.maximumKeyframeInterval,
                        codec: facts.videoCodec,
                        limits: limits
                    )
                ),
                .init(
                    requirement: .gopStructure,
                    status: evaluate(facts.gopStructure) {
                        profile.supportedGOPStructures.contains($0)
                    }
                ),
                .init(
                    requirement: .pixelFormat,
                    status: evaluatePixelFormat(
                        facts.pixelFormat,
                        codec: facts.videoCodec
                    )
                ),
                .init(
                    requirement: .dynamicRange,
                    status: evaluateDynamicRange(
                        facts.dynamicRange,
                        codec: facts.videoCodec,
                        pixelFormat: facts.pixelFormat
                    )
                ),
                .init(
                    requirement: .audio,
                    status: evaluateAudio(facts.audio)
                ),
                .init(
                    requirement: .editList,
                    status: evaluate(facts.editList) {
                        profile.supportedEditLists.contains($0)
                    }
                )
            ]
        )
    }

    private func effectiveAcceptanceTier(
        dimensions: StandardInputFact<StandardInputDisplayDimensions>,
        maximumTier: StandardInputAcceptanceTier
    ) -> StandardInputAcceptanceTier {
        guard maximumTier == .highResolution,
              let dimensions = dimensions.value,
              dimensions.width > 0,
              dimensions.height > 0 else {
            return maximumTier
        }

        let upTo1080pLimits = profile.limits(for: .upTo1080p)
        return dimensions.maximumDimension <= upTo1080pLimits.maximumSourceDimension
            ? .upTo1080p
            : .highResolution
    }

    private func evaluate<Value>(
        _ fact: StandardInputFact<Value>,
        predicate: (Value) -> Bool
    ) -> StandardInputPolicyEvaluation.Status {
        guard let value = fact.value else {
            return .unknown
        }

        return predicate(value) ? .compliant : .nonCompliant
    }

    private func evaluatePositive(
        _ fact: StandardInputFact<Int64>,
        predicate: (Int64) -> Bool
    ) -> StandardInputPolicyEvaluation.Status {
        guard let value = fact.value, value > 0 else {
            return .unknown
        }

        return predicate(value) ? .compliant : .nonCompliant
    }

    private func evaluatePositiveFinite(
        _ fact: StandardInputFact<Double>,
        predicate: (Double) -> Bool
    ) -> StandardInputPolicyEvaluation.Status {
        guard let value = fact.value, value.isFinite, value > 0 else {
            return .unknown
        }

        return predicate(value) ? .compliant : .nonCompliant
    }

    private func evaluateDimensions(
        _ dimensions: StandardInputFact<StandardInputDisplayDimensions>,
        role: StandardInputMediaRole,
        limits: StandardInputPolicyProfile.TierLimits,
        generatedOutputDimensions: StandardInputDisplayDimensions
    ) -> StandardInputPolicyEvaluation.Status {
        guard let dimensions = dimensions.value,
              dimensions.width > 0,
              dimensions.height > 0 else {
            return .unknown
        }

        let isCompliant: Bool
        switch role {
        case .sourceInput:
            isCompliant = dimensions.maximumDimension <= limits.maximumSourceDimension
        case .generatedOutput:
            isCompliant = dimensions.fitsWithin(generatedOutputDimensions)
        }

        return isCompliant ? .compliant : .nonCompliant
    }

    private func evaluateMaximumGOPBitrate(
        _ bitrate: StandardInputFact<Int64>,
        maximum: Int64?
    ) -> StandardInputPolicyEvaluation.Status {
        guard let maximum else {
            return .compliant
        }

        return evaluatePositive(bitrate) { $0 <= maximum }
    }

    private func evaluateKeyframeInterval(
        _ interval: StandardInputFact<TimeInterval>,
        codec: StandardInputFact<StandardInputVideoCodec>,
        limits: StandardInputPolicyProfile.TierLimits
    ) -> StandardInputPolicyEvaluation.Status {
        guard let codec = codec.value,
              let maximumInterval = limits.maximumKeyframeIntervals[codec] else {
            return .unknown
        }

        return evaluatePositiveFinite(interval) {
            $0 <= maximumInterval
        }
    }

    private func evaluatePixelFormat(
        _ pixelFormat: StandardInputFact<StandardInputPixelFormat>,
        codec: StandardInputFact<StandardInputVideoCodec>
    ) -> StandardInputPolicyEvaluation.Status {
        guard let pixelFormat = pixelFormat.value,
              let codec = codec.value else {
            return .unknown
        }

        return profile.supportedPixelFormats[codec]?.contains(pixelFormat) == true
            ? .compliant
            : .nonCompliant
    }

    private func evaluateDynamicRange(
        _ dynamicRange: StandardInputFact<StandardInputDynamicRange>,
        codec: StandardInputFact<StandardInputVideoCodec>,
        pixelFormat: StandardInputFact<StandardInputPixelFormat>
    ) -> StandardInputPolicyEvaluation.Status {
        guard let dynamicRange = dynamicRange.value else {
            return .unknown
        }

        guard profile.supportedDynamicRanges.contains(dynamicRange) else {
            return .nonCompliant
        }

        guard dynamicRange != .sdr else {
            return .compliant
        }

        guard let codec = codec.value,
              let pixelFormat = pixelFormat.value else {
            return .unknown
        }

        return profile.supportedHDRVideoCodecs.contains(codec)
            && profile.supportedHDRPixelFormats.contains(pixelFormat)
            ? .compliant
            : .nonCompliant
    }

    private func evaluateAudio(
        _ audio: StandardInputFact<StandardInputAudio>
    ) -> StandardInputPolicyEvaluation.Status {
        evaluate(audio) {
            profile.supportedAudio.contains($0)
        }
    }
}
