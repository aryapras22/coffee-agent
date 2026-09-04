//
//  ThreadCardViews.swift
//  Agentic
//

import SwiftUI

/// Draws whatever a turn's tools found, under the reply that used them. The
/// facts here come off the corpus and the store, never off the model's prose,
/// so a cupping score on a card is the one in the file.
struct ThreadCardView: View {
    let card: ThreadCard

    var body: some View {
        switch card {
        case .bean(let bean): BeanCardView(bean: bean)
        case .owned(let owned): OwnedCardView(owned: owned)
        case .comparison(let comparison): ComparisonCardView(comparison: comparison)
        case .seller(let seller): SellerCardView(seller: seller)
        case .flashcard(let card): FlashcardView(card: card)
        // The options are drawn as reply chips under the composer instead, so
        // the answer is where the reader is already looking.
        case .choices: EmptyView()
        }
    }
}

/// The frame every card shares: a ruled box, a title, and a footer naming
/// where the contents came from.
private struct CardFrame<Content: View>: View {
    let title: String
    var caption: String?
    var flag: String?
    var source: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.sm) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.sm) {
                Text(title)
                    .font(Theme.display)
                    .foregroundStyle(Theme.ink)
                if let flag {
                    Text(flag)
                        .font(Theme.trace)
                        .foregroundStyle(Theme.danger)
                }
            }

            if let caption {
                Text(caption).font(Theme.label).foregroundStyle(Theme.inkMuted)
            }

            content

            if let source {
                Text(source)
                    .font(Theme.trace)
                    .foregroundStyle(Theme.inkMuted)
                    .padding(.top, Theme.xs)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.md)
        .background(Theme.paperRaised, in: .rect(cornerRadius: Theme.bubbleRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.bubbleRadius)
                .stroke(Theme.rule, lineWidth: Theme.hairline)
        )
    }
}

private struct CardRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(Theme.label).foregroundStyle(Theme.inkMuted)
            Spacer(minLength: Theme.md)
            Text(value)
                .font(Theme.control)
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.trailing)
        }
    }
}

private struct TagRow: View {
    let tags: [String]

    var body: some View {
        FlowLayout(spacing: Theme.xs) {
            ForEach(tags, id: \.self) { tag in
                Text(tag)
                    .font(Theme.label)
                    .foregroundStyle(Theme.inkMuted)
                    .padding(.horizontal, Theme.sm)
                    .padding(.vertical, 3)
                    .background(Theme.paper, in: .capsule)
                    .overlay(Capsule().stroke(Theme.rule, lineWidth: Theme.hairline))
            }
        }
    }
}

private struct BeanCardView: View {
    let bean: BeanCard

    var body: some View {
        CardFrame(title: bean.name, caption: caption, source: bean.source) {
            TagRow(tags: bean.flavors)
            CardRow(label: "Processing", value: bean.processing)
            CardRow(label: "Acidity, body", value: "\(bean.acidity), \(bean.body)")
            // Named rather than left blank: the corpus carries no verified
            // roast for some lots, and an empty row reads as an oversight.
            CardRow(label: "Roast fit", value: bean.roast ?? "Not verified")
            CardRow(label: "Moka pot", value: bean.mokaPot)
            CardRow(
                label: "Cupping score",
                value: bean.cuppingScore.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "Not scored"
            )
        }
    }

    private var caption: String {
        [bean.island, bean.subregion, bean.altitude]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

private struct OwnedCardView: View {
    let owned: OwnedCard

    var body: some View {
        CardFrame(
            title: owned.name,
            caption: caption,
            flag: owned.isUnverified ? "unconfirmed" : nil,
            source: owned.corpusLink.map { "linked to \($0)" } ?? "no corpus link"
        ) {
            if let grade = owned.grade {
                CardRow(label: "Grade", value: grade)
            }
            CardRow(label: "Grind", value: owned.grind)
            if let grams = owned.remainingGrams {
                CardRow(label: "Remaining", value: "\(grams)g")
            }
            CardRow(label: "Brews", value: owned.brewCount == 1 ? "1 logged" : "\(owned.brewCount) logged")
            if owned.brewsAwaitingReview > 0 {
                CardRow(
                    label: "Awaiting review",
                    value: owned.brewsAwaitingReview == 1 ? "1 brew" : "\(owned.brewsAwaitingReview) brews"
                )
            }
            if !owned.grindAdjustable {
                Text("Pre-ground, so the dial-in works on heat and timing rather than grind.")
                    .font(Theme.trace)
                    .foregroundStyle(Theme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var caption: String {
        var parts: [String] = []
        if let roaster = owned.roaster { parts.append(roaster) }
        if let origin = owned.origin { parts.append(origin) }
        if let days = owned.daysSinceRoast { parts.append("roasted \(days)d ago") }
        parts.append(owned.provenance.lowercased())
        return parts.joined(separator: " · ")
    }
}

/// Three rows, deliberately not reconciled into one. Where the published
/// profile, the roaster's copy and the drinker's own palate diverge is the
/// thing worth looking at.
private struct ComparisonCardView: View {
    let comparison: ComparisonCard

    var body: some View {
        CardFrame(
            title: comparison.beanName,
            caption: "Three sources, three answers",
            source: comparison.corpusName.map { "corpus lot: \($0)" } ?? "no corpus link"
        ) {
            row("Corpus says", comparison.corpusSays, empty: "No linked profile")
            row("Roaster says", comparison.roasterSays, empty: "Nothing printed")
            row("You tasted", comparison.youTasted, empty: "No notes yet")

            if let caveat = comparison.caveat {
                Text(caveat)
                    .font(Theme.trace)
                    .foregroundStyle(Theme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, Theme.sm)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(Theme.accent).frame(width: Theme.accentRule)
                    }
            }
        }
    }

    private func row(_ label: String, _ values: [String], empty: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(Theme.label).foregroundStyle(Theme.inkMuted)
            Text(values.isEmpty ? empty : values.joined(separator: ", "))
                .font(Theme.control)
                .foregroundStyle(values.isEmpty ? Theme.inkMuted : Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Theme.xs)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.rule).frame(height: Theme.hairline)
        }
    }
}

private struct SellerCardView: View {
    let seller: SellerCard
    @Environment(\.openURL) private var openURL

    var body: some View {
        CardFrame(title: seller.name, caption: seller.detail, source: seller.source) {
            if let url = seller.url.flatMap(URL.init(string:)) {
                Button("Open") { openURL(url) }
                    .font(Theme.control)
                    .foregroundStyle(Theme.accent)
            }
        }
    }
}

/// Covered until tapped. A flashcard whose answer is already on screen is a
/// sentence, and the whole value here is in trying to recall it first.
private struct FlashcardView: View {
    let card: FlashcardCard

    @State private var isRevealed = false

    var body: some View {
        Button {
            withAnimation(Theme.enter) { isRevealed.toggle() }
        } label: {
            VStack(alignment: .leading, spacing: Theme.sm) {
                Text(isRevealed ? card.back : card.front)
                    .font(Theme.reading)
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(isRevealed ? "Tap to flip back" : "Tap to reveal")
                    .font(Theme.trace)
                    .foregroundStyle(Theme.inkMuted)
            }
            .padding(Theme.md)
            .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
            .background(Theme.paperRaised, in: .rect(cornerRadius: Theme.bubbleRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.bubbleRadius)
                    .stroke(Theme.rule, lineWidth: Theme.hairline)
            )
        }
        .buttonStyle(.plain)
        .accessibilityHint(isRevealed ? "Hides the answer" : "Reveals the answer")
    }
}
