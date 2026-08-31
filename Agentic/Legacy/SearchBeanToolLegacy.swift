//
//  SearchBeanTool.swift
//  Agentic
//
//  Created by Arya on 27/08/26.
//
import FoundationModels

struct SearchBeansTool: Tool {
    let name = "searchBeans"
    let description =
    "Searches the local bean catalog by flavor note, origin, or roast level"
    
    let catalog: BeanCatalog = BeanCatalog()
    
    @Generable
    struct Arguments {
        @Guide(description: "Flavor note, origin, or roast level to search for")
        var query: String
        
        @Guide(description: "How many beans to return", .range(1...5))
        var limit: Int
    }
    
    func call(arguments: Arguments) async throws -> SearchOutcome {
        let query = arguments.query
        let beans = await catalog.search(query)
        if beans.isEmpty {
            return SearchOutcome(status: .onMatchesInCatalog, beans: [])
        }
        return SearchOutcome(status: .matchesFound, beans: beans)
    }
}
