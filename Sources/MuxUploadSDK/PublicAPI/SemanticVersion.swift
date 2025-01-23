//
//  SemanticVersion.swift
//  
//
//  Created by Emily Dixon on 2/21/23.
//

import Foundation

/// Version information about the SDK
public struct SemanticVersion {
    /// Major version component.
    public static let major = 1
    /// Minor version component.
    public static let minor = 0
    /// Patch version component.
    public static let patch = 2

    /// String form of the version number in the format X.Y.Z
    /// where X, Y, and Z are the major, minor, and patch
    /// version components
    public static let versionString = "\(major).\(minor).\(patch)"
}
