# Run your own diagnostics receiver

Muesli can send its event log to a server you run, so a dictation that did not save can be traced afterwards. This
page shows how to run that server, how to reach it from your phone without exposing it to the internet, and what the
phone expects from it. A working reference server is in
[`tools/diagnostics-receiver/receiver.py`](../tools/diagnostics-receiver/receiver.py): one file, Python 3.9 or later,
standard library only.

```
iPhone (Muesli app)         your private network          your machine
┌──────────────────┐ HTTPS ┌─────────────────┐ HTTP ┌────────────────────┐
│ event log        │──────▶│ Tailscale Serve │─────▶│ receiver.py        │
│ -> allowlist     │ Bearer│ (TLS, tailnet   │ 8750 │ 127.0.0.1 only     │
│ -> batches of    │  key  │  only)          │      │ key check          │
│    100 events    │       └─────────────────┘      │ allowlist          │
└──────────────────┘                                │ SQLite file        │
                                                    └────────────────────┘
```

What the app sends and never sends is in [diagnostics-shipping.md](diagnostics-shipping.md): event names, ids,
timings, counts, error codes and device facts. Never a transcript, rewrite, selected text, audio or your device name.

## Set it up in five minutes

1. Get the file. From a checkout, `cd tools/diagnostics-receiver`. Without one, download it:

   ```bash
   curl -fsSLO https://raw.githubusercontent.com/STRML/muesli-ios/main/tools/diagnostics-receiver/receiver.py
   ```

2. Make a key. Anything of at least 16 printable characters works. You will paste it into the app, so keep it:

   ```bash
   export DIAG_API_KEY="$(openssl rand -hex 24)"
   echo "$DIAG_API_KEY"
   ```

3. Start the receiver. It binds to `127.0.0.1:8750` and creates the database file with mode 600:

   ```bash
   python3 receiver.py --db ~/muesli-diagnostics.db
   ```

4. Check it from the same machine. The first call has no key and must be refused. The second must list no devices:

   ```bash
   curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8750/v1/diagnostics/devices
   curl -s -H "Authorization: Bearer $DIAG_API_KEY" http://127.0.0.1:8750/v1/diagnostics/devices
   ```

   Expect `401`, then `{"devices":[]}`.

5. Send the app's own sample batch (`docs/diagnostics-sample-batch.json` in this repo is the encoder's output for a
   sample). Send it twice. The second answer must say `"duplicate":true`:

   ```bash
   curl -s -X POST http://127.0.0.1:8750/v1/diagnostics \
     -H "Authorization: Bearer $DIAG_API_KEY" -H "Content-Type: application/json" \
     --data @docs/diagnostics-sample-batch.json
   ```

   Expect `{"accepted":11,"dropped":0,"duplicate":false}`, then `{"accepted":0,"dropped":0,"duplicate":true}`.

## Reach it from your phone

The receiver speaks plain HTTP on the loopback address, and the app only talks HTTPS. Put a private HTTPS front in
between. Tailscale Serve does that for devices on your tailnet and gives the machine a certificate:

```bash
tailscale serve --bg --https=8444 http://127.0.0.1:8750
tailscale serve status
```

`status` prints the address, for example `https://my-mac.tail1234.ts.net:8444`. Port 8444 keeps this separate from
anything already served on 443. The flags above match `tailscale serve --help`. To remove the mapping, read the
removal syntax for your version in `tailscale serve status`. `tailscale serve reset` removes every mapping, including
ones that are not this.

**Never put this on the open internet.** Do not use `tailscale funnel`, a port forward or a public bind. The key is the
only login, there is no per-address lockout, and the app refuses to send to a non-private address until you confirm
the host.

The app counts these as private: `localhost`, `*.local`, `*.ts.net`, `10.x`, `127.x`, `192.168.x`, `169.254.x`,
`172.16-31.x` and the Tailscale range `100.64-127.x`, plus IPv6 loopback, `fc`, `fd` and `fe80`. Anything else shows a
warning and sends nothing until you acknowledge that host.

## Point the app at it

1. Open Settings > Privacy and Sync > Diagnostics.
2. Set **Diagnostics server** to `https://my-mac.tail1234.ts.net:8444/v1`. The app adds `/diagnostics`, so it posts to
   `/v1/diagnostics`. A pasted full address ending in `/diagnostics` works too.
   Leave the field empty to use the AI Services server instead.
3. The API key is the one under Settings > AI Services. Put the key from step 2 there.
4. Turn on **Send diagnostics to my server**, then tap **Send now**. The server holds events from then on.
5. Confirm from the machine:

   ```bash
   curl -s -H "Authorization: Bearer $DIAG_API_KEY" http://127.0.0.1:8750/v1/diagnostics/devices
   ```

   Your phone appears with an event count and a `last_seen` time.

