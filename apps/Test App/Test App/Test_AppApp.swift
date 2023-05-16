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
    
    @StateObject private var uploadScreenViewModel: UploadScreenViewModel = UploadScreenViewModel()
    @StateObject private var uploadCreationVM = UploadCreationViewModel()
    @StateObject private var uploadListVM = UploadListViewModel()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(uploadScreenViewModel)
                .environmentObject(uploadCreationVM)
                .environmentObject(uploadListVM)
        }
    }
    
    public init() {
        MuxUploadSDK.enableDefaultLogging()
    }
}
