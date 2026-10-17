# Keyboard readiness and truthful state

The keyboard shows listening, writing or ready only when a live app confirms it. This page is the design, the
derivation table, and the failure matrix that the tests are built from. The tests are named by row.

## The problem

The keyboard cannot record. The app owns the microphone and the speech models, and the two share state through the
shared SQLite store and Darwin notifications. Handoff phases persist across process lifetimes, so after an update, a
kill or a crash a non-terminal phase can outlive the app process that owned it, and the keyboard showed "listening" or
"writing" for a request nobody held. Separately, the first load of a model after an app or OS update is a cold Neural
Engine compile that can take minutes (935 s on a real phone), and it ran inside the first dictation, because "the
model has loaded once" survived the update and the launch warm-up skipped it.

## What changed

| Piece | Where |
|---|---|
| Boot identity: a UUID per app process launch, with the app version, build and OS | `AppBootIdentity`, `ReadinessBuildStamp` |
| Every request the app works on carries its boot id; the keyboard carries it forward when it writes stop or cancel | `KeyboardHandoffState.ownerBootID`, `SharedStore(bootID:)` |
| A heartbeat the app rewrites every 5 s from a utility queue, off the main actor | `AppReadinessPublisher`, `AppReadinessRecord.heartbeatAt` |
| A verdict on who owns a persisted request | `RequestOwnershipPolicy` |
| An atomic compare-and-set that ends an abandoned request, once | `SharedStore.abandonRequest` |
| The readiness record: model state, mic state, boot, build, heartbeat | `AppReadinessRecord`, store key `app_readiness` |
| The one state the keyboard shows, derived from the record, the heartbeat and the request | `KeyboardReadinessDerivation` |
| The words, symbols and VoiceOver text for each state | `KeyboardReadinessPresentation` |
| "Loaded once" is keyed by app build and OS, so an update warms the model again | `ModelPrewarmHistory.loadedStamp` |
| A user-requested load ignores the automatic wait; a success clears it; a load that never reported back is a strike | `ModelPrewarmPolicy.Trigger.userRequested`, `LoadMarker` |
| The prepare trip: `muesli://prepare`, a Preparing screen, a prompt to go back | `PrepareTrip`, `PrepareTripView` |

The pure logic lives in `Shared/DictationPolicy` (the `DictationPolicyKit` package target) and has host tests. The
store transitions have app-hosted tests with two connections standing in for two processes.

## The derived state

`KeyboardReadinessDerivation.derive` is a pure function of: store access, the app's record, the keyboard's own build,
the verdict on the request in play, the clock, and when the keyboard began checking.

| Input | State shown | Record does |
|---|---|---|
| Full Access off (store unreadable) | `needsApp(fullAccessOff)` | open Muesli |
| Request owned by the live boot, within its bound | `starting` / `recording` / `transcribing` | stop / nothing |
| Request past its bound, owner live | the same state, `offersEscape` | stop / nothing; the caption becomes a link to Muesli |
| Recording owned by the live boot, but no audio level for 6 s | `connectionLost`, `offersEscape`: "Lost connection to Muesli. Tap to reconnect" | open Muesli; Stop is not offered; Cancel ends the request locally |
| Keyboard's own start nobody has adopted yet, young | `starting` | stop |
| Queued result, young | `transcribing` | nothing |
| Recovery prompt | `needsApp(recovery)` | the recovery link |
| Abandoned request | ignored: the state is whatever the app says without it | |
| No record ever published | `needsApp(neverOpened)` | prepare trip |
| Record of another app build or OS, stale or fresh | `needsApp(appUpdated)` | prepare trip |
| Heartbeat stale or skewed, within the 1.5 s checking window | `checking` | open Muesli (start trip if the model was good) |
| Heartbeat stale or skewed, window over | `needsApp(appNotRunning)`, or `needsApp(loadInterrupted)` if it was loading | start trip if same build and the model was ready, else prepare trip |
| Live, model `ready` or `readyOnDemand`, mic ready | `ready` | start in place |
| Live, model ready, mic not ready | `ready` | open Muesli with the usual start request |
| Live, downloading | `loading(downloading, progress)` | prepare trip |
| Live, loading | `loading(preparing, progress, elapsed)`, `offersEscape` past 120 s | prepare trip |
| Live, not downloaded | `needsApp(modelMissing)` | prepare trip |
| Live, `notLoaded` or `deferredByBackoff` | `needsApp(modelNotLoaded)`: "Speech model not loaded. Open Muesli to load it" | prepare trip: loads now, ignores and clears the wait |
| Live, failed | `failed(reason)` | prepare trip |

