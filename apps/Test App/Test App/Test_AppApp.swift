//
//  Test_AppApp.swift
//  Test App
//
//  Created by Emily Dixon on 2/14/23.
//

import SwiftUI
import MuxUploadSDK
import OSLog

@main
struct Test_AppApp: App {
    
    static var logger = Logger(subsystem: "mux", category: "default")
    static let THUMBNAIL_HEIGHT = 228.0
    
    @StateObject private var uploadListVM = UploadListViewModel()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(uploadListVM)
        }
    }
    
    public init() {
        //MuxUploadSDK.enableDefaultLogging() // note: Kind of noisy on the simulator
    }
}
