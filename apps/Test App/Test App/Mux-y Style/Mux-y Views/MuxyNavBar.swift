//
//  SwiftUIView.swift
//  Test App
//
//  Created by Emily Dixon on 5/10/23.
//

import SwiftUI

struct MuxyNavBar: View {
    var body: some View {
        ZStack {
            // Center Content - Default is the mux logo
            VStack {
                Spacer()
                if let title = title {
                    Text(title)
                        .foregroundColor(White)
                        .font(
                            .system(
                                size: 18,
                                weight: .bold // 700
                            )
                        )
                } else {
                    Image("Mux Logo")
                }
                Spacer()
            }
            // Leading Content (default is nothing)
            if let leadingNavButton = leadingNavButton {
                HStack {
                    leadingView(for: leadingNavButton)
                    Spacer()
                }.padding()
            }
            VStack {
                Spacer()
                Gray80
                    .frame(height: 1, alignment: .bottom)
            }
        }
        .frame(height: 64)
        .background(Gray100)
    }
    
    let leadingNavButton: LeadingNavButton?
    let title: String?
    
    init(leadingNavButton: LeadingNavButton? = nil, title: String? = nil) {
        self.leadingNavButton = leadingNavButton
        self.title = title
    }
}

fileprivate func leadingView(for buttonType: LeadingNavButton) -> some View {
    switch buttonType {
    case .close:
        return Image("Mux-y Close")
    }
}

enum LeadingNavButton {
    case close
}

struct MuxyNavBar_Previews: PreviewProvider {
    static var previews: some View {
        VStack {
            MuxyNavBar(
                leadingNavButton: .close,
                title: "some title"
            )
            MuxyNavBar()
            Spacer()
        }
    }
}
