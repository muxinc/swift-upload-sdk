//
//  MuxErrorCode.swift
//  
//
//  Created by Emily Dixon on 2/27/23.
//

import Foundation

/// Represents the possible error cases from a ``MuxUpload``
public enum MuxErrorCase : Int {
    /// The cause of the error is not known
    case unknown = -1
    /// The upload was cancelled
    case cancelled = 0
    /// The input file could not be read or processed
    case file = 1
    /// The upload could not be completed due to an HTTP error
    case http = 2
    /// The upload could not be completed due to a connection error
    case connection = 3
}
