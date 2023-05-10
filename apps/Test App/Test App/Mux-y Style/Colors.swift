//
//  MuxColors.swift
//  Test App
//
//  Created by Emily Dixon on 5/10/23.
//

import Foundation
import SwiftUI

// Mux-y Grays
let Gray100 = Color(red: 10 / CONVERSION_CSS, green: 10 / CONVERSION_CSS, blue: 11 / CONVERSION_CSS)
let Gray80 = Color(red: 62 / CONVERSION_CSS, green: 66 / CONVERSION_CSS, blue: 71 / CONVERSION_CSS)
let Gray30 = Color(red: 178, green: 186, blue: 194)

// Mux-y Greens
let Green60 = Color(red: 0 / CONVERSION_CSS, green: 128 / CONVERSION_CSS, blue: 45 / CONVERSION_CSS)
let Green50 = Color(red: 0 / CONVERSION_CSS, green: 170 / CONVERSION_CSS, blue: 60 / CONVERSION_CSS)

// App Colors
let WindowBackground = Color(red: 30 / CONVERSION_CSS, green: 30 / CONVERSION_CSS, blue: 30 / CONVERSION_CSS)
let TransparentScrim = Color(red: 0, green: 0, blue: 0, opacity: 0.6)
let TranslucentWhite = Color(red: 255 / CONVERSION_CSS, green: 255 / CONVERSION_CSS, blue: 255 / CONVERSION_CSS, opacity: 0.5)
let White = Color(red: 255 / CONVERSION_CSS, green: 255 / CONVERSION_CSS, blue: 255 / CONVERSION_CSS)

fileprivate let CONVERSION_CSS = Double(0xFF)
