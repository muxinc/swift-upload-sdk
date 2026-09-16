//
//  DirectUploadOptions.swift
//

import Foundation

// MARK: - Direct Upload Options

/// Options for the direct upload
public struct DirectUploadOptions {

    // MARK: - Transport Options

    /// Options for tuning network transport of direct upload
    /// chunks to Mux. Using the ``default`` is recommended
    /// for most applications.
    public struct Transport {

        /// The size of each file chunk in bytes sent by the
        /// SDK during an upload. At least 8MiB is recommended.
        /// Chunk size should be a multiple of 256 KiB (256 x 1024 bytes)
        /// unless it's the final chunk or is greater than the size of 
        /// the video file.
        public var chunkSizeInBytes: Int

        /// Number of retry attempts per chunk if its upload
        /// request is unsuccessful
        public var retryLimitPerChunk: Int

        /// Default options for ``DirectUpload`` chunk transport
        /// over the network. The chunk size is 8MiB and the
        /// per-chunk retry limit is 3.
        public static var `default`: Transport {
            Transport(
                chunkSizeInBytes: 8 * 1024 * 1024,
                retryLimitPerChunk: 3
            )
        }

        /// Initializes options for transport of upload chunks
        /// over the network
        /// - Parameters:
        ///     - chunkSize: the size of each file chunk sent
        ///     by the SDK during an upload.
        ///     Defaults to 8MiB. Chunk size should be a 
        ///     multiple of 256 KiB (256 x 1024 bytes)
        ///     unless it's the final chunk or is greater than the 
        ///     size of the video file.
        ///     - retryLimitPerChunk: number of times a failed
        ///     chunk request is retried. Default limit is
        ///     3 retries.
        public init(
            chunkSize: Measurement<UnitInformationStorage> = .defaultDirectUploadChunkSize,
            retryLimitPerChunk: Int = 3
        ) {
            self.chunkSizeInBytes = Int(
                abs(chunkSize.converted(to: .bytes).value)
                    .rounded(.down)
            )
            self.retryLimitPerChunk = retryLimitPerChunk
        }

        /// Initializes options for transport of upload chunks
        /// over the network
        /// - Parameters:
        ///     - chunkSizeInBytes: the size of each file
        ///     chunk in bytes the SDK uploads in a single
        ///     request. Defaults to 8MiB. Chunk size should be a 
        ///     multiple of 256 KiB (256 x 1024 bytes)
        ///     unless it's the final chunk or is greater than the 
        ///     size of the video file.
        ///     - retryLimitPerChunk: number of times a failed
        ///     chunk request is retried. Default limit is
        ///     3 retries.
        public init(
            chunkSizeInBytes: Int = 8 * 1024 * 1024,
            retryLimitPerChunk: Int = 3
        ) {
            self.chunkSizeInBytes = chunkSizeInBytes
            self.retryLimitPerChunk = retryLimitPerChunk
        }
    }

    /// Network transport options for direct upload chunks
    public var transport: Transport

    // MARK: - Input Standardization Options

    /// Options for best-effort adjustments made by ``DirectUpload`` to minimize
    /// processing time during ingestion.
    ///
    /// The SDK uploads compliant H.264 and HEVC inputs without re-encoding them.
    /// When it creates standardized output, it preserves the H.264 or HEVC codec
    /// family when the device supports the required conversion. If inspection,
    /// conversion, or output validation doesn't succeed, the upload's
    /// ``DirectUpload/nonStandardInputHandler`` determines whether to cancel or
    /// upload the original input. The original input is uploaded by default.
    public struct InputStandardization: Sendable {

        /// Whether the SDK should inspect the input and attempt to standardize
        /// noncompliant media before upload. The default is `true`.
        public var isRequested: Bool = true

        /// Controls the maximum dimensions of output generated during input
        /// standardization. The SDK never scales smaller input up.
        ///
        /// Selecting 1440p or 2160p controls only the output prepared on the
        /// device. Configure the matching `new_asset_settings.max_resolution_tier`
        /// when creating the Mux Direct Upload in your trusted environment.
        public enum MaximumResolution: Sendable {
            /// Limit generated output to 1920 x 1080 (1080p). This is the
            /// default. Smaller input is not scaled up.
            case `default`
            /// Limit generated output to 1280 x 720 (720p). Smaller input is
            /// not scaled up.
            case preset1280x720  // 720p
            /// Limit generated output to 1920 x 1080 (1080p). Smaller input is
            /// not scaled up.
            case preset1920x1080 // 1080p
            /// Limit generated output to 2560 x 1440 (1440p). Smaller input is
            /// not scaled up. Set `new_asset_settings.max_resolution_tier` to
            /// `"1440p"` when creating the Mux Direct Upload.
            case preset2560x1440 // 1440p
            /// Limit generated output to 3840 x 2160 (2160p/4K). Smaller input
            /// is not scaled up. Set `new_asset_settings.max_resolution_tier`
            /// to `"2160p"` when creating the Mux Direct Upload.
            case preset3840x2160 // 2160p
        }

