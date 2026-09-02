# Reading an Indonesian coffee bag

## What this introduces

A pipeline that turns a photograph of a bag into typed fields, across a language the on-device model cannot read. Vision's `RecognizeTextRequest` recognises the label, a term substitution pass rewrites the Indonesian vocabulary as English, Foundation Models guided generation fills a `@Generable` struct, and a human confirms every field before anything is stored. `BagScanner` holds the stages; `ScanFlowView` runs them; `BagDraftSheet` is the only path that writes an `OwnedBean`.

## The constraint that shapes everything

The two frameworks do not support the same languages, and the gap is the whole problem.

Vision recognises Indonesian: `id-Latn-ID` is in `supportedRecognitionLanguages` at the `.accurate` level, among thirty. Foundation Models supports twenty-three locales and Indonesian is not one of them. So OCR reads the bag perfectly and then hands text to a model that refuses it with `GenerationError.unsupportedLanguageOrLocale`, before generating anything.

Worse, the refusal is probabilistic over the whole prompt, not a lookup. Measured on one panel: the label lines alone pass, the place names alone pass, the two together fail. Terse lines carry weak language signal, and a few Indonesian proper nouns tip the aggregate.

## Why this and not the alternatives

Typing a bag in by hand is six fields of transcription from packaging that already states all six. That is the baseline to beat.

The first design rejected a regex pre-pass, reasoning that it would not remove the confirm screen and would add a second extraction path that could disagree with the first. That reasoning assumed the model could read the text. It cannot, so the pre-pass is not an optional second path; it is what lets the first one run at all.

Three layers, each earning its place against the measured failure:

An English **carrier** wraps the label text in two sentences of ordinary prose. This alone is enough to make the classifier accept the panel, and it is the difference between a throw and a result.

**Term normalisation** rewrites the closed label vocabulary into English, so the model reads words it was trained on rather than ones it must guess at, and so the aggregate leans further from Indonesian. It covers field labels and their values only.

**Deterministic fallback** reads process, roast, date and weight off that same vocabulary. The classifier is probabilistic, so a bag with more Indonesian than the test panel may still be refused; the fallback lands the user on a prefilled form rather than a dead end. `draft(fromOCR:)` never throws.

The cost is that the model can still invent a field the bag never printed. That is what the optional field types and the confirm screen are for.

## How the logic works

`readText(from:)` sets `.accurate`, turns `automaticallyDetectsLanguage` off, sets `recognitionLanguages` to Indonesian then English, and supplies the growing regions as `customWords`. Each observation's top candidate is joined into one block in reading order. Empty text throws, because an empty prompt would make the model invent a whole bag.

`normalize(_:)` applies an ordered table of substitutions, longest phrase first so "berat bersih" is not half-consumed by "berat". Only field labels and values are in it. Place names are absent because they are proper nouns, and so are `kopi`, `biji` and `bubuk`: a bag named KOPI ARABIKA GAYO is not named "coffee ARABIKA GAYO", and translating those corrupted the one field a user is least able to correct from memory.

`extract(from:)` prepends the carrier, opens a session whose instructions contain no Indonesian at all, and calls `respond(to:generating:)`. Guided generation constrains decoding to the schema, so the reply is a typed value rather than JSON to parse.

`Draft(_:)` parses the date through `parseDate` and sets `scanConfidence` to `.scanUnverified`. `BagDraftSheet.save()` promotes it to `.scanConfirmed`. Nothing else writes either value, so the confidence is exactly a record of whether a human looked.

## Terminology

**Guided generation**: constraining decoding to a schema so the output is a typed value by construction. Driven by the `@Generable` macro and `@Guide` descriptions.

**Recognition level**: `.accurate` recognises thirty languages including Indonesian; `.fast` recognises six, all Western European. Changing the level would silently drop half of a bilingual bag, so a test asserts the gap rather than a comment describing it.

**Custom words**: a supplementary lexicon for language correction, which rewrites what it does not recognise. Bener Meriah is exactly what it would rewrite.

## Pitfalls

Running more than two `RecognizeTextRequest` operations concurrently can deadlock Vision. Scan one image at a time.

`automaticallyDetectsLanguage` is wrong for a bilingual label: it picks one language for the image, and a bag prints its origin in Indonesian and its marketing copy in English, so whichever it picks loses the other half. `recognitionLanguages` takes an ordered list, so asking for both is the bilingual case rather than a choice.

No setting makes OCR reliable on the physical object. Bags are matte, curved, and often dark on dark. Misreads are the normal case, which is why the confirm screen is a step in the pipeline rather than a nicety.

A date returned as `yyyy-MM-dd` is the happy path, but the model sometimes copies the printed form through. `parseDate` tries several formats under `en_US_POSIX` and `id_ID` and returns nil rather than today. A silently wrong roast date poisons every freshness answer afterwards.

Confidence tracking only works if it is honest. Promoting `.scanUnverified` anywhere but the confirm action makes the flag meaningless, and the agent's instructions depend on it to know when to hedge.

## Further reading

- Vision: `RecognizeTextRequest`, https://developer.apple.com/documentation/vision/recognizetextrequest
- Foundation Models: `LanguageModelSession.GenerationError`, https://developer.apple.com/documentation/foundationmodels/languagemodelsession/generationerror
- Foundation Models: guided generation, https://developer.apple.com/documentation/foundationmodels/generating-swift-data-structures-with-guided-generation
