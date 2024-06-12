//
//  UploadsFileFaked.swift
//  
//
//  Created by Emily Dixon on 3/8/23.
//

import Foundation
@testable import MuxUploadSDK

class FakeUploadsFile : UploadsFile {
    private let innerFakeFile: UploadsFile
    
    func writeContents(of jsonData: UploadsFileContents) throws {
        try innerFakeFile.writeContents(of: jsonData)
    }
    
    func readContents() throws -> UploadsFileContents {
        return try innerFakeFile.readContents()
    }
    
    func maybeOpenCache() throws {
        try innerFakeFile.maybeOpenCache()
    }
    
    private init(innerFakeFile: UploadsFile) {
        self.innerFakeFile = innerFakeFile
    }
    
    static func failsReadAndWrite() -> FakeUploadsFile {
        return FakeUploadsFile(innerFakeFile: FailsReadAndWrite())
    }
    
    static func simiulatedStorage() -> FakeUploadsFile {
        return FakeUploadsFile(innerFakeFile: try! Simulated())
    }
}

fileprivate class Simulated : UploadsFile {
    
    private var contents: String
    
    func maybeOpenCache() throws {
        // no-op
    }
    
    func writeContents(of jsonData: UploadsFileContents) throws {
        let jsonData = try JSONEncoder().encode(jsonData)
        contents = String(data: jsonData, encoding: .utf8)!
    }
    
    func readContents() throws -> UploadsFileContents {
        return try JSONDecoder().decode(UploadsFileContents.self, from: contents.data(using: .utf8)!)
    }
    
    init() throws {
        let initialContents = UploadsFileContents(entries: [])
        let data = try JSONEncoder().encode(initialContents)
        contents = String(data: data, encoding: .utf8)!
    }
}

fileprivate class FailsReadAndWrite : UploadsFile {
    func writeContents(of jsonData: UploadsFileContents) throws {
        throw DummyError()
    }
    
    func readContents() throws -> UploadsFileContents {
        throw DummyError()
    }
    
    func maybeOpenCache() throws {
        // no-op
    }
}
