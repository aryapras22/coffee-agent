//
//  BeanIndexer.swift
//  Agentic
//
//  Created by Arya on 27/08/26.
//

import CoreSpotlight
import UniformTypeIdentifiers

struct BeanIndexer {
    let index = CSSearchableIndex.default()

    static func makeSearchableItem(from profile: BeanProfile) -> CSSearchableItem {
        let attrs = CSSearchableItemAttributeSet(contentType: .text)

        attrs.title = profile.name
        attrs.keywords =
            profile.flavorNotes.map(\.rawValue)
            + [profile.island.rawValue, profile.island.label, profile.subregion,
               profile.processingMethod.rawValue, profile.processingMethod.label,
               profile.acidity.rawValue + " acidity", profile.body.rawValue + " body",
               "moka " + profile.mokaPotSuitability.rawValue]
            + (profile.roastRecommendation.map { [$0.rawValue, $0.label] } ?? [])
        attrs.textContent = profile.searchableText

        return CSSearchableItem(
            uniqueIdentifier: profile.id,
            domainIdentifier: "bean-profile",
            attributeSet: attrs
        )
    }

    func donate(_ profiles: [BeanProfile]) async throws {
        let items = profiles.map { profile -> CSSearchableItem in
            let item = Self.makeSearchableItem(from: profile)
            item.expirationDate = .distantFuture
            return item
        }
        try await index.indexSearchableItems(items)
    }

    func remove(ids: [String]) async throws {
        try await index.deleteSearchableItems(withIdentifiers: ids)
    }
}

final class BeanIndexDelegate: NSObject, CSSearchableIndexDelegate {
    let store: BeanProfileStore
    init(store: BeanProfileStore) { self.store = store }

    func searchableItems(forIdentifiers ids: [String]) async -> [CSSearchableItem] {
        let matched = await store.profiles(for: ids)

        return matched.map { profile in
            let item = BeanIndexer.makeSearchableItem(from: profile)
            item.attributeSet.contentDescription = ""
            return item
        }
    }

    func searchableIndex(
        _ index: CSSearchableIndex,
        reindexSearchableItemsWithIdentifiers identifiers: [String],
        acknowledgementHandler ack: @escaping () -> Void
    ) {
        Task {
            try? await BeanIndexer().donate(await store.profiles(for: identifiers))
            ack()
        }
    }

    func searchableIndex(
        _ index: CSSearchableIndex,
        reindexAllSearchableItemsWithAcknowledgementHandler ack: @escaping () -> Void
    ) {
        Task {
            try? await BeanIndexer().donate(await store.allProfiles())
            ack()
        }
    }
}

final class SearchInfrastructure {
    let delegate: BeanIndexDelegate

    init(store: BeanProfileStore) {
        delegate = BeanIndexDelegate(store: store)
        CSSearchableIndex.default().indexDelegate = delegate
    }
}
