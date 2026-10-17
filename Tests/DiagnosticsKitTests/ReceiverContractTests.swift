import XCTest
@testable import DiagnosticsKit

/// The Studio receiver's validation rules, copied from STRML/local-llm#20 (`asr/asr_server/diag_validate.py` and the
/// size and count limits in `docs/asr-server.md`). The two sides must agree exactly: a bad `thermal` makes the server
/// reject the whole batch, and a float, a comma, an over-long or odd-character value makes it drop the event. If the
/// receiver's rules change, change this copy in the same pull request and the tests below show what no longer fits.
enum ReceiverContract {
    static let name = #"[A-Za-z0-9_.-]{1,64}"#
    static let value = #"[A-Za-z0-9_.:=/+\- ]{0,128}"#
    static let meta = #"[A-Za-z0-9_.:=/+, \-]{1,64}"#
    static let uuid = #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#
    static let time = #"[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}(:[0-9]{2}([.][0-9]{1,9})?)?(Z|[+-][0-9]{2}:?[0-9]{2})?"#
    static let forbiddenKeys: Set<String> = ["text", "transcript", "body", "content", "selected", "context", "title", "prompt", "audio"]
    static let thermal: Set<String> = ["nominal", "fair", "serious", "critical"]
    static let maxAttrs = 64
    static let maxEvents = 500
    static let maxBodyBytes = 256 * 1024
    static let intLimit = 9_007_199_254_740_992.0

    /// `fullmatch`, as the server applies it (`$` would accept a trailing newline).
    static func fullMatch(_ pattern: String, _ text: String) -> Bool {
        text.range(of: "\\A(?:\(pattern))\\z", options: .regularExpression) != nil
    }

    private static func isBool(_ number: NSNumber) -> Bool { CFGetTypeID(number) == CFBooleanGetTypeID() }
    private static func isFloat(_ number: NSNumber) -> Bool { !isBool(number) && CFNumberIsFloatType(number) }

    /// Everything the receiver would reject or drop, as readable strings. Empty means the batch is accepted whole.
    static func violations(in body: Data) -> [String] {
        var found: [String] = []
        if body.count > maxBodyBytes { found.append("body is \(body.count) bytes, over \(maxBodyBytes)") }
        guard let doc = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return ["not a JSON object"] }

        func uint(_ key: String) {
            guard let number = doc[key] as? NSNumber, !isBool(number), !isFloat(number),
                  number.doubleValue >= 0, number.doubleValue <= intLimit else { return found.append("invalid \(key)") }
        }
        func string(_ key: String, _ pattern: String, in dict: [String: Any]? = nil, label: String? = nil) {
            guard let text = (dict ?? doc)[key] as? String, fullMatch(pattern, text) else {
                return found.append("invalid \(label ?? key)")
            }
        }
        string("device_id", uuid)
        string("batch_id", uuid)
        uint("seq")
        uint("dropped")
        string("os", meta)
        string("model", meta)
        if let thermalState = doc["thermal"] as? String, thermal.contains(thermalState) {} else { found.append("invalid thermal") }
        if let app = doc["app"] as? [String: Any] {
            string("version", meta, in: app, label: "app.version")
            string("build", meta, in: app, label: "app.build")
        } else {
            found.append("invalid app")
        }
        guard let events = doc["events"] as? [[String: Any]] else { return found + ["invalid events"] }
        if events.count > maxEvents { found.append("too many events: \(events.count)") }
        for (index, event) in events.enumerated() {
            let label = "event \(index) (\(event["name"] as? String ?? "?"))"
            if let t = event["t"] as? String, fullMatch(time, t), t.count <= 40 {} else { found.append("\(label): bad t") }
            if let n = event["name"] as? String, fullMatch(name, n) {} else { found.append("\(label): bad name") }
            if let p = event["proc"] as? String, fullMatch(name, p) {} else { found.append("\(label): bad proc") }
            guard let attrs = event["attrs"] as? [String: Any], attrs.count <= maxAttrs else {
                found.append("\(label): bad attrs")
                continue
            }
            for (key, raw) in attrs {
                if !fullMatch(name, key) { found.append("\(label): bad key \(key)") }
                if forbiddenKeys.contains(key.lowercased()) { found.append("\(label): forbidden key \(key)") }
                if let number = raw as? NSNumber {
                    if isFloat(number) { found.append("\(label): float value for \(key)") }
                    else if !isBool(number), abs(number.doubleValue) > intLimit { found.append("\(label): big int for \(key)") }
                } else if let text = raw as? String {
                    if !fullMatch(value, text) { found.append("\(label): bad value for \(key): \(text.debugDescription)") }
                } else {
                    found.append("\(label): unsupported value type for \(key)")
                }
            }
        }
        return found
    }
}

