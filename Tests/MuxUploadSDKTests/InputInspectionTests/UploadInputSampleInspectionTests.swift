//
//  UploadInputSampleInspectionTests.swift
//

import AVFoundation
import Foundation
import XCTest
@testable import MuxUploadSDK

final class UploadInputSampleInspectionTests: XCTestCase {
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

    // Manual integration hook. It skips unless a developer or CI job provisions
    // the external media package and supplies its catalog; media remains outside Git.
    func testCatalogMediaFixturesWhenConfigured() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let directory = environment["MUX_UPLOAD_MEDIA_FIXTURE_DIRECTORY"],
              let catalogPath = environment["MUX_UPLOAD_MEDIA_FIXTURE_CATALOG"] else {
            throw XCTSkip(
                "Set MUX_UPLOAD_MEDIA_FIXTURE_DIRECTORY and "
                    + "MUX_UPLOAD_MEDIA_FIXTURE_CATALOG for catalog-backed "
                    + "real-media validation"
            )
        }

        let catalogData = try Data(contentsOf: URL(fileURLWithPath: catalogPath))
        let catalog = try JSONDecoder().decode(MediaFixtureCatalog.self, from: catalogData)
        let fixturesByFilename = Dictionary(
            uniqueKeysWithValues: catalog.fixtures.map { ($0.canonicalFilename, $0) }
        )

        let urls = try FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: directory),
            includingPropertiesForKeys: nil
        ).filter { ["mov", "mp4"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(urls.isEmpty)
        XCTAssertEqual(
            Set(urls.map(\.lastPathComponent)),
            Set(fixturesByFilename.keys),
            "The configured directory must contain exactly the cataloged media fixtures"
        )

        for url in urls {
            guard let fixture = fixturesByFilename[url.lastPathComponent] else {
                XCTFail("No catalog entry for \(url.lastPathComponent)")
                continue
            }
            let completion = expectation(description: url.lastPathComponent)
            let asset = AVURLAsset(url: url)
            AVFoundationUploadInputInspector().performInspection(
                sourceInput: asset,
                maximumResolution: .preset3840x2160
            ) { result, _, error in
                XCTAssertNil(error, url.lastPathComponent)
                XCTAssertNotNil(result, url.lastPathComponent)
                if let codec = result?.mediaFacts.videoCodec.value,
                   codec == .h264 || codec == .hevc {
                    if let expectedBitrate = fixture.facts.maximumGOPBitrate {
                        XCTAssertEqual(
                            result?.mediaFacts.maximumGOPBitrate,
                            .known(expectedBitrate),
                            url.lastPathComponent
                        )
                    }
                    if let expectedInterval = fixture.facts.maximumKeyframeIntervalSeconds {
                        XCTAssertEqual(
                            result?.mediaFacts.maximumKeyframeInterval.value ?? 0,
                            expectedInterval,
                            accuracy: 0.000_001,
                            url.lastPathComponent
                        )
                    }
                    switch fixture.facts.gopStructure {
                    case "closedWithIDR":
                        XCTAssertEqual(
                            result?.mediaFacts.gopStructure,
                            .known(.closedWithIDR),
                            url.lastPathComponent
                        )
                    case "open":
                        XCTAssertEqual(
                            result?.mediaFacts.gopStructure,
                            .known(.open),
                            url.lastPathComponent
                        )
                        XCTAssertEqual(
                            result?.mediaFacts.maximumGOPByteSize,
                            .unknown,
                            url.lastPathComponent
                        )
                        XCTAssertEqual(
                            result?.mediaFacts.maximumGOPBitrate,
                            .unknown,
                            url.lastPathComponent
                        )
                    default:
                        break
                    }
                }
                asset.loadTracks(withMediaType: .video) { tracks, trackError in
                    XCTAssertNil(trackError, url.lastPathComponent)
                    guard let track = tracks?.first, tracks?.count == 1 else {
                        completion.fulfill()
                        return
                    }
                    Task {
                        let startedAt = CFAbsoluteTimeGetCurrent()
                        let sampleFacts = await AVFoundationUploadInputSampleReader.inspect(
                            asset: asset,
                            videoTrack: track,
                            codec: result?.mediaFacts.videoCodec ?? .unknown
                        )
                        let elapsed = CFAbsoluteTimeGetCurrent() - startedAt
                        XCTAssertEqual(
                            sampleFacts.maximumGOPBitrate,
                            result?.mediaFacts.maximumGOPBitrate,
                            url.lastPathComponent
                        )
                        print(
                            "Catalog real media:",
                            url.lastPathComponent,
                            "compressedSampleSeconds=\(String(format: "%.3f", elapsed))",
                            "maxGOPBytes=\(String(describing: sampleFacts.maximumGOPByteSize.value))",
                            "maxGOPBitrate=\(String(describing: sampleFacts.maximumGOPBitrate.value))",
                            "maxKeyframeInterval=\(String(describing: sampleFacts.maximumKeyframeInterval.value))",
                            "gopStructure=\(String(describing: sampleFacts.gopStructure.value))"
                        )
                        completion.fulfill()
                    }
                }
            }
            wait(for: [completion], timeout: 120)
        }
    }

    func testCatalogInspectionCancellationWhileReaderIsRegistered() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let directory = environment["MUX_UPLOAD_MEDIA_FIXTURE_DIRECTORY"] else {
            throw XCTSkip(
                "Set MUX_UPLOAD_MEDIA_FIXTURE_DIRECTORY for real-media cancellation validation"
            )
        }
        let mediaURLs = try FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: directory),
            includingPropertiesForKeys: [.fileSizeKey]
        ).filter { ["mov", "mp4"].contains($0.pathExtension.lowercased()) }
        let inputURL = try XCTUnwrap(
            mediaURLs.max {
                let left = (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                let right = (try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                return left < right
            }
        )

        for _ in 0..<10 {
            let operation = UploadInputInspectionOperation()
            let task = Task {
                await AVFoundationUploadInputInspector().inspect(
                    sourceInput: AVURLAsset(url: inputURL),
                    maximumResolution: .preset3840x2160,
                    operation: operation
                )
            }
            var registeredReader = false
            for _ in 0..<1_000 {
                if await operation.hasRegisteredAssetReader {
                    registeredReader = true
                    break
                }
                try await Task.sleep(nanoseconds: 100_000)
            }
            XCTAssertTrue(registeredReader)
            await operation.cancel()

            let outcome = await task.value
            XCTAssertNil(outcome.result)
            XCTAssertTrue(outcome.error is CancellationError)
        }
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

    private struct MediaFixtureCatalog: Decodable {
        let fixtures: [MediaFixture]
    }

    private struct MediaFixture: Decodable {
        let canonicalFilename: String
        let facts: Facts

        struct Facts: Decodable {
            let maximumGOPBitrate: Int64?
            let maximumKeyframeIntervalSeconds: TimeInterval?
            let gopStructure: String?
        }
    }
}
