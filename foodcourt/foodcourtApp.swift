//
//  foodcourtApp.swift
//  foodcourt
//
//  Created by Shafa Tiara on 03/08/26.
//

import SwiftUI
import SwiftData

@main
struct FoodcourtApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 820)
        .modelContainer(for: AnalysisRecord.self)
    }
}