`starting` is not in the list the brief gave. It is the request-in-progress state before the microphone is up, which the
keyboard already showed as "Starting…", and it needs its own bound.

### Model states

`ready` is resident now. `readyOnDemand` is downloaded and loaded before under this app build and OS, but not
resident: a fresh launch (the launch warm-up only runs until the model has loaded once under the current build and
OS), or a model iOS let go of. A load takes seconds, so the keyboard treats it as `ready`. `notLoaded` is downloaded
and never loaded under this build and OS: the next load is the cold one. `deferredByBackoff` is the same with an
automatic wait running. The app does not unload the main model on a memory warning today; if iOS reclaims the process
the next boot reports `readyOnDemand`.

### Mic ready

`mic: ready` in the record means a registered keyboard mic session (`isKeyboardMicOn`: a session id, armed, engine
running) **and** an engine that accepts a start command. The engine alone is not a session the keyboard can start into.
(The `session=none` in the device log is the *recording* session, `activeSession`, not the mic session; it is `none`
whenever nothing is recording.)

## The heartbeat bound: 15 s

The app already republishes an unchanged runtime status every `KeyboardRuntimeStatusPublishPolicy.refreshInterval`
(5 s) and the keyboard already calls it stale after `KeyboardHandoffRecoveryPolicy.runtimeFreshnessInterval` (15 s).
The readiness heartbeat uses the same cadence and the same bound: 15 s is three missed beats, so one late beat (a busy
disk, a contended database lock) is not a dead app and three are. A test pins all three constants to each other. The
heartbeat is written from a utility queue and a timer, never the main actor, so a busy main thread cannot fake a lost
owner, and a suspended app (whose queues stop with it) stops beating, which is the point.

Freshness is two-sided. A heartbeat more than 2 s in the future means the clock moved backwards and is not proof; the
live app replaces it within one beat, so a wrong clock costs one flicker and never a dead owner that looks alive. A
clock that jumps forward reads stale until the next beat, for the same reason.

The keyboard re-derives on its existing one-second tick with a single-key read. When it appears it posts a
`readinessProbe` Darwin event, so a running app writes a beat at once; a suspended app cannot, which is correct.

## Abandonment

`RequestOwnershipPolicy.evaluate(phase, owner, updatedAt, liveness, now)`:

- Settled phases (`idle`, `inserted`, `copyRequired`, `cancelled`, `failed`) are not in progress.
- `resultReady` needs no owner: the keyboard delivers it itself. It is shown as "writing" for 15 s at most.
- `recoveryRequested` is the keyboard's own "Open Muesli to finish" prompt, an honest affordance.
- `startAcknowledged`, `recordingStarted`, `stopAcknowledged`, `audioSaved`, `transcribingStarted` need an owner equal to
  the live boot. Another boot, or no owner, is `abandoned(app_restarted)` if a boot is on record that is not the owner
  or a newer one is alive, else `abandoned(owner_lost)`.
- `startRequested`, `stopRequested`, `cancelRequested` written by the keyboard have no owner yet. Young ones are
  `pendingAdoption`. Past the bound (10 s start, 8 s stop) they are `stalled` if an app is alive (the existing retry and
  recovery handle that) and `abandoned(owner_lost)` if none is.

The ownership gate sits at the top of `apply(handoffState:)`, before `activeRequestID` is assigned, and on the two other
adoption paths (`apply(status:)`, runtime status), so every "Listening" and "Writing" caption follows the truthful phase.

`SharedStore.abandonRequest(id, expectedOwner:, reason:)` is one `BEGIN IMMEDIATE` transaction: it commits only if the
row is still that request, still owned by `expectedOwner`, and still in an abandonable phase. It writes `failed` with
`endReason`, clears the pending command, pending request and in-progress dictation status of that request, and returns
whether it won. Only the winner logs `request.abandoned`. A locked database reads as a lost race.

**Audio on disk.** The handoff row and the audio are independent. Ending the row never touches the recording. At launch
the app already protected checkpointed and long-form recordings (`recoverLongVoiceNotesOnLaunch`); that now also covers
a keyboard dictation still recording or transcribing, which at launch can only belong to a boot that is gone. Its audio
is kept as a failed voice note with "Your audio is safe" and a Retry in Voice Notes. It is **not** transcribed and
inserted automatically: inserting an hours-old dictation into whatever field is focused would be wrong. A late result
from an app that was only suspended still arrives (`failed` accepts progress) and is delivered.

