# Diagnostics shipping

An opt-in way to send Muesli's event log to **your own server**, so a dictation that did not save can be traced
after the fact. Off by default. No third-party service. No content.

## What it is and is not

- **Off by default.** Settings > About > Diagnostics > "Send diagnostics to my server".
- **Only to the address you set.** It reuses the Server URL and API key from Settings > AI Summaries (the Custom LLM
  server) and posts to `<Server URL>/diagnostics`, for example `https://studio.tail13013.ts.net/v1/diagnostics`.
  HTTPS only. Redirects are refused, so the key cannot be forwarded to another host. If the address does not look
  private (not loopback, LAN, Tailscale or `.local`), nothing is sent until you confirm that you trust that host,
  and the confirmation is for that host only.
- **Only the app uploads.** The keyboard extension writes to the log, as it always has, and never touches the
  network.
- **No content, ever.** The log records what happened and when. It never holds a transcript, rewrite, selected text,
  document context, audio, contact, window or field text, and never your device name, and the uploader enforces that a second time with an
  allowlist (below). Anything not on the allowlist is dropped and counted.

## What is sent

Each batch carries the events below and a small envelope about the install: a random device ID (reset in
Settings), the app version and build, the iOS version, the hardware model (for example `iPhone18,1`, never the
name you gave the phone), the thermal state, and counts of what was dropped.

### Events

Only these event names are uploaded. An event recorded under any other name is dropped.

| Area | Events |
|---|---|
| Keyboard | `ack.retry`, `ack.timedOut`, `handoff.observed`, `insert.performed`, `insert.skipped`, `intent.start`, `intent.stop`, `intent.captureEntered`, `intent.captureExited`, `keyboard.appeared`, `keyboard.disappeared`, `keyboard.autoOff`, `keyboard.persistencePreferenceChanged`, `level.freshness`, `model.select`, `rewrite.skipped`, `live_typing.unsupported`, `live_typing.detached`, `live_typing.yielded`, `live_typing.final_withheld` |
| Audio | `audioSession.activated`, `audioSession.activateRequested`, `audioSession.configureRequested`, `audioSession.deactivated`, `audioSession.deactivateRequested`, `audioSession.deactivationFailed`, `audioSession.failed`, `audioSession.inputConfigured`, `audioSession.interruption`, `audioSession.interruptionHandling`, `audioSession.mediaServicesReset`, `audioSession.routeChanged`, `audioSession.routeHandling`, `keyboardMic.activityFailed`, `keyboardMic.ioConfiguration`, `keyboardMic.retryWithOutput`, `keyboardMic.started`, `keyboardMic.startFailed`, `keyboardMic.startStep`, `recorder.engineStarted`, `recorder.ioConfiguration`, `recorder.prepareCompleted`, `recorder.prepareRequested`, `recorder_start_failed` |
| Recording and dictation | `recording.audioEstablished`, `recording.engineAttempt`, `recording.inputReady`, `recording.interruptedStop`, `recording.recovery`, `recording.recoveryRejected`, `recording.started`, `recording.startFailed`, `recording.startRequested`, `recording.startRetry`, `dictation.delivery`, `dictation.finalText`, `preview.persistFailed`, `startup.exited`, `startup.permissionRequested`, `startup.permissionResolved` |
| Models, Live Activity, lifecycle | `liveActivity.failed`, `liveActivity.skipped`, `liveActivity.started`, `livePreview.memoryWarning`, `model.prewarm.backingOff`, `whisper.loaded`, `scene.active`, `scene.inactive`, `scene.background` |
| Stop to save | `handoff.saved`, `stop.received`, `stop.ignored`, `recording.stopped`, `transcription.started`, `transcription.finished`, `transcription.failed`, `result.persisted`, `delivery.outcome`, `dictation.cancelled`, `dictation.exit`, `backgroundTask`, `app.memoryWarning`, `app.thermalState` |

### Keys

An event keeps only the keys below, and only when the value has the shape shown. A value that does not match is
dropped, not shortened. Several words in one value, a value cut off with `...`, non-ASCII text and anything longer
than the limit never match.

