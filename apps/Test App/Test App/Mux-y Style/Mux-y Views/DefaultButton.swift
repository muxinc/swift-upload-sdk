//
//  DefaultButton.swift
//  Test App
//
//  Created by Emily Dixon on 5/10/23.
//

import SwiftUI

// As a View (compose-style)
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
    var tapDelegate: () -> Void
    
    init(text: String, tapDelegate: @escaping () -> Void) {
        self.text = text
        self.tapDelegate = tapDelegate
    }
}
struct DefaultButton_Previews: PreviewProvider {
    static var previews: some View {
        DefaultButton(text: "Button") { }
    }
}

struct DefaultButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(buttonBg(isPressed: configuration.isPressed))
            .foregroundColor(White)
            .font(
                .system(
                    size: 14,
                    weight: .bold // 700
                )
            )
    }
    
    private func buttonBg(isPressed: Bool) -> some View {
        if isPressed {
            return Green60.clipShape(RoundedRectangle(cornerRadius: 4.0))
                .frame(width: .infinity, height: 40)
        } else {
            return Green50.clipShape(RoundedRectangle(cornerRadius: 4.0))
                .frame(width: .infinity, height: 40)
        }
    }
}
