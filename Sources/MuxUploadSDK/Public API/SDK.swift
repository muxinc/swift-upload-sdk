//
//  MuxUploadSDK.swift
//
//
//  Created by AJ Barinov on 4/8/22.
//

import Foundation
import OSLog
import Sentry

///
/// Exposes SDK metadata. Has some extensions that hide global data
///
public enum MuxUploadSDK {
}

public extension MuxUploadSDK {
    static var logger: Logger? = nil
    
    static func enableDefaultLogging() {
        logger = Logger(subsystem: "Mux", category: "MuxUpload")

        var dsn: String = ProcessInfo.processInfo.sentryDsn

        if(!dsn.isEmpty) {
            SentrySDK.start { options in
                options.dsn = dsn
                options.debug = false

                //https://docs.sentry.io/platforms/apple/performance/instrumentation/automatic-instrumentation/?_ga=2.179760102.336678793.1678743391-956346762.1678743391#opt-out
                options.enableAutoPerformanceTracing = false
            }
        }
    }
    
    static func useLogger(logger: Logger) {
        self.logger = logger
    }
}
