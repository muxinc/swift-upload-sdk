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
            VStack {
                MuxyNavBar()
                screenContent
            }
        }
    }
    
    private var screenContent: some View {
        ZStack {
            WindowBackground
            VStack {
                ZStack {
                    RoundedRectangle(cornerRadius: 4.0)
                        .stroke(style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [4]))
                        .foregroundColor(Gray30)
                        .opacity(0.5)
                    VStack {
                        Image("Mux-y Add")
                            .padding()
                        Text("Tap to upload video")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(White)
                    }
                }
                .padding()
                .frame(height: 228)
                
                Spacer()
                // This way: buttonStyle (but frame doesn't work)
                Button("Upload") {}
                .buttonStyle(DefaultButtonStyle())
                .frame(width: .infinity)
                .padding()
                
                // or this way (maybe not as swifty, this is sorta kinda what Compose would do)
                DefaultButton(text: "Upload") {
                    
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
