# Keyboard microphone sessions

Keyboard dictation starts an app-owned microphone session when persistence is
enabled (the default). The first activation opens Muesli; the user returns to the
host app manually. Subsequent dictations use the running microphone without
switching apps. Automatic app return is outside this change.

## Controls and preference

Home has a compact Keyboard mic toggle. On enables persistence and starts the
session; Off ends the current session without changing the saved preference.
Settings exposes the inverse preference, Turn mic off after each dictation.
Mic-off is also available from the handoff screen, Settings, Lock Screen, and
expanded Dynamic Island. Launching the app alone never activates the microphone.

The canonical preference remains `muesli.keyboardSession.enabled`. If an experimental
development build saved `muesli.keyboardSession.keepReadyBetweenDictations`, its
newer choice is migrated to the canonical key and the duplicate is removed.

## Lifecycle

The existing keyboard reducer owns microphone session identity and cancellation
generation. Dictations create individual audio segments within that session.
Finishing a segment preserves standby. Mic-off invalidates pending startup/retry
work, seals any active segment, releases the engine, and ends the session activity.
Captured speech can finish transcribing and be delivered after the mic stops.
A stale Island action cannot stop a newer microphone session or an unrelated meeting.

Idle audio callbacks refresh background-start readiness. The audio tap is created
in a nonisolated context so the audio thread does not inherit main-actor isolation.
Permission completion checks ownership before starting cancelled audio work.

## Shared handoff rules

Both processes apply `KeyboardHandoffState.accepts` inside a SQLite transaction.
Normal progress can skip ahead but cannot regress. Inserted/cancelled outcomes
cannot resume; copy-required can become inserted; pending cancellation only accepts
cancellation acknowledgements or cancel recovery. Failure during cancellation is
persisted as cancelled, so reconstruction cannot revive that request. Existing recovery paths
remain available. Keyboard taps, Action Button starts, and app adoption use the same
atomic `claimRequest` transaction to publish the pending request and its initial
handoff together. Preparing a keyboard launch URL remains local. Competing starts
cannot replace an unsettled owner during startup, recovery, or cancellation.
Result-ready releases capture ownership: the transcript remains in result storage
and history for insertion/copy, but cannot block the next dictation. Late errors
cannot turn a saved result back into active work. A completed, cancelled,
copy-required, or failed handoff also allows the next request; duplicate adoption
preserves progress, while delayed starts
for delivered/cancelled requests are rejected. Progress updates cannot transfer
ownership. Recovery uses an atomic claim of the existing owner and pins it as
transcribing before adopting local state. Retrying a failed start also reserves
ownership atomically. Pending-request cleanup matches the request being finished;
command acknowledgement matches the exact command, including action and timestamp.
New acquisition clears the previous command in its transaction, and stale command
writers cannot overwrite a new owner or undo pending cancellation.
Pending automatic delivery is stored separately from capture ownership in SQLite
(schema 6), referencing saved history rather than duplicating transcript text.
Publishing result-ready queues delivery atomically; a new capture cannot replace
that queue. A resumed keyboard inserts queued results in completion order while
continuing to display the current capture owner. Acknowledging an older result
cannot clear the newer request, command, or live transcript. Manual insertion also
acknowledges delivery. Cancellation, copy fallback, and deletion remove automatic
delivery; ordinary history and clipboard-only results are never replayed. Existing
result-ready handoffs are backfilled without replaying old history.

Insertion into another app and the SQLite acknowledgement cannot share a transaction.
A process termination between these operations can still leave delivery uncertain;
this change does not promise exactly-once insertion across that crash window.
 Copy fallback settles its UI, and stale readiness cannot select background
start indefinitely. Recovery URLs retain the original request and Stop/Cancel action across refresh
and recreation; preparing another launch URL cannot replace a recovery URL. A Stop
received after app relaunch resolves persisted audio through the existing recovery
pipeline before adopting the request. If no recoverable recording exists, it marks
the request failed and releases it instead of waiting for a nonexistent recorder.

## Delivery destination

