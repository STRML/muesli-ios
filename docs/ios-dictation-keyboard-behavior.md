# iOS dictation and the iOS keyboard: a brief for Muesli's keyboard extension

Date of research: 2026-10-18. Scope: how iOS system dictation and the system keyboard behave, what a third-party `UIInputViewController` keyboard can reproduce, and where Muesli differs today.

## How to read this brief

Every non-obvious claim has a source tag. Tags:

- `[H]` = read from the local UIKit header in Xcode (iPhoneOS SDK, `UIKit.framework/Headers/`). Most reliable.
- `[A1]`..`[A9]`, `[F1]`..`[F6]`, `[G1]`.. = web sources, listed in "Sources" at the end.
- `[code]` = read from this repo (worktree `system-dictation-guard`).
- UNVERIFIED = I could not confirm it from a primary source. Treat as a hypothesis to test on a device.

Honest limit: Apple publishes almost nothing about how the system keyboard and system dictation work internally. The Apple Support dictation pages did not render through my fetch tool (only the nav shell came back), so what I know of end-user dictation behavior comes from search-result summaries of those pages and from press coverage. Anything about "when does dictation rewrite earlier words" is therefore mostly UNVERIFIED and must be measured on a device before we design to it.

## 0. Correction to the premise: `setMarkedText` IS public on the proxy

The task brief said `UITextDocumentProxy` has no `setMarkedText`. It does, since iOS 13. From `UIInputViewController.h` `[H]`:

```
@protocol UITextDocumentProxy <UIKeyInput>
@property documentContextBeforeInput / documentContextAfterInput / selectedText (11.0)
@property documentInputMode (10.0)
@property documentIdentifier (11.0)
- (void)adjustTextPositionByCharacterOffset:(NSInteger)offset;
// Setting marked text either replaces the existing marked text or, if none is present, inserts it in place of the current input location.
- (void)setMarkedText:(NSString *)markedText selectedRange:(NSRange)selectedRange API_AVAILABLE(ios(13.0));
- (void)unmarkText API_AVAILABLE(ios(13.0));
```

Apple documents it with examples (combining accent, autocomplete tail) in "Handling text interactions in custom keyboards" `[A1]`. Muesli already uses it (`ProxyLiveTypingHost`) `[code]`. What the proxy does NOT have: `markedTextRange`, `replace(range:withText:)`, `selectedTextRange` setter, `beginningOfDocument`, or any range-based API. All edits are relative to the cursor. `UITextInput.h` `[H]` has those, but only the host sees them.

Other header facts used below `[H]`:

| API | Header fact |
|---|---|
| `hasDictationKey` | "When this property is set to YES, the system dictation key, if provided, will be disabled." (read/write, `UIInputViewController.h`) |
| `hasFullAccess`, `needsInputModeSwitchKey` | read-only, iOS 11 |
| `requestSupplementaryLexiconWithCompletion:` | "This will not provide a complete repository of a language's vocabulary. It is solely intended to supplement existing lexicons." |
| `UITextChecker` | `guessesForWordRange`, `completionsForPartialWordRange`, `rangeOfMisspelledWord`, `ignoreWord`, class `learnWord` / `unlearnWord` / `hasLearnedWord`, class `availableLanguages` (`UITextChecker.h`) |
| `UITextInputTraits` | `autocorrectionType`, `spellCheckingType` (5.0), `smartQuotesType`, `smartDashesType`, `smartInsertDeleteType` (11.0), `inlinePredictionType` (17.0), `keyboardAppearance`, `enablesReturnKeyAutomatically`, `textContentType` (`UITextInputTraits.h`) |
| Host-side dictation hooks | `insertDictationResult:` ("optional ... If they do not implement this method, dictation will just insert the most likely interpretation of what was spoken via -insertText:"), `dictationRecordingDidEnd`, `dictationRecognitionFailed`, `insertDictationResultPlaceholder`, `removeDictationResultPlaceholder:willInsertResult:` (`UITextInput.h`). These are implemented by the host text view, not callable from an extension. |
| Input clicks | `-[UIDevice playInputClick]`: "Plays a click only if an enabling input view is on-screen and user has enabled input clicks." `enableInputClicksWhenVisible` (`UIDevice.h`) |
| `UITextInputDelegate` | `selectionWillChange/DidChange`, `textWillChange/DidChange` with a `UITextInput?` argument. In an extension the argument is nil `[A1]`. |

## 1. System dictation in the host field

