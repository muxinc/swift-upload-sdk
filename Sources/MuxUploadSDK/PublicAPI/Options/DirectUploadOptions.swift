//
//  DirectUploadOptions.swift
//

import Foundation

// MARK: - Direct Upload Options

/// Options for the direct upload
public struct DirectUploadOptions {

    // MARK: - Transport Options

    /// Options to adjust ``DirectUpload`` chunk transport
    /// over the network.
    public struct Transport {

        /// The size of each file chunk in bytes sent by the
        /// SDK during an upload. At least 8MB is recommended.
        public var chunkSizeInBytes: Int

        /// Number of retry attempts per chunk if its upload
        /// request is unsuccessful
        public var retryLimitPerChunk: Int

        /// Default options for ``DirectUpload`` chunk transport
        /// over the network. The chunk size is 8MB and the
        /// per-chunk retry limit is 3.
        public static var `default`: Transport {
            Transport(
                chunkSizeInBytes: 8 * 1024 * 1024,
                retryLimitPerChunk: 3
            )
        }

        /// Initializes options for upload chunk transport
        /// over the network
        /// - Parameters:
        ///     - chunkSize: the size of each file chunk sent
        ///     by the SDK during an upload.
        ///     Defaults to 8MB.
        ///     - retryLimitPerChunk: number of retry attempts
        ///     if the chunk request fails, default value is 3
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

        /// Initializes options for upload chunk transport
        /// over the network
        /// - Parameters:
        ///     - chunkSizeInBytes: the size of each file chunk in
        ///     bytes the SDK sends when uploading, default
        ///     value is 8MB
        ///     - retryLimitPerChunk: number of retry attempts
        ///     if the chunk request fails, default value is 3
        public init(
            chunkSizeInBytes: Int = 8 * 1024 * 1024,
            retryLimitPerChunk: Int = 3
        ) {
            self.chunkSizeInBytes = chunkSizeInBytes
            self.retryLimitPerChunk = retryLimitPerChunk
        }
    }

    /// Transport options for the direct upload
    public var transport: Transport

    // MARK: - Input Standardization Options

    /// Options for adjusments made by ``DirectUpload``
    /// to some inputs to minimize processing time during
    /// ingestion
    public struct InputStandardization {

        /// If requested the SDK will attempt to detect
        /// non-standard input formats and if so detected
        /// will attempt to standardize to a standard input
        /// format. ``true`` by default
        public var isRequested: Bool = true

        /// Preset to control the resolution of the standard
        /// input.
        ///
        /// See ``DirectUploadOptions.InputStandardization.maximumResolution``
        /// for more details.
        public enum MaximumResolution {
            /// Preset standardized direct upload input to the SDK
            /// default standard resolution of 1920x1080 (1080p).
            case `default`
            /// Limit standardized direct upload input resolution to
            /// 1280x720 (720p).
            case preset1280x720  // 720p
            /// Limit standardized direct upload input resolution to
            /// 1920x1080 (1080p).
            case preset1920x1080 // 1080p
        }

        /// The maximum resolution of the standardized direct
        /// upload input. If the input has a video resolution
        /// below this value, the resolution will remain
        /// unchanged after input standardization.
        ///
        /// Example 1: a direct upload input with 1440 x 1080
        /// resolution encoded using Apple ProRes and with
        /// no other non-standard input parameters with
        /// ``MaximumResolution.default`` selected.
        ///
        /// If input standardization is requested, the SDK
        /// will attempt standardize the input into an H.264
        /// encoded output that will maintain its original
        /// 1440 x 1080 resolution.
        ///
        /// Example 2: a direct upload input with 1440 x 1080
        /// resolution encoded using H.264 and with no other
        /// non-standard input format parameters with
        /// ``MaximumResolution.preset1280x720`` selected.
        ///
        /// If input standardization is requested, the SDK
        /// will attempt standardize the input into an H.264
        /// encoded output with a reduced 1280 x 720 resolution.
        ///
        public var maximumResolution: MaximumResolution = .default

        /// Default options where input standardization is
        /// requested and the maximum resolution is set to 1080p.
        public static let `default`: InputStandardization = InputStandardization(
            isRequested: true,
            maximumResolution: .default
        )

        /// Skip all local input standardization by the SDK.
        ///
        /// Initializing a ``DirectUpload`` with input
        /// standardization skipped will result in SDK
        /// uploading all inputs as they are with no format
        /// changes performed on the client. Mux Video will
        /// still convert your input to a standard format
        /// on the server when it is ingested.
        public static let skipped: InputStandardization = InputStandardization(
            isRequested: false,
            maximumResolution: .default
        )

        // Kept private to avoid an invalid combination of
        // parameters being used for initialization
        private init(
            isRequested: Bool,
            maximumResolution: MaximumResolution
        ) {
            self.isRequested = isRequested
            self.maximumResolution = maximumResolution
        }

        /// Initializes options that request input
        /// standardization with a custom maximum resolution
        /// - Parameters:
        ///     - maximumResolution: the maximum resolution
        ///     of the standardized input
        public init(
            maximumResolution: MaximumResolution
        ) {
            self.isRequested = true
            self.maximumResolution = maximumResolution
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
    ///     - inputStandardization: options to enable or
    ///     disable standardizing the format of the direct
    ///     upload inputs, it is requested by default. To
    ///     prevent the SDK from making any changes to the
    ///     format of the input use ``DirectUploadOptions.InputStandardization.skipped``
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
    ///     - inputStandardization: options to enable or
    ///     disable standardizing the format of the direct
    ///     upload inputs. True by default.
    ///     To prevent the SDK from making any changes to the
    ///     upload inputs. True by default.
    ///     To prevent the SDK from making any changes to the
    ///     format of the input use ``DirectUploadOptions.InputStandardization.skipped``
    ///     - chunkSize: The size of each file chunk sent by
    ///     the SDK during an upload. Defaults to 8MB.
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
    ///     - inputStandardization: options to enable or
    ///     disable standardizing the format of the direct
    ///     upload inputs. True by default.
    ///     To prevent the SDK from making any changes to the
    ///     upload inputs. True by default.
    ///     format of the input use ``DirectUploadOptions.InputStandardization.skipped``
    ///     - chunkSizeInBytes: The size of each file chunk
    ///     in bytes sent by the SDK during an upload.
    ///     Defaults to 8MB.
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
            unit: .megabytes
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
        case .default:
            return "default"
        }
    }
}

extension DirectUploadOptions: Codable { }

extension DirectUploadOptions.EventTracking: Codable { }

extension DirectUploadOptions.InputStandardization: Codable { }

extension DirectUploadOptions.InputStandardization.MaximumResolution: Codable { }

extension DirectUploadOptions.Transport: Codable { }

extension DirectUploadOptions: Equatable { }

extension DirectUploadOptions.EventTracking: Equatable { }

extension DirectUploadOptions.InputStandardization: Equatable { }

extension DirectUploadOptions.InputStandardization.MaximumResolution: Equatable { }

extension DirectUploadOptions.Transport: Equatable { }
