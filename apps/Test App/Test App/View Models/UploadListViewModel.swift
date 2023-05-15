//
//  UploadListViewModel.swift
//  Test App
//
//  Created by Emily Dixon on 5/15/23.
//

import Foundation
import MuxUploadSDK

class UploadListViewModel : ObservableObject {
    
    // TODO: Observe Upload progress also 
    
    init() {
        UploadManager.shared.addUploadsUpdatedDelegate(id: 0) { uploads in
            self.lastKnownUploads = uploads
        }
    }
    
    @Published var lastKnownUploads: [MuxUpload] = []
}