        /// Controls how the SDK handles supported HDR input during input
        /// standardization.
        public enum HDRHandling: Codable, Equatable, Sendable {
            /// Upload eligible HLG and PQ input unchanged for Mux processing.
            /// This is the default. PQ input requires compatible Mux
            /// configuration and may require an additional server-side
            /// transcode. Preservation does not guarantee end-to-end HDR
            /// playback; processing, playback configuration, the player, and
            /// the display also affect the result.
            case preserve
            /// Convert supported HLG and PQ input to BT.709 SDR on the device.
            /// If the device cannot complete and validate the conversion, the
            /// upload follows the configured original-input fallback behavior.
            case toneMapToSDR
        }

        /// The maximum resolution of the standardized direct
        /// upload input. If the input has a video resolution
        /// below this value, the resolution will remain
        /// unchanged after input standardization.
        ///
        /// Example 1: a direct upload input with 1440 x 1080
        /// resolution encoded using Apple ProRes and with
        /// no other non-standard input parameters with
        /// ``MaximumResolution/default`` selected.
        ///
        /// If input standardization is requested, the SDK
        /// will attempt to standardize the input into an H.264
        /// encoded output that will maintain its original
        /// 1440 x 1080 resolution.
        ///
        /// Example 2: a direct upload input with 1440 x 1080
        /// resolution encoded using H.264 and with no other
        /// non-standard input format parameters with
        /// ``MaximumResolution/preset1280x720`` selected.
        ///
        /// If input standardization is requested, the SDK
        /// will attempt to standardize the input into an H.264
        /// encoded output with a reduced 1280 x 720 resolution.
        ///
        public var maximumResolution: MaximumResolution = .default

        /// The requested behavior for supported HDR input. The default is
        /// ``HDRHandling/preserve``.
        public var hdrHandling: HDRHandling = .preserve

        /// Default options where input standardization is
        /// requested, the maximum resolution is set to 1080p,
        /// and eligible HDR input is preserved.
        public static let `default`: InputStandardization = InputStandardization(
            isRequested: true,
            maximumResolution: .default,
            hdrHandling: .preserve
        )

        /// Skip all local input inspection and standardization by the SDK.
        ///
        /// Initializing a ``DirectUpload`` with input
        /// standardization skipped will result in SDK
        /// uploading all inputs as they are with no format
        /// changes performed on the client. Mux Video will
        /// still convert your input to a standard format
        /// on the server when it is ingested.
        public static let skipped: InputStandardization = InputStandardization(
            isRequested: false,
            maximumResolution: .default,
            hdrHandling: .preserve
        )

        // Kept private to avoid an invalid combination of
        // parameters being used for initialization
        private init(
            isRequested: Bool,
            maximumResolution: MaximumResolution,
            hdrHandling: HDRHandling
        ) {
            self.isRequested = isRequested
            self.maximumResolution = maximumResolution
            self.hdrHandling = hdrHandling
        }

        /// Initializes options that request input
        /// standardization with a custom maximum resolution
        /// and HDR behavior.
        /// - Parameters:
        ///     - maximumResolution: the maximum resolution
        ///     of the standardized input
        ///     - hdrHandling: how eligible HDR input is handled.
        ///     Defaults to ``HDRHandling/preserve``.
        public init(
            maximumResolution: MaximumResolution,
            hdrHandling: HDRHandling = .preserve
        ) {
            self.isRequested = true
            self.maximumResolution = maximumResolution
            self.hdrHandling = hdrHandling
        }
    }

    /// Input standardization options for the direct upload
    public var inputStandardization: InputStandardization

    // MARK: - Event Tracking Options

    /// Event tracking options
    public struct EventTracking {

        /// Default options that opt into event tracking
        static public var `default`: EventTracking {
            EventTracking(optedOut: false)
        }

        /// Flag indicating if opted out of event tracking
        public var optedOut: Bool

        /// - Parameters:
        ///     - optedOut: if true opts out of event
        ///     tracking
        public init(
            optedOut: Bool
        ) {
            self.optedOut = optedOut
        }
    }

    /// Event tracking options for the direct upload
    public var eventTracking: EventTracking

    // MARK: Default Direct Upload Options

    public static var `default`: DirectUploadOptions {
        DirectUploadOptions()
    }

    // MARK: Direct Upload Options Initializers