**Launch reconcile.** `DictationCoordinator.init` publishes this boot's record first, then reconciles. It ends any
request whose owner is not this boot, except a young keyboard start nobody has adopted yet, because `init` runs before
`onOpenURL` and the URL that launched this process is about to adopt it. It also clears the last boot's runtime status.

## The prepare trip

When Record is tapped and the app is not known to be ready, the keyboard opens `muesli://prepare?trip=<id>`, with no
`claimRequest` (a start request would hang). The routing:

- Known good (same build and OS, the model was `ready`, the app was just killed): the usual one-trip start URL.
- Everything else not ready (never opened, updated, model loading/missing/failed/deferred, Full Access off): prepare.

The app, on `prepare`: reconciles abandoned state, starts the model load as a **user request** (the persisted prewarm
backoff does not apply, and a success clears it however long it took), arms the keyboard mic session so iOS keeps the
process running if the user swipes back while the model compiles, and shows the Preparing screen: download progress,
loading with elapsed time and "The first load after an update can take a few minutes. Keep Muesli open until it
finishes.", then "Ready" with "Swipe back to your app" (the host app is not known; the return-to-host spike is not
merged and this does not depend on it). If the load finishes while the app is in the background and notifications are
already allowed, it posts a local notification.

Deviation from the brief, argued: the brief says to start the microphone session "when the model is ready". Starting it
at the beginning of the trip is what lets the process survive a swipe back during a 15 minute compile (audio background
mode), which is what makes "readiness updates live in the keyboard while the user is back" possible at all. The
keyboard still shows `loading` until the model is ready, because the model state, not the mic, decides `ready`. If the
mic session is disabled in Settings, the Preparing screen says to keep Muesli open, and a suspended app shows as
`needsApp(loadInterrupted)` ("Open Muesli to finish loading"), never as a frozen "Loading".

**Notifications.** There is an existing permission flow: the Action Button setup (`ActionButtonOnboardingView`) requests
`.alert`, and `ConfirmMuesliClipboardIntent` posts only when the status is authorized or provisional. The prepare trip
reuses that check and adds no prompt. A keyboard-only user has usually never been through the Action Button setup, so
for most people the notification will not fire and the Preparing screen and the keyboard's live state are the signal.

## Failure matrix

One row per reachable state. Each is a test; the file is named in the last column.

