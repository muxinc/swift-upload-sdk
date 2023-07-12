//
//  UploadListViewModel.swift
//  Test App
//
//  Created by Emily Dixon on 5/15/23.
//

import Foundation
import AVFoundation
import MuxUploadSDK

class UploadListModel : ObservableObject {
    
    init() {
        UploadManager.shared.addUploadsUpdatedDelegate(
            Delegate(
                handler: { uploads in
                var uploadSet = Set(self.lastKnownUploads)
                uploads.forEach {
                    uploadSet.insert($0)
                }
                self.lastKnownUploads = Array(uploadSet)
                    .sorted(
                        by: { lhs, rhs in
                            (lhs.uploadStatus?.startTime ?? 0) >= (rhs.uploadStatus?.startTime ?? 0)
                        }
                    )
                }
            )
        )
    }
    
    @Published var lastKnownUploads: [MuxUpload] = Array()
}

fileprivate class Delegate: UploadsUpdatedDelegate {
    let handler: ([MuxUpload]) -> Void
    
    func uploadListUpdated(with list: [MuxUpload]) {
        handler(list)
    }
    
    init(handler: @escaping ([MuxUpload]) -> Void) {
        self.handler = handler
    }
}
