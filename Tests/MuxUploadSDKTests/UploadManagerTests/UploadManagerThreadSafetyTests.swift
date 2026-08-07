//
//  UploadManagerThreadSafetyTests.swift
//

import AVFoundation
import Foundation
import XCTest

@testable import MuxUploadSDK

/// Regression tests for https://github.com/muxinc/swift-upload-sdk/issues/122,
/// where unsynchronized access to the manager's dictionaries crashed.
///
/// Only meaningful under `swift test --sanitize=thread`. Without TSan a
/// surviving race is timing-dependent and will usually pass.
class UploadManagerThreadSafetyTests: XCTestCase {

    private static let concurrentOperationCount = 50

    /// Builds persistence pre-seeded with one resumable entry per input URL.
    private func makePersistence(
        inputFileURLs: [URL]
    ) throws -> UploadPersistence {
        let persistence = UploadPersistence(
            innerFile: FakeUploadsFile.simiulatedStorage(),
            atURL: try XCTUnwrap(inputFileURLs.first)
        )

        for inputFileURL in inputFileURLs {
            let uploadInfo = UploadInfo(
                id: UUID().uuidString,
                uploadURL: try XCTUnwrap(
                    URL(string: "https://www.example.com/upload/\(UUID().uuidString)")
                ),
                options: .inputStandardizationSkipped
            )

            try persistence.write(
                entry: PersistenceEntry(
                    savedAt: Date().timeIntervalSince1970,
                    stateCode: .wasInProgress,
                    lastSuccessfulByte: 1234,
                    uploadInfo: uploadInfo,
                    inputFileURL: inputFileURL
                ),
                for: uploadInfo.id
            )
        }

        return persistence
    }

    private func inputFileURLs(count: Int) throws -> [URL] {
        try (0..<count).map { index in
            try XCTUnwrap(URL(string: "file://path/to/dummy/file/\(index)"))
        }
    }

    /// The crashing path from the original report, minus network transport.
    func testConcurrentRegistrationDoesNotRaceOnUploadStorage() async throws {
        let inputFileURLs = try inputFileURLs(
            count: Self.concurrentOperationCount
        )
        let uploadManager = DirectUploadManager(
            uploadActor: UploadCacheActor(
                persistence: try makePersistence(inputFileURLs: inputFileURLs)
            )
        )

        await withTaskGroup(of: Void.self) { group in
            for inputFileURL in inputFileURLs {
                group.addTask {
                    _ = await uploadManager.resumeDirectUpload(ofFile: inputFileURL)
                }
            }
        }

        XCTAssertEqual(
            uploadManager.allManagedDirectUploads().count,
            inputFileURLs.count,
            "Every concurrently resumed upload should survive registration"
        )
    }

    /// A read racing a write is as much a crash as two writes.
    func testConcurrentRegistrationAndReadsDoNotRace() async throws {
        let inputFileURLs = try inputFileURLs(
            count: Self.concurrentOperationCount
        )
        let uploadManager = DirectUploadManager(
            uploadActor: UploadCacheActor(
                persistence: try makePersistence(inputFileURLs: inputFileURLs)
            )
        )

        await withTaskGroup(of: Void.self) { group in
            for inputFileURL in inputFileURLs {
                group.addTask {
                    _ = await uploadManager.resumeDirectUpload(ofFile: inputFileURL)
                }
                group.addTask {
                    _ = uploadManager.allManagedDirectUploads()
                }
                group.addTask {
                    _ = uploadManager.startedDirectUpload(ofFile: inputFileURL)
                }
            }
        }

        XCTAssertEqual(
            uploadManager.allManagedDirectUploads().count,
            inputFileURLs.count
        )
    }

    /// The delegate map is exposed too: `notifyDelegates()` reads it off-main
    /// while `addDelegate`/`removeDelegate` run on any thread.
    func testConcurrentDelegateMutationDoesNotRace() async throws {
        let inputFileURLs = try inputFileURLs(
            count: Self.concurrentOperationCount
        )
        let uploadManager = DirectUploadManager(
            uploadActor: UploadCacheActor(
                persistence: try makePersistence(inputFileURLs: inputFileURLs)
            )
        )

        // Held for the duration so they stay registered while notifying.
        let delegates = (0..<Self.concurrentOperationCount).map { _ in
            CountingDirectUploadManagerDelegate()
        }

        await withTaskGroup(of: Void.self) { group in
            for (index, delegate) in delegates.enumerated() {
                group.addTask {
                    uploadManager.addDelegate(delegate)
                }
                group.addTask {
                    _ = await uploadManager.resumeDirectUpload(
                        ofFile: inputFileURLs[index]
                    )
                }
                // Churn the map: half the delegates come straight back out.
                if index.isMultiple(of: 2) {
                    group.addTask {
                        uploadManager.removeDelegate(delegate)
                    }
                }
            }
        }

        XCTAssertEqual(
            uploadManager.allManagedDirectUploads().count,
            inputFileURLs.count
        )
    }

