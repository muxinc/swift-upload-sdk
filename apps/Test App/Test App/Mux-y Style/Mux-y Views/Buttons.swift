//
//  DefaultButton.swift
//  Test App
//
//  Created by Emily Dixon on 5/10/23.
//

import SwiftUI

/// Default, mux-styled button.
struct DefaultButton: View {
    var body: some View {
        Button {
            action()
        } label: {
            Text(text).padding()
        }
        .buttonStyle(DefaultButtonStyle())
    }
    
    var text: String
    var action: () -> Void
    
    init(_ text: String, action: @escaping () -> Void) {
        self.text = text
        self.action = action
    }
}

/// Stretchy version of the default button. It tries to be as wide as its container
struct StretchyDefaultButton: View {
    var body: some View {
        Button {
            action()
        } label: {
            Text(text)
                .padding()
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(DefaultButtonStyle())
    }
    
    var text: String
    var action: () -> Void
    
    init(_ text: String, action: @escaping () -> Void) {
        self.text = text
        self.action = action
    }
}

/// Base style for buttons in this file. This isn't used directly because you can't set the padding of the label, or control the width of the button via the style. Fully-customizing a button (bg, width, label padding, etc) requires you to create a Button with a specified label. Visible Views in this file do this.
fileprivate struct DefaultButtonStyle: ButtonStyle {
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
        } else {
            return Green50.clipShape(RoundedRectangle(cornerRadius: 4.0))
        }
    }
}

struct DefaultButton_Previews: PreviewProvider {
    static var previews: some View {
        HStack {
            DefaultButton("Default Button") { }
        }
    }
}

struct StretchyDefaultButton_Previews: PreviewProvider {
    static var previews: some View {
        VStack {
            StretchyDefaultButton("Stretchy Button") { }
                .padding()
        }
    }
}
