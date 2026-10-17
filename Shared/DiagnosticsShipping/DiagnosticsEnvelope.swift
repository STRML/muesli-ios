import Foundation

struct DiagnosticsDeviceInfo: Equatable, Sendable {
    var deviceID: String
    var appVersion: String
    var appBuild: String
    var iosVersion: String
    /// `utsname().machine`, for example `iPhone17,1`. Never `UIDevice.name`, which the user types.
    var deviceModel: String
    var thermalState: String
}

enum DiagnosticsFlushTrigger: String, Codable, Sendable {
    case timer, background, manual, size
}

/// The JSON body of `POST <base>/diagnostics`. The wire format is documented in `docs/diagnostics-shipping.md`.
struct DiagnosticsEnvelope: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    var schema = DiagnosticsEnvelope.schemaVersion
    var batchID: String
    var seq: Int
    var sentAt: String
    var deviceID: String
    var appVersion: String
    var appBuild: String
    var iosVersion: String
    var deviceModel: String
    var thermalState: String
    var trigger: DiagnosticsFlushTrigger
    var droppedEvents: Int
    var droppedFields: Int
    var rejectedEvents: Int
    var events: [DiagnosticsEvent]

    enum CodingKeys: String, CodingKey {
        case schema
        case batchID = "batch_id"
        case seq
        case sentAt = "sent_at"
        case deviceID = "device_id"
        case appVersion = "app_version"
        case appBuild = "app_build"
        case iosVersion = "ios_version"
        case deviceModel = "device_model"
        case thermalState = "thermal_state"
        case trigger
        case droppedEvents = "dropped_events"
        case droppedFields = "dropped_fields"
        case rejectedEvents = "rejected_events"
        case events
    }

    func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)) ?? Data()
    }
}
