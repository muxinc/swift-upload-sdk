//
//  Created for UploadTests.
//
//  Copyright © 2022 Mux, Inc.
//  Licensed under the MIT License.
//

import Foundation

/// Functions to fetch environment variables containing Mux-related
/// API tokens or signing key parameters
///

enum EnvironmentVariableError: Error {
    case missing(variableName: String)
}

enum EnvironmentVariable: String {
    case tokenID = "MUX_ACCESS_TOKEN_ID"
    case tokenSecret = "MUX_ACCESS_SECRET_KEY"
}

func fetchEnvironmentVariable(
    _ variable: EnvironmentVariable
) throws -> String {
    guard let variable = ProcessInfo.processInfo.environment[
        variable.rawValue
    ] else {
        throw EnvironmentVariableError.missing(
            variableName: variable.rawValue
        )
    }

    return variable
}


func fetchTokenID() throws -> String {
    try fetchEnvironmentVariable(
        .tokenID
    )
}

func fetchTokenSecret() throws -> String {
    try fetchEnvironmentVariable(
        .tokenSecret
    )
}
