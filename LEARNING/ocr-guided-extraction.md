# Reading a coffee bag: OCR into guided generation

## What this introduces

A two-stage extraction pipeline that turns a photograph into typed fields, with a mandatory human confirmation between the machine and the store. Stage one is Vision's `RecognizeTextRequest`, which returns flat lines of recognised text. Stage two is Foundation Models guided generation, which reads those lines and fills a `@Generable` struct. `BagScanner` holds both stages; `ScanFlowView` runs them and hands the result to `BagDraftSheet`, which is the only path that writes an `OwnedBean`.

## Why this and not the alternatives

Typing a bag in by hand is six fields of transcription from packaging that already states all six. That is the baseline to beat.

A pure regex pass over the OCR text is deterministic and free, and it works for the formatted fields: a weight is a number next to `g`, a date is a date. It fails on prose. "Proses: Giling Basah" and "Semi-washed, dried in parchment" name the same method, and no reasonable set of patterns covers how a roaster writes it. A regex pre-pass in front of the model was rejected: it would not remove the confirm screen, and it adds a second extraction path that can disagree with the first.

A vision-language model reading the photograph directly would skip the OCR stage entirely. Foundation Models on device is text-in, text-out, so that option needs a server round trip the rest of the app does not.

The cost is that the model can hallucinate a field the bag never printed. That is what the `@Guide` descriptions and the optional field types are for, and why the confirm screen is not polish.

## How the logic works

`BagScanner.readText(from:)` builds a `RecognizeTextRequest`, sets `recognitionLevel` to `.accurate`, turns `automaticallyDetectsLanguage` off, and sets `recognitionLanguages` to Indonesian then English, then awaits `perform(on:)`. Each `RecognizedTextObservation` carries ranked candidate strings; taking `topCandidates(1).first` and joining with newlines gives one block of text in roughly reading order. Empty text throws rather than returning an empty string, because an empty prompt would make the model invent a whole bag.

`BagScanner.extract(from:)` opens a fresh `LanguageModelSession` whose instructions state the domain (an Indonesian coffee bag), the vocabulary (giling basah is wet-hulled, proses means process), and one standing rule: leave a field empty rather than guess. It then calls `respond(to:generating: ScannedBagFields.self)`. Guided generation constrains decoding to the schema, so the reply is a value of that type rather than JSON to parse and validate.

Every field on `ScannedBagFields` is optional. A bag with no roast date is ordinary, and an optional is how the schema says "this may be absent" to the model as well as to the caller.

`BagScanner.Draft(_:)` maps the generated value onto the form's shape, parses the date through `parseDate`, and sets `scanConfidence` to `.scanUnverified`. `BagDraftSheet.save()` promotes that to `.scanConfirmed`. Nothing else writes either value, so the confidence is exactly a record of whether a human looked.

## Terminology

**Guided generation**: constraining decoding to a schema so the output is a typed value by construction, not a string that happens to parse. Foundation Models drives this from the `@Generable` macro and the `@Guide` descriptions.

**Recognition level**: Vision's tradeoff between a fast recogniser and a slower, more accurate one. `.accurate` is the right default for a still photograph; `.fast` exists for video frames. The two do not cover the same languages: `.fast` recognises six, all Western European, while `.accurate` recognises thirty including Indonesian. Changing the level here would quietly drop half of a bilingual bag, which is why a test asserts the difference rather than a comment describing it.

**Candidate**: Vision returns several possible readings per observation, ranked by confidence. Taking the top one is the usual choice.

**Custom words**: a supplementary lexicon for language correction. Correction rewrites strings it does not recognise, and Indonesian growing regions are exactly the proper nouns it would rewrite, so Bener Meriah and Tana Toraja are supplied explicitly.

## Pitfalls

Running more than two `RecognizeTextRequest` operations concurrently can deadlock Vision. Scan one image at a time. There is no reason to batch here, but a future "scan the whole shelf" feature would hit this.

`automaticallyDetectsLanguage` is the wrong tool for a bilingual label. Detection picks one language for the image, and an Indonesian bag prints its origin and process in Indonesian and its marketing copy in English, so whichever it picks loses the other half. `recognitionLanguages` takes an ordered list, so asking for both is the bilingual case rather than a choice between them.

No language setting makes OCR reliable on the physical object. Coffee bags are matte, curved, and often print dark on dark. Misreads are the normal case, not the failure case, which is why the confirm screen is a step in the pipeline rather than a nicety.

A date returned as `yyyy-MM-dd` is the happy path, but the model sometimes copies the printed form through unchanged. `parseDate` tries several formats under both `en_US_POSIX` and `id_ID`, and returns nil rather than defaulting to today. A silently wrong roast date poisons every freshness answer afterwards.

Confidence tracking only works if it is honest. Promoting `.scanUnverified` to `.scanConfirmed` anywhere but the confirm action makes the flag meaningless, and the agent's instructions depend on it to know when to hedge.

## Further reading

- Vision: `RecognizeTextRequest` and `RecognizedTextObservation`, https://developer.apple.com/documentation/vision/recognizetextrequest
- Vision: reading documents with structure, `RecognizeDocumentsRequest`, https://developer.apple.com/documentation/vision/recognizedocumentsrequest
- Foundation Models: generating Swift data structures with guided generation, https://developer.apple.com/documentation/foundationmodels/generating-swift-data-structures-with-guided-generation
