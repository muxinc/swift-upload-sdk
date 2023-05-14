//
//  CreateUploadScreen.swift
//  Test App
//
//  Created by Emily Dixon on 5/9/23.
//

import SwiftUI
import PhotosUI

struct CreateUploadScreen: View {
    var body: some View {
        ZStack { // Outer window
            Gray100.ignoresSafeArea(.container)
            VStack(spacing: 0) {
                MuxNavBar(title: "Create a New Upload")
                ScreenContent()
            }
        }
    }
}

struct ScreenContent: View {
    var body: some View {
        ZStack {
            WindowBackground
            // TODO: If we have a thumbnail loaded, that's what we want to show
            EmptyView()
        }
    }
}

struct EmptyView: View {
    var body: some View {
        VStack {
            BigUploadCTA()
            .padding(
                EdgeInsets(
                    top: 64,
                    leading: 20,
                    bottom: 0,
                    trailing: 20
                )
            )
            Spacer()
        }
    }
}

struct CreateUploadScreen_Previews: PreviewProvider {
    static var previews: some View {
        CreateUploadScreen()
            .environmentObject(UploadScreenViewModel())
    }
}

struct EmptyView_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            WindowBackground.ignoresSafeArea()
            EmptyView()
        }.environmentObject(UploadScreenViewModel())
    }
}
