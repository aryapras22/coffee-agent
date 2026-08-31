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
        }
        .modelContainer(for: [ChatSession.self, ChatMessage.self])
    }
}
