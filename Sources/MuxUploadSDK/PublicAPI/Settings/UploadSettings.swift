//
//  UploadSettings.swift
//

import Foundation

public struct UploadSettings {

    /// Settings to control the SDK network operations to
    /// transport the direct upload input to Mux
    public struct Transport {

        /// At least 8M is recommended
        public var chunkSize: Int

        /// Number of retry attempts per chunk if the
        /// associated request fails
        public var retriesPerChunk: Int

        public init(
            chunkSize: Int = 8 * 1024 * 1024,
            retriesPerChunk: Int = 3
        ) {
            self.chunkSize = chunkSize
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
        public var isEnabled: Bool = true

        /// Preset to control the resolution of the standard
        /// input.
        ///
        /// See ``UploadSettings.Standardization.targetResolution``
        /// for more details.
        public enum ResolutionPreset {
            /// Preset standardized upload input to the SDK
            /// default standard resolution of 1920x1080 (1080p).
            case `default`
            /// Preset standardized upload input to 1280x720
            /// (720p).
            case preset1280x720  // 720p
            /// Preset standardized upload input to 1920x1080
            /// (1080p).
            case preset1920x1080 // 1080p
        }

        /// The preset resolution of the standardized upload
        /// input. If your input resolution is below 1920 by
        /// 1080 for the width and height, respectively, then
        /// the resolution will remain unchanged after input
        /// standardization.
        ///
        /// Example 1: a direct upload input with 1440 x 1080
        /// resolution encoded using Apple ProRes and with
        /// no other non-standard input parameters with
        /// ``ResolutionPreset.default`` selected.
        ///
        /// If input standardization is enabled, the SDK
        /// will attempt standardize the input into an H.264
        /// encoded output that will maintain its original
        /// 1440 x 1080 resolution.
        ///
        /// Example 2: a direct upload input with 1440 x 1080
        /// resolution encoded using H.264 and with no other
        /// non-standard input format parameters with
        /// ``ResolutionPreset.preset1280x720`` selected.
        ///
        /// If input standardization is enabled, the SDK will
        /// not make changes to the resolution of the input.
        /// The input will be uploaded to Mux as-is.
        ///
        public var targetResolution: ResolutionPreset = .default

        /// Disable all local input standardization by the SDK,
        /// any inputs provided to the `MuxUpload` instance
        /// along with this setting will be uploaded to Mux
        /// as they are with no local changes.
        public static let disabled: InputStandardization = InputStandardization(
            isEnabled: false,
            targetResolution: .default
        )

        private init(
            isEnabled: Bool,
            targetResolution: ResolutionPreset
        ) {
            self.isEnabled = isEnabled
            self.targetResolution = targetResolution
        }

        ///
        public init(
            targetResolution: ResolutionPreset
        ) {
            self.isEnabled = true
            self.targetResolution = targetResolution
        }
    }

    /// Input standardization settings for the direct upload
    public var inputStandardization: InputStandardization

    ///
    public struct EventTracking {

        ///
        public var optedOut: Bool

        ///
        public init(optedOut: Bool) {
            self.optedOut = optedOut
        }
    }

    /// Event tracking settings for the direct upload
    public var eventTracking: EventTracking

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
            targetResolution: .default
        ),
        transport: Transport = Transport(),
        eventTracking: EventTracking
    ) {
        self.transport = transport
        self.inputStandardization = inputStandardization
        self.eventTracking = eventTracking
    }

}