| Shape | Keys |
|---|---|
| UUID | `capture_request`, `intent_invocation`, `history_id` |
| UUID or 8 hex characters | `request` |
| UUID, 8 hex characters, or `none` | `active`, `active_request`, `session`, `mic_generation` |
| integer (sent as a JSON integer) | `type`, `attempt`, `elapsed_ms`, `duration_ms`, `samples`, `bytes`, `characters`, `code`, `options`, `options_before`, `channels`, `app_state`, `audio_ms`, `heartbeat_age_ms`, `bg_remaining_ms` |
| code word or integer | `reason` |
| true, false, yes or no (sent as a JSON bool) | `should_resume`, `enabled`, `startup`, `recording`, `protected_data`, `persistent`, `loaded`, `input_enabled`, `output_enabled`, `input_available`, `other_audio`, `file_written`, `empty`, `fresh`, `inserted`, `matchesActive`, `canUseRuntimeStart` |
| decimal number | `sample_rate`, `input_sample_rate` |
| seconds as text (`0.45`, `1.2s`, `none`, `never`; sent as a string, never a JSON float) | `total_s`, `wall_s`, `encoder_load_s`, `encoder_specialization_s`, `decoder_load_s`, `decoder_specialization_s`, `age`, `appSeenAt` |
| one short code word (letters, digits, `_ . : -`, up to 48) | `model`, `variant`, `source`, `trigger`, `kind`, `error`, `stage`, `step`, `caller`, `file`, `category`, `category_before`, `mode`, `mode_before`, `preference`, `phase`, `localPhase`, `appPhase` |
| code words, joined with `+` on the wire | `input_ports`, `output_ports` |
| error domain (`NSURLErrorDomain`) | `domain` |
| closed list: `saved failed cancelled superseded abandoned missingAudio noRecoverableRecording` | `outcome` |
| closed list: `requested startup recording stopping finalizingAudio transcribing persisting delivering completed` | `last_stage`, `cancel_stage` |
| closed list: `keyboardCommand appUser taskCancelled unknown` | `cancel_by` |
| closed list: `conflictingCommand notRecording lifecycleRejected noActiveRequest recoveredFromStorage` | `ignored_reason` |
| closed list: `onDevice remote streaming` | `text_source` |
| closed list: `timeout interrupted engineFailure audioUnavailable checkpointFailure unknown` | `failure` |
| closed list: `insertDirect copied copyRequired` | `route` |
| closed list: `ok noExtensionStatus noOpenAccess notVisible heartbeatStale` | `route_reason` |
| closed list: `begin denied end expired` | `bg_state` |
| closed list: `nominal fair serious critical` | `thermal` |
| closed list: `clipboard foregroundCopyRequired` | `destination` |

The source of truth is `Shared/DiagnosticsShipping/DiagnosticsVocabulary.swift`; a test fails when this page and that
file disagree, and another fails when the app records an event that is not in the list.

## How a lost dictation shows up

Every dictation request ends with exactly one `dictation.exit` event: `outcome` is `saved`, `failed`, `cancelled`,
`superseded` or `abandoned`, and `last_stage` is the last step it reached. `abandoned` means the work stopped and
nothing said why, so it points at the step in `last_stage`. A cancel also logs `dictation.cancelled` with
`cancel_by` (who). The path between has `stop.received`, `recording.stopped` (duration, sample count, bytes, whether a file
was written), `transcription.started`, `transcription.finished` or `transcription.failed`, `result.persisted` and
`delivery.outcome` (with `route_reason`, for example `heartbeatStale` when the keyboard had not reported in for 3.5
seconds), plus `backgroundTask` (begin, expired, end, with the time the OS left), `app.memoryWarning` and
`app.thermalState`.

## Wire format

