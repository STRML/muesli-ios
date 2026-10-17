"""Black-box tests for receiver.py: each test starts the real server on an ephemeral port and talks HTTP to it.

Run from the repo root:  python3 -m unittest discover -s tools/diagnostics-receiver -v
"""
import copy
import http.client
import json
import logging
import os
import re
import socket
import subprocess
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
sys.path.insert(0, str(HERE))

import receiver  # noqa: E402

KEY = "test-key-0123456789abcdef"
DEVICE = "11111111-2222-4333-8444-555555555555"
REQUEST = "04FCC3FC-0000-4000-8000-000000000001"
SAMPLE = json.loads((REPO / "docs" / "diagnostics-sample-batch.json").read_text())


def batch(batch_id, events=None, **overrides):
    """A minimal valid batch in the app's envelope shape."""
    doc = {
        "schema": 1,
        "batch_id": batch_id,
        "seq": 1,
        "sent_at": "2026-10-17T16:00:00.000Z",
        "device_id": DEVICE,
        "app": {"version": "0.1.7", "build": "24"},
        "os": "iOS 27.0.1",
        "model": "iPhone18,4",
        "thermal": "nominal",
        "trigger": "timer",
        "dropped": 0,
        "dropped_events": 0,
        "dropped_fields": 0,
        "rejected_events": 0,
        "events": events if events is not None else [event("scene.active")],
    }
    doc.update(overrides)
    return doc


def event(name, attrs=None, t="2026-10-17T16:00:00.000Z", proc="Muesli"):
    return {"id": "9c4f1d2e7a3b5c60", "t": t, "proc": proc, "name": name, "attrs": attrs or {}}


def bid(n):
    return f"6F1C5E0A-2B77-4D0B-9C52-{n:012d}"


class ServerCase(unittest.TestCase):
    max_body = 256 * 1024
    rate_per_min = 60

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.server = receiver.make_server(
            "127.0.0.1", 0, KEY, Path(self.tmp.name) / "diag.db",
            max_body=self.max_body, rate_per_min=self.rate_per_min,
        )
        self.port = self.server.server_address[1]
        thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True)
        thread.start()
        self.addCleanup(thread.join, 5)
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)

    def call(self, method, path, body=None, key=KEY, headers=None, raw=None):
        data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
        request = urllib.request.Request(f"http://127.0.0.1:{self.port}{path}", data=data, method=method)
        if data is not None:
            request.add_header("Content-Type", "application/json")
        if key is not None:
            request.add_header("Authorization", f"Bearer {key}")
        for name, value in (headers or {}).items():
            request.add_header(name, value)
        try:
            with urllib.request.urlopen(request, timeout=10) as response:
                return response.status, json.loads(response.read() or b"null"), response.headers
        except urllib.error.HTTPError as e:
            with e:
                payload = e.read()
                return e.code, (json.loads(payload) if payload else None), e.headers

    def post(self, body, **kwargs):
        return self.call("POST", "/v1/diagnostics", body, **kwargs)

    def stored_names(self):
        status, doc, _ = self.call("GET", f"/v1/diagnostics/recent?device={DEVICE}&limit=2000")
        self.assertEqual(status, 200)
        return [e["name"] for e in doc["events"]]


class StartupTests(unittest.TestCase):
    def run_cli(self, *args, env=None):
        merged = {k: v for k, v in os.environ.items() if k != "DIAG_API_KEY"}
        merged.update(env or {})
        return subprocess.run(
            [sys.executable, str(HERE / "receiver.py"), *args],
            capture_output=True, text=True, timeout=15, env=merged,
        )

    def test_refuses_to_start_without_a_key(self):
        result = self.run_cli("--port", "0")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("DIAG_API_KEY", result.stderr)

    def test_refuses_a_short_key(self):
        result = self.run_cli("--port", "0", env={"DIAG_API_KEY": "short"})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("at least 16", result.stderr)

    def test_reads_the_key_from_a_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            key_file = Path(tmp) / "key"
            key_file.write_text(KEY + "\n")
            key_file.chmod(0o600)
            self.assertEqual(receiver.load_key(env={}, key_file=str(key_file)), KEY)

    def test_refuses_a_world_readable_key_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            key_file = Path(tmp) / "key"
            key_file.write_text(KEY)
            key_file.chmod(0o644)
            with self.assertRaises(SystemExit):
                receiver.load_key(env={}, key_file=str(key_file))

    def test_binds_to_loopback_by_default(self):
        self.assertEqual(receiver.DEFAULT_HOST, "127.0.0.1")