Turning diagnostics on starts from now. **Send now** also uploads the newest 600 events already in the phone's log.
Changing the server address discards anything not yet sent.

## What the phone expects

This is the contract the app's upload engine relies on (`Shared/DiagnosticsShipping/DiagnosticsUploadEngine.swift`,
`DiagnosticsURLSessionTransport.swift`, `DiagnosticsEnvelope.swift`). The reference server and the Studio receiver
both follow it.

### Request

`POST <base>/diagnostics`, HTTPS only, redirects refused, 20 second timeout.

| Header | Value |
|---|---|
| `Authorization` | `Bearer <API key>`, left out when the key is empty |
| `Content-Type` | `application/json` |
| `Idempotency-Key` | the batch's `batch_id` |

Body, as the app encodes it (`docs/diagnostics-sample-batch.json` is a real one):

| Field | Type and rule |
|---|---|
| `schema` | integer, currently `1`. Receivers may ignore it. |
| `batch_id` | UUID, the idempotency key |
| `seq` | integer from 1, per install |
| `sent_at` | UTC time the batch left the phone |
| `device_id` | random UUID for this install, reset in Settings |
| `app` | `{"version": "0.1.7", "build": "24"}` |
| `os`, `model` | `iOS 27.0.1`, `iPhone18,4` (hardware identifier, never the device name) |
| `thermal` | one of `nominal`, `fair`, `serious`, `critical`. Anything else must reject the whole batch. |
| `trigger` | `timer`, `background`, `manual` or `size` |
| `dropped` | integer: events this device lost or refused since the last batch the server received |
| `dropped_events`, `dropped_fields`, `rejected_events` | integers, the split of `dropped` |
| `events` | array, at most 100 from the app |

Each event is `{"id": "<16 hex>", "t": "<UTC time>", "proc": "Muesli" | "MuesliKeyboard", "name": "...", "attrs":
{...}}`. Attribute values are strings, integers or bools, never floats. The allowed event names, attribute keys and
value shapes are listed in [diagnostics-shipping.md](diagnostics-shipping.md) and live in
`Shared/DiagnosticsShipping/DiagnosticsVocabulary.swift`.

### Answers

| Your server answers | The phone does |
|---|---|
| 200-299, 409 | Treats the batch as received and removes it from its queue. |
| 401, 403 | Stops uploading and shows "key rejected" until the key or address changes or you tap Send now. |
| 3xx, 404, 405 | Stops and shows "no diagnostics route". |
| 429 or 503 with `Retry-After` | Waits that many seconds (at most an hour). |
| 408, other 429, 5xx, no answer | Retries after 30 seconds, doubling to 15 minutes. The wait survives a relaunch. |
| any other 4xx (400, 413, 415) | Drops the batch for good, counts it in the next batch's `dropped_events`, and waits. |

The last row is why a server must be careful with 4xx: a refused batch is gone. Use 5xx, or 429 with `Retry-After`, for
anything that may pass later (a full disk, a busy database).

Send the same `batch_id` twice and the server must answer 200 or 409 and store it once. The phone resends a batch
unchanged until it hears back, so a lost answer produces a repeat.

### Limits

| Limit | App | Reference server |
|---|---|---|
| Events per batch | 100 | 500, more is a 400 |
| Body size | well under 256 KB | 256 KB, more is a 413 |
| Batches per device | one every 15 seconds while the app is open | 60 per minute, then 429 with `Retry-After` |
| Queue on the phone | 2 MB, 7 days | |
| Kept on the server | | 14 days and 1,000,000 events |

### Reading it back

Both read routes need the same key and answer `Cache-Control: no-store`.

| Route | Answer |
|---|---|
| `GET /v1/diagnostics/devices` | `{"devices": [{"device_id", "last_seen", "events"}]}`, most recently seen first |
| `GET /v1/diagnostics/recent` | `{"device": "<uuid>", "events": [...]}`, oldest first, newest last |

`recent` takes `device` (default: the most recent device), `since` (an ISO 8601 time, inclusive, on the event's own
time), `name` (a prefix such as `recording.`), `request` (matches the `request` or `capture_request` attribute) and
`limit` (default 200, at most 2000). Each event carries `received`, `device_id`, `batch_id`, `seq`, `app`, `os`,
`model`, `thermal`, `client_dropped`, `t`, `proc`, `name` and `attrs`.

## What the reference server does

| Property | How |
|---|---|
| Local by default | Binds `127.0.0.1`. A non-loopback `--host` needs `--allow-remote`. |
| No key, no start | Exits unless `DIAG_API_KEY` or `--key-file` holds at least 16 characters. A key file readable by other users is refused. |
| Key check | Constant-time comparison on every route, reads included. |
| Bounded input | 256 KB body cap on both `Content-Length` and chunked uploads, 15 second read timeout, 500 events per batch. |
| Allowlist | An event whose name, attribute keys or value shapes are not on the app's list is dropped and counted in `dropped`. A malformed envelope rejects the batch. |
| Idempotent | A known `batch_id` for a device answers 200 with `"duplicate": true` and stores nothing. |
| Rate limit | 60 batches per device per minute. |
| Private storage | One SQLite file, created with mode 600. Queries use parameters. |
| Quiet logs | Logs ids, counts and status codes. Never event values, query strings or the key. |