final class ReceiverContractTests: XCTestCase {
    private func envelope(events: [DiagnosticsEvent], thermal: String = "nominal") -> DiagnosticsEnvelope {
        DiagnosticsEnvelope(
            batchID: UUID().uuidString, seq: 3, sentAt: DiagnosticsLogFormat.timestamp(Fixture.t0),
            deviceID: Fixture.device.deviceID, appVersion: "0.1.7", appBuild: "9", os: "iOS 26.0.1", model: "iPhone18,1",
            thermal: thermal, trigger: .timer, droppedEvents: 1, droppedFields: 2, rejectedEvents: 3, events: events
        )
    }

    private func sanitized(_ records: [DiagnosticsRecord]) -> [DiagnosticsEvent] {
        records.enumerated().compactMap { index, record in
            let text = DiagnosticsLogFormat.line(
                date: Fixture.t0.addingTimeInterval(Double(index) / 100), process: "Muesli", event: record.name, detail: record.fields
            ) + "\n"
            return DiagnosticsSanitizer.sanitize(DiagnosticsLogParser.parse(text).lines[0]).event
        }
    }

    static let allBuilders: [DiagnosticsRecord] = {
        let request = Fixture.request
        return [
            DiagnosticsEvents.stopReceived(request: request, source: "keyboard"),
            DiagnosticsEvents.stopIgnored(request: request, reason: .lifecycleRejected),
            DiagnosticsEvents.recordingStopped(request: request, durationMs: 6100, samples: 97_600, bytes: 195_200, fileWritten: true),
            DiagnosticsEvents.transcriptionStarted(request: request, model: "parakeet-tdt-v3", audioMs: 6100),
            DiagnosticsEvents.transcriptionFinished(request: request, model: "remote-custom-llm", durationMs: 810, source: .remote, characters: 120),
            DiagnosticsEvents.transcriptionFailed(request: request, model: "parakeet-tdt-v3", durationMs: 18_000, failure: .timeout, domain: "Muesli.VoiceNoteRetryError", code: 0),
            DiagnosticsEvents.resultPersisted(request: request, historyID: UUID(uuidString: "A1B2C3D4-0000-4000-8000-00000000AAAA"), characters: 120),
            DiagnosticsEvents.deliveryOutcome(request: request, route: .copyRequired, reason: .heartbeatStale, heartbeatAge: 4.25),
            DiagnosticsEvents.cancelled(request: request, by: .keyboardCommand, stage: .transcribing),
            DiagnosticsEvents.handoffSaved(request: request, phase: "copyRequired"),
            DiagnosticsEvents.backgroundTask(request: request, state: .expired, remaining: 0.4),
            DiagnosticsEvents.backgroundTask(request: nil, state: .begin, remaining: .greatestFiniteMagnitude),
            DiagnosticsEvents.memoryWarning(),
            DiagnosticsEvents.thermalState(.serious),
            DiagnosticsRecord(name: "dictation.exit", fields: [
                "request": request.uuidString, "outcome": "abandoned", "last_stage": "transcribing",
            ]),
            DiagnosticsRecord(name: "recorder_start_failed", fields: [
                "stage": "start", "step": "engineStart", "domain": "NSOSStatusErrorDomain", "code": "-50",
                "sample_rate": "48000.0", "channels": "1", "input_available": "true", "other_audio": "false",
                "input_ports": "MicrophoneBuiltIn,BluetoothHFP",
            ]),
            DiagnosticsRecord(name: "whisper.loaded", fields: ["variant": "small.en", "total_s": "12.34", "wall_s": "13.00"]),
            DiagnosticsRecord(name: "level.freshness", fields: ["fresh": "yes", "age": "0.4s", "appPhase": "recording"]),
        ]
    }()