class AuthTests(ServerCase):
    def test_post_without_a_key_is_401(self):
        status, doc, headers = self.post(batch(bid(1)), key=None)
        self.assertEqual(status, 401)
        self.assertEqual(headers["WWW-Authenticate"], "Bearer")
        self.assertEqual(doc["error"]["type"], "authentication_error")

    def test_post_with_a_wrong_key_is_401(self):
        self.assertEqual(self.post(batch(bid(1)), key="wrong-key-0123456789abcdef")[0], 401)

    def test_reads_need_the_key_too(self):
        self.assertEqual(self.call("GET", "/v1/diagnostics/recent", key=None)[0], 401)
        self.assertEqual(self.call("GET", "/v1/diagnostics/devices", key=None)[0], 401)

    def test_a_non_bearer_scheme_is_401(self):
        self.assertEqual(self.post(batch(bid(1)), key=None, headers={"Authorization": f"Basic {KEY}"})[0], 401)


class ValidationTests(ServerCase):
    def test_wrong_content_type_is_415(self):
        status, _, _ = self.post(None, raw=b"{}", headers={"Content-Type": "text/plain"})
        self.assertEqual(status, 415)

    def test_invalid_json_is_400(self):
        self.assertEqual(self.post(None, raw=b"{not json")[0], 400)

    def test_a_body_that_is_not_an_object_is_400(self):
        self.assertEqual(self.post([1, 2, 3])[0], 400)

    def test_a_non_finite_number_is_400(self):
        self.assertEqual(self.post(None, raw=b'{"seq": NaN}')[0], 400)

    def test_thermal_outside_the_four_levels_rejects_the_batch(self):
        status, doc, _ = self.post(batch(bid(1), thermal="toasty"))
        self.assertEqual(status, 400)
        self.assertEqual(doc["error"]["message"], "invalid thermal")

    def test_a_bad_device_id_rejects_the_batch(self):
        self.assertEqual(self.post(batch(bid(1), device_id="not-a-uuid"))[0], 400)

    def test_a_bad_batch_id_rejects_the_batch(self):
        self.assertEqual(self.post(batch("not-a-uuid"))[0], 400)

    def test_a_missing_app_rejects_the_batch(self):
        doc = batch(bid(1))
        del doc["app"]
        self.assertEqual(self.post(doc)[0], 400)

    def test_a_negative_seq_rejects_the_batch(self):
        self.assertEqual(self.post(batch(bid(1), seq=-1))[0], 400)

    def test_a_bool_is_not_an_integer(self):
        self.assertEqual(self.post(batch(bid(1), seq=True))[0], 400)

    def test_more_than_500_events_rejects_the_batch(self):
        status, doc, _ = self.post(batch(bid(1), events=[event("scene.active")] * 501))
        self.assertEqual(status, 400)
        self.assertIn("500", doc["error"]["message"])

    def test_error_messages_never_echo_the_request(self):
        status, doc, _ = self.post(batch(bid(1), thermal="SECRET-VALUE-XYZ"))
        self.assertEqual(status, 400)
        self.assertNotIn("SECRET-VALUE-XYZ", json.dumps(doc))

    def test_unknown_paths_are_404_and_wrong_methods_405(self):
        self.assertEqual(self.call("GET", "/nope")[0], 404)
        self.assertEqual(self.call("GET", "/v1/diagnostics")[0], 405)
        self.assertEqual(self.call("POST", "/v1/diagnostics/recent", {})[0], 405)


