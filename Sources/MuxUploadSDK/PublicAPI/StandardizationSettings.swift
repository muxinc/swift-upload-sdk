//
//  StandardizationSettings.swift
//

import Foundation

/// Standard input conversion preferences
public enum StandardizationSettings {
    /// Standard input conversion disabled, input file is passed through
    /// as is without modifications
    case disabled

    /// Attempts to convert to standard input at the specified resolution
    /// Input files with a smaller resolution keep their resolution
    case enabled(resolution: ResolutionPreset)

    public enum ResolutionPreset {
        case `default`
        case preset1280x720  // 720p
        case preset1920x1080 // 1080p
    }
}
