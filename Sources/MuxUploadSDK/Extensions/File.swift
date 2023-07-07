//
//  NSMutableURLRequest+Reporting.swift
//  

import Foundation

extension NSMutableURLRequest {
    static func make(
        url: URL,
        httpBody: Data
    ) -> NSMutableURLRequest {
        let request = NSMutableURLRequest(
            url: url,
            cachePolicy: .useProtocolCachePolicy,
            timeoutInterval: 10.0
        )

        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = httpBody

        return request
    }
}