Keyboard-originated dictation inserts into the currently focused field, including
when the user switches screens before delivery. This is intentional product behavior.
Action Button dictation always returns text for the shortcut's Copy to Clipboard
action. When the keyboard is visible with Full Access and a fresh heartbeat at
completion, it also queues automatic insertion. Hidden, absent, stale, or restricted
keyboards use clipboard-only delivery and do not insert when opened later. Insertion
acknowledgement leaves the shortcut result pickup intact. The Open to copy fallback
remains available when foreground clipboard access is needed. Explicit Insert latest
still allows the user to insert any saved transcript.

The visible keyboard displays Action Button recording levels from the same pipeline.
No new recording states are needed: resultReady authorizes insertion; copyRequired
or copied completion does not. A resultChanged notification alone cannot insert text.

## Recorder startup recovery

Checkpointed dictation retries the observed Core Audio `2003329396` engine-start
failure at most twice, after 250 ms and 500 ms. Each attempt creates a fresh recorder
under the same request. Permission, storage, Live Activity, unrelated audio errors,
and failures after microphone buffers arrive are not retried. Ownership loss,
Cancel/Stop, task cancellation, and mic-off invalidate startup before another attempt.
All recorder paths validate the same request and mic-session generation before
audio startup, after audio startup, and after asynchronous Live Activity creation.
Lost ownership runs the selected recorder cleanup before startup can publish success.
The wrapper requires this validation; the file recorder cannot bypass it.
After engine start, microphone buffers (including silence) must arrive within one
second before Listening is published. Input readiness failure ends startup without
restarting captured audio. Route/interruption events and startup route characteristics
are logged without transcript or audio content. This is bounded recovery, not a
claim that the underlying intermittent iOS failure has been eliminated.

## Waveforms and activities

Keyboard and Action Button activities reuse the status row, microphone tint, and
waveform renderer across Lock Screen and expanded Dynamic Island. They retain
separate ActivityAttributes because persistent standby and a single recording have
different lifetimes and controls. Action Button samples always update its recording
activity; keyboard-originated samples update the persistent mic activity.
A mic session has its own ActivityAttributes rather than a synthetic recording or
history row. It shows Listening, Mic ready, or Mic paused. Recording uses the same
five-bar amplitude envelope, sampler, renderer, and tint as Action Button activities.
Updates are coalesced to at most two per second with one meter update in flight.
Ready/paused states clear waveform data. Successful dictation briefly shows a
completion checkmark for five seconds, then clears it while retaining mic-off
controls. Initial standby never shows a completion checkmark. Starting another
recording or ending the mic session cancels the old completion timeout. Older
activities decode without samples or a completion deadline.

The keyboard's listening waveform uses native bars driven by metered input rather
than an animation timeline and Canvas. Meter publication is capped at 12.5 Hz
(approximately 10 Hz with the 20 Hz sampler), with 1% level precision and native
120 ms interpolation between updates. Reduce Motion disables interpolation. This
avoids depending on animation resumption
after screen timeout. Waiting animation and electric-spectrum rendering retain
their existing behavior.

## Validation and device checks

Regression tests cover session cancellation during permission startup, real-audio
standby readiness, duplicate insertion, late handoff updates, keyboard recreation,
terminal outcomes, recovery, preference migration, and waveform sampling/decoding.
Pico testing confirmed persistence across dictations, recovery to idle after text
insertion, waveform visibility after timeout, and the shared Island waveform.

Before release, repeat permission denial, microphone shutdown during recording and
processing, lock/unlock, audio-route changes, and switching to meeting capture.
Confirm mic-off releases microphone access while captured text can finish delivery.
Test with Live Activities disabled and with AirPods. Simulator tests do not establish
all hardware interruption or ActivityKit scheduling behavior.

Startup ownership remains valid when the same request receives Stop. The pending Stop is consumed after capture starts, preserving audio for transcription; cancellation still invalidates startup. Regression coverage injects Stop before audio, after audio, and during Live Activity publication.

### Background audio startup diagnostics

The existing capture path tags startup logs with a task-local capture request ID and, for Action Button, an intent invocation ID. These are diagnostic context, not lifecycle ownership. Notification handlers separately snapshot the coordinator's active request, startup flag, app state, and protected-data availability. Audio-session deactivation logs include the caller even when cleanup runs outside the startup task. Engine preparation and start have separate success markers without changing retry classification. The bounded diagnostic buffer retains 600 entries; transcript text and audio are never logged.

