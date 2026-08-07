//
//  UploadManagerThreadSafetyTests.swift
//

import AVFoundation
import Foundation
import XCTest

@testable import MuxUploadSDK

/// Regression tests for the data race described in
/// https://github.com/muxinc/swift-upload-sdk/issues/122.
///
/// `DirectUploadManager` keeps its uploads and its delegates in plain
/// dictionaries that are reached from arbitrary threads: uploads register
/// themselves from AVFoundation's inspection queue, while readers like
/// `allManagedDirectUploads()` are typically called from the main thread.
/// Without synchronization, concurrent access crashed inside
/// `swift_isUniquelyReferenced_nonNull_native` — the copy-on-write uniqueness
/// check `Dictionary.updateValue` performs before mutating.
///
/// These tests are only meaningful with Thread Sanitizer enabled:
///
///     swift test --sanitize=thread
///
/// Without TSan a surviving race is timing-dependent and will usually pass.
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

    /// Registers many uploads concurrently. This is the crashing path from the
    /// original report, minus the network transport.
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

    /// Interleaves registration with the reads a UI layer would be making at
    /// the same time. A read racing a write is as much a crash as two writes.
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

    /// `uploadsUpdateDelegatesByToken` has the same exposure: `notifyDelegates()`
    /// reads it from a detached task while `addDelegate`/`removeDelegate` can be
    /// called from any thread.
    func testConcurrentDelegateMutationDoesNotRace() async throws {
        let inputFileURLs = try inputFileURLs(
            count: Self.concurrentOperationCount
        )
        let uploadManager = DirectUploadManager(
            uploadActor: UploadCacheActor(
                persistence: try makePersistence(inputFileURLs: inputFileURLs)
            )
        )

        // Held for the duration so the delegates stay registered while
        // registrations are notifying them.
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

    /// Acknowledgement removes from the same dictionary registration writes to,
    /// and is reached off-main from uploader state callbacks.
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

}

private class CountingDirectUploadManagerDelegate: DirectUploadManagerDelegate {
    func didUpdate(managedDirectUploads: [DirectUpload]) {
        // Body intentionally empty. These tests are about the manager's
        // internal state, not what it reports.
    }
}
