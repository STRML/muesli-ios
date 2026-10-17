# Diagnostics receiver

A one-file server for Muesli's opt-in diagnostics. Python 3.9+, standard library only, SQLite storage.

```bash
export DIAG_API_KEY="$(openssl rand -hex 24)"
python3 receiver.py --db ~/muesli-diagnostics.db
python3 -m unittest discover -s . -v        # the tests
```

It binds to `127.0.0.1:8750`, refuses to start without a key, and drops any event that is not on the app's allowlist.

The full guide covers exposing it over Tailscale, pointing the app at it, the wire contract, launchd and systemd
examples, and how an agent can stand one up and debug a stuck dictation with it:
[docs/diagnostics-receiver.md](../../docs/diagnostics-receiver.md).
