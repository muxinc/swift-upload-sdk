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
            CreateUploadScreen()
        }.preferredColorScheme(.dark)
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