    func testEveryStopToSaveEventTheAppBuildsIsAcceptedWhole() {
        let body = envelope(events: sanitized(Self.allBuilders)).encoded()
        XCTAssertEqual(ReceiverContract.violations(in: body), [])
        XCTAssertEqual(sanitized(Self.allBuilders).count, Self.allBuilders.count)
    }

    func testABatchTheEngineActuallyProducesIsAcceptedWhole() async {
        let rig = ScriptedTransport()
        let engine = Fixture.engine(transport: rig)
        let settings = DiagnosticsRunSettings(
            enabled: true,
            endpoint: DiagnosticsEndpoint(url: Fixture.endpointURL, host: "studio.tail13013.ts.net", looksPrivate: true, keyFingerprint: "k"),
            acknowledgedHost: nil
        )
        _ = await engine.run(settings: settings, logText: "", trigger: .timer)
        let lines = Self.allBuilders.enumerated().map { index, record in
            DiagnosticsLogFormat.line(date: Fixture.t0.addingTimeInterval(Double(index)), process: "Muesli", event: record.name, detail: record.fields)
        }
        _ = await engine.run(settings: settings, logText: lines.joined(separator: "\n") + "\n", trigger: .background)
        XCTAssertEqual(rig.sent.count, 1)
        for sent in rig.sent {
            XCTAssertEqual(ReceiverContract.violations(in: sent.envelope.encoded()), [])
        }
        XCTAssertEqual(rig.sent.first?.envelope.events.count, Self.allBuilders.count)
    }

    func testAHundredEventsWithLongValuesStayUnderTheBodyLimit() {
        let longValue = String(repeating: "a", count: 48)
        let fields = Dictionary(uniqueKeysWithValues: ["model", "variant", "source", "trigger", "kind", "error", "stage", "step", "caller", "file",
                                                       "category", "mode", "preference", "phase", "localPhase", "appPhase", "category_before",
                                                       "mode_before"].map { ($0, longValue) })
        let event = DiagnosticsEvent(id: "0123456789abcdef", time: DiagnosticsLogFormat.timestamp(Fixture.t0), process: "MuesliKeyboard", name: "audioSession.failed", fields: fields)
        let body = envelope(events: Array(repeating: event, count: DiagnosticsEngineConfig.standard.maxBatchEvents)).encoded()
        XCTAssertLessThan(body.count, ReceiverContract.maxBodyBytes)
        XCTAssertEqual(ReceiverContract.violations(in: body), [])
        XCTAssertLessThanOrEqual(DiagnosticsEngineConfig.standard.maxBatchEvents, ReceiverContract.maxEvents)
    }

    func testNoVocabularyEventOrKeyBreaksTheReceiversNameRulesOrIsForbidden() {
        for event in DiagnosticsVocabulary.events {
            XCTAssertTrue(ReceiverContract.fullMatch(ReceiverContract.name, event), event)
        }
        for key in DiagnosticsVocabulary.keyRules.keys {
            XCTAssertTrue(ReceiverContract.fullMatch(ReceiverContract.name, key), key)
            XCTAssertFalse(ReceiverContract.forbiddenKeys.contains(key.lowercased()), "\(key) is a key the receiver drops events for")
        }
    }

    func testEveryClosedValueIsInTheReceiversValueAlphabet() {
        for (key, rule) in DiagnosticsVocabulary.keyRules {
            guard case .oneOf(let values) = rule else { continue }
            for value in values { XCTAssertTrue(ReceiverContract.fullMatch(ReceiverContract.value, value), "\(key)=\(value)") }
        }
    }

