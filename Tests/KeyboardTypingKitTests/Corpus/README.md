# Autocorrect evaluation corpus

Test data for `TypingAutocorrector`. Nothing here ships in the app.

| File | What it is |
|---|---|
| `CommonWords.swift` | About 4,300 common English words, one per line. Generated; do not edit. |
| `TailWords.swift` | About 2,000 less used words (a sample, by hash, of those that only show up under a three-letter prefix). Generated; do not edit. |
| `TypoGenerator.swift` | Writes typos from those words with a fixed seed: neighbour-key substitution, dropped letter, doubled letter, transposition, missing apostrophe. |
| `AutocorrectCorpus.swift` | The hand-made typo list from PR 13 and the never-change set (names, brands, abbreviations, technical terms, hashtags, handles, URLs, emails, numbers with units, code, rare words, and valid words one edit from a commoner one). |
| `CorpusRunner.swift` | Types a token key by key through the real `TypingEngine` and `TypingAutocorrector`, then reads the field. Shared by the host tests (a fake dictionary) and the simulator tests (the real `UITextChecker`). |

## Where the word list comes from, and why

The list is the system's own completion ranking, read once on the iOS 27.0 simulator: for every one-letter
prefix, `UITextChecker.completions` returns the 20 most used words, and for every one-letter prefix that fills
all 20 slots the same is done for each two-letter prefix. The words are written in the order they first
appeared. The harvest is `MuesliTests/CommonWordsHarvestTests`, skipped unless
`TEST_RUNNER_MUESLI_COMMON_WORDS_OUT=<file>` is set.

I looked for a published frequency list first and could not establish a licence that allows redistribution
inside this repository:

- Peter Norvig's `count_1w.txt`: his MIT licence covers his code. The counts are derived from the Google Web
  Trillion Word Corpus, distributed by the Linguistic Data Consortium (https://norvig.com/ngrams/).
- `first20hours/google-10000-english`: derived from the same data. Its licence file says educational and
  personal use is permitted and recommends against commercial use without an LDC licence
  (https://github.com/first20hours/google-10000-english).
- `hermitdave/FrequencyWords`: content is CC-BY-SA 4.0, share-alike (https://github.com/hermitdave/FrequencyWords).
- SCOWL / the English Speller Database has a clear MIT-like licence (https://github.com/en-wl/wordlist,
  `Copyright`) but no frequency order inside a size, and its smallest size is 44,800 words, so it does not
  give "the common few thousand".

So the list is generated on the Mac from `UITextChecker`, as the fallback allowed. It is a list of facts
(English words), 33 KB, ordered only roughly: a word that first appears under a one-letter prefix is more used
than one that first appears under a two-letter prefix, but two prefixes cannot be compared with each other
(`xenophobic` is among the 20 most used words starting with `x`).

The tail list exists because the common list is, by construction, every word that is listed under a one- or
two-letter prefix, which is also the rule's own definition of a "used" word. A corpus made only of those would
teach the rule that an unlisted word is never the target. `TailWords` are the words listed only under a
three-letter prefix (`CommonWordsHarvestTests.testHarvestTailWords`, `MUESLI_TAIL_WORDS_OUT`), sampled one in
eleven by the same stable hash. Reports keep them apart: the headline numbers are for the common words, the tail
is a check on the usage prior.

## Fixed seed, tuning half and report half

Every typo is generated from `SplitMix64` seeded with a constant xor the FNV-1a hash of the word, so a word's
typos do not depend on the list around it and are the same on every run and machine (Swift's `hashValue` and
`Set` order are not). A word falls in the tuning half or the held-out half by the parity of its hash. Weights
and the margin rule are tuned on the tuning half; the numbers stated in the PR come from the held-out half.

## What is excluded

A generated typo that the dictionary accepts as a word ("from" typed as "form") cannot be fixed without
context, by this keyboard or any other. The simulator run drops those before it types anything and reports
how many it dropped for each class. The hand-made list and the never-change set are not filtered.
