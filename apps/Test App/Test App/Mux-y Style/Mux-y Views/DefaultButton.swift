//
//  DefaultButton.swift
//  Test App
//
//  Created by Emily Dixon on 5/10/23.
//

import SwiftUI

struct DefaultButton: View {
    var body: some View {
        ZStack {
            Green50
                .clipShape(RoundedRectangle(cornerRadius: 4.0))
            Text(text)
                .font(.system(size: 14.0, weight: .bold))
                .foregroundColor(White)
            
        }
        .frame(width: .infinity, height: 40)
    }
    
    var text: String
}

struct DefaultButton_Previews: PreviewProvider {
    static var previews: some View {
        DefaultButton(text: "Button")
    }
}