    /// Acknowledgement removes from the dictionary registration writes to, and
    /// is reached off-main from uploader state callbacks.
    func testConcurrentRegistrationAndAcknowledgementDoNotRace() async throws {
        let inputFileURLs = try inputFileURLs(
            count: Self.concurrentOperationCount
        )
        let uploadManager = DirectUploadManager(
            uploadActor: UploadCacheActor(
                persistence: try makePersistence(inputFileURLs: inputFileURLs)
            )
        )

        let uploads = await withTaskGroup(
            of: DirectUpload?.self,
            returning: [DirectUpload].self
        ) { group in
            for inputFileURL in inputFileURLs {
                group.addTask {
                    await uploadManager.resumeDirectUpload(ofFile: inputFileURL)
                }
            }

            var resumed: [DirectUpload] = []
            for await upload in group {
                if let upload {
                    resumed.append(upload)
                }
            }
            return resumed
        }

        XCTAssertEqual(uploads.count, inputFileURLs.count)

        await withTaskGroup(of: Void.self) { group in
            for upload in uploads {
                group.addTask {
                    uploadManager.acknowledgeUpload(id: upload.id)
                }
                group.addTask {
                    _ = uploadManager.allManagedDirectUploads()
                }
            }
        }

        XCTAssertTrue(
            uploadManager.allManagedDirectUploads().isEmpty,
            "Acknowledging every upload should empty the manager"
        )
    }

    /// In an add-only workload the list delegates receive must never shrink.
    ///
    /// Caveat: this does *not* fail against the snapshot-before-hop version.
    /// Registrations serialize behind ``UploadCacheActor``, so notifications
    /// are enqueued in order anyway. It guards the invariant, it does not
    /// reproduce the bug.
    func testDelegateNotificationsNeverGoBackwards() async throws {
        let inputFileURLs = try inputFileURLs(
            count: Self.concurrentOperationCount
        )
        let uploadManager = DirectUploadManager(
            uploadActor: UploadCacheActor(
                persistence: try makePersistence(inputFileURLs: inputFileURLs)
            )
        )

        let recorder = RecordingDirectUploadManagerDelegate()
        uploadManager.addDelegate(recorder)

        await withTaskGroup(of: Void.self) { group in
            for inputFileURL in inputFileURLs {
                group.addTask {
                    _ = await uploadManager.resumeDirectUpload(ofFile: inputFileURL)
                }
            }
        }

        // Wait for the final count, then a little longer: a late stale
        // notification is the failure being tested for.
        var observed = await recorder.observedUploadCounts()
        for _ in 0..<200 where observed.last != inputFileURLs.count {
            try await Task.sleep(nanoseconds: 10_000_000)
            observed = await recorder.observedUploadCounts()
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        observed = await recorder.observedUploadCounts()

        XCTAssertFalse(
            observed.isEmpty,
            "Delegate should have been notified at least once"
        )
        XCTAssertEqual(
            observed.last,
            inputFileURLs.count,
            "The last notification should reflect every registered upload"
        )

        let firstRegression = zip(observed, observed.dropFirst())
            .enumerated()
            .first { $0.element.0 > $0.element.1 }
        XCTAssertNil(
            firstRegression,
            "Upload count went backwards. Full sequence: \(observed)"
        )
    }

}

private class CountingDirectUploadManagerDelegate: DirectUploadManagerDelegate {
    func didUpdate(managedDirectUploads: [DirectUpload]) {
        // Intentionally empty; these tests check internal state, not reports.
    }
}

/// Records the size of every upload list handed over, in delivery order.
/// `didUpdate` always runs on the main actor, so `counts` is only touched there.
private class RecordingDirectUploadManagerDelegate: DirectUploadManagerDelegate {

    private var counts: [Int] = []

    func didUpdate(managedDirectUploads: [DirectUpload]) {
        counts.append(managedDirectUploads.count)
    }

    func observedUploadCounts() async -> [Int] {
        await MainActor.run { counts }
    }

}
