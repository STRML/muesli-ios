import Foundation

struct DiagnosticsDeviceInfo: Equatable, Sendable {
    var deviceID: String
    var appVersion: String
    var appBuild: String
    /// The version number only, for example `26.0.1`. The envelope's `os` field adds the `iOS ` prefix.
    var iosVersion: String
    /// `utsname().machine`, for example `iPhone17,1`. Never `UIDevice.name`, which the user types.
    var deviceModel: String
    var thermalState: String
}

enum DiagnosticsFlushTrigger: String, Codable, Sendable {
    case timer, background, manual, size
}

/// An attribute value as the receiver accepts it: a string, an integer or a bool. Never a float, which makes the
/// receiver drop the event.
enum DiagnosticsAttrValue: Codable, Equatable, Sendable {
    case string(String)
    case int(Int)
    case bool(Bool)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int.self) { self = .int(value) }
        else { self = .string(try container.decode(String.self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        }
    }

    /// The sanitized text value typed by its key's rule: integers and flags go out as JSON numbers and bools.
    static func typed(key: String, value: String) -> DiagnosticsAttrValue {
        switch DiagnosticsVocabulary.keyRules[key] {
        case .int?: Int(value).map(DiagnosticsAttrValue.int) ?? .string(value)
        case .flag?: ["true", "yes"].contains(value) ? .bool(true) : .bool(false)
        default: .string(value)
        }
    }

    var text: String {
        switch self {
        case .string(let value): value
        case .int(let value): String(value)
        case .bool(let value): String(value)
        }
    }
}

/// The JSON body of `POST <base>/diagnostics`, in the shape the Studio receiver validates (STRML/local-llm#20,
/// `asr/asr_server/diag_validate.py`). Fields the receiver does not know are ignored by it, so `schema`, `sent_at`,
/// `trigger` and the drop counters ride along. The wire format is documented in `docs/diagnostics-shipping.md`.
struct DiagnosticsEnvelope: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    var schema = DiagnosticsEnvelope.schemaVersion
    var batchID: String
    var seq: Int
    var sentAt: String
    var deviceID: String
    var appVersion: String
    var appBuild: String
    /// `iOS 26.0.1`
    var os: String
    var model: String
    /// One of `nominal fair serious critical`. Anything else makes the receiver reject the whole batch.
    var thermal: String
    var trigger: DiagnosticsFlushTrigger
    var droppedEvents: Int
    var droppedFields: Int
    var rejectedEvents: Int
    var events: [DiagnosticsEvent]

    private struct App: Codable, Equatable {
        var version: String
        var build: String
    }

    private struct WireEvent: Codable {
        var id: String
        var t: String
        var proc: String
        var name: String
        var attrs: [String: DiagnosticsAttrValue]
    }

    enum CodingKeys: String, CodingKey {
        case schema
        case batchID = "batch_id"
        case seq
        case sentAt = "sent_at"
        case deviceID = "device_id"
        case app, os, model, thermal, trigger, dropped
        case droppedEvents = "dropped_events"
        case droppedFields = "dropped_fields"
        case rejectedEvents = "rejected_events"
        case events
    }

    init(
        batchID: String, seq: Int, sentAt: String, deviceID: String, appVersion: String, appBuild: String,
        os: String, model: String, thermal: String, trigger: DiagnosticsFlushTrigger,
        droppedEvents: Int, droppedFields: Int, rejectedEvents: Int, events: [DiagnosticsEvent]
    ) {
        self.batchID = batchID
        self.seq = seq
        self.sentAt = sentAt
        self.deviceID = deviceID
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.os = os
        self.model = model
        self.thermal = thermal
        self.trigger = trigger
        self.droppedEvents = droppedEvents
        self.droppedFields = droppedFields
        self.rejectedEvents = rejectedEvents
        self.events = events
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decode(Int.self, forKey: .schema)
        batchID = try container.decode(String.self, forKey: .batchID)
        seq = try container.decode(Int.self, forKey: .seq)
        sentAt = try container.decode(String.self, forKey: .sentAt)
        deviceID = try container.decode(String.self, forKey: .deviceID)
        let app = try container.decode(App.self, forKey: .app)
        appVersion = app.version
        appBuild = app.build
        os = try container.decode(String.self, forKey: .os)
        model = try container.decode(String.self, forKey: .model)
        thermal = try container.decode(String.self, forKey: .thermal)
        trigger = try container.decode(DiagnosticsFlushTrigger.self, forKey: .trigger)
        droppedEvents = try container.decode(Int.self, forKey: .droppedEvents)
        droppedFields = try container.decode(Int.self, forKey: .droppedFields)
        rejectedEvents = try container.decode(Int.self, forKey: .rejectedEvents)
        events = try container.decode([WireEvent].self, forKey: .events).map {
            DiagnosticsEvent(id: $0.id, time: $0.t, process: $0.proc, name: $0.name, fields: $0.attrs.mapValues(\.text))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schema, forKey: .schema)
        try container.encode(batchID, forKey: .batchID)
        try container.encode(seq, forKey: .seq)
        try container.encode(sentAt, forKey: .sentAt)
        try container.encode(deviceID, forKey: .deviceID)
        try container.encode(App(version: appVersion, build: appBuild), forKey: .app)
        try container.encode(os, forKey: .os)
        try container.encode(model, forKey: .model)
        try container.encode(thermal, forKey: .thermal)
        try container.encode(trigger, forKey: .trigger)
        // The receiver's one counter: everything this device lost or refused since the last batch it got.
        try container.encode(droppedEvents + rejectedEvents, forKey: .dropped)
        try container.encode(droppedEvents, forKey: .droppedEvents)
        try container.encode(droppedFields, forKey: .droppedFields)
        try container.encode(rejectedEvents, forKey: .rejectedEvents)
        try container.encode(events.map { event in
            WireEvent(
                id: event.id, t: event.time, proc: event.process, name: event.name,
                attrs: Dictionary(uniqueKeysWithValues: event.fields.map { ($0.key, DiagnosticsAttrValue.typed(key: $0.key, value: $0.value)) })
            )
        }, forKey: .events)
    }

    func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)) ?? Data()
    }
}
