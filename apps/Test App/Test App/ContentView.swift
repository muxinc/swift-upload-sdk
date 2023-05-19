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
    
    var body: some View {
        NavigationView {
            ZStack(alignment: .bottomTrailing) {
                UploadListScreen()
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
        }
        .preferredColorScheme(.dark)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environmentObject(UploadCreationModel())
            .environmentObject(UploadListModel())
    }
}
