//
//  MuxUpload+Transport.swift
//

import Foundation

extension MuxUpload {

    /// Transport-related settings
    public struct TransportSettings {
        /// // Google recommends *at least* 8M
        public var chunkSize: Int
        public var retriesPerChunk: Int

        public init(
            chunkSize: Int = 8 * 1024 * 1024,
            retriesPerChunk: Int = 3
        ) {
            self.chunkSize = chunkSize
            self.retriesPerChunk = retriesPerChunk
        }
    }

}
