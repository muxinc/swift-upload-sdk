//
//  UploadInputSampleInspectionTests.swift
//

import AVFoundation
import Foundation
import XCTest
@testable import MuxUploadSDK

final class UploadInputSampleInspectionTests: XCTestCase {
    func testTimelinePresentationStartUsesTrackRangeInsteadOfDecodeOrder() {
        let timeRange = CMTimeRange(
            start: CMTime(seconds: -0.4, preferredTimescale: 600),
            duration: CMTime(seconds: 10, preferredTimescale: 600)
        )

        let presentationStart = StandardInputTimelineInspector.presentationStart(
            in: timeRange
        )

        XCTAssertEqual(
            try XCTUnwrap(presentationStart),
            -0.4,
            accuracy: 0.000_001
        )
    }

    func testMeasuresCompleteAndTerminalGOPs() {
        let facts = UploadInputCompressedSampleAggregator.inspect([
            sample(time: 0, duration: 1, bytes: 100, sync: true, kind: .idr),
            sample(time: 1, duration: 1, bytes: 100),
            sample(time: 2, duration: 0.5, bytes: 300, sync: true, kind: .idr),
            sample(time: 2.5, duration: 1.5, bytes: 100)
        ])

        XCTAssertEqual(facts.maximumGOPByteSize, .known(400))
        XCTAssertEqual(facts.maximumGOPBitrate, .known(1_600))
        XCTAssertEqual(facts.maximumKeyframeInterval, .known(2))
        XCTAssertEqual(facts.gopStructure, .known(.closedWithIDR))
    }

    func testUsesPresentationTimingForVariableFrameRateIntervals() {
        let facts = UploadInputCompressedSampleAggregator.inspect([
            sample(time: 0, duration: 0.04, bytes: 10, sync: true, kind: .idr),
            sample(time: 0.04, duration: 0.06, bytes: 10),
            sample(time: 0.1, duration: 0.04, bytes: 10, sync: true, kind: .idr),
            sample(time: 0.14, duration: 0.11, bytes: 10)
        ])

        XCTAssertEqual(facts.maximumKeyframeInterval.value ?? 0, 0.15, accuracy: 0.000_001)
    }

    func testTerminalGOPCanProvideMaximumBitrate() {
        let facts = UploadInputCompressedSampleAggregator.inspect([
            sample(time: 0, duration: 1, bytes: 100, sync: true, kind: .idr),
            sample(time: 1, duration: 1, bytes: 100),
            sample(time: 2, duration: 0.5, bytes: 400, sync: true, kind: .idr)
        ])

        XCTAssertEqual(facts.maximumGOPByteSize, .known(400))
        XCTAssertEqual(facts.maximumGOPBitrate, .known(6_400))
        XCTAssertEqual(facts.maximumKeyframeInterval, .known(2))
    }

    func testEditListPrerollUsesStoredClosedGOPTiming() {
        let facts = UploadInputCompressedSampleAggregator.inspect([
            sample(time: -1.9, duration: 0.1, bytes: 100, sync: true, kind: .idr),
            sample(time: -0.9, duration: 0.1, bytes: 100),
            sample(time: 0.1, duration: 0.1, bytes: 300, sync: true, kind: .idr),
            sample(time: 0.4, duration: 0.1, bytes: 100)
        ])

        XCTAssertEqual(facts.maximumGOPByteSize, .known(400))
        XCTAssertEqual(facts.maximumGOPBitrate, .known(8_000))
        XCTAssertEqual(facts.maximumKeyframeInterval, .known(2))
        XCTAssertEqual(facts.gopStructure, .known(.closedWithIDR))
    }

    func testOpenRandomAccessPointMakesGOPStructureOpen() {
        let facts = UploadInputCompressedSampleAggregator.inspect([
            sample(time: 0, duration: 1, bytes: 100, sync: true, kind: .idr),
            sample(time: 1, duration: 1, bytes: 100),
            sample(time: 2, duration: 1, bytes: 100, sync: true, kind: .openGOP)
        ])

        XCTAssertEqual(facts.maximumGOPByteSize, .unknown)
        XCTAssertEqual(facts.maximumGOPBitrate, .unknown)
        XCTAssertEqual(facts.maximumKeyframeInterval, .known(2))
        XCTAssertEqual(facts.gopStructure, .known(.open))
    }

    func testOpenGOPLeadingPicturesDoNotProduceMisleadingByteFacts() {
        let facts = UploadInputCompressedSampleAggregator.inspect([
            sample(time: 0, duration: 0.5, bytes: 100, sync: true, kind: .idr),
            sample(time: 0.5, duration: 0.5, bytes: 100),
            sample(time: 1, duration: 0.1, bytes: 1_000, sync: true, kind: .openGOP),
            // This leading picture follows the CRA in decode order but precedes
            // it in presentation order, so its bytes cross the apparent boundary.
            sample(time: 0.9, duration: 0.1, bytes: 10_000)
        ])

        XCTAssertEqual(facts.maximumGOPByteSize, .unknown)
        XCTAssertEqual(facts.maximumGOPBitrate, .unknown)
        XCTAssertEqual(facts.maximumKeyframeInterval, .known(1))
        XCTAssertEqual(facts.gopStructure, .known(.open))
    }