For the recurring background CoreAudio failure, compare Action Button → foreground Quick Note → Action Button on Pico. Correlate configure/activate/input-route events, recorder preparation/start markers, intent capture entry/exit, scene/interruptions, and deactivation callers. A successful simulator test does not validate background recording authorization. This instrumentation does not claim to fix the OS failure or introduce a fallback flow.

### Startup recovery cleanup

The temporary development delay and fault-injection controls have been removed.
Startup uses the normal recorder path; saved experimental preferences are no longer read.

Failed recorder startup discards only that attempt's audio files. The session
checkpoint manifest must survive retries so Stop can finalize the successful
attempt. Full recording cancellation still removes the checkpoint directory.

## Two-pass dictation

When the streaming model produces partials, the keyboard shows them in a one-line
preview in the status line under the controls: gray, truncated from the left so the
newest words stay visible, with the recording dot and elapsed time. With "Type live
into the field" on (the default) the same words are also typed into the host field as
marked text; see "Live typing" below. With it off, or in a host that cannot show marked
text, the preview is never written to the host field.

On release the full-clip pass always runs (`runKeyboardTranscriptionJob`: on-device
beside the remote endpoint inside its budget), and only its text is inserted, once:
it replaces the live words, or goes in at the cursor when nothing was typed live.
The preview dims with a shimmer meanwhile and clears when the result lands.
`FinalTextPolicy` falls back to the streaming text when that pass fails, times out
or comes back empty. When both are empty nothing is inserted. Cancellation never
falls back. A long voice note keeps its streaming text without a second pass, and
notepad bursts keep their own path.

Partials come from Parakeet Realtime EOU 120M (`LivePreviewEnginePolicy`):

- When it is the selected model, the one engine streams and runs the final pass.
- Otherwise a dedicated preview engine streams beside the selected model for keyboard
  dictations, fed from the persistent mic segment (`KeyboardSessionKeeper`) or the
  checkpointing recorder. Action Button, in-app dictation and notepad bursts do not load it.
- It runs only when the EOU model is downloaded. Settings offers
  "Download live preview model (224 MB)" under the model picker while it is missing,
  and waits while another model downloads (the download service runs one at a time).
- It loads on the first dictation that uses it, and the streaming session starts inside
  the buffer task, so loading never delays recording. A memory warning unloads it when
  idle, or after the dictation it is streaming (`LivePreviewResidency`). Selecting EOU as
  the model, or removing EOU, releases the dedicated copy.
- Its text is only ever the preview and the short-dictation fallback. A long voice note
  streamed by it still gets the selected model's pass, as before.

## Keyboard layout and the Dictate page during a dictation

Settings, Keyboard has a "Keyboard layout" row: **Full** (default) or **Minimal**. It is stored as
`muesli.keyboard.layout` and published in `KeyboardTypingSettings.layout` through the shared store,
like Autocorrect and live typing.

- **Full**: the Type page (QWERTY, suggestion strip, autocorrect, Record and Fix) and the Dictate page,
  which a 3 s hold on the Record key opens. The last page chosen is remembered.
- **Minimal**: the Dictate page only. No Type page, no hold, no suggestion strip, no ABC key, and the
  remembered page is neither read nor written, so switching back to Full finds it as it was.
- Both keep the 262 pt shared height. Setup verification forces the Dictate page in both layouts.
- The keyboard reads the layout once per appearance (`viewWillAppear`, before the launch snapshot), so a
  change in Settings shows the next time the keyboard opens. The `typingSettingsChanged` event still
  updates autocorrect and live typing at once, but never the layout.
- Without Full Access the shared store is unreachable, the read fails, and the keyboard is Full. The
  same holds for a missing, unknown or wrongly typed value; a bad layout value does not cost the user
  their autocorrect or live-typing choice.

While a dictation records or transcribes in Full, the keyboard shows the Dictate page (the view Minimal always
shows: big pill, stop key, punctuation, globe), and the Type page returns when the dictation ends (inserted,
failed, cancelled, copy required). `TypingSurface.resolve` decides it from the dictation phase.

