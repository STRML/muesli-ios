import Foundation
@testable import DictationPolicyKit

/// Shared inputs for the readiness tests. One fixed clock, one build, and a record builder.
enum ReadinessFixtures {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    static let stamp = ReadinessBuildStamp(appVersion: "0.1.7", appBuild: "40", osVersion: "27.0")
    static let updatedStamp = ReadinessBuildStamp(appVersion: "0.1.8", appBuild: "41", osVersion: "27.0")
    static let newOSStamp = ReadinessBuildStamp(appVersion: "0.1.7", appBuild: "40", osVersion: "27.1")
    static let liveBoot = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    static let oldBoot = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    static func record(
        boot: UUID = liveBoot,
        stamp: ReadinessBuildStamp = ReadinessFixtures.stamp,
        heartbeatAge: TimeInterval = 0,
        model: ReadinessModelState = .ready,
        mic: ReadinessMicState = .ready,
        now: Date = t0
    ) -> AppReadinessRecord {
        AppReadinessRecord(
            boot: AppBootIdentity(id: boot, startedAt: now.addingTimeInterval(-600), stamp: stamp),
            heartbeatAt: now.addingTimeInterval(-heartbeatAge),
            model: model,
            mic: mic
        )
    }

    static func liveness(_ record: AppReadinessRecord?, now: Date = t0) -> AppLiveness {
        AppLivenessPolicy.liveness(record: record, keyboardStamp: stamp, now: now)
    }
}
