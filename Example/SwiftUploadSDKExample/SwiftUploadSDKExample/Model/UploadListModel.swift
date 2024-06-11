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

    @Published var lastKnownUploads: [DirectUpload]

    init(
        directUploadManager: DirectUploadManager = .shared
    ) {

        self.lastKnownUploads = directUploadManager.allManagedDirectUploads()
        directUploadManager.addDelegate(
            Delegate(
                handler: { uploads in

                    var lastKnownUploadsToUpdate = self.lastKnownUploads

                    for updatedUpload in uploads {
                        if !lastKnownUploadsToUpdate.contains(
                            where: {
                                $0.uploadURL == updatedUpload.uploadURL &&
                                $0.videoFile == updatedUpload.videoFile
                            }
                        ) {
                            lastKnownUploadsToUpdate.append(updatedUpload)
                        }
                    }

                    self.lastKnownUploads = lastKnownUploadsToUpdate
                        .sorted(
                            by: { lhs, rhs in
                                (lhs.uploadStatus?.startTime ?? 0) >= (rhs.uploadStatus?.startTime ?? 0)
                            }
                        )
                    }
            )
        )
    }
}

fileprivate class Delegate: DirectUploadManagerDelegate {
    let handler: ([DirectUpload]) -> Void

    func didUpdate(managedDirectUploads: [DirectUpload]) {
        handler(managedDirectUploads)
    }
    
    init(handler: @escaping ([DirectUpload]) -> Void) {
        self.handler = handler
    }
}
