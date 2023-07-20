//
//  UploadSettings.swift
//

import Foundation

/// Settings for the direct upload
public struct UploadOptions {

    /// Settings to control the SDK network operations to
    /// transport the direct upload input to Mux
    public struct Transport {

        /// At least 8M is recommended
        public var chunkSizeInBytes: Int

        /// Number of retry attempts per chunk if the
        /// associated request fails
        public var retriesPerChunk: Int

        /// Initializes options that govern network transport
        /// by the SDK
        ///
        /// - Parameters:
        ///     - chunkSize: the size of each file chunk in
        ///     bytes the SDK sends when uploading, default
        ///     value is 8MB
        ///     - retriesPerChunk: number of retry attempts
        ///     if the chunk request fails, default value is 3
        public init(
            chunkSizeInBytes: Int = 8 * 1024 * 1024,
            retriesPerChunk: Int = 3
        ) {
            self.chunkSizeInBytes = chunkSizeInBytes
            self.retriesPerChunk = retriesPerChunk
        }
    }

    /// Transport settings for the direct upload
    public var transport: Transport

    /// Settings controlling direct upload input standardization
    public struct InputStandardization {

        /// If enabled the SDK will attempt to detect
        /// non-standard input formats and if so detected
        /// will attempt to standardize to a standard input
        /// format. ``true`` by default
        public var isRequested: Bool = true

        /// Preset to control the resolution of the standard
        /// input.
        ///
        /// See ``UploadSettings.Standardization.maximumResolution``
        /// for more details.
        public enum MaximumResolution {
            /// Preset standardized upload input to the SDK
            /// default standard resolution of 1920x1080 (1080p).
            case `default`
            /// Limit standardized upload input resolution to
            /// 1280x720 (720p).
            case preset1280x720  // 720p
            /// Limit standardized upload input resolution to
            /// 1920x1080 (1080p).
            case preset1920x1080 // 1080p
        }

        /// The maximum resolution of the standardized upload
        /// input. If the input video provided to the upload
        /// has a resolution below this value, the resolution
        /// will remain unchanged after input standardization.
        ///
        /// Example 1: a direct upload input with 1440 x 1080
        /// resolution encoded using Apple ProRes and with
        /// no other non-standard input parameters with
        /// ``MaximumResolution.default`` selected.
        ///
        /// If input standardization is enabled, the SDK
        /// will attempt standardize the input into an H.264
        /// encoded output that will maintain its original
        /// 1440 x 1080 resolution.
        ///
        /// Example 2: a direct upload input with 1440 x 1080
        /// resolution encoded using H.264 and with no other
        /// non-standard input format parameters with
        /// ``MaximumResolution.preset1280x720`` selected.
        ///
        /// If input standardization is enabled, the SDK
        /// will attempt standardize the input into an H.264
        /// encoded output with a reduced 1280 x 720 resolution.
        ///
        public var maximumResolution: MaximumResolution = .default

        /// Default options where input standardization is
        /// enabled and the maximum resolution is set to 1080p.
        public static let `default`: InputStandardization = InputStandardization(
            isRequested: true,
            maximumResolution: .default
        )

        /// Disable all local input standardization by the SDK.
        ///
        /// Initializing an upload with input standardization
        /// disabled will prevent the SDK from making any
        /// changes before commencing the upload. All input
        /// will be uploaded to Mux as-is.
        ///
        /// Note: non-standard input will still be converted
        /// to a standardized format upon ingestion.
        public static let disabled: InputStandardization = InputStandardization(
            isRequested: false,
            maximumResolution: .default
        )

        // Kept private to an invalid combination of parameters
        // being used for initialization
        private init(
            isRequested: Bool,
            maximumResolution: MaximumResolution
        ) {
            self.isRequested = isRequested
            self.maximumResolution = maximumResolution
        }

        /// Used to initialize ``UploadOptions.InputStandardization``
        /// with that enables input standardization with
        /// a maximum resolution
        ///
        /// - Parameters:
        ///     - maximumResolution: the maximum resolution
        ///     of the standardized upload input
        public init(
            maximumResolution: MaximumResolution
        ) {
            self.isRequested = true
            self.maximumResolution = maximumResolution
        }
    }

    /// Input standardization settings for the direct upload
    public var inputStandardization: InputStandardization

    ///
    public struct EventTracking {

        static public var `default`: EventTracking {
            EventTracking(optedOut: false)
        }

        ///
        public var optedOut: Bool

        ///
        public init(optedOut: Bool) {
            self.optedOut = optedOut
        }
    }

    /// Event tracking settings for the direct upload
    public var eventTracking: EventTracking

    public static var `default`: UploadOptions {
        UploadOptions()
    }

    /// - Parameters:
    ///     - inputStandardization: settings to enable or
    ///     disable standardizing the format of the direct
    ///     upload inputs, enabled by default. To prevent the
    ///     SDK from making any changes to the format of the
    ///     input use ``UploadSettings.InputStandardization.disabled``
    ///     - transport: settings for transporting the
    ///     direct upload input to Mux
    ///     - eventTracking: event tracking settings for the
    ///     direct upload
    public init(
        inputStandardization: InputStandardization = InputStandardization(
            maximumResolution: .default
        ),
        transport: Transport = Transport(),
        eventTracking: EventTracking = .default
    ) {
        self.transport = transport
        self.inputStandardization = inputStandardization
        self.eventTracking = eventTracking
    }

}

extension UploadOptions.InputStandardization.MaximumResolution: CustomStringConvertible {
    public var description: String {
        switch self {
        case .preset1280x720:
            return "preset1280x720"
        case .preset1920x1080:
            return "preset1920x1080"
        case .default:
            return "default"
        }
    }
}

extension UploadOptions: Codable { }

extension UploadOptions.EventTracking: Codable { }

extension UploadOptions.InputStandardization: Codable { }

extension UploadOptions.InputStandardization.MaximumResolution: Codable { }

extension UploadOptions.Transport: Codable { }

extension UploadOptions: Equatable { }

extension UploadOptions.EventTracking: Equatable { }

extension UploadOptions.InputStandardization: Equatable { }

extension UploadOptions.InputStandardization.MaximumResolution: Equatable { }

extension UploadOptions.Transport: Equatable { }
