//
//  SemanticVersion.swift
//  
//
//  Created by Emily Dixon on 2/21/23.
//

import Foundation

/// Version information about the SDK
public struct SemanticVersion {
  /// Major version.
  public static let major = 0
  /// Minor version.
  public static let minor = 6
  /// Patch version.
  public static let patch = 0

  /// String form of the version number.
  public static let versionString = "\(major).\(minor).\(patch)"
}
