//
//  MuxErrorCode.swift
//  
//
//  Created by Emily Dixon on 2/27/23.
//

import Foundation

public enum MuxErrorCase : Int {
    case unknown = -1,
         cancelled = 0,
         file = 1,
         http = 2,
         connection = 3
}
