//
//  AgenticApp.swift
//  Agentic
//
//  Created by Arya on 24/08/26.
//

import SwiftData
import SwiftUI

@main
struct AgenticApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                // Pins the whole window, so the keyboard, the menu pickers and
                // the date picker come up light alongside `Theme`'s palette
                // instead of following the device and clashing with it.
                .preferredColorScheme(.light)
        }
        .modelContainer(for: [ChatSession.self, ChatMessage.self, OwnedBean.self, TastingNote.self, BrewSession.self])
    }
}