class SizeTests(ServerCase):
    max_body = 4096

    def test_a_declared_oversize_body_is_413(self):
        big = batch(bid(1), events=[event("scene.active", {"request": REQUEST})] * 200)
        self.assertGreater(len(json.dumps(big)), self.max_body)
        self.assertEqual(self.post(big)[0], 413)

    def test_a_body_under_the_cap_is_fine(self):
        self.assertEqual(self.post(batch(bid(1)))[0], 200)

    def chunked(self, wire):
        """POST `wire` as a raw chunked body and return (status, body)."""
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        conn.putrequest("POST", "/v1/diagnostics")
        conn.putheader("Authorization", f"Bearer {KEY}")
        conn.putheader("Content-Type", "application/json")
        conn.putheader("Transfer-Encoding", "chunked")
        conn.endheaders()
        conn.send(wire)
        conn.sock.shutdown(socket.SHUT_WR)  # the client is done: a truncated body ends here, not at the timeout
        response = conn.getresponse()
        result = (response.status, json.loads(response.read()))
        conn.close()
        return result

    @staticmethod
    def as_chunks(payload, size):
        out = b"".join(b"%x\r\n%s\r\n" % (len(part), part) for part in
                       (payload[i:i + size] for i in range(0, len(payload), size)))
        return out + b"0\r\n\r\n"

    def test_a_chunked_upload_is_accepted(self):
        payload = json.dumps(batch(bid(1))).encode()
        status, doc = self.chunked(self.as_chunks(payload, 37))
        self.assertEqual((status, doc["accepted"]), (200, 1))

    def test_a_chunked_upload_over_the_cap_is_413(self):
        payload = json.dumps(batch(bid(1), events=[event("scene.active", {"request": REQUEST})] * 200)).encode()
        self.assertGreater(len(payload), self.max_body)
        self.assertEqual(self.chunked(self.as_chunks(payload, 1000))[0], 413)

    def test_a_malformed_chunked_upload_is_400(self):
        self.assertEqual(self.chunked(b"zz\r\nhello\r\n0\r\n\r\n")[0], 400)
        self.assertEqual(self.chunked(b"5\r\nhel")[0], 400)

    def test_a_request_with_neither_length_nor_chunks_is_411(self):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        conn.putrequest("POST", "/v1/diagnostics")
        conn.putheader("Authorization", f"Bearer {KEY}")
        conn.putheader("Content-Type", "application/json")
        conn.endheaders()
        self.assertEqual(conn.getresponse().status, 411)
        conn.close()

    def test_an_invalid_content_length_is_400(self):
        status, _, _ = self.post(None, raw=b"{}", headers={"Content-Length": "12abc"})
        self.assertEqual(status, 400)


