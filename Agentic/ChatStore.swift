//
//  ChatStore.swift
//  Agentic
//
//  Created by Arya on 31/08/26.
//

import Foundation
import SwiftData

enum ChatRole: String {
    case user
    case assistant
}

@Model
final class ChatSession {
    var id: UUID
    var createdAt: Date
    var summary: String?

    @Relationship(deleteRule: .cascade, inverse: \ChatMessage.session)
    var messages: [ChatMessage] = []

    init(id: UUID = UUID(), createdAt: Date = .now) {
        self.id = id
        self.createdAt = createdAt
    }

    /// Falls back to `createdAt` for an empty session so a brand new chat
    /// still sorts to the top of the session list.
    var lastActivity: Date {
        messages.map(\.timestamp).max() ?? createdAt
    }

    /// Derived rather than stored, so every chat already in the store gets a
    /// name without a migration. What the user asked first is what they
    /// recognise the room by.
    var title: String {
        messages
            .filter { $0.role == .user }
            .min { $0.timestamp < $1.timestamp }?
            .content ?? "New chat"
    }
}

@Model
final class ChatMessage {
    var id: UUID
    private var roleValue: String
    var content: String
    var timestamp: Date
    var session: ChatSession?

    /// The agent's work for this reply, JSON-encoded. Held as `Data` rather
    /// than as modelled attributes because nothing ever queries inside it: it
    /// is written once and read back whole, for one message, to redraw what
    /// the run showed. Both are optional so an added attribute migrates
    /// without touching the messages already stored.
    private var traceData: Data?
    private var placesData: Data?
    private var cardsData: Data?

    init(role: ChatRole, content: String, timestamp: Date = .now) {
        self.id = UUID()
        self.roleValue = role.rawValue
        self.content = content
        self.timestamp = timestamp
    }

    /// Stored as a raw `String` because SwiftData persists enums by identity,
    /// not by value, so a plain accessor over the stored string is simpler
    /// than modeling a persisted enum for two cases.
    var role: ChatRole {
        get { ChatRole(rawValue: roleValue) ?? .user }
        set { roleValue = newValue.rawValue }
    }

    var steps: [AgentStep] {
        get { Self.decode(traceData) }
        set { traceData = Self.encode(newValue) }
    }

    var places: [MappedPlace] {
        get { Self.decode(placesData) }
        set { placesData = Self.encode(newValue) }
    }

    /// The result cards the run produced. Stored rather than rebuilt so
    /// scrolling back shows the bean that was actually found, not whatever the
    /// corpus would return for the same question today.
    var cards: [ThreadCard] {
        get { Self.decode(cardsData) }
        set { cardsData = Self.encode(newValue) }
    }

    /// An empty list stores as nil, so a reply that used no tools costs no
    /// bytes and reads back the same as one written before these existed.
    private static func encode(_ value: [some Encodable]) -> Data? {
        value.isEmpty ? nil : try? JSONEncoder().encode(value)
    }

    /// A decode failure yields nothing to draw rather than throwing: the
    /// message itself is still readable, and the trace is a record of a run
    /// that has already happened.
    private static func decode<Element: Decodable>(_ data: Data?) -> [Element] {
        guard let data else { return [] }
        return (try? JSONDecoder().decode([Element].self, from: data)) ?? []
    }
}