- It is derived, never stored: the remembered page (`keyboard.selectedSurface`) is untouched, so the page the
  user chose is the page they get back.
- It starts on `recording`, not `requested`, so a start that fails never flashes the Dictate page. It stays
  through `transcribing`, which includes the live-typing final replacement (`resultReady` is mapped to
  transcribing).
- A user who holds the Dictate page by choice is not moved.
- ABC on the Dictate page (Full only) is honoured: the Type page stays for the rest of that dictation (letters
  are there again, and a typed letter yields the live words as in PR 18) and the next dictation switches again.
  This flag lives in memory and ends with the dictation; a keyboard recreated mid-dictation shows the Dictate page.

While the Dictate page is up for a dictation, letters and shift do not exist, so the live-typing rows that start
from a typed letter apply only after ABC. Its space, return, punctuation and delete keys still take the live words
out of the field and the dictation continues strip-only (`KeyboardDictationSurfaceTypingTests`).

## Live typing

With "Type live into the field" on (Settings, Keyboard; on by default; stored as
`muesli.keyboard.liveTyping` and read by the keyboard from `KeyboardTypingSettings.liveTyping`
in the shared store), the streaming words appear in the host field as the user speaks,
the way system dictation does, and the final text replaces them.

API: `UITextDocumentProxy.setMarkedText(_:selectedRange:)` and `unmarkText()`
(`UIInputViewController.h`, iOS 13.0; "Setting marked text either replaces the existing
marked text or, if none is present, inserts it in place of the current input location").
Every update replaces the whole marked range (no diffing); the cursor goes at the end
(`selectedRange` counts UTF-16 units). The pure logic is `LiveTypingSession`
(Shared/DictationPolicy); `KeyboardLiveTyper` performs it on the main actor, and
`ProxyLiveTypingHost` is the proxy adapter.

- Updates are coalesced to about six writes a second (`LiveTypingThrottle`); only the newest
  text is written, in order, and only when it changed. Empty partials never erase the words.
- A capability probe runs on the first words: the proxy must show them at the end of
  `documentContextBeforeInput` (compared ignoring case, smart punctuation and non-breaking
  spaces) with `documentContextAfterInput` unchanged, then the same words are marked again and
  the context must not grow. The proxy is an out-of-process snapshot, so the probe waits for
  `textDidChange` or 0.35 s. A host that fails is cleared with `setMarkedText("")` and
  `unmarkText()` (never `deleteBackward`, which would eat the user's own text on a host that
  ignored the marking) and the dictation falls back to strip-only with
  `live_typing.unsupported reason=...` in the diagnostics log.
- The final text replaces the marked range and unmarks in one step. If the final pass failed
  the result is the streaming text, so the same path unmarks it.
- Cancel (the X, or the app) removes the marked words. A failed dictation or a result that
  went to the clipboard leaves them as plain text.
- Measured on a real `UITextView` (iOS 27 simulator): `insertText` over marked text replaces
  it and `deleteBackward` over it removes the whole range. So before any other edit (a typed
  key, backspace, an older queued insertion, setup verification) the keyboard takes the words
  out and the dictation continues strip-only; the final then goes in at the cursor, after
  whatever the user typed.
- Hiding the keyboard takes the words out too, so none dangles and a recreated keyboard that
  replays the delivery cannot insert them a second time.
- If the cursor moves, the selection changes, the field changes or the host edits the words
  (seen after the fact, so they cannot be removed), the words stay as plain text and the final
  is withheld instead of inserted next to them. The status line says so; the full text is in
  Muesli.
- A selection at the start of the dictation keeps live typing off for that dictation.
- Past 1,500 characters of marked text (above anything a 60 s dictation produces), finished
  sentences are committed as plain text so the host does not re-lay-out a huge range. The final
  then replaces only the marked tail when it extends the committed text, and otherwise deletes
  and retypes it when the field still ends with exactly that text (up to 3,000 characters),
  and is withheld if not.
- Voice edits (Quill) are not typed live.
- Autocorrect never sees the words: it only judges a word typed key by key.