    func testContradictoryDependencyAttachmentMakesStructureUnknown() {
        let facts = UploadInputCompressedSampleAggregator.inspect([
            sample(
                time: 0,
                duration: 1,
                bytes: 100,
                sync: true,
                kind: .idr,
                dependsOnOthers: true
            )
        ])

        XCTAssertEqual(facts.maximumGOPByteSize, .known(100))
        XCTAssertEqual(facts.gopStructure, .unknown)
    }

    func testMissingRandomAccessEvidenceOnlyMakesStructureUnknown() {
        let facts = UploadInputCompressedSampleAggregator.inspect([
            sample(time: 0, duration: 1, bytes: 100, sync: true, kind: .unknown),
            sample(time: 1, duration: 1, bytes: 100)
        ])

        XCTAssertEqual(facts.maximumGOPByteSize, .known(200))
        XCTAssertEqual(facts.maximumGOPBitrate, .known(800))
        XCTAssertEqual(facts.maximumKeyframeInterval, .known(2))
        XCTAssertEqual(facts.gopStructure, .unknown)
    }

    func testInitialPartialGOPKeepsAllGOPFactsUnknown() {
        let facts = UploadInputCompressedSampleAggregator.inspect([
            sample(time: 0, duration: 1, bytes: 100),
            sample(time: 1, duration: 1, bytes: 100, sync: true, kind: .idr)
        ])

        XCTAssertEqual(facts.maximumGOPByteSize, .unknown)
        XCTAssertEqual(facts.maximumGOPBitrate, .unknown)
        XCTAssertEqual(facts.maximumKeyframeInterval, .unknown)
        XCTAssertEqual(facts.gopStructure, .unknown)
    }

    func testInvalidTimingKeepsAllGOPFactsUnknown() {
        let facts = UploadInputCompressedSampleAggregator.inspect([
            sample(time: 0, duration: .nan, bytes: 100, sync: true, kind: .idr)
        ])

        XCTAssertEqual(facts.maximumGOPByteSize, .unknown)
        XCTAssertEqual(facts.maximumGOPBitrate, .unknown)
        XCTAssertEqual(facts.maximumKeyframeInterval, .unknown)
        XCTAssertEqual(facts.gopStructure, .unknown)
    }

    func testParsesLengthPrefixedH264NALUnitTypes() throws {
        let data = lengthPrefixed([
            Data([0x67, 0x01]),
            Data([0x65, 0x02, 0x03])
        ])

        let types = try XCTUnwrap(
            AVFoundationUploadInputSampleReader.nalUnitTypes(
                in: data,
                lengthFieldSize: 4,
                codec: .h264
            )
        )
        XCTAssertEqual(types, [7, 5])
        XCTAssertEqual(
            AVFoundationUploadInputSampleReader.randomAccessKind(
                codec: .h264,
                nalUnitTypes: types
            ),
            .idr
        )
    }

    func testParsesHEVCIDRAndCRAAccessUnits() throws {
        let idrTypes = try XCTUnwrap(
            AVFoundationUploadInputSampleReader.nalUnitTypes(
                in: lengthPrefixed([Data([19 << 1, 0x01, 0x02])]),
                lengthFieldSize: 4,
                codec: .hevc
            )
        )
        let craTypes = try XCTUnwrap(
            AVFoundationUploadInputSampleReader.nalUnitTypes(
                in: lengthPrefixed([Data([21 << 1, 0x01, 0x02])]),
                lengthFieldSize: 4,
                codec: .hevc
            )
        )

        XCTAssertEqual(
            AVFoundationUploadInputSampleReader.randomAccessKind(
                codec: .hevc,
                nalUnitTypes: idrTypes
            ),
            .idr
        )
        XCTAssertEqual(
            AVFoundationUploadInputSampleReader.randomAccessKind(
                codec: .hevc,
                nalUnitTypes: craTypes
            ),
            .openGOP
        )
    }

    func testRejectsMalformedLengthPrefixedSample() {
        XCTAssertNil(
            AVFoundationUploadInputSampleReader.nalUnitTypes(
                in: Data([0, 0, 0, 8, 0x65]),
                lengthFieldSize: 4,
                codec: .h264
            )
        )
    }

    private func sample(
        time: TimeInterval,
        duration: TimeInterval,
        bytes: Int64,
        sync: Bool = false,
        kind: UploadInputCompressedSampleObservation.RandomAccessKind = .unknown,
        dependsOnOthers: Bool? = nil
    ) -> UploadInputCompressedSampleObservation {
        UploadInputCompressedSampleObservation(
            presentationTime: time,
            duration: duration,
            byteCount: bytes,
            syncState: sync ? .sync : .notSync,
            randomAccessKind: kind,
            dependsOnOthers: dependsOnOthers
        )
    }

    private func lengthPrefixed(_ nalUnits: [Data]) -> Data {
        nalUnits.reduce(into: Data()) { result, nalUnit in
            var length = UInt32(nalUnit.count).bigEndian
            withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
            result.append(nalUnit)
        }
    }

}
