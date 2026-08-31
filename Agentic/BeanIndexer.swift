//
//  BeanIndexer.swift
//  Agentic
//
//  Created by Arya on 27/08/26.
//

import CoreSpotlight
import UniformTypeIdentifiers

struct CoffeeBean: Codable {
    let coffee_id: String
    let name: String
    let origin_countries: [String]
    // Nullable in the corpus: roughly half the records carry no price, and a
    // sixth carry no acidity. Defaulting them would make the agent quote a
    // price of zero for beans whose price is simply unknown.
    let roast_level: String?
    let process: [String]
    let price_per_100g_usd: Double?
    let price_band: String?
    let acidity_level: String?
    let body_level: String?
    let flavor_tags: [String]
    let card_text: String
}


struct BeanIndexer {
    let index = CSSearchableIndex.default()

    static func makeSearchableItem(from bean: CoffeeBean) -> CSSearchableItem {
        let attrs = CSSearchableItemAttributeSet(contentType: .text)

        attrs.title = bean.name
        attrs.keywords =
            bean.flavor_tags + bean.origin_countries + bean.process
            + [bean.roast_level, bean.acidity_level, bean.body_level].compactMap { $0 }
            + (bean.price_band.map { ["price: \($0)"] } ?? [])
        attrs.textContent = bean.card_text


        return CSSearchableItem(
            uniqueIdentifier: bean.coffee_id,
            domainIdentifier: "coffee-bean",
            attributeSet: attrs
        )
    }

    func donate(_ beans: [CoffeeBean]) async throws {
        let items = beans.map { bean -> CSSearchableItem in
            let item = Self.makeSearchableItem(from: bean)
            item.expirationDate = .distantFuture
            return item
        }
        try await index.indexSearchableItems(items)

    }

    func remove(ids: [String]) async throws {
        try await index.deleteSearchableItems(withIdentifiers: ids)
    }
}

actor BeanStore {
    private var byID: [String: CoffeeBean]

    init(beans: [CoffeeBean]) {
        byID = Dictionary(
            uniqueKeysWithValues: beans.map { ($0.coffee_id, $0) }
        )
    }

    func beans(for ids: [String]) -> [CoffeeBean] {
        return ids.compactMap { byID[$0] }
    }

    func allBeans() -> [CoffeeBean] {
        return Array(byID.values)
    }
}

final class BeanIndexDelegate: NSObject, CSSearchableIndexDelegate {
    let store: BeanStore
    init(store: BeanStore) { self.store = store }

    func searchableItems(forIdentifiers ids: [String]) async
        -> [CSSearchableItem]
    {
        let matched = await store.beans(for: ids)

        return matched.map { bean in

            let item = BeanIndexer.makeSearchableItem(from: bean)
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
            try? await BeanIndexer().donate(await store.beans(for: identifiers))
            ack()
        }
    }

    func searchableIndex(_ index: CSSearchableIndex, reindexAllSearchableItemsWithAcknowledgementHandler ack: @escaping () -> Void) {
        Task {
            try? await BeanIndexer().donate(await store.allBeans())
            ack()
        }
    }
}


final class SearchInfrastructure {
    let delegate: BeanIndexDelegate
    
    init(store: BeanStore) {
        delegate = BeanIndexDelegate(store: store)
        CSSearchableIndex.default().indexDelegate = delegate
    }
}
