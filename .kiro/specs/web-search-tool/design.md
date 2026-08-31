# Design Document

## Architecture

`WebSearchTool` follows the same shape as `BeanSearchTool`: a `Tool` whose `call(arguments:)` never throws for an ordinary failure, returning a three-state status instead so the model can tell "ran, empty" from "did not run".

    CoffeeAgent.makeSession()
      → tools: [spotlightTool, webSearchTool]
        → WebSearchTool.call(arguments:)
          → key lookup (empty/missing → .searchUnavailable, no network call)
          → URLSession.shared.data(for:) POST https://api.tavily.com/search
            → transport throws → caught → .searchUnavailable
            → non-200 → .searchUnavailable
            → decode ResponseBody → decode throws → caught → .searchUnavailable
          → map results → empty → .noResultsFound, else .resultsFound
        → WebSearchOutcome(status, results)

## Domain Types

Generable types, request/response bodies, and `call(arguments:)` are exactly the handed-off code: `WebSearchStatus`, `WebSearchHit`, `WebSearchOutcome`, `WebSearchTool` with `Arguments { query, maxResults: .range(1...5) }`, private `RequestBody { query, max_results, search_depth = "basic" }`, private `ResponseBody { results: [Result { title, url, content }] }`. `content` maps to `WebSearchHit.snippet`.

## Confirmed vs Inferred

Confirmed against Tavily's own docs: endpoint `POST https://api.tavily.com/search`, header `Authorization: Bearer tvly-...`, minimum body `{"query": "..."}`, documented parameters `search_depth`, `topic`, `max_results`, `include_answer`, `include_domains`, `exclude_domains`, `time_range`.

Inferred, not confirmed: `results[].title/url/content`. No raw response was checked against `ResponseBody`. Before trusting the decode, run one real request with a valid key and print the raw JSON body. A decode failure must map to `.searchUnavailable`, never to a thrown error or a silently empty `.noResultsFound`.

## Credential

Recommended: a gitignored `.xcconfig` value surfaced into Info.plist and read via `Bundle.main.object(forInfoDictionaryKey:)`, over `Secrets.plist` or Keychain — cheapest to wire for a single string that isn't rotated at runtime, and it keeps the literal key out of source control the same way as any `.xcconfig`-based secret. `loadTavilyKey()` returns `String?`; an absent or empty value makes `WebSearchTool.call` return `.searchUnavailable` before any network call.

## Failure Strategy

Every failure mode — missing key, transport error, non-200, undecodable body — collapses to `.searchUnavailable` as returned data, not a thrown error, matching `BeanSearchTool`'s `indexUnavailable`. `URLSession.shared.data(for:)` throws on transport failure (no connectivity, DNS, TLS); `call(arguments:)` wraps that call in `do/catch` and returns `.searchUnavailable` from the catch rather than propagating.

`CoffeeAgent.instructions` gains a line: "A status of searchUnavailable means the web search failed to run, not that nothing was found. Say search is unavailable, do not say the information doesn't exist." — same shape as the existing `indexStale`/`indexUnavailable` line.

## Trust Boundary

The query text is model-authored, sent to a third-party HTTP API. `WebSearchTool` does not interpolate bean-corpus or chat history into the query beyond what the model puts in `arguments.query` — nothing else from local state crosses this boundary.

## Trade-offs

No retry or backoff, unlike `CheckStockTool`'s pattern; add one if Tavily proves flaky in practice, one line named in Deferred.

`search_depth: "basic"` is hardcoded; exposing it as an argument is deferred, and basic content may be thin for pricing or breaking-news queries.

## Testing Strategy

Unit tests stub `URLSession` (or inject a protocol wrapping `data(for:)`) to cover: 200 with results, 200 with empty results, non-200, malformed body, and missing key — asserting the returned `WebSearchStatus` in each case. One integration task (not a unit test) runs a real request to confirm `ResponseBody` field names before relying on them.