It is a tool for one person's devices, not a service. It speaks plain HTTP, so keep it behind the private proxy. It has
one key for every device and no lockout after failed logins. If you need more, use the same contract with a framework
you trust.

Test it:

```bash
python3 -m unittest discover -s tools/diagnostics-receiver -v
```

One test reads `DiagnosticsVocabulary.swift` and fails when the server's copy of the allowlist differs from the app's.
Run it after you update the app.

## Keep it running

### macOS (launchd)

Save as `~/Library/LaunchAgents/local.muesli-diagnostics.plist`, with the key written to a file that only you can read
(`chmod 600`):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>local.muesli-diagnostics</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/python3</string>
    <string>/Users/you/muesli-diagnostics/receiver.py</string>
    <string>--key-file</string><string>/Users/you/muesli-diagnostics/key</string>
    <string>--db</string><string>/Users/you/muesli-diagnostics/diagnostics.db</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardErrorPath</key><string>/Users/you/muesli-diagnostics/receiver.log</string>
</dict>
</plist>
```

```bash
launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/local.muesli-diagnostics.plist
```

### Linux (systemd)

Save as `/etc/systemd/system/muesli-diagnostics.service`. Create the `muesli-diag` user, put the key in
`/etc/muesli-diagnostics/key` (owner `muesli-diag`, mode 600), then `systemctl enable --now muesli-diagnostics`:

```ini
[Unit]
Description=Muesli diagnostics receiver
After=network.target

[Service]
User=muesli-diag
ExecStart=/usr/bin/python3 /opt/muesli-diagnostics/receiver.py \
  --key-file /etc/muesli-diagnostics/key --db /var/lib/muesli-diagnostics/diagnostics.db
Restart=on-failure
StateDirectory=muesli-diagnostics
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
```

The two service files are examples. The launchd file is checked with `plutil -lint`. Neither has been started on a
real machine for this page.

## For agents

Stand one up and prove it works. Stop at the first step that does not give the stated result.

1. `python3 --version` prints 3.9 or later.
2. `export DIAG_API_KEY="$(openssl rand -hex 24)"` and keep the value.
3. Start `python3 tools/diagnostics-receiver/receiver.py --db "$TMPDIR/diag.db" &`. The log line says `listening on
   127.0.0.1:8750`.
4. A call without the key returns 401: `curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8750/v1/diagnostics/devices`.
5. POST `docs/diagnostics-sample-batch.json` as in step 5 above. The answer is `{"accepted":11,"dropped":0,"duplicate":false}`.
6. Post it again. The answer says `"duplicate":true`.
7. `python3 -m unittest discover -s tools/diagnostics-receiver` ends in `OK`.
8. To expose it, run the `tailscale serve` command above, then call the printed `https://` address with the key. A
   response from there, not from `127.0.0.1`, proves the path the phone uses.
9. To connect a phone, a person sets **Diagnostics server** and the key in the app and taps **Send now**. Then
   `devices` shows the phone with a growing `events` count. Do not enter keys on a person's behalf.

### Debug a stuck or lost dictation

Every dictation request ends with exactly one `dictation.exit` event. Start there:

```bash
H="Authorization: Bearer $DIAG_API_KEY"; B=http://127.0.0.1:8750/v1/diagnostics
show='.events[] | "\(.t) \(.proc) \(.name) \(.attrs | to_entries | map("\(.key)=\(.value)") | join(" "))"'

curl -s -H "$H" "$B/recent?name=dictation.exit&limit=5" | jq -r "$show"
curl -s -H "$H" "$B/recent?request=<request id from the line above>&limit=200" | jq -r "$show"
```

`outcome` is `saved`, `failed`, `cancelled`, `superseded` or `abandoned`, and `last_stage` is the last step it
reached. `abandoned` means the work stopped without saying why, and `last_stage` is where. Match what you see against
[How a lost dictation shows up](diagnostics-shipping.md#how-a-lost-dictation-shows-up). Two more things to read:

- The app's `scene.active` and `scene.background` events carry `active_request`, `recording` and `session`. A
  keyboard that reports a recording request while the app's `active_request` is `none` is a state with no owner.
- `model.prewarm.backingOff` means the app is holding off loading the speech model. The `trigger` attribute says what
  asked for the load.

A gap between `received` and `t` on the same event is time the batch spent queued on the phone. `client_dropped` is
what the phone lost or refused before that batch.
