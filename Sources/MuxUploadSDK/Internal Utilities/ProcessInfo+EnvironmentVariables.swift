//
//  File.swift
//  
//
//  Created by Liam Lindner on 3/15/23.
//

import Foundation

extension ProcessInfo {

    /// Set the Sentry DSN an environment variable to track upload statistics
    var sentryDsn: String {
        environment[
            "SENTRY_DSN"
        ] ?? ""
    }

}
