# Learning Notes

## Failure as data, not an exception

`WebSearchTool.call` never throws for an ordinary failure — it returns a status. A thrown error tells the model only that something broke; it gives the model nothing to reason with. A three-state status (found, empty, unavailable) is something the model can act on: it can tell the person "search isn't working right now" instead of quietly concluding nothing exists. This matters more for a tool a language model drives than for ordinary application code, because the caller here can't read a stack trace — it can only read the fields you hand back.

## Decoding an unverified external contract

`ResponseBody` is `Codable` against field names inferred from documentation, not a real response. `Codable` will happily decode a JSON object that merely happens to have matching keys; if Tavily's real shape differs, `JSONDecoder().decode` throws, and that throw is caught and turned into `.searchUnavailable`. The request body goes the other way: `RequestBody.max_results` uses Tavily's snake_case names directly rather than a `keyDecodingStrategy`, because `Encodable`'s default is exact property-name matching — mismatch the name and Tavily silently ignores or rejects the field, it does not error locally.

## How a Tool actually gets called

The model, not your code, decides when to call `WebSearchTool` and synthesizes an `Arguments` value matching your `@Generable` struct. `@Guide(description:)` is a hint to the model about what a good query looks like; `.range(1...5)` is a hint about a good count. Neither is enforced the way a compiler or a runtime assertion would enforce it — a `@Generable` struct's job is to shape what the model is likely to produce, not to guarantee it. If `maxResults` genuinely must stay in range, clamp it in `call(arguments:)` rather than trusting the guide.

## Terms

**Trust boundary** — a point where data crosses from one party's control to another's. The model's query text crossing into an HTTP request to Tavily is one; treat the query as untrusted the way you'd treat any user input reaching a network call.

**`@Generable`** — a macro marking a type the model can both read (as a description of expected arguments) and produce (as its actual output), turning free text generation into a typed value.

**`@Guide`** — attaches a natural-language hint and optional constraint to a `@Generable` property, shown to the model as part of the tool's schema.

**Tool calling** — the model, mid-response, choosing to invoke a declared tool with arguments it generates itself, then incorporating the tool's result into its next output.

**snake_case vs camelCase key mapping** — many web APIs use snake_case (`max_results`); Swift convention is camelCase (`maxResults`). `RequestBody` and `ResponseBody` here just spell the wire names directly rather than using a decoding strategy, because only one or two keys differ.

**Bearer token** — a credential sent as `Authorization: Bearer <token>`; anyone holding the string can use it, which is why it can't live in committed source.

## Pitfalls

Treating a decode failure as "no results" rather than "search failed" — the model would then state absence as fact when the truth is that the response couldn't be parsed. This design maps both failure to the same `.searchUnavailable`, deliberately.

Hardcoding or committing the API key. A key in a Swift source file ships inside the compiled app binary and in every git clone, forever, even after a later commit deletes it.

Assuming a 200 status means a well-formed body. Tavily can return 200 with a body shape you didn't expect; only a successful decode confirms the contract held.

Treating `@Guide`'s `.range` as enforcement. It biases what the model generates; it does not reject an out-of-range value the way a validator would.

## Further reading

- [Tavily Search API](https://docs.tavily.com/documentation/api-reference/endpoint/search)
- [Tool (Foundation Models)](https://developer.apple.com/documentation/foundationmodels/tool)
- [Generable](https://developer.apple.com/documentation/foundationmodels/generable)
- [URLSession](https://developer.apple.com/documentation/foundation/urlsession)
- [Codable](https://developer.apple.com/documentation/swift/codable)