class EventFilterTests(ServerCase):
    def test_an_unknown_event_name_is_dropped_and_counted(self):
        doc = batch(bid(1), events=[event("scene.active"), event("made.up.event"), event("scene.background")])
        status, result, _ = self.post(doc)
        self.assertEqual(status, 200)
        self.assertEqual((result["accepted"], result["dropped"], result["duplicate"]), (2, 1, False))
        self.assertEqual(sorted(self.stored_names()), ["scene.active", "scene.background"])

    def test_an_unknown_attribute_key_drops_the_event(self):
        status, result, _ = self.post(batch(bid(1), events=[event("scene.active", {"favourite_colour": "blue"})]))
        self.assertEqual((status, result["accepted"], result["dropped"]), (200, 0, 1))

    def test_keys_that_would_carry_content_drop_the_event(self):
        for key in ("text", "transcript", "Body", "prompt", "audio"):
            with self.subTest(key=key):
                _, result, _ = self.post(batch(bid(abs(hash(key)) % 10**11), events=[event("scene.active", {key: "x"})]))
                self.assertEqual(result["dropped"], 1)

    def test_a_float_value_drops_the_event(self):
        _, result, _ = self.post(batch(bid(1), events=[event("recording.stopped", {"duration_ms": 6.5})]))
        self.assertEqual((result["accepted"], result["dropped"]), (0, 1))

    def test_a_value_that_does_not_match_its_keys_shape_drops_the_event(self):
        bad = [
            ("dictation.exit", {"outcome": "banana"}),
            ("dictation.exit", {"request": "hello there friend"}),
            ("dictation.exit", {"last_stage": "transcribing now"}),
            ("recording.stopped", {"duration_ms": "6100"}),
            ("scene.active", {"recording": "maybe"}),
            ("recording.started", {"model": "has a space"}),
            ("recording.started", {"model": "x" * 49}),
            ("recording.started", {"model": "caf\u00e9"}),
            ("audioSession.failed", {"domain": "justaword"}),
            ("scene.active", {"active_request": "0123456"}),
        ]
        for n, (name, attrs) in enumerate(bad):
            with self.subTest(name=name, attrs=attrs):
                _, result, _ = self.post(batch(bid(100 + n), events=[event(name, attrs)]))
                self.assertEqual((result["accepted"], result["dropped"]), (0, 1))

    def test_values_in_each_documented_shape_are_kept(self):
        good = [
            ("dictation.exit", {"request": REQUEST, "outcome": "abandoned", "last_stage": "transcribing"}),
            ("dictation.exit", {"request": "04fcc3fc", "cancel_by": "appUser"}),
            ("scene.active", {"active_request": "none", "session": "none", "recording": False, "startup": True,
                              "app_state": 1, "mic_generation": REQUEST}),
            ("recording.stopped", {"duration_ms": 6100, "samples": 97600, "bytes": 195200, "file_written": True}),
            ("whisper.loaded", {"total_s": "1.2s", "wall_s": "0.45", "encoder_load_s": "none", "model": "whisper-large-turbo"}),
            ("audioSession.routeChanged", {"input_ports": "BluetoothHFP+MicrophoneBuiltIn", "sample_rate": "44100.0",
                                           "reason": 3}),
            ("audioSession.failed", {"domain": "NSURLErrorDomain", "code": -1001, "reason": "categoryChange"}),
            ("delivery.outcome", {"route": "copyRequired", "route_reason": "heartbeatStale", "heartbeat_age_ms": 4250}),
            ("app.thermalState", {"thermal": "serious"}),
            ("backgroundTask", {"bg_state": "expired", "bg_remaining_ms": 400}),
            ("transcribe.trimmed", {"leading_ms": 120, "trailing_ms": 300, "text_source": "onDevice"}),
            ("dictation.exit", {"outcome": "failed", "failure": "timeout"}),
            ("handoff.saved", {"destination": "clipboard", "phase": "copyRequired"}),
        ]
        events = [event(name, attrs) for name, attrs in good]
        status, result, _ = self.post(batch(bid(1), events=events))
        self.assertEqual((status, result["accepted"], result["dropped"]), (200, len(good), 0))

    def test_reason_as_digits_is_kept_because_the_app_sends_it_as_text(self):
        # DiagnosticsAttrValue.typed sends only `int` and `flag` keys as JSON numbers and bools; `reason` is a
        # code word or an integer and goes out as a string either way.
        events = [event("recording.interruptedStop", {"reason": "3"}), event("audioSession.routeChanged", {"reason": 3}),
                  event("audioSession.interruption", {"reason": "-1"}), event("scene.active", {"reason": "3.5"})]
        _, result, _ = self.post(batch(bid(1), events=events))
        self.assertEqual((result["accepted"], result["dropped"]), (3, 1))

    def test_a_bad_time_drops_the_event(self):
        _, result, _ = self.post(batch(bid(1), events=[event("scene.active", t="yesterday-ish")]))
        self.assertEqual((result["accepted"], result["dropped"]), (0, 1))

    def test_an_event_that_is_not_an_object_is_dropped(self):
        _, result, _ = self.post(batch(bid(1), events=["scene.active", 7, None]))
        self.assertEqual((result["accepted"], result["dropped"]), (0, 3))


class IdempotencyTests(ServerCase):
    def test_a_repeated_batch_is_acknowledged_and_stored_once(self):
        doc = batch(bid(1), events=[event("scene.active"), event("scene.background")])
        first = self.post(doc)
        again = self.post(doc)
        self.assertEqual((first[0], first[1]["accepted"], first[1]["duplicate"]), (200, 2, False))
        self.assertEqual((again[0], again[1]["accepted"], again[1]["duplicate"]), (200, 0, True))
        self.assertEqual(len(self.stored_names()), 2)

    def test_the_same_batch_id_from_another_device_is_a_new_batch(self):
        other = "99999999-2222-4333-8444-555555555555"
        self.post(batch(bid(1)))
        status, result, _ = self.post(batch(bid(1), device_id=other))
        self.assertEqual((status, result["duplicate"]), (200, False))

    def test_a_repeat_survives_a_restart(self):
        path = Path(self.tmp.name) / "diag.db"
        self.post(batch(bid(1)))
        self.server.shutdown()
        self.server.server_close()
        self.server = receiver.make_server("127.0.0.1", 0, KEY, path)
        self.port = self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True).start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.assertTrue(self.post(batch(bid(1)))[1]["duplicate"])