### 1.1 What is documented

- Dictation runs where the user can type; the keyboard stays on screen, and since iOS 16 you can type, tap, move the cursor and use QuickType suggestions without stopping dictation `[A4][A5]`.
- Dictation can replace selected text `[A2]`. Spoken punctuation and formatting commands exist; automatic punctuation is on in supported languages `[A5][A2]`.
- Dictation commands include select, delete, undo, redo, in supported locales `[A3]`.
- The host-side contract is `UITextInput`: a host may implement `insertDictationResult:` (phrases with alternatives) or fall back to plain `insertText:` `[H]`. This is also why a blue underline (alternatives) appears only in hosts that implement it. UNVERIFIED that the underline is exactly this mechanism.

### 1.2 Marked text vs committed text (UNVERIFIED internals)

No Apple source states whether the system shows interim dictation hypotheses as marked text. What is observable and sourced:

- While system dictation runs under a third-party keyboard, the extension gets `textWillChange` / `textDidChange` with a nil argument, and on accept a final `textDidChange` delivers the text `[F2]`. That means from the extension's side, dictation is "text changed under me" and the keyboard has no hook for the interim state.
- iOS 16 changed it so that starting dictation no longer fires the old input-mode-change notification (`primaryLanguage == "dictation"`) `[F1]`. Muesli's `SystemDictation.isEnabled` only reads `activeInputModes`; `KeyboardViewController` calls `systemDictationDidStart()` from line 221 `[code]`. I did not check which event triggers that call, so confirm on iOS 16+ that it still fires, since the old input-mode notification does not.

So the design target "words live in the field, replaced in place as the recognizer revises" is what system dictation looks like to a user, and `setMarkedText` is the only public lever that gives the same replace-in-place semantics from an extension. Whether the system itself uses marked text is irrelevant to us.

### 1.3 When does iOS rewrite earlier words

UNVERIFIED in detail. What the sources support:

- Interim words can change as more audio arrives; users report that dictated words are sometimes changed after they stop speaking `[F3]` (2017 Apple Community thread, old).
- Punctuation is inserted automatically as you speak since iOS 16 `[A5]`. Capitalization follows the field's `autocapitalizationType`. A reported bug: with a custom keyboard active, accepting a dictation lowercases the first word in an empty sentence-capitalized field; the system keyboard does not do this, Gboard no longer does. The poster suspects dictation asks the active keyboard for capitalization context `[F2]`. Implication for Muesli: our keyboard may be asked and must keep `autocapitalizationType` / context answers consistent. UNVERIFIED.
- Number and format normalization ("twenty five" to "25", dates, emails) happens in the recognizer. No documentation of when. UNVERIFIED.

Recommendation: do not try to match the exact revision schedule. Match the shape: stable prefix, volatile tail, final pass may revise everything.

### 1.4 Pauses, blur, tapping, typing, undo

| Situation | iOS system dictation | Source |
|---|---|---|
| Long pause | Older versions stopped after a few seconds of silence; whether iOS 17+ continues indefinitely is unclear. UNVERIFIED | [F4] (weak) |
| Field blur / keyboard dismissed | Dictation ends. UNVERIFIED (no source) | n/a |
| Tap in field or move cursor mid-dictation | Allowed since iOS 16; dictation continues and, per the press coverage, new words go at the new insertion point | [A4][A5] |
| Typing during dictation | Allowed since iOS 16 ("hybrid dictation") | [A4][A5] |
| Dictate over a selection | Replaces it | [A2] |
| Undo | Spoken "undo" / "redo" exist `[A3]`. Three-finger swipe left or three-finger double tap undoes the last text action in any app; shake to undo can be turned off `[A6]`. Whether one gesture removes a whole dictation or one phrase is UNVERIFIED. | [A3][A6] |

Undo for a keyboard extension: the host's `NSUndoManager` records what the host sees. Text we insert via `insertText` is an ordinary typing action to the host and is undoable by the host's gesture. Text composed through `setMarkedText` then `unmarkText` is how IMEs commit; whether the host coalesces it into one undo step is host-specific. UNVERIFIED. Muesli's own Undo button (`RewriteUndo`) is separate and fine.

## 2. Backspace

