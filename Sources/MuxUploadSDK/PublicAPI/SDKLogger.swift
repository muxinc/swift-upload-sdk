//
//  SDKLogger.swift
//
//
//  Created by AJ Barinov on 4/8/22.
//

import Foundation
import OSLog

///
/// Metadata and logging for this SDK
///
public enum SDKLogger {
}

public extension SDKLogger {
    
    /// The `Logger` being used to log events from this SDK
    static var logger: os.Logger? = nil
    
    /// Enables logging by adding a `Logger` with `subsystem: "Mux"` and `category: "Upload"`
    static func enableDefaultLogging() {
        logger = os.Logger(subsystem: "Mux", category: "MuxUpload")
    }
    
    /// Uses the specified `Logger` to log events from this SDK
    static func useLogger(logger: os.Logger) {
        self.logger = logger
    }

}