class RateLimitTests(ServerCase):
    rate_per_min = 2

    def test_the_third_batch_in_a_minute_is_429_with_retry_after(self):
        self.assertEqual(self.post(batch(bid(1)))[0], 200)
        self.assertEqual(self.post(batch(bid(2)))[0], 200)
        status, doc, headers = self.post(batch(bid(3)))
        self.assertEqual(status, 429)
        self.assertEqual(doc["error"]["type"], "rate_limit_error")
        self.assertTrue(1 <= int(headers["Retry-After"]) <= 60)

    def test_the_limit_is_per_device(self):
        other = "99999999-2222-4333-8444-555555555555"
        self.post(batch(bid(1)))
        self.post(batch(bid(2)))
        self.assertEqual(self.post(batch(bid(3), device_id=other))[0], 200)

    def test_a_rejected_batch_does_not_use_up_the_budget(self):
        self.post(batch(bid(1), thermal="toasty"))
        self.post(batch(bid(2), thermal="toasty"))
        self.assertEqual(self.post(batch(bid(3)))[0], 200)


class HappyPathTests(ServerCase):
    def test_the_apps_real_sample_batch_is_accepted_whole(self):
        status, result, _ = self.post(SAMPLE)
        self.assertEqual(status, 200)
        self.assertEqual(result, {"accepted": len(SAMPLE["events"]), "dropped": 0, "duplicate": False})

    def test_recent_returns_what_was_stored_oldest_first(self):
        self.post(SAMPLE)
        status, doc, headers = self.call("GET", "/v1/diagnostics/recent")
        self.assertEqual(status, 200)
        self.assertEqual(headers["Cache-Control"], "no-store")
        self.assertEqual(doc["device"], SAMPLE["device_id"])
        names = [e["name"] for e in doc["events"]]
        self.assertEqual(names, [e["name"] for e in SAMPLE["events"]])
        first = doc["events"][0]
        for field in ("received", "device_id", "batch_id", "seq", "app", "os", "model", "thermal", "t", "proc", "name",
                      "attrs"):
            self.assertIn(field, first)
        self.assertEqual(first["app"], {"version": "0.1.7", "build": "9"})
        self.assertEqual(first["client_dropped"], SAMPLE["dropped"])

    def test_recent_filters(self):
        events = [
            event("recording.started", {"request": REQUEST}, t="2026-10-17T16:00:01.000Z"),
            event("recording.stopped", {"request": REQUEST}, t="2026-10-17T16:00:02.000Z"),
            event("scene.active", {"request": "aaaaaaaa"}, t="2026-10-17T16:00:03.000Z"),
        ]
        self.post(batch(bid(1), events=events))
        recent = lambda q: [e["name"] for e in self.call("GET", f"/v1/diagnostics/recent?{q}")[1]["events"]]  # noqa: E731
        self.assertEqual(recent("name=recording."), ["recording.started", "recording.stopped"])
        self.assertEqual(recent(f"request={REQUEST}"), ["recording.started", "recording.stopped"])
        self.assertEqual(recent("since=2026-10-17T16:00:02Z"), ["recording.stopped", "scene.active"])
        self.assertEqual(recent("limit=1"), ["scene.active"])
        self.assertEqual(recent(f"device={DEVICE.upper()}&limit=2"), ["recording.stopped", "scene.active"])

    def test_recent_rejects_bad_queries(self):
        for query in ("device=nope", "since=yesterday", "limit=0", "limit=abc", "name=has%20space"):
            with self.subTest(query=query):
                self.assertEqual(self.call("GET", f"/v1/diagnostics/recent?{query}")[0], 400)

    def test_recent_is_empty_before_anything_arrives(self):
        status, doc, _ = self.call("GET", "/v1/diagnostics/recent")
        self.assertEqual((status, doc), (200, {"device": None, "events": []}))

    def test_devices_lists_each_device_with_counts_most_recent_first(self):
        self.post(batch(bid(1), events=[event("scene.active")] * 3))
        other = "99999999-2222-4333-8444-555555555555"
        self.post(batch(bid(2), device_id=other, events=[event("scene.active")]))
        status, doc, _ = self.call("GET", "/v1/diagnostics/devices")
        self.assertEqual(status, 200)
        ids = [d["device_id"] for d in doc["devices"]]
        self.assertEqual(ids, [other, DEVICE])
        self.assertEqual([d["events"] for d in doc["devices"]], [1, 3])
        self.assertRegex(doc["devices"][0]["last_seen"], r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$")


class PrivacyTests(ServerCase):
    def test_the_log_carries_names_and_counts_never_values_or_the_key(self):
        records = []

        class Capture(logging.Handler):
            def emit(self, record):
                records.append(record.getMessage())

        handler = Capture()
        logger = logging.getLogger("diagnostics_receiver")
        logger.addHandler(handler)
        previous = logger.level
        logger.setLevel(logging.DEBUG)
        self.addCleanup(logger.removeHandler, handler)
        self.addCleanup(logger.setLevel, previous)
        self.post(batch(bid(1), events=[event("dictation.exit", {"request": REQUEST, "outcome": "saved"})]))
        self.post(batch(bid(2)), key="wrong-key-0123456789abcdef")
        self.call("GET", f"/v1/diagnostics/recent?request={REQUEST}")
        joined = "\n".join(records)
        self.assertTrue(records)
        for secret in (REQUEST, KEY, "wrong-key-0123456789abcdef", "outcome"):
            self.assertNotIn(secret, joined)


class VocabularyDriftTests(unittest.TestCase):
    """receiver.py copies the app's closed vocabulary. This fails when DiagnosticsVocabulary.swift moves on."""

    SWIFT = REPO / "Shared" / "DiagnosticsShipping" / "DiagnosticsVocabulary.swift"

    def swift_source(self):
        if not self.SWIFT.exists():
            self.skipTest("the Swift sources are not next to this checkout")
        return self.SWIFT.read_text()

    def test_events_match_the_apps_list(self):
        source = self.swift_source()
        block = source.split("static let events: Set<String> = [", 1)[1].split("\n    ]", 1)[0]
        block = re.sub(r"//[^\n]*", "", block)
        self.assertEqual(set(re.findall(r'"([^"]+)"', block)), set(receiver.EVENTS))

    def test_attribute_keys_match_the_apps_rules(self):
        source = self.swift_source()
        rules = source.split("static let keyRules", 1)[1].split("private static func values", 1)[0]
        # Each statement is `add(<rule>, "key", "key", ...)`. Drop the rule (its parentheses can nest three deep,
        # and `extra:` lists hold quoted values), then collect the quoted keys.
        rule = r"\s*\.\w+(?:\((?:[^()]|\((?:[^()]|\([^()]*\))*\))*\))?\s*,"
        keys = set()
        for statement in re.split(r"\n\s*add\(", "\n" + rules)[1:]:
            statement = statement.split("\n        return rules")[0]
            keys.update(re.findall(r'"([A-Za-z_]+)"', re.sub(rf"^{rule}", "", statement)))
        self.assertEqual(keys, set(receiver.KEY_RULES))

    def test_closed_value_lists_match_the_apps_enums(self):
        source = self.swift_source()
        enums = {
            "outcome": ("DictationExitOutcome", ["missingAudio", "noRecoverableRecording"]),
            "last_stage": ("DictationStage", []),
            "cancel_by": ("DictationCancelSource", []),
            "ignored_reason": ("StopIgnoredReason", []),
            "text_source": ("TextSource", []),
            "failure": ("FailureCode", []),
            "bg_state": ("BackgroundTaskState", []),
            "thermal": ("ThermalLevel", []),
        }
        delivery = (REPO / "Shared" / "DiagnosticsShipping" / "KeyboardDeliveryRoute.swift").read_text()
        for key, (enum_name, extra) in enums.items():
            body = re.search(rf"enum {enum_name}: String[^{{]*{{(.*?)\n}}", source, re.S).group(1)
            body = re.sub(r"///[^\n]*", "", body)
            cases = re.findall(r"case ([^\n]+)", body)
            names = {n.strip() for line in cases for n in line.split(",")}
            self.assertEqual(set(receiver.KEY_RULES[key][1]), names | set(extra), key)
        for key, enum_name in (("route", "KeyboardDeliveryRoute"), ("route_reason", "KeyboardDeliveryReason")):
            body = re.search(rf"enum {enum_name}: String[^{{]*{{(.*?)\n}}", delivery, re.S).group(1)
            body = re.sub(r"///[^\n]*", "", body)
            names = {n.strip() for line in re.findall(r"case ([^\n]+)", body) for n in line.split(",")}
            self.assertEqual(set(receiver.KEY_RULES[key][1]), names, key)


if __name__ == "__main__":
    unittest.main()
