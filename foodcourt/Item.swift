//
//  Item.swift
//  foodcourt
//
//  Created by Shafa Tiara on 03/08/26.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