This is the shape the Studio receiver validates (STRML/local-llm#20, `asr/asr_server/diag_validate.py`).
`Tests/DiagnosticsKitTests/ReceiverContractTests.swift` holds a copy of the receiver's rules and runs the app's real
encoder output through it, and `docs/diagnostics-sample-batch.json` is that encoder's output for a sample batch, ready
to `curl`.

`POST <Server URL>/diagnostics`

Headers: `Authorization: Bearer <API key>` (omitted when the key is empty), `Content-Type: application/json`,
`Idempotency-Key: <batch_id>`.

```json
{
  "schema": 1,
  "batch_id": "6F1C5E0A-2B77-4D0B-9C52-5B7A0D0E4C11",
  "seq": 42,
  "sent_at": "2026-10-16T09:30:00.123Z",
  "device_id": "11111111-2222-4333-8444-555555555555",
  "app": { "version": "0.1.7", "build": "9" },
  "os": "iOS 26.0.1",
  "model": "iPhone18,1",
  "thermal": "nominal",
  "trigger": "timer",
  "dropped": 0,
  "dropped_events": 0,
  "dropped_fields": 0,
  "rejected_events": 0,
  "events": [
    {
      "id": "9c4f1d2e7a3b5c60",
      "t": "2026-10-16T09:29:58.412Z",
      "proc": "Muesli",
      "name": "dictation.exit",
      "attrs": { "request": "04FCC3FC-0000-4000-8000-000000000001", "outcome": "abandoned", "last_stage": "transcribing" }
    }
  ]
}
```

- `thermal` is always one of `nominal`, `fair`, `serious`, `critical` (the receiver rejects the whole batch otherwise);
  an unknown iOS value is sent as `nominal`.
- `attrs` values are strings, integers or bools, never floats (the receiver drops an event that has one). Durations
  the app creates are integer milliseconds (`duration_ms`, `heartbeat_age_ms`, `bg_remaining_ms`). Text values use
  only letters, digits and `_ . : = / + -` and are at most 128 characters; lists are joined with `+`.
- `batch_id` is a UUID, also sent as `Idempotency-Key`. A batch is numbered and stored before the first attempt and
  resent unchanged until the server answers, so a lost response produces a repeat with the same `batch_id`; the
  receiver answers a known `batch_id` with 200 and `duplicate: true`. `seq` is per install, starts at 1 and rises by
  one per new batch (a reset of the device ID starts it over).
- `events[].id` is a 16 hex character hash of the log line (the receiver ignores it). `t` is the moment the event
  happened (UTC, milliseconds); `sent_at` is when the batch went out. `proc` is `Muesli` or `MuesliKeyboard` (or the
  `Dev` builds).
- `trigger` is `timer` (every 15 seconds while the app is open), `background` (the app is leaving the screen),
  `manual` (Send now) or `size`.
- `dropped` is the receiver's counter: events lost to the queue cap (2 MB), the age cap (7 days) or a rejected batch,
  plus events the allowlist refused, since the last batch that reached the server. The same numbers are split out
  as `dropped_events` and `rejected_events`; `dropped_fields` counts values the allowlist removed from events that
  were kept.
- At most 100 events per batch (the receiver allows 500) and far under its 256 KB limit.

### Status codes

| Status | Meaning to the phone |
|---|---|
| 200-299, 409 | Received (`duplicate: true` included). The batch is removed from the queue. |
| 401, 403 | The key is wrong. Uploading stops and Settings says so, until the key or address changes or you tap Send now. |
| 404, 405, other redirects | The server has no `/diagnostics` route. Same stop. |
| 429, 503 with `Retry-After` | Wait at least that many seconds (at most an hour). |
| 408, 429, 5xx, no response | Try again later: 30 seconds, doubling, up to 15 minutes. The wait survives a relaunch. |
| other 4xx (400, 413, 415) | The batch is dropped, counted in `dropped_events` of the next batch, and a wait applies. |

## Queue and behavior

- Events are read from the on-device log every 15 seconds while the app is open and diagnostics are on, and once more
  when the app goes to the background (inside a background task; if the OS time runs out, the batch stays queued
  without penalty).
- The queue lives in the app's own Application Support folder (not the shared app group, not backed up), capped at
  2 MB and 7 days. The oldest events go first and the count is reported in the next batch.
- **Turning it on starts from now.** The log as it stood is not uploaded. **Send now** uploads the events already in
  this phone's log (the newest 600) that have not been sent, including ones from before you turned this on, and tries
  once even if the uploader is waiting or stopped.
- **Turning it off** deletes the queue and every trace of progress. Removing the server address does the same.
- **Changing the server address** discards the queue (it was gathered for the old server) and starts from now at the
  new one. Changing only the key keeps the queue and lifts a stop.
- **Reset device ID** makes a new random ID, restarts `seq` at 1 and discards unsent events.
- The log file is read with a hash per line, so the app and the keyboard can write it while it is read; a half-written
  last line is skipped until it is whole.
