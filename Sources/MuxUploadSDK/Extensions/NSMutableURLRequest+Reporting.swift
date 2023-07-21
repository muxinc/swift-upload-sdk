//
//  NSMutableURLRequest+Reporting.swift
//  

import Foundation

extension NSMutableURLRequest {
    static func makeJSONPost(
        url: URL,
        httpBody: Data,
        additionalHTTPHeaders: [String: String]
    ) -> NSMutableURLRequest {
        let request = NSMutableURLRequest(
            url: url,
            cachePolicy: .useProtocolCachePolicy,
            timeoutInterval: 10.0
        )

        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for keypair in additionalHTTPHeaders {
            request.setValue(keypair.value, forHTTPHeaderField: keypair.key)
        }

        request.httpBody = httpBody

        return request
    }
}
