//
//  HttpError.swift
//  
//
//  Created by Emily Dixon on 2/27/23.
//

import Foundation

struct HttpError : Error {
    let statusCode: Int
    let statusMsg: String
    
    var localizedDescription: String {
        return "HTTP \(statusCode): \(statusMsg)"
    }
}
