//
//  CreateUploadScreen.swift
//  Test App
//
//  Created by Emily Dixon on 5/9/23.
//

import SwiftUI
import PhotosUI

struct CreateUploadView: View {
    
    @EnvironmentObject var uploadCreationModel: UploadCreationModel

    var body: some View {
        ZStack { // Outer window
            Gray100.ignoresSafeArea(.container)
            VStack(spacing: 0) {
                MuxNavBar(
                    leadingNavButton: .close,
                    title: "Create a New Upload"
                )
                ZStack {
                    WindowBackground
                    switch uploadCreationModel.exportState {
                    case .not_started: SelectVideoView()
                    case .preparing: ProcessingView()
                    case .failure(let error): ErrorView(error: error)
                    case .ready(let upload): ThumbnailView(preparedMedia: upload)
                    }

                }
            }
        }
        .environmentObject(uploadCreationModel)
    }
}

