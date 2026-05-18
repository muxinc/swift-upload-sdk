//
//  SwiftUploadSDKExample.swift
//
//  Created by Emily Dixon on 2/14/23.
//

import SwiftUI
import MuxUploadSDK
import OSLog

@main
struct SwiftUploadSDKExample: App {
    
    static let logger = Logger(
        subsystem: "UploadExample",
        category: "diagnostics"
    )
    static let thumbnailHeight = 228.0
    
    @StateObject var uploadCreationModel = UploadCreationModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(uploadCreationModel)
        }
    }
}
