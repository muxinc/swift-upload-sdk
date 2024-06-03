//
//  PersistenceEntry+Fixtures.swift
//

import Foundation
@testable import MuxUploadSDK

extension PersistenceEntry {

    init(
        basename: String,
        savedAt: TimeInterval = Date().timeIntervalSince1970
    ) {
        self.init(
            savedAt: savedAt,
            stateCode: .wasPaused,
            lastSuccessfulByte: 0,
            uploadInfo: UploadInfo(
                id: UUID().uuidString,
                uploadURL: URL(string: "https://dummy.site/page/\(basename)")!,
                options: .default
            ),
            inputFileURL: URL(string: "file://path/to/dummy/file/\(basename)")!
        )
    }

}
