//
//  LearnView.swift
//  Agentic
//

import SwiftUI

/// Flashcards on processing methods and the moka pot itself. Kept as a deck
/// rather than a chat exchange because the value is in covering the card
/// before the answer, which a transcript gives away.
struct LearnView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var isRevealed = false

    private let cards = Flashcards.all

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Theme.lg) {
                Text("Card \(index + 1) of \(cards.count)")
                    .font(Theme.label)
                    .foregroundStyle(Theme.inkMuted)

                Button {
                    withAnimation(Theme.enter) { isRevealed.toggle() }
                } label: {
                    VStack(alignment: .leading, spacing: Theme.md) {
                        Text(isRevealed ? cards[index].back : cards[index].front)
                            .font(Theme.reading)
                            .foregroundStyle(Theme.ink)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Text(isRevealed ? "Tap to flip back" : "Tap to reveal")
                            .font(Theme.trace)
                            .foregroundStyle(Theme.inkMuted)
                    }
                    .padding(Theme.lg)
                    .frame(maxWidth: .infinity, minHeight: 200, alignment: .topLeading)
                    .background(Theme.paperRaised, in: .rect(cornerRadius: Theme.bubbleRadius))
                }
                .buttonStyle(.plain)

                HStack {
                    Button("Previous") { move(-1) }
                        .disabled(index == 0)
                    Spacer()
                    Button("Next") { move(1) }
                        .disabled(index == cards.count - 1)
                }
                .font(Theme.control)
                .tint(Theme.accent)

                Spacer(minLength: 0)
            }
            .padding(Theme.lg)
            .background(Theme.paper)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.paper, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Flashcards").font(Theme.display).foregroundStyle(Theme.ink)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.tint(Theme.accent)
                }
            }
        }
    }

    private func move(_ step: Int) {
        withAnimation(Theme.enter) {
            index = min(max(index + step, 0), cards.count - 1)
            isRevealed = false
        }
        Log.write(.ui, "flashcard \(index + 1)/\(cards.count) \(cards[index].id)")
    }
}
