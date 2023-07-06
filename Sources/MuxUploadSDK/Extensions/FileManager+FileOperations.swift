//
//  FileManager+FileOperations.swift
//

import Foundation

extension FileManager {

    // Work around Swift compiler not bridging Dictionary
    // and NSDictionary properly when calling attributesOfItem
    func fileSizeOfItem(
        atPath path: String
    ) throws -> UInt64 {
        (try attributesOfItem(atPath: path) as NSDictionary)
            .fileSize()
    }
}
