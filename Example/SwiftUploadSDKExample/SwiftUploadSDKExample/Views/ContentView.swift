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
            .background {
                WindowBackground
            }
            NavigationLink {
                CreateUploadView()
                    .navigationBarHidden(true)
            } label : {
                if !uploadListModel.lastKnownUploads.isEmpty {
                    ZStack {
                        Image("Mux-y Add")
                            .padding()
                            .background(Green50.clipShape(Circle()))
                    }
                    .padding(24.0)
                }
            }
        }
        .background {
            WindowBackground
                .ignoresSafeArea()
        }
        .navigationViewStyle(.stack)
        .preferredColorScheme(.dark)
        .environmentObject(uploadListModel)
        .environmentObject(uploadCreationModel)
    }
}