| Behavior | iOS system keyboard | Evidence |
|---|---|---|
| Single tap | Deletes one grapheme cluster before the cursor or the selection | `deleteBackward` is documented only as "delete the character preceding the current insertion point" `[A1]`. Cluster behavior UNVERIFIED but standard `UIKeyInput` behavior on UITextView. |
| Hold | Repeats; after a few seconds switches from characters to words | Forum reports say about 4 seconds `[F5]` (non-Apple, one source). Exact timings UNVERIFIED. |
| Right after an autocorrect | Restores the original word (or shows it in the suggestion strip) | Third-party guides `[F6]`; no Apple doc. Muesli already does this (`TypingEngine.tapBackspace`, `restore`) `[code]`. |
| After dictation | UNVERIFIED. Expectation: plain delete of one character; the dictated text is ordinary text | n/a |
| While dictating | Dictation keeps going; backspace edits the field (hybrid dictation) | [A4][A5] inferred. Whether iOS deletes the last word or one character is UNVERIFIED. |
| With selection | Deletes selection | standard UIKeyInput |
| Emoji / ZWJ / flags | One `deleteBackward` call per cluster on the host side; the extension cannot count code units reliably | UNVERIFIED, host-specific |

What the extension can do: only `deleteBackward()` calls, one per call; the host decides what one call removes. No word-granular delete exists in the proxy. Word delete must be synthesized: read `documentContextBeforeInput`, find the word boundary, call `deleteBackward()` N times (KeyboardKit and others do exactly this; I could not fetch its docs, so UNVERIFIED for the exact implementation). Risk: N is in grapheme counts but hosts may delete by code unit for some clusters.

Context limits of `documentContextBeforeInput`:

- Apple says nothing about a limit `[A7]`. Open-source dictation keyboards report that iOS gives "a bounded window of context" and long insertions never appear in full; one project accepts a tail-only match of at least 24 characters for undo `[G2]`. A second keyboard's issue measured that the host serves one cached window that shrinks as deletions consume it and does not refill, even after caret nudges `[G1]`.
- The proxy can lie: after a selection delete, one keyboard measured `documentContextBeforeInput` showing a phantom character the screen did not have, and its own `deleteBackward()` did not reach the mirror `[G1]`. Their fix was to refuse autocorrect while the mirror is suspect.
- After paste, `documentContextBeforeInput` can be nil in Gmail and Mail until the text is edited `[F7]`.

## 3. Text injection

### 3.1 `insertText` vs marked text

| API | What it does | Who sees it | Caveat |
|---|---|---|---|
| `insertText(_:)` | Inserts plain text at the cursor, replaces a selection. `"\n"` acts like Return (host may treat it as submit), `"\t"` acts like Tab. | Host, as typing | Not revisable |
| `setMarkedText(_:selectedRange:)` | Replaces the current marked range, or inserts marked text at the cursor. `selectedRange` is relative to the marked text. | Host, as IME composition | Host must implement UITextInput composition correctly |
| `unmarkText()` | Commits marked text as plain text | Host | |
| `adjustTextPosition(byCharacterOffset:)` | Moves the cursor (documented use: forward delete) `[A1]` | Host | Distance semantics differ by host `[G2]` |

Apple's own example uses marked text for IME composition and for autocomplete tails `[A1]`. So using it for "revisable partial dictation" is in-contract.

### 3.2 Host quirks (the important section for the Claude app bug)

- A UITextInput host that re-assigns its text while a marked range exists destroys the composition. A user report on the Claude iOS app says the first character typed after focusing the input is lost with Japanese input, and the reporter suspects a draft restore or state sync writing to the text view while `markedTextRange` is non-nil, discarding the composition `[F8]` (I could only read this through a search summary; the page itself did not load. UNVERIFIED as to cause.)
- React Native `TextInput` is a controlled component; native text is forced to match the value prop and "in some cases this may cause flickering" `[F9]`. A secondary article says overwriting `attributedText` during a marked range kills the composition and that RN's reconciliation has known hazards around it `[F10]` (UNVERIFIED code excerpts).
- Marked text can vanish when touched or when the cursor moves into it, reproduced on an iOS 27 beta, acknowledged as expected-to-work by an Apple framework engineer who asked for a Feedback report `[F11]`.
- Hosts that never expose text to the keyboard exist (the proxy shows nothing); Muesli's engine already forwards `deleteBackward` blindly for that reason `[code]`.
- `textWillChange` / `textDidChange` do not fire for all host edits. A KeyboardKit author saw no callbacks after `insertText` or external-keyboard typing and used a `adjustTextPosition(+1)` then `(-1)` toggle to force a refresh (with race and callout side effects) `[F12]`. 2016/2019 report on older iOS; current behavior UNVERIFIED.
- Secure text fields always show the system keyboard; `phonePad` and `namePhonePad` also show the system keyboard; apps can reject all third-party keyboards with `shouldAllowExtensionPointIdentifier` `[A8]`.
- Web views and custom text engines (contenteditable, Canvas editors) implement composition in JS; marked-text behavior is the least predictable there. UNVERIFIED (no source found).

