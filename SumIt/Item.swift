//
//  Item.swift
//  SumIt
//
//  Created by Mykyta Metlytskyi on 25.03.2026.
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
