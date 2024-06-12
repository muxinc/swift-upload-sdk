//
//  ErrorView.swift
//  SwiftUploadSDKExample
//

import SwiftUI

struct ErrorView: View {
    var body: some View {
        VStack {
            ZStack {
                RoundedRectangle(cornerRadius: 4.0)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.0))
                    .foregroundColor(Gray30)
                    .background(Gray90)
                VStack {
                    Label(
                        "",
                        systemImage: "square.and.arrow.up.trianglebadge.exclamationmark"
                    )
                    .foregroundColor(.red)
                    Spacer()
                        .frame(maxHeight: 12)

                    Text(message)
                        .foregroundColor(White)
                        .multilineTextAlignment(.center)
                        .font(.system(size: 12))
                        .padding(.leading)
                        .padding(.trailing)
                }
            }
            .padding(
                EdgeInsets(
                    top: 64,
                    leading: 20,
                    bottom: 0,
                    trailing: 20
                )
            )
            .frame(height: SwiftUploadSDKExample.thumbnailHeight)

            Spacer()
        }
    }

    let error: Error?

    let message: String

    init(error: Error? = nil) {
        self.error = error
        self.message = "Couldn't prepare the video for upload. Please try another video."
    }

    init(error: UploadCreationModel.PickerError) {
        self.error = error

        if error == UploadCreationModel.PickerError.createUploadFailed {
            self.message = "Couldn't create direct upload. Check your access token and network connectivity."
        } else {
            self.message = "Couldn't prepare the video for upload. Please try another video."
        }
    }
}

struct ErrorView_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            WindowBackground.ignoresSafeArea()
            ErrorView()
        }
        .environmentObject(UploadCreationModel())
    }
}
