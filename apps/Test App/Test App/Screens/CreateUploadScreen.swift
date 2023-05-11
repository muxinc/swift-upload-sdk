//
//  CreateUploadScreen.swift
//  Test App
//
//  Created by Emily Dixon on 5/9/23.
//

import SwiftUI

struct CreateUploadScreen: View {
    var body: some View {
        ZStack { // Outer window
            Gray100.ignoresSafeArea(.container)
            VStack(spacing: 0) {
                MuxyNavBar()
                screenContent
            }
        }
    }
    
    private var screenContent: some View {
        ZStack {
            WindowBackground
            VStack {
                UploadVideoCta()
                    .padding(EdgeInsets(top: 64, leading: 20, bottom: 0, trailing: 20))
                Spacer()
                DefaultButton("Upload") {
                    // TODO: Start Upload
                }.padding()
            }
        }
    }
}

struct CreateUploadScreen_Previews: PreviewProvider {
    static var previews: some View {
        CreateUploadScreen()
    }
}