### 3.3 Hacks that exist

- Cursor-nudge refresh (above) `[F12]`.
- Move-then-edit to emulate forward delete, or to capitalize a letter mid-word `[A1]`.
- Treat the proxy as lossy: verify by reading it back after the write (Muesli's probe already does this) and refuse destructive follow-ups when it disagrees `[G1]`.

## 4. Autocorrect and predictive text

What a custom keyboard must build itself (Apple lists these as user expectations, not APIs): autocorrection and suggestion, auto-capitalization, automatic period on double space, smart quotes, caps lock `[A8b]`.

Available building blocks:

- Traits from the host via `UITextInputTraits` on the controller `[H]`: `autocapitalizationType` (none/words/sentences/allCharacters), `autocorrectionType`, `spellCheckingType`, `smartQuotesType`, `smartDashesType`, `smartInsertDeleteType`, `inlinePredictionType`, `keyboardAppearance`, `returnKeyType`, `textContentType`.
- `UITextChecker` for spelling guesses and completions, plus class-level `learnWord` / `unlearnWord` `[H]`. This learns into the keyboard's own checker store, not into the system keyboard's dictionary. UNVERIFIED whether it is shared with the system learned words.
- `UILexicon` from `requestSupplementaryLexicon`: unpaired first and last names from Contacts, Text Replacement shortcuts, and a common-words dictionary `[A9]`. Available with or without Full Access in practice (Apple's open-access page lists "Access to a common words lexicon" and "Access to the text shortcuts list" in the no-Full-Access column) `[A10]`.

System behavior, for reference (all from non-Apple guides unless noted):

- Autocorrect fires on space, punctuation, and return. Backspace right after reverts and shows the original in the strip; tapping the quoted original keeps it; repeated rejection teaches the dictionary `[F6]`.
- Double space inserts ". " when the setting is on `[F13]`. Smart punctuation turns `--` into a dash `[F13]`. Three-slot QuickType bar: three suggestions is widely known but I found no source stating it. UNVERIFIED.
- iOS 17 added inline prediction (`inlinePredictionType` trait) `[H]`. A custom keyboard can honor the trait but cannot draw ghost text in the host; it could use `setMarkedText` with a partial selection (Apple's "Anth|ony" example `[A1]`) as a rough analogue.

## 5. Cursor and selection

- Proxy gives `selectedText` and relative cursor motion only `[H]`. There is no selection-range setter.
- Space-bar trackpad (long press on space, drag to move; second finger to select) is system UI; third-party keyboards implement their own `[F14]`. A keyboard can emulate cursor movement with `adjustTextPosition(byCharacterOffset:)` per drag step. It cannot create or extend a selection (no API); a workaround is none. Partial emulation only, and cursor-distance semantics vary by host `[G2]`.
- Double-tap-to-select-word and tap-to-place-cursor are host gestures that happen above the keyboard; the keyboard only learns of the result via `selectionDidChange` and the proxy snapshot.
- Dictation replacing a selection: system does `[A2]`. Muesli's live typing deliberately does not start when a selection exists (`stripOnly(.selection)`) because marking would replace the selection and cancel could not restore it `[code]`. That is a safe, defensible difference.

## 6. Full Access, haptics, sounds, globe, dictation key, appearance, height

| Topic | Fact | Source |
|---|---|---|
| Full Access | Without it: no network, no writes to shared container (read only), "No access to microphone and speaker"; with it: shared container, network, Location and Contacts with permission | [A10] |
| Haptics | I found no source that says haptics need Full Access. UNVERIFIED. (Muesli uses `MuesliHaptics`.) | n/a |
| Key click sound | Adopt `UIInputViewAudioFeedback`, return true from `enableInputClicksWhenVisible`, call `UIDevice.current.playInputClick()`; plays only if the user enabled keyboard clicks `[H][F15]`. Muesli does not call it `[code]`. | [H][F15] |
| Globe key | `needsInputModeSwitchKey` false on Face ID iPhones means the system draws the globe below the keyboard; use `handleInputModeList(from:with:)` on all touch events for long-press picker | [A8] |
| `hasDictationKey` | Set true to suppress the system dictation mic: "iOS won't show the system button, because having two buttons to perform dictation would be confusing" | [A8b] |
| Appearance | `keyboardAppearance` trait is available to read; a custom keyboard is not auto-themed | [H] |
| Height | System sets width; you set height with Auto Layout on the controller's view / `inputView` | [A8b] |
| Gray bands | iOS 26: extra native grey strip at left, right and top of custom keyboards in Messages, Notes, Safari, not in Instagram; unresolved `[F16]`. iOS 27: after switching apps, a blank 17 pt area appears above the keyboard because the host's input host view grows (397 to 414 pt) while the extension's bounds and safe-area are unchanged; depends on which keyboard you came from (Apple English adds it, Emoji does not); no supported reset `[F17]` | [F16][F17] |

## 7. Why live typing words vanish in the Claude app (analysis)

This is a reasoned diagnosis, not a measurement. It needs one device test (section 9).

What the code does `[code]`:

```
partial -> setMarked(text) -> probe: wait for proxy.before to end with text
        -> setMarked(same) -> probe: before must be unchanged (replace, not append)
        -> live: setMarked(tail) at most 6 times/s
        -> every write: recheck after 0.3 s; if !isAttached -> phase = .kept, unmark
final   -> .kept => outcome .withheld("detached")  (nothing inserted)
```

A React Native or otherwise state-controlled host passes the probe (the words do show up), then its JS round trip (tens to hundreds of ms) writes its own state back into the native view, which discards the marked range and, with it, the words. Next recheck: `isAttached` is false (the marked words are not in `before`), so `observeAttachment` sets `.kept(.textChanged)` and calls `unmark` on nothing. At the end `finishLive` hits `guard isAttached(snapshot)`, finishes with `.withheld("detached")`, and the user sees "Kept what was typed. Full text is in Muesli", but nothing was typed. The words "appear briefly then disappear" and the final text is never inserted. That is the worst possible failure: silent text loss from the field.

The cause for the disappearance is supported (not proven) by `[F8][F9][F10]`.

## 8. Gap analysis: Muesli vs iOS

Files read: `Shared/DictationPolicy/LiveTypingSession.swift`, `MuesliKeyboard/KeyboardLiveTyping.swift`, `LiveTypingText.swift`, `LiveTypingThrottle.swift`, `KeyboardController.swift` (live typing, delete, deliver), `KeyboardViewController.swift`, `KeyboardRootView.swift`, `KeyboardDictationParts.swift`, `KeyboardTypePage.swift`, `TypingEngine.swift`, `TypingTraitsMapping.swift`, `TypingAutocapitalizationPolicy.swift`, `KeyboardLivePreview.swift`.

Ranked by how often a user feels it:

| # | Gap | What Muesli does `[code]` | What iOS does | Frequency felt |
|---|---|---|---|---|
| 1 | Redundant preview strip while words are in the field | `KeyboardLivePreviewStrip` is always shown while recording when `livePreview` is non-nil; `KeyboardLivePreview.make` has no knowledge of live typing state. The doc comment says the strip is the "fallback view" but the code shows it always. | Words live in the field only | Every dictation |
| 2 | Backspace ends live typing and erases all dictated words | `KeyboardController.deleteBackward` calls `deleteFromHost(1)`, which calls `liveTyper.yield(.yielded)`: the session goes `stripOnly`, the marked words are cleared, the final text is inserted at the end. The user sees every dictated word vanish, then reappear at the end. | Backspace edits the field; dictation continues (hybrid dictation) `[A4]` | Whenever someone corrects a word mid-dictation |
| 3 | Silent text loss on hosts that rewrite the field (Claude app) | `.kept` then `.withheld("detached")` inserts nothing | n/a | Every dictation in affected apps (high for Claude/ChatGPT-style users) |
| 4 | Typing during dictation also yields (any key) | `insertTextKey` and others call `liveTyper.yield` | Typing and dictation coexist `[A4]` | Common |
| 5 | Dictated text is not fitted to the field: leading space, capitalization after context | No such logic in the keyboard code (grep for leading-space/capitalize found none; the app side may do it. UNVERIFIED) | Dictation capitalizes by traits and adds spacing | Common when dictating mid-sentence |
| 6 | No double-space period | `tapSpace` only inserts a space | Setting-driven ". " | Every typing session |
| 7 | No smart quotes or dashes; traits not read | `TypingTraits` does not read `smartQuotesType` / `smartDashesType` | Honors the traits | Frequent for typed apostrophes and quotes |
| 8 | Hold-to-delete has no word acceleration | `HoldToRepeat`: 360 ms delay then constant 65 ms | Accelerates, then deletes by word `[F5]` | Whenever clearing text |
| 9 | No key click sound | no `UIInputViewAudioFeedback` / `playInputClick` | Clicks if enabled | Users with clicks on |
| 10 | No space-bar trackpad | no `adjustTextPosition` use in the keyboard | Trackpad | Occasional |
| 11 | Gray band above keyboard | Surface overscan of 32 pt; height constraint at priority 999; `allowsSelfSizing = false` | System-owned | Visible on iOS 26/27 hosts; out of our control `[F16][F17]` |
| 12 | Long dictations commit sentences as plain text at 1,500 characters | `chunkThreshold` | A single flow | Rare (over about 90 s) |
| 13 | Code unit vs grapheme mismatch in rewrite deletes | `deleteBackward(count)` uses `String.count` | host-defined | Rare (emoji in dictation) |

Things Muesli already gets right: autocorrect plus backspace-revert and rejection learning, `UITextChecker`, `UILexicon` loaded, autocapitalization policy including closing quotes, secure-field guard, `hasDictationKey = true` so there is only one mic, ends Muesli dictation when system dictation starts, proxy lag tolerance (settle delay, previous-marked tolerance), selection guard, foldable comparison for host-modified text, `documentIdentifier` read without trapping, probing for host support.

### 8.1 The gray band

The 32 pt overscan is a reasonable mitigation. The two Apple Forums threads show that the extra region is created by the host's input host view (iOS 26 side margins in Apple apps; iOS 27 a 17 pt inset after switching apps), outside the extension's bounds, with no supported fix `[F16][F17]`. The best available lever is the one already in place: paint the root background taller than the envelope and keep the controller view transparent.

## 9. Recommendations (in order)

1. Hide the strip while the field is carrying the words. Show it only when `LiveTypingSession.phase` is `stripOnly` or `kept` (a derived property on the typer, exposed to `livePreview`). Keep the elapsed time and recording dot on the status pill.
2. Replace "backspace ends live typing" with "backspace edits the dictation": on backspace during a live session, remove the last word (or the last character if the tail is mid-word) from `mirroredText`, rewrite the marked range, and remember an anchor so later partials do not resurrect it. Partials are cumulative, so keep `rawAtEdit` (the partial at the time of the edit) and `edited` (what the user left); for each later partial `P`: if `P.hasPrefix(rawAtEdit)` write `edited + P.dropFirst(rawAtEdit.count)`; else write `edited + P.dropFirst(commonPrefix(P, rawAtEdit minus deleted word).count)`; on a revision that touches the edited region, commit `edited` as plain text and continue with only the tail. At final, if any user edit occurred, never replace the whole mirror with the model's final; use `edited` plus the final's tail.
3. Fix silent loss: if at final the words are not in the field and the cursor and text-after are unchanged (detached by the host rewriting the field), return `.insertPlain(final)` instead of `.withheld`. Also detect the host rewrite earlier: if `isAttached` fails once with `textChanged` and `before` equals `base.before` exactly (the marked words are simply gone), fall back to `stripOnly(.hostRewrote)` and remember the failing `documentIdentifier` for the session so the next dictation goes straight to the strip. Log reason `hostRewrote` (no text).
4. Do not yield on typing a letter; yield only on events that make marked text unsafe (cursor moved, selection, field changed). Typing a character while marked text exists can be handled by `unmark`, then inserting, then continuing from a new committed prefix. This is the hybrid dictation behavior.
5. Fit dictated text to context: leading space when `before` ends in a non-space, no leading capital when `before` ends mid-sentence, capital after `.?!` or at start (`TypingAutocapitalizationPolicy` already encodes the rule).
6. Add double-space period, smart quotes and dashes from the traits, and word-granular hold-to-delete (switch to word deletion after about 4 s, an UNVERIFIED target; measure the real device).
7. Optional: key clicks via `UIInputViewAudioFeedback`, and a space-bar trackpad using `adjustTextPosition`.

## 10. Least surprise table

Feasibility: yes / partial / no.

| Behavior | iOS does | Muesli should do | Feasible in extension | Workaround |
|---|---|---|---|---|
| Live words in field | Words appear and are revised in place | Same, via marked text | yes (host dependent) | Probe; fall back to strip per document id |
| No duplicate preview | Only the field | Hide strip while live in field | yes | Derive from session phase |
| Pause / blur | Pause may stop; blur ends. UNVERIFIED | End on blur (`yield(.hidden)` exists) | yes | Already handled |
| Backspace during dictation | Edits field; dictation continues | Delete last word/char from live text, keep going | yes | Anchored edit buffer (section 9.2) |
| Backspace after dictation | Plain delete | Plain delete (one grapheme) | yes | Already plain |
| Hold-to-delete | Chars then words | Same | partial | Timer; synthesize word delete from `documentContextBeforeInput` |
| Backspace after autocorrect | Reverts | Reverts | yes | Already done |
| Typing during dictation | Allowed | Allow; commit marked text first | yes | `unmarkText`, then insert |
| Tap/move cursor during dictation | Words go to new position | Stop live typing, keep words in place, final inserted at new cursor if text was withheld | partial | Detach path; make final insert plain at the cursor |
| Dictate over selection | Replaces | Replace | partial | Currently refused; `setMarkedText` would replace selection; Cancel cannot restore. Keep refusal, insert final over selection |
| Revising earlier words | Final pass may change anything | Final pass replaces marked range | yes | Already done |
| Number/punctuation normalization | Recognizer does it | Model/post-process | yes | `FinalTextPolicy` |
| Capitalization and spacing by context | By traits and context | Do the same | yes | Section 9.5 |
| Undo gesture | Host undoes | Host-driven; plus own Undo | partial | Commit via `unmarkText` or `insertText` so host records it. UNVERIFIED how host coalesces |
| Newline / tab | Return / Tab | `insertText("\n")` may submit | partial | Avoid in live text; commit after sentence only |
| Secure fields | System keyboard | n/a | no | Nothing to do |
| Host rewrites text (React Native, web views) | n/a | Fall back, never lose text | partial | Insert final plain; per-document strip fallback |
| Autocorrect and suggestions | Space/punct/return; 3-slot bar | Same | yes | `UITextChecker`, `UILexicon` |
| Double-space period | Setting | Same | yes | Not built |
| Smart quotes / dashes | `smartQuotesType` | Read the trait | yes | Not built |
| Space-bar trackpad | System | Emulate | partial | `adjustTextPosition`; no selection |
| Haptics / clicks | Yes | Haptics yes; clicks add | yes | `UIInputViewAudioFeedback` |
| Globe key | System draws on Face ID | Draw only if `needsInputModeSwitchKey` | yes | Already done |
| Dictation mic | System mic | One mic only | yes | `hasDictationKey = true` (done) |
| Appearance | Light/dark | Follow system | yes | Trait + `userInterfaceStyle` |
| Height and bands | System-owned | Fixed height, overscan | partial | Overscan paint; cannot control host region `[F16][F17]` |

## 11. Device tests needed (to turn UNVERIFIED into facts)

1. Claude iOS app: log `markedTextRange` effects by running the probe and watching `documentContextBeforeInput` every 50 ms for 2 s after the first `setMarkedText`; confirm the words vanish within one JS round trip.
2. Notes and Messages: confirm system backspace-during-dictation behavior (word or character).
3. Hold backspace for 10 s in Notes: time the switch to word deletion.
4. Dictate, then three-finger undo: one step or per phrase.
5. `documentContextBeforeInput` length in Notes with a 5,000-character document.
6. Delete an emoji family (ZWJ) with one `deleteBackward()` in Notes, Messages and a React Native field.

## Sources

Apple, primary:

- [A1] Handling text interactions in custom keyboards: https://developer.apple.com/documentation/uikit/handling-text-interactions-in-custom-keyboards.md
- [A2] Dictate text on iPhone (Apple Support, content via fetch of the 12.0 guide): https://support.apple.com/en-asia/guide/iphone/dictate-text-iph2c0651d2/12.0
- [A3] Commands for dictating text on iPhone (undo, redo, select, delete listed; seen via search summary only): https://support.apple.com/en-bw/guide/iphone/iph3bf19d7b9/ios
- [A4][A5] iOS 16 dictation coverage: https://www.cultofmac.com/779399/ios-16-will-make-iphone-dictation-far-less-cumbersome/ and https://www.phonearena.com/news/ios-16-new-features-release-date_id140589 and https://9to5mac.com/2022/06/10/ios-16-dictation-hands-on/ (press, based on a developer beta)
- [A6] Undo gestures: https://www.howtogeek.com/800327/how-to-undo-on-iphone and https://www.phonearena.com/news/how-to-undo-redo-gesture-on-iphone-ios_id132468
- [A7] documentContextBeforeInput: https://developer.apple.com/tutorials/data/documentation/uikit/uitextdocumentproxy/documentcontextbeforeinput.md
- [A8] Configuring a custom keyboard interface (secure fields, phonePad, host rejection, autocomplete sources, `hasDictationKey`, height): https://developer.apple.com/documentation/uikit/configuring-a-custom-keyboard-interface.md
- [A8b] Same page, "Handle common keyboard behaviors" and "Indicate dictation support" sections; also Creating a custom keyboard (globe, `needsInputModeSwitchKey`): https://developer.apple.com/documentation/uikit/creating-a-custom-keyboard.md
- [A9] UILexicon: https://developer.apple.com/documentation/uikit/uilexicon.md
- [A10] Configuring open access: https://developer.apple.com/documentation/uikit/configuring-open-access-for-a-custom-keyboard.md
- UITextDocumentProxy: https://developer.apple.com/documentation/uikit/uitextdocumentproxy.md
- [H] Local headers: `/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk/System/Library/Frameworks/UIKit.framework/Headers/` (`UIInputViewController.h`, `UITextInput.h`, `UITextInputTraits.h`, `UITextChecker.h`, `UILexicon.h`, `UIDevice.h`)

Apple Developer Forums:

- [F1] Dictation notification gone on iOS 16: https://developer.apple.com/forums/thread/711413
- [F2] Dictation case change with a custom keyboard: https://developer.apple.com/forums/thread/791725
- [F7] Context nil after paste in Gmail and Mail: https://developer.apple.com/forums/thread/812642
- [F11] Marked text disappears when touched (iOS 27 beta; Apple engineer replied): https://developer.apple.com/forums/thread/833053
- [F12] textDidChange not called, cursor-nudge workaround (KeyboardKit author): https://developer.apple.com/forums/thread/45121
- [F16] iOS 26 grey margin: https://developer.apple.com/forums/thread/800838
- [F17] iOS 27 17 pt blank area: https://developer.apple.com/forums/thread/843093

Other:

- [F3] Words change after dictating (2017): https://discussions.apple.com/thread/8087600
- [F4] Dictation stops after a pause (Intego, weak): https://www.intego.com/mac-security-blog/save-time-typing-with-dictation-and-predictive-text-in-macos-sonoma-ios-17-and-ipados-17/amp/
- [F5] Hold-delete switches to words after a few seconds (forum reports; one measured about 4 s): https://forum.xojo.com/t/bksp-auto-repeat/43472 and https://www.applevis.com/comment/129488
- [F6] Autocorrect undo via backspace: https://www.tapsmart.com/tips-and-tricks/autocorrect-in-ios17/?amp=1 and https://www.macworld.com/article/220598/how-to-make-ios-autocorrect-work-for-you.html
- [F8] Claude iOS app composition bug report (read via search summary; page did not load): https://claudeissues.com/issue/83283-bug-ios-app-code-tab-the-first-character-typed-after-focusing-the-input-field-is
- [F9] React Native TextInput controlled flicker: https://archive.reactnative.dev/docs/0.27/textinput
- [F10] RN typing drop article (secondary): https://hackernoon.com/your-users-type-faster-than-your-javascript-react-native-drops-the-difference
- [F13] Double-space period, smart dashes: https://www.digitaltrends.com/phones/iphone-keyboard-tips-and-tricks/
- [F14] Trackpad mode: https://www.macworld.com/article/558720/how-to-iphone-keyboard-trackpad.html
- [F15] Input clicks: https://developer.apple.com/documentation/uikit/uiinputviewaudiofeedback.md
- [G1] Dictus iOS keyboard, proxy desync measurements: https://github.com/getdictus/dictus-ios/issues/530
- [G2] VocaPhone keyboard, bounded context window, tail-only undo match: https://github.com/VocaHQ/vocaphone/pull/388
- Gutenberg dictation guard regression (host-side dictation pitfalls): https://github.com/WordPress/gutenberg/pull/49154

Not obtainable: KeyboardKit documentation (GitHub README only summarized features), Gboard/Fleksy iOS notes (Fleksy docs only appeared in search), Hacker News threads (no relevant result), WWDC session on third-party keyboards (none found for dictation/marked text).
