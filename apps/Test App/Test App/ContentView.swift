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
    @State private var navScreen: NavScreen = .upload_list
    
    var body: some View {
        NavigationView {
            ZStack(alignment: .bottomTrailing) {
                CreateUploadScreen() // TODO: Not here
                // UploadList
                // Upload CTA (optional), NavigationLink to CreateUpload, Label is Floating Btton
                
                // TODO: only if there's already some uploads
                NavigationLink {
                    CreateUploadScreen()
                        .navigationBarHidden(true)
                } label : {
                    ZStack {
                        Image("Mux-y Add")
                            .padding()
                            .background(Green50.clipShape(Circle()))
                            .border(.red)
                    }
                    .border(.blue)
                    .padding(24.0)
                }
            }
            .border(.yellow)
        }
        .preferredColorScheme(.dark)
    }
}

enum NavScreen {
    case upload_list, create_upload
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environmentObject(UploadScreenViewModel())
            .environmentObject(UploadCreationViewModel())
    }
}
