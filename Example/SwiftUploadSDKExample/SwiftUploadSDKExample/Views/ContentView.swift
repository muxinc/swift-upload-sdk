//
//  ContentView.swift
//  Test App
//
//  Created by Emily Dixon on 2/14/23.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var uploadCreationModel: UploadCreationModel

    var body: some View {
        VStack(spacing: 0) {
            MuxNavBar()
            UploadWorkspaceView()
            Spacer(minLength: 0)
        }
        .background {
            WindowBackground
                .ignoresSafeArea()
        }
        .preferredColorScheme(.dark)
        .environmentObject(uploadCreationModel)
    }
}