    func testAnythingTheSanitizerAcceptsFitsTheReceiversValueAlphabet() {
        // One representative of each open shape, at its longest.
        let samples = [
            "04FCC3FC-0000-4000-8000-000000000001", "04fcc3fc", "none", "-123456789012", "48000.0", "-0.3s", "unlimited", "yes",
            String(repeating: "a", count: 48), "AVAudioSessionCategoryPlayAndRecord", "com.apple.coreaudio.avfaudio",
            "a.b:c-d_e", "Mic+Bluetooth",
        ]
        for sample in samples { XCTAssertTrue(ReceiverContract.fullMatch(ReceiverContract.value, sample), sample) }
    }

    // MARK: The contract copy has teeth

    func testAFloatThermalOddValueOrForbiddenKeyIsCaught() throws {
        func violations(editing edit: (inout [String: Any]) -> Void) throws -> [String] {
            var doc = try XCTUnwrap(JSONSerialization.jsonObject(
                with: envelope(events: sanitized([Self.allBuilders[2]])).encoded()
            ) as? [String: Any])
            edit(&doc)
            return ReceiverContract.violations(in: try JSONSerialization.data(withJSONObject: doc))
        }
        func editAttrs(_ change: @escaping (inout [String: Any]) -> Void) -> (inout [String: Any]) -> Void {
            { doc in
                var events = doc["events"] as! [[String: Any]]
                var attrs = events[0]["attrs"] as! [String: Any]
                change(&attrs)
                events[0]["attrs"] = attrs
                doc["events"] = events
            }
        }
        XCTAssertEqual(try violations { _ in }, [])
        XCTAssertFalse(try violations { $0["thermal"] = "unknown" }.isEmpty)
        XCTAssertFalse(try violations(editing: editAttrs { $0["duration_ms"] = 1.5 }).isEmpty, "a float drops the event")
        XCTAssertFalse(try violations(editing: editAttrs { $0["input_ports"] = "A,B" }).isEmpty, "a comma is outside the alphabet")
        XCTAssertFalse(try violations(editing: editAttrs { $0["Transcript"] = "x" }).isEmpty, "forbidden keys match any case")
        XCTAssertFalse(try violations(editing: editAttrs { $0["error"] = String(repeating: "a", count: 129) }).isEmpty)
        XCTAssertFalse(try violations(editing: editAttrs { $0["error"] = "line\n" }).isEmpty, "a trailing newline is not accepted")
        XCTAssertFalse(try violations { $0["device_id"] = "unknown" }.isEmpty)
    }

    // MARK: The sample batch for the Studio's end-to-end check

    private var sampleURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/diagnostics-sample-batch.json")
    }

    private func sampleEnvelope() -> DiagnosticsEnvelope {
        var sample = envelope(events: sanitized(Array(Self.allBuilders.prefix(11))))
        sample.batchID = "6F1C5E0A-2B77-4D0B-9C52-5B7A0D0E4C11"
        return sample
    }

    /// `docs/diagnostics-sample-batch.json` is what `curl` posts in the receiver's end-to-end check. It is the real
    /// encoder's output, so the doc cannot drift from the app. Regenerate with `WRITE_SAMPLE_BATCH=1 swift test`.
    func testTheSampleBatchOnDiskIsExactlyWhatTheEncoderProducesAndTheReceiverAcceptsIt() throws {
        let expected = sampleEnvelope().encoded()
        if ProcessInfo.processInfo.environment["WRITE_SAMPLE_BATCH"] == "1" {
            try expected.write(to: sampleURL)
        }
        let onDisk = try Data(contentsOf: sampleURL)
        XCTAssertEqual(String(decoding: onDisk, as: UTF8.self), String(decoding: expected, as: UTF8.self))
        XCTAssertEqual(ReceiverContract.violations(in: onDisk), [])
    }
}