    /// Initializes options that dictate how the direct upload
    /// is carried out by the SDK
    /// - Parameters:
    ///     - inputStandardization: options related to input
    ///     standardization. Input standardization is requested
    ///     by default.
    ///     To skip input standardization, pass
    ///     ``InputStandardization/skipped``.
    ///     - transport: options for transporting the
    ///     direct upload input to Mux
    ///     - eventTracking: event tracking options for the
    ///     direct upload
    public init(
        inputStandardization: InputStandardization = .default,
        transport: Transport = .default,
        eventTracking: EventTracking = .default
    ) {
        self.inputStandardization = inputStandardization
        self.transport = transport
        self.eventTracking = eventTracking
    }

    /// Initializes options that dictate how the direct upload
    /// is carried out by the SDK
    /// - Parameters:
    ///     - eventTracking: event tracking options for the
    ///     direct upload
    ///     - inputStandardization: options related to input
    ///     standardization. Input standardization is requested
    ///     by default.
    ///     To skip input standardization, pass
    ///     ``InputStandardization/skipped``.
    ///     - chunkSize: The size of each file chunk sent by
    ///     the SDK during an upload. Defaults to 8MiB. 
    ///     Chunk size should be a multiple of 256 KiB (256 x 1024 bytes)
    ///     unless it's the final chunk or is greater than the size of 
    ///     the video file.
    ///     - retryLimitPerChunk: number of retry attempts
    ///     if the chunk request fails. Defaults to 3.
    public init(
        eventTracking: EventTracking = .default,
        inputStandardization: InputStandardization = .default,
        chunkSize: Measurement<UnitInformationStorage> = .defaultDirectUploadChunkSize,
        retryLimitPerChunk: Int = 3
    ) {
        self.eventTracking = eventTracking
        self.inputStandardization = inputStandardization
        self.transport = Transport(
            chunkSize: chunkSize,
            retryLimitPerChunk: retryLimitPerChunk
        )
    }

    /// Initializes options that dictate how the direct upload
    /// is carried out by the SDK
    /// - Parameters:
    ///     - eventTracking: event tracking options for the
    ///     direct upload
    ///     - inputStandardization: options related to input
    ///     standardization. Input standardization is requested
    ///     by default.
    ///     To skip input standardization, pass
    ///     ``InputStandardization/skipped``.
    ///     - chunkSizeInBytes: The size of each file chunk
    ///     in bytes sent by the SDK during an upload.
    ///     Defaults to 8MiB. Chunk size should be a 
    ///     multiple of 256 KiB (256 x 1024 bytes)
    ///     unless it's the final chunk or is greater than the 
    ///     size of the video file.
    ///     - retryLimitPerChunk: number of retry attempts
    ///     if the chunk request fails. Defaults to 3.
    public init(
        eventTracking: EventTracking = .default,
        inputStandardization: InputStandardization = .default,
        chunkSizeInBytes: Int = 8 * 1024 * 1024,
        retryLimitPerChunk: Int = 3
    ) {
        self.eventTracking = eventTracking
        self.inputStandardization = inputStandardization
        self.transport = Transport(
            chunkSizeInBytes: chunkSizeInBytes,
            retryLimitPerChunk: retryLimitPerChunk
        )
    }

}

// MARK: - Extensions

extension Measurement where UnitType == UnitInformationStorage {
    /// Default direct upload chunk size
    public static var defaultDirectUploadChunkSize: Self {
        Measurement(
            value: 8,
            unit: .mebibytes
        )
    }
}

extension DirectUploadOptions.InputStandardization.MaximumResolution: CustomStringConvertible {
    public var description: String {
        switch self {
        case .preset1280x720:
            return "preset1280x720"
        case .preset1920x1080:
            return "preset1920x1080"
        case .preset2560x1440:
            return "preset2560x1440"
        case .preset3840x2160:
            return "preset3840x2160"
        case .default:
            return "default"
        }
    }
}

extension DirectUploadOptions: Codable { }

extension DirectUploadOptions.EventTracking: Codable { }

extension DirectUploadOptions.InputStandardization: Codable {
    enum CodingKeys: String, CodingKey {
        case isRequested
        case maximumResolution
        case hdrHandling
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.isRequested = try container.decode(
            Bool.self,
            forKey: .isRequested
        )
        self.maximumResolution = try container.decode(
            MaximumResolution.self,
            forKey: .maximumResolution
        )
        self.hdrHandling = try container.decodeIfPresent(
            HDRHandling.self,
            forKey: .hdrHandling
        ) ?? .preserve
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isRequested, forKey: .isRequested)
        try container.encode(maximumResolution, forKey: .maximumResolution)
        try container.encode(hdrHandling, forKey: .hdrHandling)
    }
}

extension DirectUploadOptions.InputStandardization.MaximumResolution: Codable { }

extension DirectUploadOptions.Transport: Codable { }

extension DirectUploadOptions: Equatable { }

extension DirectUploadOptions.EventTracking: Equatable { }

extension DirectUploadOptions.InputStandardization: Equatable { }

extension DirectUploadOptions.InputStandardization.MaximumResolution: Equatable { }

extension DirectUploadOptions.Transport: Equatable { }
