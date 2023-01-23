//
//  MuxUploadSDK.swift
//
//
//  Created by AJ Barinov on 4/8/22.
//

import Foundation
import OSLog

///
/// Exposes SDK metadata. Has some extensions that hide global data
///
public enum MuxUploadSDK {
}

public extension MuxUploadSDK {
    static var logger: Logger? = nil
    
    static func enableDefaultLogging() {
        logger = Logger(subsystem: "Mux", category: "MuxUpload")
    }
    
    static func useLogger(logger: Logger) {
        self.logger = logger
    }
}
