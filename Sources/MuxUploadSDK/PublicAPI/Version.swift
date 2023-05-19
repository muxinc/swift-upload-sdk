//
//  Version.swift
//  
//
//  Created by Emily Dixon on 2/21/23.
//

import Foundation

public struct Version {
  /// Major version.
  public static let major = 0
  /// Minor version.
  public static let minor = 2
  /// Revision number.
  public static let revision = 1

  /// String form of the version number.
  public static let versionString = "\(major).\(minor).\(revision)"
}
