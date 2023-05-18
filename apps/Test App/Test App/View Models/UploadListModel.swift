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
        UploadManager.shared.addUploadsUpdatedDelegate(id: 0) { uploads in
            var uploadSet = Set(self.lastKnownUploads)
            uploads.forEach {
                uploadSet.insert($0)
            }
            self.lastKnownUploads = Array(uploadSet)
                .sorted(
                    by: { lhs, rhs in
                        lhs.uploadStatus.startTime >= rhs.uploadStatus.startTime
                    }
                )
        }
    }
    
    @Published var lastKnownUploads: [MuxUpload] = Array()
}