| # | State or input | What happens | How it can fail | What the user sees | Test |
|---|---|---|---|---|---|
| R01 | Fresh install, keyboard opens, app never run | `needsApp(neverOpened)`; Record opens the prepare URL; no request claimed | A start request claims and hangs | "Open Muesli to set up dictation" | `KeyboardReadinessTests.testAFreshInstallNeedsTheAppAndOpensItWithAPrepareTrip` |
| R02a | After an update: `recordingStarted`/`transcribingStarted`/`stopRequested`/`startAcknowledged`/`stopAcknowledged`/`audioSaved`, old boot | Idle; the row ends as `failed(app_restarted)` once | Shown as listening/writing; two keyboards both log | Nothing active; the usual keyboard | `testAnOldBootsInProgressRequestIsIdleAndEndedOnce`, `RequestOwnershipPolicyTests.testAnOldBootOwnerIsAbandonedAsRestartedWhileANewBootIsAlive` |
| R02d | After an update: `resultReady`, undelivered | The keyboard inserts it; not abandoned | Lost, or abandoned | The text appears | `testAnUndeliveredResultFromBeforeTheUpdateIsInserted` |
| R02e-h | After an update: `copyRequired`, `cancelled`, `failed`, `inserted` | Settled; not ended again | Repeated `handoff.observed` lines | Idle | `testSettledPhasesFromAnOldBootStaySettled`, `testHandoffObservedIsLoggedOncePerChangeAcrossKeyboardInstances` |
| R02 | First tap after the update | Prepare trip; app reconciles, loads, prompts a return; the new boot reports `ready` at once if already loaded | Cold compile inside the first dictation | "Muesli was updated. Open it to continue", then loading, then ready | `testAnUpdatedAppNeedsAPrepareTripUntilTheNewBootReportsReady`, `ModelPrewarmReadinessTests.testAModelLoadedBeforeTheUpdateIsWarmedAgainWhenTheAppOpens` |
| R03 | App killed mid-recording, same build, model fine | Idle; row `failed(owner_lost)`; Record opens the usual start URL | Stuck "Listening" | "Open Muesli to start" | `testAKilledAppMidRecordingIsIdleAndStartsWithTheUsualTrip` |
| R04 | App killed mid-transcribing, audio on disk | Idle; next dictation free; audio kept as a failed voice note with Retry | Audio lost | Idle; the note in Voice Notes | `testAKilledAppMidTranscriptionIsIdleAndFreesTheNextDictation` (keyboard); `recoverLongVoiceNotesOnLaunch` (app, device check) |
| R05 | App crashes at launch, again and again | The load marker counts each as a strike; automatic loads back off 5 min doubling to 6 h; the user can still ask | Retry forever | `needsApp(modelNotLoaded)` | `ModelPrewarmReadinessTests.testALaunchLoopBacksOffInsteadOfRetryingForever` |
| R06 | Heartbeat 14.9 s vs 15.1 s | Live vs abandoned | Off by one | Recording, then idle | `AppLivenessPolicyTests.testFreshnessAtTheBoundary`, `testTheHeartbeatBoundaryDecidesWhetherARecordingIsReal` |
| R07 | Clock moved backwards / forwards | Skewed reads stale; forward reads stale until the next beat | A dead owner looks alive | Idle | `testAHeartbeatFromTheFutureIsNotLive`, `testAClockMovedBackwardsReadsTheHeartbeatAsStale` |
| R08 | Two keyboards abandon the same request | One winner, one log line | Two logs; a second write undoes the first | One idle keyboard | `SharedStoreOwnershipTests.testRacingAbandonersProduceExactlyOneWinner` |
| R09 | App and keyboard abandon at once | Same CAS | Same | Same | same test (the contenders include app stores) |
| R10 | Keyboard shown while the app is mid-launch | `starting` while young; adopted when the app comes up; released past the bound | Abandoned too early, or never released | "Starting…", then idle | `testAStartWaitingForAnAppLaunchIsStartingNotAbandoned`, `testAStartNobodyTookIsReleasedPastTheBound` |
| R11 | Model `notDownloaded`, `downloading`, loading 15 min, `ready`, `failed`, `deferredByBackoff` | One derived state each; a long load offers an escape | A frozen or blank state | Captions per state | `KeyboardReadinessDerivationTests` |
| R12 | User-initiated load with a backoff running | `userRequested` ignores it; success clears it, however long | The automatic wait refuses the user | The load runs | `ModelPrewarmReadinessTests.testAUserRequestedLoadIgnoresTheAutomaticWait`, `testASuccessfulUserRequestedLoadClearsTheBackoffWhateverItsDuration` |
| R13 | Record tapped in each state | Start in place, usual start trip, or prepare trip; never a start that hangs | A start request into a model that cannot transcribe | Per state | `testRecordInPlaceOnlyWhenTheModelIsReadyAndTheMicIsHot`, `testRecordOpensTheAppWithAPrepareTripWhenTheModelIsNotReady`, `testReadyWithAColdMicKeepsTheStartTrip` |
| R14 | Prepare trip ends while the user is in the app vs already back | Preparing screen turns to Ready; no notification in the app; in the background, notify once if allowed; the keyboard flips to ready on its own | A second trip needed | Ready, with or without a banner | `PrepareTripTests`, `testTheRecordKeyBecomesNormalWhenTheLoadFinishesWithoutAnotherTrip` |
| R15 | Model unloaded after a memory warning | `readyOnDemand`, shown as ready | A needless trip | Ready | `ModelPrewarmReadinessTests.testReadyOnDemandNeedsALoadUnderThisBuildAndOS` |
| R16 | Full Access off | `needsApp(fullAccessOff)` | A guess | "Turn on Full Access to dictate" | `testWithoutFullAccessTheStateIsTheSetupStateAndNeverFake` |
| R17 | Live typing, two-pass, tap-to-stop pill | Unchanged when ready | Regressions | As before | existing `KeyboardLiveTypingTests`, `KeyboardStatusPillTests`, `KeyboardDictationWithTypingTests` against a live-app fixture |
| R18 | Minimal/Full layouts, Type/Dictate pages | One presentation table | Pages disagree | Same state | `KeyboardReadinessPresentationTests`, `testBothPagesReadTheSameState` |
| R19 | Setup verification | Keeps its row | Replaced by a badge | Verify row | existing setup-verification tests |
| R20 | Bounded states | checking 1.5 s, starting 10 s, stopping 8 s, transcribing 120 s, loading 120 s each offer an escape | A state that waits forever | A link to Muesli | `testCheckingBecomesNeedsAppAfterTheWindow`, `testStagesHaveBounds`, `testALongTranscriptionStaysTranscribingAndOffersAnEscape` |
| R21 | Persisted `recordingStarted`, dead owner | `showsActiveWaveform` false, no live preview, not "Listening" | The caption path reads raw phases | Idle | `testAnOldBootsInProgressRequestIsIdleAndEndedOnce` |
| R22 | Owner stamping | App stamps its boot; the keyboard carries it; `claimRecovery` takes the recovering boot; a young unadopted start survives the launch reconcile | The keyboard abandons what is being recovered | n/a | `SharedStoreOwnershipTests`, `testStopFromTheKeyboardKeepsTheAppsOwnership` |
| R23 | Logging | One `keyboard.readiness` per change across instances; `handoff.observed` once per change | Per-refresh noise | n/a | `testReadinessIsLoggedOncePerChangeNotPerRefresh`, `testALogLineIsWorthWritingOncePerChange` |
| R24 | Database locked | Treated as a lost race | A thrown error | n/a | `testALockedDatabaseCountsAsLost` |
| R25 | Late result for an abandoned request | Delivered | Lost words | The text appears | `testALateResultForAnAbandonedRequestIsStillDelivered` |
| R26 | Notifications | Only in the background, only if already allowed, once | A prompt, or a banner while in the app | n/a | `PrepareTripTests` |
| R28 | Fresh heartbeat from another build | Not live | The new keyboard trusts an old app | "Muesli was updated" | `testAFreshHeartbeatFromAnotherBuildIsNotLive` |
| R29 | Keyboard appears | Posts a probe; a running app beats at once | A live app shown absent | n/a | `testAppearingProbesTheApp`, `AppReadinessPublisherTests` |
| R31 | The stuck picture: flat meter, owner still beats, pill ignored, Cancel greyed | `connectionLost`; Stop not offered; the pill and the Record key open Muesli; Cancel ends the request here as `cancelled(owner_lost)` and still sends the cancel command; Open Muesli ends a request this boot owns but holds nothing for | A pill that does nothing; a Cancel that waits for an app that never answers | `testARecordingWithNoAudioIsALostConnectionWithAnEscapeThatAlwaysWorks`, `testOpeningMuesliEndsAZombieThisBootOwns`, `testALostConnectionSaysSoAndOffersTheWayBack`, `testARecordingWithNoAudioLevelIsALostConnection` |
| R32 | Persisted `recordingStarted` for X, no live boot, Cancel unacknowledged, keyboard comes back (from the device log) | Idle, and stays idle across reappearances; the app waking up cannot revive a cancelled request | Recording resurrected at the next appearance | "Ready" | `testACancelNobodyAcknowledgedNeverResurrectsTheRecording` |
| R33 | First dictation after an update while the automatic wait from the old build is active (three prewarms refused) | The wait earned under another build does not apply; the first launch warms the model; if it still is not loaded the keyboard says so and Record loads it now | The model never loads and the keyboard cannot tell | "Speech model not loaded. Open Muesli to load it" | `ModelPrewarmReadinessTests.testABackoffEarnedByTheOldBuildDoesNotHoldBackTheFirstLaunchAfterTheUpdate`, `testStrikesFromBeforeStampsDoNotApplyToAnyBuild`, `testABackoffFromAnotherBuildLeavesTheModelPlainlyNotLoaded` |
| R34 | `keyboardMic.started` but no registered mic session | Mic is `ready` only with a registered session and an engine that accepts a start | "Ready" while a start would hang | Prepare trip | `currentReadinessMicState` (device check); derivation covers mic states |
| R30 | App suspended mid-load | `needsApp(loadInterrupted)` | A frozen "Loading 3 min" | "Open Muesli to finish loading" | `testALoadThatStoppedBeatingIsNeedsAppNotLoading` |

## Checking it on a phone

A real update from one TestFlight build to the next is the test that matters, because it is the only way to get a real
cold compile, a real process kill and a real new boot.

1. On build A: dictate once with the keyboard so the model has loaded under build A. Start a dictation and leave it
   recording (do not stop it). Switch to another app so the keyboard is hidden.
2. Install build B from TestFlight over it. Do not open Muesli.
3. Open any text field and show the Muesli keyboard. Expected: no "Listening" and no "Writing" anywhere; the strip
   says "Muesli was updated. Open it to continue".
4. Tap Record. Expected: Muesli opens on the Preparing screen with the loading time counting. Do not touch anything.
5. When it says Ready, swipe back to the app. The Record key is now normal (a microphone). Tap it and dictate.
6. Repeat 3-4, but at step 4 swipe back to the text field while it is still loading. Expected: the strip keeps
   counting ("Loading speech model, 1 min 20 s") while the app stays alive, then the Record key turns normal on its own.
7. With Diagnostics shipping on, look for `keyboard.readiness` (one per change), `request.abandoned` with
   `reason=app_restarted` (once), `prepare.started`/`prepare.finished`, and `whisper.loaded` with its time.
