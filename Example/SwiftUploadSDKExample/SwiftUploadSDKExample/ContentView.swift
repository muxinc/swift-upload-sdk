//
//  ContentView.swift
//  Test App
//
//  Created by Emily Dixon on 2/14/23.
//
import SwiftUI
import PhotosUI
import MuxUploadSDK

struct ContentView: View {
    @EnvironmentObject var uploadListModel: UploadListModel
    @EnvironmentObject var uploadCreationModel: UploadCreationModel

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                MuxNavBar()
                UploadListContainerView()
                Spacer()
            }
        }
        .background {
            WindowBackground
                .ignoresSafeArea()
        }
        .preferredColorScheme(.dark)
        .environmentObject(uploadListModel)
        .environmentObject(uploadCreationModel)
    }
}
