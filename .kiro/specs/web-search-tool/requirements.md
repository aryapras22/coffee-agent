# Requirements Document

## Introduction

The Agentic coffee agent can only answer from its local bean corpus, so anything current — a roaster's news, a variety it has never heard of, prices in the wider market — is outside its reach. This feature adds a FoundationModels tool, WebSearchTool, that queries the Tavily search API over HTTP and hands the model back web results. The tool follows the contract already set by BeanSearchTool: generable arguments with guided descriptions and a validated range, a status that separates "ran and found nothing" from "did not run", and an outcome pairing that status with the hits.

## Glossary

- **WebSearchTool**: The FoundationModels tool that searches the web on the model's behalf and returns results to it.
- **Tavily_API**: The external search service the tool calls over HTTPS.
- **Web_Hit**: One returned search result, carrying its title, its source URL, and a snippet of its content.
- **Search_Status**: The value on the tool's outcome stating whether the search found results, found nothing, or could not run.
- **CoffeeAgent**: The existing agent that owns the tool list and the model instructions.

## Requirements

**User Story:** As someone using the coffee agent, I want it to look things up on the web when the answer is not in its bean collection, so that I get a current answer instead of being told the agent does not know.

### Acceptance Criteria

1. WHEN the model invokes WebSearchTool with a search query, THE WebSearchTool SHALL return the web results the Tavily_API reports for that query.
2. THE WebSearchTool SHALL describe its arguments to the model and constrain the requested number of results to a valid range.
3. WHEN a search returns at least one result, THE WebSearchTool SHALL return a Search_Status of results found together with the Web_Hit values.
4. WHEN a search completes and the Tavily_API reports no matching results, THE WebSearchTool SHALL return a Search_Status stating that the search ran and found nothing.
5. IF the Tavily_API cannot be reached, rejects the request, or returns a response body that THE WebSearchTool cannot interpret, THEN THE WebSearchTool SHALL return a Search_Status stating that the search did not run, together with an empty result set.
6. IF no Tavily_API credential is configured, THEN THE WebSearchTool SHALL return a Search_Status stating that the search did not run.
7. THE WebSearchTool SHALL obtain its Tavily_API credential from a source held outside source control.
8. WHEN a tool result carries a Search_Status stating the search did not run, THE CoffeeAgent SHALL tell the user that web search is unavailable rather than that no such information exists.

## Deferred

- Retrying transient network failures with backoff.
- Exposing Tavily's `search_depth` as a tool argument.
- Filtering by `include_domains` or `time_range`.
- Caching repeated queries.
